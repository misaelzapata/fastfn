local cjson = require "cjson.safe"
local routes = require "fastfn.core.routes"
local invoke_rules = require "fastfn.core.invoke_rules"

local M = {}

local CACHE = ngx.shared.fn_cache
local NAME_RE = "^[a-zA-Z0-9_-]+$"
local FILE_TARGET_RE = "^[a-zA-Z0-9_/%[%]%.%-]+$"
local VERSION_RE = "^[a-zA-Z0-9_.-]+$"
local MAX_CODE_BYTES = 2 * 1024 * 1024
local MAX_REQ_BYTES = 128 * 1024
local MAX_ROUTES_PER_FUNCTION = 32
local HIDDEN_SECRET_VALUE = "<hidden>"
local SECRET_KEY_PATTERNS = {
  "secret",
  "token",
  "password",
  "passwd",
  "pwd",
  "api_key",
  "apikey",
  "private_key",
  "auth",
  "credential",
}
local CONFIG_BASENAMES = {
  ["fn.config.json"] = true,
  ["fn.env.json"] = true,
  ["requirements.txt"] = true,
  ["package.json"] = true,
  ["package-lock.json"] = true,
  ["npm-shrinkwrap.json"] = true,
  ["composer.json"] = true,
  ["composer.lock"] = true,
  ["Cargo.toml"] = true,
  ["Cargo.lock"] = true,
}

local function sorted_keys(tbl)
  local keys = {}
  for k, _ in pairs(tbl or {}) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if not f then
    return false
  end
  f:close()
  return true
end

local function is_symlink(path)
  local cmd = string.format("[ -L %q ] && echo 1 || true", tostring(path))
  local p = io.popen(cmd)
  if not p then
    return false
  end
  local out = p:read("*l")
  p:close()
  return out == "1"
end

local function allowed_handler_filenames(runtime)
  if runtime == "python" then
    return { "app.py", "handler.py" }
  end
  if runtime == "node" then
    return { "app.js", "handler.js", "app.ts", "handler.ts" }
  end
  if runtime == "php" then
    return { "app.php", "handler.php" }
  end
  if runtime == "lua" then
    return { "app.lua", "handler.lua", "main.lua", "index.lua" }
  end
  if runtime == "rust" then
    return { "app.rs", "handler.rs" }
  end
  if runtime == "go" then
    return { "app.go", "handler.go", "main.go" }
  end
  return {}
end

local function detect_runtime_from_file_path(path)
  local ext = tostring(path):match("%.([A-Za-z0-9]+)$")
  if not ext then
    return nil
  end
  ext = string.lower(ext)
  if ext == "js" or ext == "ts" then
    return "node"
  end
  if ext == "py" then
    return "python"
  end
  if ext == "php" then
    return "php"
  end
  if ext == "lua" then
    return "lua"
  end
  if ext == "rs" then
    return "rust"
  end
  if ext == "go" then
    return "go"
  end
  return nil
end

local function is_file_target_name(name)
  if type(name) ~= "string" then
    return false
  end
  return name:find("/", 1, true) ~= nil or name:match("%.[A-Za-z0-9]+$") ~= nil
end

local function file_target_name_allowed(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  if not name:match(FILE_TARGET_RE) then
    return false
  end
  if name:sub(1, 1) == "/" or name:find("\\", 1, true) then
    return false
  end
  if name:find("//", 1, true) then
    return false
  end
  for segment in name:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      return false
    end
  end
  return true
end

local function function_name_allowed(name)
  if type(name) ~= "string" then
    return false
  end
  if name:match(NAME_RE) then
    return true
  end
  return file_target_name_allowed(name)
end

local function path_is_under(root, path)
  if type(root) ~= "string" or type(path) ~= "string" then
    return false
  end
  local base = root:gsub("/+$", "")
  if base == "" then
    return false
  end
  if path == base then
    return true
  end
  local prefix = base .. "/"
  return path:sub(1, #prefix) == prefix
end

local function default_handler_filename(runtime)
  local names = allowed_handler_filenames(runtime)
  return names[1]
end

local function handler_name_allowed(path, runtime)
  local name = tostring(path):match("([^/]+)$") or ""
  for _, filename in ipairs(allowed_handler_filenames(runtime)) do
    if name == filename then
      return true
    end
  end
  return false
end

local function config_name(path)
  return tostring(path):match("([^/]+)$")
end

local function is_allowed_config_path(path)
  local base = config_name(path)
  return CONFIG_BASENAMES[base] == true
end

local function dir_exists(path)
  local p = io.popen(string.format("[ -d %q ] && echo 1 || true", tostring(path)))
  if not p then
    return false
  end
  local out = p:read("*l")
  p:close()
  return out == "1"
end

local function ensure_dir(path)
  local ok = os.execute(string.format("mkdir -p %q", tostring(path)))
  return ok == true or ok == 0
end

local function rm_path(path)
  local ok = os.execute(string.format("rm -rf %q", tostring(path)))
  return ok == true or ok == 0
end

local function list_dirs(path)
  local p = io.popen(string.format("find %q -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null", tostring(path)))
  if not p then
    return {}
  end
  local out = {}
  for line in p:lines() do
    out[#out + 1] = line
  end
  p:close()
  table.sort(out)
  return out
end

local function version_children_count(path)
  local count = 0
  for _, _ in ipairs(list_dirs(path)) do
    count = count + 1
  end
  return count
end

local function default_handler_template(runtime)
  if runtime == "python" then
    return [[import json


def handler(event):
    query = event.get("query") or {}
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"query": query}, separators=(",", ":")),
    }
]]
  end
  if runtime == "node" then
    return [[exports.handler = async (event) => {
  const query = event.query || {};
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query }),
  };
};
]]
  end
  if runtime == "php" then
    return [[<?php

function handler(array $event): array
{
    $query = $event['query'] ?? [];
    return [
        'status' => 200,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode(['query' => $query], JSON_UNESCAPED_SLASHES),
    ];
}
]]
  end
  if runtime == "lua" then
    return [[local cjson = require("cjson.safe")

function handler(event)
    local query = (type(event) == "table" and event.query) or {}
    return {
        status = 200,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode({ query = query }),
    }
end
]]
  end
  if runtime == "rust" then
    return [[use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    let query = event.get("query").cloned().unwrap_or_else(|| json!({}));
    json!({
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json!({"query": query}).to_string()
    })
}
]]
  end
  if runtime == "go" then
    return [[package main

import "encoding/json"

func handler(event map[string]interface{}) map[string]interface{} {
    queryAny := event["query"]
    query, _ := queryAny.(map[string]interface{})

    body, _ := json.Marshal(map[string]interface{}{
        "runtime": "go",
        "query":   query,
    })

    return map[string]interface{}{
        "status": 200,
        "headers": map[string]interface{}{
            "Content-Type": "application/json",
        },
        "body": string(body),
    }
}
]]
  end
  return ""
end

local function normalize_methods_for_create(raw)
  local allowed = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true }
  local out = {}
  local seen = {}
  if type(raw) == "table" then
    for _, v in ipairs(raw) do
      local m = tostring(v):upper()
      if allowed[m] and not seen[m] then
        seen[m] = true
        out[#out + 1] = m
      end
    end
  end
  if #out == 0 then
    out = { "GET" }
  end
  return out
end

local function table_is_empty(tbl)
  if type(tbl) ~= "table" then
    return true
  end
  return next(tbl) == nil
end

local function env_enabled(name, default_value)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default_value
  end
  raw = string.lower(tostring(raw))
  if raw == "0" or raw == "false" or raw == "off" or raw == "no" then
    return false
  end
  if raw == "1" or raw == "true" or raw == "on" or raw == "yes" then
    return true
  end
  return default_value
end

local function read_file(path, max_bytes)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end

  local data
  if max_bytes then
    data = f:read(max_bytes + 1)
  else
    data = f:read("*a")
  end
  f:close()

  if not data then
    return nil
  end

  if max_bytes and #data > max_bytes then
    return data:sub(1, max_bytes), true
  end

  return data, false
end

local function write_file(path, data)
  if is_symlink(path) then
    return nil, "symlink target is not allowed"
  end
  local f, err = io.open(path, "wb")
  if not f then
    return nil, err
  end
  f:write(data)
  f:close()
  return true
end

local function detect_app_file(dir, runtime)
  for _, filename in ipairs(allowed_handler_filenames(runtime)) do
    local path = dir .. "/" .. filename
    if file_exists(path) and not is_symlink(path) then
      return path
    end
  end
  return nil
end

local function read_json_file(path)
  if is_symlink(path) then
    return nil
  end
  local raw = read_file(path, 256 * 1024)
  if not raw then
    return nil
  end

  local obj = cjson.decode(raw)
  if type(obj) ~= "table" then
    return nil
  end

  return obj
end

local function copy_table(tbl)
  if type(tbl) ~= "table" then
    return {}
  end
  local out = {}
  for k, v in pairs(tbl) do
    out[k] = v
  end
  return out
end

local function is_potential_secret_key(key)
  local lower = string.lower(tostring(key))
  for _, pattern in ipairs(SECRET_KEY_PATTERNS) do
    if string.find(lower, pattern, 1, true) then
      return true
    end
  end
  return false
end

local function normalize_env_file(env)
  local out = {}
  if type(env) ~= "table" then
    return out
  end

  for k, v in pairs(env) do
    if type(k) == "string" then
      if type(v) == "table" and v.value ~= nil then
        local value = v.value
        if value ~= cjson.null then
          local value_type = type(value)
          if value_type == "string" or value_type == "number" or value_type == "boolean" then
            out[k] = {
              value = value,
              is_secret = v.is_secret == true,
            }
          end
        end
      elseif v ~= cjson.null then
        local value_type = type(v)
        if value_type == "string" or value_type == "number" or value_type == "boolean" then
          out[k] = {
            value = v,
            is_secret = is_potential_secret_key(k),
          }
        end
      end
    end
  end
  return out
end

local function scalar_value(v)
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" then
    return v
  end
  return tostring(v)
end

local function build_env_view(env_tbl)
  local out = {}
  for _, key in ipairs(sorted_keys(env_tbl or {})) do
    local entry = env_tbl[key] or {}
    local is_secret = entry.is_secret == true
    local raw = entry.value
    out[key] = {
      is_secret = is_secret,
      value = is_secret and HIDDEN_SECRET_VALUE or scalar_value(raw),
    }
  end
  return out
end

local function extract_inline_requirements(path)
  local out = {}
  local seen = {}

  local f = io.open(path, "rb")
  if not f then
    return out
  end

  for _ = 1, 40 do
    local line = f:read("*l")
    if not line then
      break
    end
    local reqs = line:match("^%s*#@?requirements%s+(.+)%s*$")
    if reqs then
      reqs = reqs:gsub(",", " ")
      for token in reqs:gmatch("%S+") do
        if not seen[token] then
          seen[token] = true
          out[#out + 1] = token
        end
      end
    end
  end

  f:close()
  table.sort(out)
  return out
end

local function parse_requirements_file(raw)
  local out = {}
  local seen = {}
  if not raw then
    return out
  end

  for line in raw:gmatch("[^\r\n]+") do
    local value = line:gsub("^%s+", ""):gsub("%s+$", "")
    if value ~= "" and not value:match("^#") then
      local dep = value:match("^([^=<>!~%s]+)") or value
      if dep ~= "" and not seen[dep] then
        seen[dep] = true
        out[#out + 1] = dep
      end
    end
  end

  table.sort(out)
  return out
end

local function parse_dependency_keys_from_json(path, field_name)
  local obj = read_json_file(path)
  if type(obj) ~= "table" then
    return {}, false
  end
  local deps = obj[field_name]
  if type(deps) ~= "table" then
    return {}, true
  end
  return sorted_keys(deps), true
end

local function parse_cargo_dependency_names(raw)
  local out = {}
  local seen = {}
  local in_section = false

  if type(raw) ~= "string" then
    return out
  end

  for line in raw:gmatch("[^\r\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed:match("^%[.+%]$") then
      in_section = trimmed:match("^%[dependencies")
    elseif in_section and trimmed ~= "" and not trimmed:match("^#") then
      local key = trimmed:match("^([%w%._%-]+)%s*=")
      if key and not seen[key] then
        seen[key] = true
        out[#out + 1] = key
      end
    end
  end

  table.sort(out)
  return out
end

local function parse_methods(raw)
  return invoke_rules.normalized_methods(raw, { "GET" })
end

local function normalize_single_route(raw)
  return invoke_rules.normalize_route(raw)
end

local function parse_invoke_routes(input)
  return invoke_rules.parse_route_list(input, MAX_ROUTES_PER_FUNCTION)
end

local function normalize_routes_from_invoke(invoke_cfg)
  if type(invoke_cfg) ~= "table" then
    return nil
  end
  local routes_out = {}
  local seen = {}

  local function merge(list)
    for _, route in ipairs(list) do
      if not seen[route] then
        seen[route] = true
        routes_out[#routes_out + 1] = route
      end
      if #routes_out >= MAX_ROUTES_PER_FUNCTION then
        break
      end
    end
  end

  if invoke_cfg.route ~= nil then
    merge(parse_invoke_routes(invoke_cfg.route))
  end
  if invoke_cfg.routes ~= nil then
    merge(parse_invoke_routes(invoke_cfg.routes))
  end

  if #routes_out == 0 then
    if invoke_cfg.route ~= nil or invoke_cfg.routes ~= nil then
      return {}
    end
    return nil
  end

  return routes_out
end

local function validate_invoke_routes_payload(invoke_cfg)
  if type(invoke_cfg) ~= "table" then
    return nil
  end
  local provided = false
  local had_invalid = false

  local function check(raw)
    if raw == nil then
      return
    end
    provided = true
    if type(raw) == "string" then
      if normalize_single_route(raw) == nil then
        had_invalid = true
      end
      return
    end
    if type(raw) ~= "table" then
      had_invalid = true
      return
    end
    for _, v in ipairs(raw) do
      if normalize_single_route(v) == nil then
        had_invalid = true
        return
      end
    end
  end

  check(invoke_cfg.route)
  check(invoke_cfg.routes)

  if provided and had_invalid then
    return nil, "invoke.routes must contain valid URL paths (absolute, non-reserved)"
  end
  return true
end

local function normalize_allow_hosts_payload(raw)
  if raw == nil then
    return nil
  end
  if raw == cjson.null then
    return cjson.null
  end

  local items = {}
  if type(raw) == "string" then
    for token in raw:gmatch("[^,]+") do
      items[#items + 1] = token
    end
  elseif type(raw) == "table" then
    items = raw
  else
    return nil, "invoke.allow_hosts must be an array of host strings or null"
  end

  local out = {}
  local seen = {}
  for _, item in ipairs(items) do
    if type(item) ~= "string" then
      return nil, "invoke.allow_hosts must be an array of host strings or null"
    end
    local host = item:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if host ~= "" then
      if #host > 200 then
        return nil, "invoke.allow_hosts host length must be <= 200"
      end
      if host:find("[/%s]") then
        return nil, "invoke.allow_hosts host entries may not include spaces or '/'"
      end
      if not host:match("^[a-z0-9%*%-%._:%[%]]+$") then
        return nil, "invoke.allow_hosts contains invalid host characters"
      end
      if not seen[host] then
        seen[host] = true
        out[#out + 1] = host
      end
    end
  end

  return out
end

local function parse_handler_hints(path)
  local hints = {}
  local f = io.open(path, "rb")
  if not f then
    return hints
  end

  for _ = 1, 80 do
    local line = f:read("*l")
    if not line then
      break
    end

    local key, value = line:match("^%s*#%s*@([a-zA-Z_]+)%s+(.+)%s*$")
    if not key then
      key, value = line:match("^%s*//%s*@([a-zA-Z_]+)%s+(.+)%s*$")
    end
    if key and value then
      key = string.lower(key)
      if key == "summary" then
        hints.summary = value
      elseif key == "methods" then
        hints.methods = parse_methods(value)
      elseif key == "query" then
        local parsed = cjson.decode(value)
        if type(parsed) == "table" then
          hints.query_example = parsed
        end
      elseif key == "body" then
        hints.body_example = value
      elseif key == "content_type" then
        hints.content_type = value
      end
    end
  end

  f:close()
  return hints
end

local function normalize_invoke_config(invoke_cfg)
  if type(invoke_cfg) ~= "table" then
    return {}
  end

  local out = {}
  if type(invoke_cfg.summary) == "string" and invoke_cfg.summary ~= "" then
    out.summary = invoke_cfg.summary
  end
  if invoke_cfg.methods ~= nil then
    out.methods = parse_methods(invoke_cfg.methods)
  end
  if type(invoke_cfg.query) == "table" then
    out.query_example = invoke_cfg.query
  end
  if invoke_cfg.body ~= nil then
    if type(invoke_cfg.body) == "string" then
      out.body_example = invoke_cfg.body
    else
      local encoded = cjson.encode(invoke_cfg.body)
      if encoded then
        out.body_example = encoded
      end
    end
  end
  if type(invoke_cfg.content_type) == "string" and invoke_cfg.content_type ~= "" then
    out.content_type = invoke_cfg.content_type
  end
  if type(invoke_cfg.default_method) == "string" then
    out.default_method = string.upper(invoke_cfg.default_method)
  end
  if type(invoke_cfg.handler) == "string" then
    local h = invoke_cfg.handler:gsub("^%s+", ""):gsub("%s+$", "")
    if h ~= "" and h:match("^[A-Za-z_][A-Za-z0-9_]*$") then
      out.handler = h
    end
  end
  local routes_cfg = normalize_routes_from_invoke(invoke_cfg)
  if routes_cfg ~= nil then
    out.routes = routes_cfg
  end
  if invoke_cfg.allow_hosts ~= nil then
    local hosts = normalize_allow_hosts_payload(invoke_cfg.allow_hosts)
    if type(hosts) == "table" then
      out.allow_hosts = hosts
    end
  end
  return out
end

local function build_query_string(query_obj)
  if type(query_obj) ~= "table" then
    return ""
  end

  local parts = {}
  for _, k in ipairs(sorted_keys(query_obj)) do
    local v = query_obj[k]
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then
      local key = ngx.escape_uri(k)
      local val = ngx.escape_uri(tostring(v))
      parts[#parts + 1] = key .. "=" .. val
    end
  end

  return table.concat(parts, "&")
end

local function merge_unique_routes(primary, extra)
  local out = {}
  local seen = {}
  local function push(v)
    if type(v) == "string" and v ~= "" and not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  for _, v in ipairs(type(primary) == "table" and primary or {}) do
    push(v)
  end
  for _, v in ipairs(type(extra) == "table" and extra or {}) do
    push(v)
  end
  return out
end

local function mapped_public_routes_for_target(runtime, name, version)
  local catalog = routes.discover_functions(false)
  local mapped = (catalog and catalog.mapped_routes) or {}
  local out = {}

  for _, route in ipairs(sorted_keys(mapped)) do
    local entries = mapped[route]
    if type(entries) == "table" and entries.runtime ~= nil then
      entries = { entries }
    end
    if type(entries) == "table" then
      for _, entry in ipairs(entries) do
        if type(entry) == "table"
          and entry.runtime == runtime
          and entry.fn_name == name
          and (entry.version or nil) == (version or nil) then
          out[#out + 1] = route
          break
        end
      end
    end
  end

  return out
end

local function merge_invoke(route, hint_invoke, config_invoke)
  local methods = config_invoke.methods or hint_invoke.methods or { "GET" }
  local query_example = config_invoke.query_example
  if type(query_example) ~= "table" then
    query_example = hint_invoke.query_example
  end
  if type(query_example) ~= "table" then
    query_example = {}
  end

  local body_example = config_invoke.body_example
  if body_example == nil then
    body_example = hint_invoke.body_example
  end
  if body_example == nil then
    body_example = ""
  end

  local summary = config_invoke.summary or hint_invoke.summary
  local content_type = config_invoke.content_type or hint_invoke.content_type
  local default_method = config_invoke.default_method or methods[1] or "GET"
  local handler_name = type(config_invoke.handler) == "string" and config_invoke.handler or nil
  local mapped_routes = type(config_invoke.routes) == "table" and config_invoke.routes or {}
  local allow_hosts = type(config_invoke.allow_hosts) == "table" and config_invoke.allow_hosts or nil
  local primary_route = (#mapped_routes > 0 and mapped_routes[1]) or route

  local query_string = build_query_string(query_example)
  local full_route = primary_route
  if query_string ~= "" then
    full_route = full_route .. "?" .. query_string
  end

  local public_routes = {}
  local seen = {}
  local function push_unique(v)
    if type(v) == "string" and v ~= "" and not seen[v] then
      seen[v] = true
      public_routes[#public_routes + 1] = v
    end
  end
  push_unique(primary_route)
  push_unique(route)
  for _, r in ipairs(mapped_routes) do
    push_unique(r)
  end

  return {
    summary = summary,
    methods = methods,
    default_method = default_method,
    handler = handler_name,
    query_example = query_example,
    body_example = body_example,
    content_type = content_type,
    route = primary_route,
    canonical_route = route,
    mapped_routes = mapped_routes,
    allow_hosts = allow_hosts,
    public_routes = public_routes,
    full_route_example = full_route,
    curl_get_example = "curl -sS 'http://127.0.0.1:8080" .. full_route .. "'",
  }
end

local function build_fn_dir(functions_root, runtime, name, version)
  local base = string.format("%s/%s/%s", functions_root, runtime, name)
  if version and version ~= "" then
    return base .. "/" .. version
  end
  return base
end

local function ensure_function_exists(runtime, name, version)
  local policy, err = routes.resolve_function_policy(runtime, name, version)
  if not policy then
    return nil, err
  end
  return policy
end

local function resolve_function_paths(cfg, runtime, name, version)
  local is_file_target = is_file_target_name(name)
  if is_file_target then
    if version ~= nil and version ~= "" then
      return nil, "version not supported for file targets"
    end
    if not file_target_name_allowed(name) then
      return nil, "invalid function"
    end

    local app_path = cfg.functions_root .. "/" .. name
    local fn_dir = app_path:match("^(.*)/[^/]+$") or cfg.functions_root
    if not path_is_under(cfg.functions_root, fn_dir) or not path_is_under(cfg.functions_root, app_path) then
      return nil, "invalid function path"
    end
    if is_symlink(app_path) then
      return nil, "invalid function code path"
    end
    if not file_exists(app_path) then
      return nil, "function code not found"
    end
    local detected = detect_runtime_from_file_path(app_path)
    if detected and detected ~= runtime then
      return nil, "runtime mismatch for function file"
    end

    return {
      fn_dir = fn_dir,
      app_path = app_path,
      conf_path = fn_dir .. "/fn.config.json",
      env_path = fn_dir .. "/fn.env.json",
    }
  end

  local fn_dir = build_fn_dir(cfg.functions_root, runtime, name, version)
  if not path_is_under(cfg.functions_root, fn_dir) then
    return nil, "invalid function path"
  end
  local app_path = detect_app_file(fn_dir, runtime)
  if not app_path then
    return nil, "function code not found"
  end
  if not path_is_under(fn_dir, app_path) or not handler_name_allowed(app_path, runtime) then
    return nil, "invalid function code path"
  end

  return {
    fn_dir = fn_dir,
    app_path = app_path,
    conf_path = fn_dir .. "/fn.config.json",
    env_path = fn_dir .. "/fn.env.json",
  }
end

local function normalize_config_payload(payload)
  if type(payload) ~= "table" then
    return nil, "payload must be an object"
  end

  local out = {}

  if payload.group ~= nil then
    if payload.group == cjson.null then
      out.group = cjson.null
    elseif type(payload.group) ~= "string" then
      return nil, "group must be a string"
    else
      local v = payload.group:gsub("^%s+", ""):gsub("%s+$", "")
      if v == "" then
        out.group = cjson.null
      elseif #v > 80 then
        return nil, "group must be <= 80 chars"
      else
        out.group = v
      end
    end
  end

  if payload.timeout_ms ~= nil then
    local v = tonumber(payload.timeout_ms)
    if not v or v <= 0 then
      return nil, "timeout_ms must be > 0"
    end
    out.timeout_ms = math.floor(v)
  end

  if payload.max_concurrency ~= nil then
    local v = tonumber(payload.max_concurrency)
    if v == nil or v < 0 then
      return nil, "max_concurrency must be >= 0"
    end
    out.max_concurrency = math.floor(v)
  end

  if payload.max_body_bytes ~= nil then
    local v = tonumber(payload.max_body_bytes)
    if not v or v <= 0 then
      return nil, "max_body_bytes must be > 0"
    end
    out.max_body_bytes = math.floor(v)
  end

  if payload.include_debug_headers ~= nil then
    out.include_debug_headers = payload.include_debug_headers == true
  end

  local methods_input = nil
  if payload.methods ~= nil then
    methods_input = payload.methods
  end
  if type(payload.invoke) == "table" and payload.invoke.methods ~= nil then
    methods_input = payload.invoke.methods
  end
  if methods_input ~= nil then
    local methods = parse_methods(methods_input)
    if type(methods) ~= "table" or #methods == 0 then
      return nil, "methods must include at least one valid method"
    end
    out.invoke = {
      methods = methods,
    }
  end

  if type(payload.invoke) == "table" then
    local ok_routes, routes_err = validate_invoke_routes_payload(payload.invoke)
    if not ok_routes then
      return nil, routes_err
    end
    local invoke_routes = normalize_routes_from_invoke(payload.invoke)
    if invoke_routes ~= nil then
      if out.invoke == nil then
        out.invoke = {}
      end
      out.invoke.routes = invoke_routes
    end

    if payload.invoke.handler ~= nil then
      if out.invoke == nil then
        out.invoke = {}
      end

      local raw_handler = payload.invoke.handler
      if raw_handler == cjson.null then
        out.invoke.handler = cjson.null
      elseif type(raw_handler) ~= "string" then
        return nil, "invoke.handler must be a string or null"
      else
        local h = raw_handler:gsub("^%s+", ""):gsub("%s+$", "")
        if h == "" then
          out.invoke.handler = cjson.null
        elseif not h:match("^[A-Za-z_][A-Za-z0-9_]*$") then
          return nil, "invoke.handler must match ^[A-Za-z_][A-Za-z0-9_]*$"
        else
          out.invoke.handler = h
        end
      end
    end

    if payload.invoke.allow_hosts ~= nil then
      if out.invoke == nil then
        out.invoke = {}
      end
      local hosts, hosts_err = normalize_allow_hosts_payload(payload.invoke.allow_hosts)
      if hosts_err then
        return nil, hosts_err
      end
      out.invoke.allow_hosts = hosts
    end
  end

  if payload.response ~= nil then
    if type(payload.response) ~= "table" then
      return nil, "response must be an object"
    end

    local response = {}
    if payload.response.include_debug_headers ~= nil then
      response.include_debug_headers = payload.response.include_debug_headers == true
    end

    if next(response) ~= nil then
      out.response = response
    end
  end

  if payload.schedule ~= nil then
    if payload.schedule == cjson.null then
      out.schedule = cjson.null
    elseif type(payload.schedule) ~= "table" then
      return nil, "schedule must be an object"
    else
      local sched = {}
      if payload.schedule.enabled ~= nil then
        sched.enabled = payload.schedule.enabled == true
      end
      if payload.schedule.every_seconds ~= nil then
        local v = tonumber(payload.schedule.every_seconds)
        if not v or v <= 0 then
          return nil, "schedule.every_seconds must be > 0"
        end
        sched.every_seconds = math.floor(v)
      end
      if payload.schedule.cron ~= nil then
        if payload.schedule.cron == cjson.null then
          sched.cron = cjson.null
        elseif type(payload.schedule.cron) ~= "string" then
          return nil, "schedule.cron must be a string or null"
        else
          local expr = payload.schedule.cron:gsub("^%s+", ""):gsub("%s+$", "")
          if expr == "" then
            return nil, "schedule.cron must be a non-empty string"
          end
          if expr:sub(1, 1) == "@" then
            local macro = expr:lower()
            local allowed = {
              ["@yearly"] = true,
              ["@annually"] = true,
              ["@monthly"] = true,
              ["@weekly"] = true,
              ["@daily"] = true,
              ["@midnight"] = true,
              ["@hourly"] = true,
            }
            if not allowed[macro] then
              return nil, "schedule.cron must be 5/6-field cron or a supported @macro"
            end
          else
            local fields = 0
            for _ in expr:gmatch("%S+") do
              fields = fields + 1
            end
            if fields ~= 5 and fields ~= 6 then
              return nil, "schedule.cron must have 5 or 6 fields"
            end
          end
          sched.cron = expr
        end
      end
      if payload.schedule.timezone ~= nil then
        if payload.schedule.timezone == cjson.null then
          sched.timezone = cjson.null
        elseif type(payload.schedule.timezone) ~= "string" then
          return nil, "schedule.timezone must be a string or null"
        else
          local tz = payload.schedule.timezone:gsub("^%s+", ""):gsub("%s+$", "")
          if tz == "" then
            return nil, "schedule.timezone must be non-empty when set"
          end
          local lower = tz:lower()
          if not (lower == "utc" or lower == "local" or tz == "Z" or tz:match("^[+-]%d%d:?%d%d$")) then
            return nil, "schedule.timezone must be UTC, local, Z, or a fixed offset (+HH:MM)"
          end
          sched.timezone = tz
        end
      end
      if payload.schedule.retry ~= nil then
        if payload.schedule.retry == cjson.null then
          sched.retry = cjson.null
        elseif type(payload.schedule.retry) == "boolean" then
          sched.retry = payload.schedule.retry == true
        elseif type(payload.schedule.retry) ~= "table" then
          return nil, "schedule.retry must be a boolean, object, or null"
        else
          local r = {}
          if payload.schedule.retry.enabled ~= nil then
            r.enabled = payload.schedule.retry.enabled == true
          end
          if payload.schedule.retry.max_attempts ~= nil then
            local v = tonumber(payload.schedule.retry.max_attempts)
            if not v or v < 1 then
              return nil, "schedule.retry.max_attempts must be >= 1"
            end
            v = math.floor(v)
            if v > 10 then
              v = 10
            end
            r.max_attempts = v
          end
          if payload.schedule.retry.base_delay_seconds ~= nil then
            local v = tonumber(payload.schedule.retry.base_delay_seconds)
            if v == nil or v < 0 then
              return nil, "schedule.retry.base_delay_seconds must be >= 0"
            end
            if v > 3600 then
              v = 3600
            end
            r.base_delay_seconds = v
          end
          if payload.schedule.retry.max_delay_seconds ~= nil then
            local v = tonumber(payload.schedule.retry.max_delay_seconds)
            if v == nil or v < 0 then
              return nil, "schedule.retry.max_delay_seconds must be >= 0"
            end
            if v > 3600 then
              v = 3600
            end
            r.max_delay_seconds = v
          end
          if payload.schedule.retry.jitter ~= nil then
            local v = tonumber(payload.schedule.retry.jitter)
            if v == nil or v < 0 then
              return nil, "schedule.retry.jitter must be >= 0"
            end
            if v > 0.5 then
              v = 0.5
            end
            r.jitter = v
          end
          if r.base_delay_seconds ~= nil and r.max_delay_seconds ~= nil and r.max_delay_seconds < r.base_delay_seconds then
            return nil, "schedule.retry.max_delay_seconds must be >= base_delay_seconds"
          end
          if next(r) == nil then
            return nil, "schedule.retry must include at least one field"
          end
          sched.retry = r
        end
      end
      if payload.schedule.method ~= nil then
        local m = tostring(payload.schedule.method):upper()
        if not invoke_rules.ALLOWED_METHODS[m] then
          return nil, "schedule.method must be a valid HTTP method"
        end
        sched.method = m
      end
      if payload.schedule.query ~= nil then
        if type(payload.schedule.query) ~= "table" then
          return nil, "schedule.query must be an object"
        end
        sched.query = payload.schedule.query
      end
      if payload.schedule.headers ~= nil then
        if type(payload.schedule.headers) ~= "table" then
          return nil, "schedule.headers must be an object"
        end
        sched.headers = payload.schedule.headers
      end
      if payload.schedule.body ~= nil then
        if type(payload.schedule.body) == "string" then
          sched.body = payload.schedule.body
        else
          sched.body = tostring(payload.schedule.body)
        end
      end
      if payload.schedule.context ~= nil then
        if type(payload.schedule.context) ~= "table" then
          return nil, "schedule.context must be an object"
        end
        sched.context = payload.schedule.context
      end
      out.schedule = sched
    end
  end

  if payload.shared_deps ~= nil or payload.sharedDeps ~= nil or payload.deps ~= nil then
    local raw = payload.shared_deps
    if raw == nil then
      raw = payload.sharedDeps
    end
    if raw == nil then
      raw = payload.deps
    end

    if raw == cjson.null then
      out.shared_deps = cjson.null
    elseif type(raw) == "string" then
      local packs = {}
      local seen = {}
      for part in raw:gmatch("[^\n,]+") do
        local v = part:gsub("^%s+", ""):gsub("%s+$", "")
        if v ~= "" then
          if not v:match(NAME_RE) then
            return nil, "shared_deps entries must match " .. NAME_RE
          end
          if not seen[v] then
            seen[v] = true
            packs[#packs + 1] = v
          end
        end
      end
      out.shared_deps = packs
    elseif type(raw) == "table" then
      local packs = {}
      local seen = {}
      for _, v in ipairs(raw) do
        local s = tostring(v)
        if not s:match(NAME_RE) then
          return nil, "shared_deps entries must match " .. NAME_RE
        end
        if not seen[s] then
          seen[s] = true
          packs[#packs + 1] = s
        end
      end
      out.shared_deps = packs
    else
      return nil, "shared_deps must be an array of strings, a string, or null"
    end
  end

  if payload.edge ~= nil then
    if payload.edge == cjson.null then
      out.edge = cjson.null
    elseif type(payload.edge) ~= "table" then
      return nil, "edge must be an object"
    else
      local edge_in = payload.edge
      local edge_out = {}

      if edge_in.base_url ~= nil then
        if edge_in.base_url == cjson.null then
          edge_out.base_url = cjson.null
        else
          local v = tostring(edge_in.base_url)
          v = v:gsub("^%s+", ""):gsub("%s+$", "")
          if v == "" then
            return nil, "edge.base_url must be a non-empty string"
          end
          edge_out.base_url = v
        end
      end

      if edge_in.allow_hosts ~= nil then
        if edge_in.allow_hosts == cjson.null then
          edge_out.allow_hosts = cjson.null
        elseif type(edge_in.allow_hosts) ~= "table" then
          return nil, "edge.allow_hosts must be an array"
        else
          local hosts = {}
          local seen = {}
          for _, item in ipairs(edge_in.allow_hosts) do
            local s = tostring(item):gsub("^%s+", ""):gsub("%s+$", "")
            if s ~= "" and not seen[s] then
              seen[s] = true
              hosts[#hosts + 1] = s
            end
          end
          edge_out.allow_hosts = hosts
        end
      end

      if edge_in.allow_private ~= nil then
        edge_out.allow_private = edge_in.allow_private == true
      end

      if edge_in.max_response_bytes ~= nil then
        if edge_in.max_response_bytes == cjson.null then
          edge_out.max_response_bytes = cjson.null
        else
          local v = tonumber(edge_in.max_response_bytes)
          if not v or v <= 0 then
            return nil, "edge.max_response_bytes must be > 0"
          end
          edge_out.max_response_bytes = math.floor(v)
        end
      end

      out.edge = edge_out
    end
  end

  return out
end

local function normalize_env_payload(payload)
  if type(payload) ~= "table" then
    return nil, "payload must be an object"
  end

  local updates = {}
  for k, v in pairs(payload) do
    if type(k) ~= "string" or k == "" then
      return nil, "env keys must be non-empty strings"
    end

    if type(v) == "table" then
      local update = {
        is_secret = v.is_secret == true,
      }
      local env_value = v.value
      if env_value == cjson.null then
        update.delete = true
      elseif env_value == HIDDEN_SECRET_VALUE then
        update.keep_hidden = true
      elseif env_value == nil then
        return nil, "env entry objects must include value"
      else
        local value_type = type(env_value)
        if value_type == "string" or value_type == "number" or value_type == "boolean" then
          update.value = env_value
        else
          return nil, "env value must be string|number|boolean|null"
        end
      end
      updates[k] = update
    else
      local value_type = type(v)
      if value_type == "string" or value_type == "number" or value_type == "boolean" then
        updates[k] = { value = v }
      elseif v == cjson.null then
        updates[k] = { delete = true }
      elseif v == nil then
        -- no-op
      else
        return nil, "env values must be string|number|boolean|null or {value,is_secret}"
      end
    end
  end

  return {
    updates = updates,
  }
end

local function sched_state_key(runtime, name, version, suffix)
  local v = version or "default"
  local key = runtime .. "/" .. name .. "@" .. v
  return "sched:" .. key .. ":" .. suffix
end

local function function_state(runtime, name, version, keep_warm_cfg)
  local key = runtime .. "/" .. name .. "@" .. (version or "default")
  local warm_at = CACHE:get("warm:" .. key)
  local state = "cold"
  local idle_ttl = nil
  if type(keep_warm_cfg) == "table" then
    idle_ttl = tonumber(keep_warm_cfg.idle_ttl_seconds)
  end
  if warm_at ~= nil then
    if idle_ttl and idle_ttl > 0 and (ngx.now() - tonumber(warm_at)) > idle_ttl then
      state = "stale"
    else
      state = "warm"
    end
  end
  return {
    key = key,
    state = state,
    warm_at = warm_at,
    keep_warm = keep_warm_cfg,
    keep_warm_next = CACHE:get(sched_state_key(runtime, name, version, "keep_warm_next")),
    keep_warm_last = CACHE:get(sched_state_key(runtime, name, version, "keep_warm_last")),
    keep_warm_last_status = CACHE:get(sched_state_key(runtime, name, version, "keep_warm_last_status")),
    keep_warm_last_error = CACHE:get(sched_state_key(runtime, name, version, "keep_warm_last_error")),
  }
end

function M.catalog()
  local cfg = routes.get_config()
  local catalog = routes.discover_functions(false)

  local out = {
    generated_at = ngx.now(),
    functions_root = cfg.functions_root,
    defaults = cfg.defaults,
    runtime_order = cfg.runtime_order,
    mapped_routes = catalog.mapped_routes or {},
    mapped_route_conflicts = catalog.mapped_route_conflicts or {},
    runtimes = {},
  }

  for _, runtime in ipairs(sorted_keys(catalog.runtimes or {})) do
    local rt_cfg = (cfg.runtimes or {})[runtime] or {}
    local rt_src = (catalog.runtimes or {})[runtime] or { functions = {} }

    local rt_out = {
      socket = rt_cfg.socket,
      timeout_ms = rt_cfg.timeout_ms,
      health = routes.runtime_status(runtime),
      functions = {},
    }

    local fn_index = {}
    local function ensure_fn_entry(name)
      local existing = fn_index[name]
      if existing then
        return existing
      end
      local created = {
        name = name,
        has_default = false,
        versions = {},
        policy = { methods = {}, routes = {} },
        versions_policy = {},
        default_state = nil,
        versions_state = {},
        _methods_seen = {},
        _routes_seen = {},
      }
      fn_index[name] = created
      return created
    end

    for _, name in ipairs(sorted_keys(rt_src.functions or {})) do
      local fn_entry = rt_src.functions[name] or {}
      local out_entry = ensure_fn_entry(name)
      out_entry.has_default = fn_entry.has_default == true
      out_entry.versions = fn_entry.versions or {}
      out_entry.versions_policy = fn_entry.versions_policy or {}
      out_entry.policy = fn_entry.policy or {}
      if type(out_entry.policy) ~= "table" then
        out_entry.policy = {}
      end
      if type(out_entry.policy.methods) ~= "table" then
        out_entry.policy.methods = {}
      end
      if type(out_entry.policy.routes) ~= "table" then
        out_entry.policy.routes = {}
      end
      for _, m in ipairs(out_entry.policy.methods) do
        out_entry._methods_seen[m] = true
      end
      for _, r in ipairs(out_entry.policy.routes) do
        out_entry._routes_seen[r] = true
      end
    end

    for _, route in ipairs(sorted_keys(catalog.mapped_routes or {})) do
      local entries = (catalog.mapped_routes or {})[route]
      if type(entries) == "table" and entries.runtime ~= nil then
        entries = { entries }
      end
      if type(entries) == "table" then
        for _, entry in ipairs(entries) do
          if type(entry) == "table"
            and entry.runtime == runtime
            and type(entry.fn_name) == "string"
            and entry.fn_name ~= "" then
            local out_entry = ensure_fn_entry(entry.fn_name)
            out_entry.has_default = true
            out_entry.policy = type(out_entry.policy) == "table" and out_entry.policy or {}
            out_entry.policy.methods = type(out_entry.policy.methods) == "table" and out_entry.policy.methods or {}
            out_entry.policy.routes = type(out_entry.policy.routes) == "table" and out_entry.policy.routes or {}
            for _, m in ipairs(type(entry.methods) == "table" and entry.methods or {}) do
              if not out_entry._methods_seen[m] then
                out_entry._methods_seen[m] = true
                out_entry.policy.methods[#out_entry.policy.methods + 1] = m
              end
            end
            if not out_entry._routes_seen[route] then
              out_entry._routes_seen[route] = true
              out_entry.policy.routes[#out_entry.policy.routes + 1] = route
            end
          end
        end
      end
    end

    for _, name in ipairs(sorted_keys(fn_index)) do
      local out_entry = fn_index[name]
      if out_entry.has_default then
        local policy = routes.resolve_function_policy(runtime, name, nil)
        local keep_warm_cfg = type(policy) == "table" and type(policy.keep_warm) == "table" and policy.keep_warm or nil
        out_entry.default_state = function_state(runtime, name, nil, keep_warm_cfg)
      end
      local versions_state = {}
      for _, ver in ipairs(out_entry.versions or {}) do
        local policy = routes.resolve_function_policy(runtime, name, ver)
        local keep_warm_cfg = type(policy) == "table" and type(policy.keep_warm) == "table" and policy.keep_warm or nil
        versions_state[ver] = function_state(runtime, name, ver, keep_warm_cfg)
      end
      out_entry.versions_state = versions_state
      out_entry._methods_seen = nil
      out_entry._routes_seen = nil
      rt_out.functions[#rt_out.functions + 1] = out_entry
    end

    out.runtimes[runtime] = rt_out
  end

  return out
end

function M.function_detail(runtime, name, version, include_code)
  if type(runtime) ~= "string" or not runtime:match(NAME_RE) then
    return nil, "invalid runtime"
  end
  if not function_name_allowed(name) then
    return nil, "invalid function"
  end
  if version ~= nil and version ~= "" and (type(version) ~= "string" or not version:match(VERSION_RE)) then
    return nil, "invalid version"
  end

  local policy, policy_err = ensure_function_exists(runtime, name, version)
  if not policy then
    return nil, policy_err or "function not found"
  end

  local cfg = routes.get_config()
  local target, target_err = resolve_function_paths(cfg, runtime, name, version)
  if not target then
    return nil, target_err
  end
  local dir = target.fn_dir
  local app_path = target.app_path
  local conf_path = target.conf_path
  if not path_is_under(dir, conf_path) or not is_allowed_config_path(conf_path) then
    return nil, "invalid config path"
  end
  local fn_config = read_json_file(conf_path)
  local env_path = target.env_path
  local env_exists = file_exists(env_path)
  local fn_env = normalize_env_file(read_json_file(env_path))
  local env_keys = sorted_keys(fn_env or {})
  local fn_env_view = build_env_view(fn_env or {})

  local response_cfg = (type(fn_config) == "table" and type(fn_config.response) == "table")
    and fn_config.response
    or {}
  local invoke_cfg = (type(fn_config) == "table" and type(fn_config.invoke) == "table")
    and fn_config.invoke
    or {}
  local schedule_cfg = (type(fn_config) == "table" and type(fn_config.schedule) == "table")
    and fn_config.schedule
    or nil
  local shared_deps_cfg = (type(fn_config) == "table" and fn_config.shared_deps) or nil
  local group_cfg = (type(fn_config) == "table" and fn_config.group) or nil

  local shared_deps = {}
  if type(shared_deps_cfg) == "table" then
    local seen = {}
    for _, v in ipairs(shared_deps_cfg) do
      local s = tostring(v)
      if s:match(NAME_RE) and not seen[s] then
        seen[s] = true
        shared_deps[#shared_deps + 1] = s
      end
    end
  end

  local req_path = dir .. "/requirements.txt"
  local req_raw, req_truncated = read_file(req_path, MAX_REQ_BYTES)
  local inline_requirements = extract_inline_requirements(app_path)
  local file_requirements = parse_requirements_file(req_raw)

  local package_json_path = dir .. "/package.json"
  local package_lock_path = dir .. "/package-lock.json"
  local npm_shrinkwrap_path = dir .. "/npm-shrinkwrap.json"
  local package_json = read_json_file(package_json_path)
  local package_name = type(package_json) == "table" and package_json.name or nil
  local package_dependencies = type(package_json) == "table" and sorted_keys(package_json.dependencies or {}) or {}
  local package_dev_dependencies = type(package_json) == "table" and sorted_keys(package_json.devDependencies or {}) or {}
  local lock_file
  if file_exists(package_lock_path) then
    lock_file = "package-lock.json"
  elseif file_exists(npm_shrinkwrap_path) then
    lock_file = "npm-shrinkwrap.json"
  end

  local composer_json_path = dir .. "/composer.json"
  local composer_lock_path = dir .. "/composer.lock"
  local composer_require, composer_exists = parse_dependency_keys_from_json(composer_json_path, "require")
  local composer_require_dev, _ = parse_dependency_keys_from_json(composer_json_path, "require-dev")

  local cargo_toml_path = dir .. "/Cargo.toml"
  local cargo_lock_path = dir .. "/Cargo.lock"
  local cargo_raw = read_file(cargo_toml_path, MAX_REQ_BYTES)
  local cargo_dependencies = parse_cargo_dependency_names(cargo_raw)

  local mapped_public_routes = mapped_public_routes_for_target(runtime, name, version)
  local route = mapped_public_routes[1]
  if not route then
    route = "/" .. name
    if version and version ~= "" then
      route = route .. "@" .. version
    end
  end
  local hint_invoke = parse_handler_hints(app_path)
  local config_invoke = normalize_invoke_config(invoke_cfg)
  local invoke = merge_invoke(route, hint_invoke, config_invoke)
  local effective_mapped_routes = merge_unique_routes(invoke.mapped_routes or {}, mapped_public_routes)
  local effective_public_routes = merge_unique_routes(invoke.public_routes or {}, mapped_public_routes)
  if #effective_public_routes == 0 then
    effective_public_routes = { route }
  end
  invoke.mapped_routes = effective_mapped_routes
  invoke.public_routes = effective_public_routes
  local public_urls = {}
  for _, r in ipairs(effective_public_routes) do
    if type(r) == "string" and r ~= "" then
      public_urls[#public_urls + 1] = "http://127.0.0.1:8080" .. r
    end
  end

  local out = {
    runtime = runtime,
    name = name,
    version = version or nil,
    function_dir = dir,
    file_path = app_path,
    config_path = conf_path,
    policy = policy,
    fn_env = fn_env_view,
    runtime_health = routes.runtime_status(runtime),
    metadata = {
      handler_file = app_path:match("([^/]+)$") or app_path,
      response = {
        include_debug_headers = response_cfg.include_debug_headers == true,
        effective_include_debug_headers = policy.include_debug_headers == true,
      },
      schedule = {
        configured = schedule_cfg,
        state = {
          next = CACHE:get(sched_state_key(runtime, name, version, "next")),
          last = CACHE:get(sched_state_key(runtime, name, version, "last")),
          last_status = CACHE:get(sched_state_key(runtime, name, version, "last_status")),
          last_error = CACHE:get(sched_state_key(runtime, name, version, "last_error")),
        },
      },
      env = {
        exists = env_exists,
        keys = env_keys,
      },
      shared_deps = {
        packs_root = cfg.functions_root .. "/.fastfn/packs/" .. runtime,
        configured = shared_deps,
      },
      group = (type(group_cfg) == "string" and group_cfg) or nil,
      endpoints = {
        public_route = route,
        mapped_routes = effective_mapped_routes,
        public_routes = effective_public_routes,
        public_urls = public_urls,
        preferred_public_route = invoke.route or route,
        preferred_public_url = (#public_urls > 0 and public_urls[1]) or ("http://127.0.0.1:8080" .. route),
        invoke_api = "/_fn/invoke",
        function_detail_api = "/_fn/function",
        config_api = "/_fn/function-config",
        env_api = "/_fn/function-env",
      },
      invoke = invoke,
      python = {
        requirements = {
          inline = inline_requirements,
          file_path = req_path,
          file_exists = req_raw ~= nil,
          file_truncated = req_truncated == true,
          file_entries = file_requirements,
          auto_install_enabled = env_enabled("FN_AUTO_REQUIREMENTS", true),
        },
      },
      node = {
        package_json_path = package_json_path,
        package_json_exists = package_json ~= nil,
        package_name = package_name,
        lock_file = lock_file,
        dependency_count = #package_dependencies,
        dependencies = package_dependencies,
        dev_dependency_count = #package_dev_dependencies,
        dev_dependencies = package_dev_dependencies,
        auto_install_enabled = env_enabled("FN_AUTO_NODE_DEPS", true),
      },
      php = {
        composer_json_path = composer_json_path,
        composer_json_exists = composer_exists,
        composer_lock_exists = file_exists(composer_lock_path),
        dependency_count = #composer_require,
        dependencies = composer_require,
        dev_dependency_count = #composer_require_dev,
        dev_dependencies = composer_require_dev,
        auto_install_enabled = env_enabled("FN_AUTO_PHP_DEPS", true),
      },
      lua = {
        sandbox = "in-process",
        requires = { "cjson.safe" },
      },
      rust = {
        cargo_toml_path = cargo_toml_path,
        cargo_toml_exists = cargo_raw ~= nil,
        cargo_lock_exists = file_exists(cargo_lock_path),
        dependency_count = #cargo_dependencies,
        dependencies = cargo_dependencies,
        hot_reload_enabled = env_enabled("FN_HOT_RELOAD", true),
      },
    },
  }

  if include_code then
    local code, truncated = read_file(app_path, MAX_CODE_BYTES)
    out.code = code or ""
    out.code_truncated = truncated and true or false
  end

  return out
end

function M.set_function_config(runtime, name, version, payload)
  if type(runtime) ~= "string" or not runtime:match(NAME_RE) then
    return nil, "invalid runtime"
  end
  if not function_name_allowed(name) then
    return nil, "invalid function"
  end
  if version ~= nil and version ~= "" and (type(version) ~= "string" or not version:match(VERSION_RE)) then
    return nil, "invalid version"
  end

  local normalized, err = normalize_config_payload(payload)
  if not normalized then
    return nil, err
  end

  local _, p_err = ensure_function_exists(runtime, name, version)
  if p_err then
    return nil, p_err
  end

  local cfg = routes.get_config()
  local target, target_err = resolve_function_paths(cfg, runtime, name, version)
  if not target then
    return nil, target_err
  end
  local fn_dir = target.fn_dir
  local conf_path = target.conf_path
  if not path_is_under(fn_dir, conf_path) or not is_allowed_config_path(conf_path) then
    return nil, "invalid config path"
  end

  local base = read_json_file(conf_path) or {}
  if type(base) ~= "table" then
    base = {}
  end
  for k, v in pairs(normalized) do
    if k == "response" and type(v) == "table" then
      local current = type(base.response) == "table" and copy_table(base.response) or {}
      for rk, rv in pairs(v) do
        current[rk] = rv
      end
      base.response = current
    elseif k == "invoke" and type(v) == "table" then
      local current = type(base.invoke) == "table" and copy_table(base.invoke) or {}
      for ik, iv in pairs(v) do
        current[ik] = iv
      end
      base.invoke = current
    else
      base[k] = v
    end
  end

  local encoded = cjson.encode(base)
  if not encoded then
    return nil, "failed to encode config"
  end

  local ok, w_err = write_file(conf_path, encoded .. "\n")
  if not ok then
    return nil, "failed to write config: " .. tostring(w_err)
  end

  routes.discover_functions(true)

  local detail, d_err = M.function_detail(runtime, name, version, false)
  if not detail then
    return nil, d_err or "failed to load updated function"
  end

  return detail
end

function M.set_function_env(runtime, name, version, payload)
  if type(runtime) ~= "string" or not runtime:match(NAME_RE) then
    return nil, "invalid runtime"
  end
  if not function_name_allowed(name) then
    return nil, "invalid function"
  end
  if version ~= nil and version ~= "" and (type(version) ~= "string" or not version:match(VERSION_RE)) then
    return nil, "invalid version"
  end

  local normalized, err = normalize_env_payload(payload)
  if not normalized then
    return nil, err
  end

  local _, p_err = ensure_function_exists(runtime, name, version)
  if p_err then
    return nil, p_err
  end

  local cfg = routes.get_config()
  local target, target_err = resolve_function_paths(cfg, runtime, name, version)
  if not target then
    return nil, target_err
  end
  local fn_dir = target.fn_dir
  local env_path = target.env_path
  if not path_is_under(fn_dir, env_path) or not is_allowed_config_path(env_path) then
    return nil, "invalid env path"
  end

  local base = normalize_env_file(read_json_file(env_path) or {})
  for k, update in pairs(normalized.updates or {}) do
    if update.delete == true then
      base[k] = nil
    else
      local current = base[k] or {
        value = nil,
        is_secret = is_potential_secret_key(k),
      }

      local next_entry = {
        value = current.value,
        is_secret = current.is_secret == true,
      }

      if update.keep_hidden == true then
        -- if key doesn't exist, interpret as "no change"
        if next_entry.value == nil then
          goto continue_env_update
        end
      elseif update.value ~= nil then
        next_entry.value = update.value
      end

      if update.is_secret ~= nil then
        next_entry.is_secret = update.is_secret == true
      elseif base[k] == nil then
        next_entry.is_secret = is_potential_secret_key(k)
      end

      if next_entry.value == nil then
        base[k] = nil
      else
        base[k] = next_entry
      end
    end

    ::continue_env_update::
  end

  local encoded = cjson.encode(base)
  if not encoded then
    return nil, "failed to encode env"
  end

  local ok, w_err = write_file(env_path, encoded .. "\n")
  if not ok then
    return nil, "failed to write env: " .. tostring(w_err)
  end

  routes.discover_functions(true)

  local detail, d_err = M.function_detail(runtime, name, version, false)
  if not detail then
    return nil, d_err or "failed to load updated function"
  end

  return detail
end

function M.set_function_code(runtime, name, version, payload)
  if type(runtime) ~= "string" or not runtime:match(NAME_RE) then
    return nil, "invalid runtime"
  end
  if not function_name_allowed(name) then
    return nil, "invalid function"
  end
  if version ~= nil and version ~= "" and (type(version) ~= "string" or not version:match(VERSION_RE)) then
    return nil, "invalid version"
  end
  if type(payload) ~= "table" then
    return nil, "payload must be an object"
  end
  if type(payload.code) ~= "string" then
    return nil, "code must be a string"
  end
  if #payload.code > MAX_CODE_BYTES then
    return nil, "code exceeds maximum size"
  end

  local _, p_err = ensure_function_exists(runtime, name, version)
  if p_err then
    return nil, p_err
  end

  local cfg = routes.get_config()
  local target, target_err = resolve_function_paths(cfg, runtime, name, version)
  if not target then
    return nil, target_err
  end
  local app_path = target.app_path

  local ok, w_err = write_file(app_path, payload.code)
  if not ok then
    return nil, "failed to write code: " .. tostring(w_err)
  end

  routes.discover_functions(true)

  local detail, d_err = M.function_detail(runtime, name, version, true)
  if not detail then
    return nil, d_err or "failed to load updated function"
  end

  return detail
end

function M.create_function(runtime, name, version, payload)
  if type(runtime) ~= "string" or not runtime:match(NAME_RE) then
    return nil, "invalid runtime"
  end
  if type(name) ~= "string" or not name:match(NAME_RE) then
    return nil, "invalid function"
  end
  if version ~= nil and version ~= "" and (type(version) ~= "string" or not version:match(VERSION_RE)) then
    return nil, "invalid version"
  end

  local cfg = routes.get_config()
  if type((cfg.runtimes or {})[runtime]) ~= "table" then
    return nil, "unknown runtime"
  end

  local fn_dir = build_fn_dir(cfg.functions_root, runtime, name, version)
  if not path_is_under(cfg.functions_root, fn_dir) then
    return nil, "invalid function path"
  end
  if is_symlink(fn_dir) then
    return nil, "symlink function path is not allowed"
  end

  if not ensure_dir(fn_dir) then
    return nil, "failed to create function directory"
  end

  local existing = detect_app_file(fn_dir, runtime)
  if existing then
    return nil, "function already exists"
  end

  local filename = default_handler_filename(runtime)
  if not filename then
    return nil, "unsupported runtime for create"
  end
  if type(payload) == "table" and type(payload.filename) == "string" and payload.filename ~= "" then
    if not handler_name_allowed(payload.filename, runtime) then
      return nil, "invalid filename for runtime"
    end
    filename = payload.filename
  end
  local app_path = fn_dir .. "/" .. filename

  local methods = normalize_methods_for_create(type(payload) == "table" and payload.methods or nil)
  local default_query = {}
  if type(payload) == "table" and type(payload.query_example) == "table" then
    default_query = payload.query_example
  end
  local body_example = ""
  if type(payload) == "table" and type(payload.body_example) == "string" then
    body_example = payload.body_example
  end
  local summary = "Generated function"
  if type(payload) == "table" and type(payload.summary) == "string" and payload.summary ~= "" then
    summary = payload.summary
  end
  local invoke_routes = nil
  if type(payload) == "table" then
    local invoke_payload = {}
    if payload.route ~= nil then
      invoke_payload.route = payload.route
    end
    if payload.routes ~= nil then
      invoke_payload.routes = payload.routes
    end
    local ok_routes, routes_err = validate_invoke_routes_payload(invoke_payload)
    if not ok_routes then
      return nil, routes_err
    end
    invoke_routes = normalize_routes_from_invoke(invoke_payload)
  end

  local code = nil
  if type(payload) == "table" and type(payload.code) == "string" and payload.code ~= "" then
    code = payload.code
  else
    code = default_handler_template(runtime)
  end
  if #code > MAX_CODE_BYTES then
    return nil, "code exceeds maximum size"
  end

  local ok, w_err = write_file(app_path, code)
  if not ok then
    return nil, "failed to write code: " .. tostring(w_err)
  end

  local config = {
    invoke = {
      summary = summary,
      methods = methods,
      query = default_query,
      body = body_example,
    },
  }
  if type(invoke_routes) == "table" then
    config.invoke.routes = invoke_routes
  end
  local conf_path = fn_dir .. "/fn.config.json"
  if not path_is_under(fn_dir, conf_path) or not is_allowed_config_path(conf_path) then
    return nil, "invalid config path"
  end
  local encoded = cjson.encode(config)
  if not encoded then
    return nil, "failed to encode config"
  end
  local ok_cfg, err_cfg = write_file(conf_path, encoded .. "\n")
  if not ok_cfg then
    return nil, "failed to write config: " .. tostring(err_cfg)
  end

  routes.discover_functions(true)
  local detail, d_err = M.function_detail(runtime, name, version, true)
  if not detail then
    return nil, d_err or "failed to load created function"
  end
  return detail
end

function M.delete_function(runtime, name, version)
  if type(runtime) ~= "string" or not runtime:match(NAME_RE) then
    return nil, "invalid runtime"
  end
  if type(name) ~= "string" or not name:match(NAME_RE) then
    return nil, "invalid function"
  end
  if version ~= nil and version ~= "" and (type(version) ~= "string" or not version:match(VERSION_RE)) then
    return nil, "invalid version"
  end

  local cfg = routes.get_config()
  local fn_dir = build_fn_dir(cfg.functions_root, runtime, name, version)
  if not path_is_under(cfg.functions_root, fn_dir) then
    return nil, "invalid function path"
  end
  if is_symlink(fn_dir) then
    return nil, "symlink function path is not allowed"
  end
  if not dir_exists(fn_dir) then
    return nil, "function not found"
  end

  if version and version ~= "" then
    local ok = rm_path(fn_dir)
    if not ok then
      return nil, "failed to delete function version"
    end
  else
    for _, filename in ipairs(allowed_handler_filenames(runtime)) do
      local p = fn_dir .. "/" .. filename
      if file_exists(p) then
        rm_path(p)
      end
    end
    rm_path(fn_dir .. "/fn.config.json")
    rm_path(fn_dir .. "/fn.env.json")
    rm_path(fn_dir .. "/requirements.txt")
    rm_path(fn_dir .. "/package.json")
    rm_path(fn_dir .. "/package-lock.json")
    rm_path(fn_dir .. "/npm-shrinkwrap.json")
    rm_path(fn_dir .. "/composer.json")
    rm_path(fn_dir .. "/composer.lock")
    rm_path(fn_dir .. "/go.mod")
    rm_path(fn_dir .. "/go.sum")
    rm_path(fn_dir .. "/Cargo.toml")
    rm_path(fn_dir .. "/Cargo.lock")
    rm_path(fn_dir .. "/.deps")
    rm_path(fn_dir .. "/node_modules")
    rm_path(fn_dir .. "/vendor")
    rm_path(fn_dir .. "/.rust-build")
    rm_path(fn_dir .. "/target")

    if version_children_count(fn_dir) == 0 then
      rm_path(fn_dir)
    end
  end

  routes.discover_functions(true)
  return { ok = true, runtime = runtime, name = name, version = version or nil }
end

function M.list_secrets()
    local s = ngx.shared.fn_cache:get("sys:secrets_list")
    if s then return cjson.decode(s) end
    return {}
end

function M.set_secret(key, value)
    local list = M.list_secrets()
    local found = false
    -- Check if exists
    for i, item in ipairs(list) do
        if item.key == key then
            item.updated = os.time()
            found = true
            break
        end
    end
    if not found then
        table.insert(list, { key = key, created = os.time() })
    end
    
    -- In a real system, store value in encrypted vault.
    -- We're storing it in shared dict for this MVP.
    local enc_list = cjson.encode(list)
    ngx.shared.fn_cache:set("sys:secrets_list", enc_list)
    ngx.shared.fn_cache:set("sys:secret:val:"..key, value)
    
    return true
end

function M.delete_secret(key)
    local list = M.list_secrets()
    local new_list = {}
    local changed = false
    for i, item in ipairs(list) do
        if item.key ~= key then
            table.insert(new_list, item)
        else
            changed = true
        end
    end
    
    if changed then
        local enc_list = cjson.encode(new_list)
        ngx.shared.fn_cache:set("sys:secrets_list", enc_list)
        ngx.shared.fn_cache:delete("sys:secret:val:"..key)
    end
    return true
end

function M.get_dashboard_metrics()
    -- Mock metrics aggregation
    return {
        requests_24h = 1000 + math.random(0, 100),
        errors_24h = math.random(0, 5),
        avg_latency_ms = 45,
        invocations_chart = {
            labels = {"00:00", "04:00", "08:00", "12:00", "16:00", "20:00"},
            data = {120, 132, 101, 134, 90, 230}
        }
    }
end

return M
