local cjson = require "cjson.safe"
local guard = require "fastfn.console.guard"
local console = require "fastfn.console.data"
local routes = require "fastfn.core.routes"
local invoke_rules = require "fastfn.core.invoke_rules"
local client = require "fastfn.core.client"
local lua_runtime = require "fastfn.core.lua_runtime"
local utils = require "fastfn.core.gateway_utils"

local function sorted_keys(tbl)
  local keys = {}
  for k, _ in pairs(tbl or {}) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local function parse_cookies(cookie_header)
  local cookies = {}
  if type(cookie_header) ~= "string" or cookie_header == "" then
    return cookies
  end
  for pair in cookie_header:gmatch("[^;]+") do
    local k, v = pair:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
    if k and k ~= "" then
      cookies[k] = v or ""
    end
  end
  return cookies
end

local function build_session(req_headers)
  local raw = ""
  if type(req_headers) == "table" then
    raw = req_headers["Cookie"] or req_headers["cookie"] or ""
  end
  if raw == "" then
    return nil
  end
  local cookies = parse_cookies(raw)
  local session_id = cookies["session_id"] or cookies["sessionid"] or cookies["sid"] or nil
  return {
    id = session_id,
    raw = raw,
    cookies = cookies,
  }
end

local function call_external_runtime(runtime, runtime_cfg, request_payload, timeout_ms)
  local tried = {}
  local get_sockets = type(routes.get_runtime_sockets) == "function"
    and routes.get_runtime_sockets
    or function(_runtime, cfg)
      if type(cfg) == "table" and type(cfg.socket) == "string" and cfg.socket ~= "" then
        return { cfg.socket }
      end
      return {}
    end
  local pick_socket = type(routes.pick_runtime_socket) == "function"
    and routes.pick_runtime_socket
    or function(_runtime, cfg)
      if type(cfg) == "table" and type(cfg.socket) == "string" and cfg.socket ~= "" then
        return cfg.socket, 1, "single"
      end
      return nil, nil, "single", "runtime unavailable"
    end
  local set_socket_health = type(routes.set_runtime_socket_health) == "function"
    and routes.set_runtime_socket_health
    or function() return true end
  local sockets = get_sockets(runtime, runtime_cfg)
  local attempts = 0
  local max_attempts = #sockets > 1 and 2 or 1
  local last_code, last_msg

  while attempts < max_attempts do
    local socket_uri, socket_index = pick_socket(runtime, runtime_cfg, tried)
    if not socket_uri then
      return nil, last_code or "connect_error", last_msg or "runtime unavailable"
    end

    local resp, err_code, err_msg = client.call_unix(socket_uri, request_payload, timeout_ms)
    if resp then
      set_socket_health(runtime, socket_index, socket_uri, true, "ok")
      routes.set_runtime_health(runtime, true, "ok")
      return resp, nil, nil
    end

    last_code, last_msg = err_code, err_msg
    if err_code ~= "connect_error" then
      return nil, err_code, err_msg
    end

    tried[socket_index] = true
    set_socket_health(runtime, socket_index, socket_uri, false, err_msg or "connect_error")
    local ok_rt, reason_rt = routes.check_runtime_health(runtime, runtime_cfg)
    routes.set_runtime_health(runtime, ok_rt, ok_rt and (reason_rt or "ok") or reason_rt)
    if not ok_rt then
      return nil, err_code, err_msg
    end
    attempts = attempts + 1
  end

  return nil, last_code, last_msg
end

local function method_allowed(entry_methods, method)
  if type(entry_methods) ~= "table" then
    return true
  end
  for _, m in ipairs(entry_methods) do
    if string.upper(tostring(m)) == method then
      return true
    end
  end
  return false
end

local function resolve_mapped_route(runtime, name, version, method)
  local catalog = routes.discover_functions(false)
  local mapped = (catalog and catalog.mapped_routes) or {}
  local candidates = {}

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
          and (entry.version or nil) == (version or nil)
          and method_allowed(entry.methods, method) then
          candidates[#candidates + 1] = route
          break
        end
      end
    end
  end

  if #candidates == 0 then
    return nil
  end
  table.sort(candidates)
  return candidates[1]
end

local function parse_params_object(raw)
  if raw == nil or raw == cjson.null then
    return {}
  end
  if type(raw) ~= "table" or raw[1] ~= nil then
    return nil, "params must be a JSON object"
  end

  local out = {}
  for k, v in pairs(raw) do
    if type(k) ~= "string" or k == "" then
      return nil, "params keys must be non-empty strings"
    end
    if v == nil or v == cjson.null then
      -- allow explicit null as "unset"
    elseif type(v) == "string" then
      out[k] = v
    else
      out[k] = tostring(v)
    end
  end
  return out
end

local function encode_path_segment(value)
  return ngx.escape_uri(tostring(value or ""))
end

local function encode_catch_all(value)
  local raw = tostring(value or "")
  if raw == "" then
    return ""
  end
  local out = {}
  for seg in raw:gmatch("[^/]+") do
    out[#out + 1] = ngx.escape_uri(seg)
  end
  if #out == 0 then
    return ngx.escape_uri(raw)
  end
  return table.concat(out, "/")
end

local function interpolate_route_params(route, params)
  local missing = {}
  local rendered = tostring(route or ""):gsub(":([A-Za-z0-9_]+)(%*?)", function(name, star)
    local value = params and params[name] or nil
    if value == nil or tostring(value) == "" then
      missing[#missing + 1] = name
      return ":" .. name .. (star or "")
    end
    if star == "*" then
      return encode_catch_all(value)
    end
    return encode_path_segment(value)
  end)

  if #missing > 0 then
    return nil, missing
  end
  return rendered, nil
end

if not guard.enforce_api() then
  return
end

if ngx.req.get_method() ~= "POST" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

if not guard.enforce_body_limit(1048576) then  -- 1MB for invoke payloads
  return
end

ngx.req.read_body()
local payload = cjson.decode(ngx.req.get_body_data() or "")
if type(payload) ~= "table" then
  guard.write_json(400, { error = "invalid json body" })
  return
end

local name = payload.name
local version = payload.version
local runtime = payload.runtime
local method = string.upper(tostring(payload.method or "GET"))
local context = payload.context
local route = payload.route
local params_raw = payload.params

if version == cjson.null or version == "" then
  version = nil
end
if runtime == cjson.null or runtime == "" then
  runtime = nil
end
if route == cjson.null or route == "" then
  route = nil
end

if type(name) ~= "string" then
  guard.write_json(400, { error = "name is required" })
  return
end
if runtime == nil then
  -- Allow omitting runtime when invoking by name. Resolve using the configured
  -- runtime order.
  local resolved_rt, resolved_ver = routes.resolve_named_target(name, version)
  if not resolved_rt then
    guard.write_json(404, { error = "unknown function or version" })
    return
  end
  runtime = resolved_rt
  version = resolved_ver
end
if type(runtime) ~= "string" or runtime == "" then
  guard.write_json(400, { error = "runtime must be a non-empty string" })
  return
end

if method ~= "GET" and method ~= "POST" and method ~= "PUT" and method ~= "PATCH" and method ~= "DELETE" then
  guard.write_json(400, { error = "unsupported method" })
  return
end
if route ~= nil and type(route) ~= "string" then
  guard.write_json(400, { error = "route must be a string when provided" })
  return
end

local params, params_err = parse_params_object(params_raw)
if not params then
  guard.write_json(400, { error = params_err or "invalid params" })
  return
end

local resolved_runtime = runtime
local resolved_version = version
local policy_precheck, perr = routes.resolve_function_policy(resolved_runtime, name, resolved_version)
if not policy_precheck then
  guard.write_json(404, { error = perr or "unknown function or version" })
  return
end

local policy, policy_err = routes.resolve_function_policy(resolved_runtime, name, resolved_version)
if not policy then
  guard.write_json(404, { error = policy_err or "unknown function or version" })
  return
end

local allowed = {}
local allowed_set = {}
for _, m in ipairs(type(policy.methods) == "table" and policy.methods or { "GET" }) do
  local mm = string.upper(tostring(m))
  if mm ~= "" and not allowed_set[mm] then
    allowed_set[mm] = true
    allowed[#allowed + 1] = mm
  end
end
if not allowed_set[method] then
  guard.write_json(405, { error = "method not allowed", allowed_methods = allowed })
  return
end

local uri
if route ~= nil then
  uri = invoke_rules.normalize_route(route)
  if not uri then
    guard.write_json(400, { error = "invalid route" })
    return
  end
else
  uri = resolve_mapped_route(resolved_runtime, name, resolved_version, method)
  if not uri then
    -- Fallback for ambiguous routing: allow invoking by runtime+name even when
    -- the canonical public URL is in conflict (for example node/foo and python/foo).
    -- This endpoint is already protected by guard.enforce_api().
    local seg = routes.canonical_route_segment_for_name(name)
    if seg then
      uri = invoke_rules.normalize_route("/" .. seg)
    end
    if not uri then
      guard.write_json(404, { error = "no mapped public route for target" })
      return
    end
  end
end
local route_template = uri
local resolved_uri, missing_params = interpolate_route_params(route_template, params)
if not resolved_uri then
  guard.write_json(400, {
    error = "missing required path params",
    route = route_template,
    missing_params = missing_params or {},
  })
  return
end
uri = resolved_uri

local query = type(payload.query) == "table" and payload.query or {}
local body = payload.body
if body ~= nil and type(body) ~= "string" then
  local encoded = cjson.encode(body)
  if not encoded then
    guard.write_json(400, { error = "body must be a string or JSON-encodable value" })
    return
  end
  body = encoded
end

if context ~= nil then
  if type(context) ~= "table" then
    guard.write_json(400, { error = "context must be an object" })
    return
  end
  local encoded_ctx = cjson.encode(context)
  if not encoded_ctx then
    guard.write_json(400, { error = "context is not JSON-encodable" })
    return
  end
  query.__fnctx = ngx.encode_base64(encoded_ctx)
end

local runtime_cfg = routes.get_runtime_config(resolved_runtime)
if not runtime_cfg then
  guard.write_json(404, { error = "unknown runtime" })
  return
end
if routes.runtime_is_up(resolved_runtime) ~= true then
  local ok_rt, rt_reason = routes.check_runtime_health(resolved_runtime, runtime_cfg)
  routes.set_runtime_health(resolved_runtime, ok_rt, ok_rt and (rt_reason or "ok") or rt_reason)
  if not ok_rt then
    guard.write_json(503, { error = "runtime down" })
    return
  end
end

local timeout_ms = utils.resolve_numeric(policy.timeout_ms, runtime_cfg.timeout_ms, nil, 2500)
local max_concurrency = utils.resolve_numeric(policy.max_concurrency, nil, nil, 0)
local max_body_bytes = utils.resolve_numeric(policy.max_body_bytes, nil, nil, 1024 * 1024)
if type(body) == "string" and #body > max_body_bytes then
  guard.write_json(413, { error = "payload too large" })
  return
end

local version_label = resolved_version or "default"
local request_id = "invoke-" .. tostring(math.floor(ngx.now() * 1000)) .. "-" .. tostring(math.random(1000, 9999))
local start = ngx.now()
local req_headers = type(payload.headers) == "table" and payload.headers or {}
local session = build_session(req_headers)
local fn_source_dir = type(routes.resolve_function_source_dir) == "function"
  and routes.resolve_function_source_dir(resolved_runtime, name)
  or nil
local request_payload = {
  fn = name,
  fn_source_dir = fn_source_dir,
  version = resolved_version,
  event = {
    id = request_id,
    ts = math.floor(ngx.now() * 1000),
    method = method,
    path = uri,
    raw_path = uri,
    query = query,
    params = params,
    path_params = params,
    headers = req_headers,
    body = type(body) == "string" and body or "",
    session = session,
    client = { ip = "127.0.0.1", ua = "fastfn-console-invoke" },
    context = {
      request_id = request_id,
      runtime = resolved_runtime,
      function_name = name,
      version = version_label,
      timeout_ms = timeout_ms,
      max_concurrency = max_concurrency,
      max_body_bytes = max_body_bytes,
      gateway = { worker_pid = ngx.worker.pid() },
      debug = { enabled = policy.include_debug_headers == true },
      user = type(context) == "table" and context or nil,
    },
  },
}
-- Inject only the secrets that this specific function references via its
-- fn.env.json (keys with is_secret=true).  This prevents function A from
-- reading secrets that belong to function B.
local secrets_list = console.list_secrets() or {}
if #secrets_list > 0 then
  local cjson_local = require "cjson.safe"
  local allowed_keys = nil
  local entrypoint = routes.resolve_function_entrypoint(resolved_runtime, name, resolved_version)
  if type(entrypoint) == "string" and entrypoint ~= "" then
    local fn_dir = entrypoint:match("^(.*)/[^/]+$") or "."
    local env_path = fn_dir .. "/fn.env.json"
    local ef = io.open(env_path, "rb")
    if ef then
      local raw_env = ef:read("*a")
      ef:close()
      if type(raw_env) == "string" and raw_env ~= "" then
        local env_parsed = cjson_local.decode(raw_env)
        if type(env_parsed) == "table" then
          allowed_keys = {}
          for k, v in pairs(env_parsed) do
            if type(k) == "string" and k ~= "" then
              if type(v) == "table" and v.is_secret == true then
                allowed_keys[k] = true
              end
            end
          end
        end
      end
    end
  end

  local secrets_map = {}
  local fcache = ngx.shared.fn_cache
  for _, item in ipairs(secrets_list) do
    if allowed_keys == nil or allowed_keys[item.key] then
      local val = fcache:get("sys:secret:val:" .. item.key)
      if val then secrets_map[item.key] = val end
    end
  end
  if next(secrets_map) then
    request_payload.event.secrets = secrets_map
  end
end

local res, err_code, err_msg
if routes.runtime_is_in_process(resolved_runtime, runtime_cfg) then
  res, err_code, err_msg = lua_runtime.call(request_payload)
else
  res, err_code, err_msg = call_external_runtime(resolved_runtime, runtime_cfg, request_payload, timeout_ms)
end
local elapsed_ms = math.floor((ngx.now() - start) * 1000)

if not res then
  local status, msg = utils.map_runtime_error(err_code)
  guard.write_json(status, { error = msg .. ": " .. tostring(err_msg), latency_ms = elapsed_ms })
  return
end

local headers = {}
for k, v in pairs(res.headers or {}) do
  if type(k) == "string" then
    headers[k] = v
  end
end

local stdout = type(res.stdout) == "string" and res.stdout ~= "" and res.stdout or nil
local stderr = type(res.stderr) == "string" and res.stderr ~= "" and res.stderr or nil

if res.is_base64 == true then
  guard.write_json(200, {
    status = res.status,
    latency_ms = elapsed_ms,
    route = uri,
    route_template = route_template,
    headers = headers,
    is_base64 = true,
    body_base64 = res.body_base64 or "",
    stdout = stdout,
    stderr = stderr,
  })
  return
end

guard.write_json(200, {
  status = res.status,
  latency_ms = elapsed_ms,
  route = uri,
  route_template = route_template,
  headers = headers,
  body = res.body or "",
  stdout = stdout,
  stderr = stderr,
})
