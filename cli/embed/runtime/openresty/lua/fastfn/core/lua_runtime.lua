local cjson = require "cjson.safe"
local routes = require "fastfn.core.routes"

local M = {}
local _native_getenv = os.getenv
local _current_event_env = nil

local function runtime_getenv(name)
  if type(name) ~= "string" or name == "" then
    return _native_getenv(name)
  end
  if type(_current_event_env) == "table" then
    local value = _current_event_env[name]
    if value ~= nil then
      return tostring(value)
    end
  end
  return _native_getenv(name)
end

local function json_body(payload)
  local encoded = cjson.encode(payload)
  if type(encoded) ~= "string" then
    encoded = "{\"error\":\"json encode failed\"}"
  end
  return encoded
end

local function error_response(message)
  return {
    status = 500,
    headers = { ["Content-Type"] = "application/json" },
    body = json_body({ error = tostring(message or "lua runtime error") }),
  }
end

local function normalize_headers(raw)
  if type(raw) ~= "table" then
    return {}
  end
  local out = {}
  for k, v in pairs(raw) do
    local key = tostring(k)
    if key ~= "" and not key:find("[\r\n]") then
      local value = tostring(v)
      if not value:find("[\r\n]") then
        out[key] = value
      end
    end
  end
  return out
end

local function contains_response_fields(obj)
  return obj.status ~= nil
    or obj.headers ~= nil
    or obj.body ~= nil
    or obj.is_base64 ~= nil
    or obj.body_base64 ~= nil
    or obj.proxy ~= nil
end

local function normalize_function_env(raw)
  if type(raw) ~= "table" then
    return {}
  end
  local out = {}
  for key, value in pairs(raw) do
    if type(key) == "string" and key ~= "" then
      if type(value) == "table" then
        local scalar = value.value
        if scalar ~= nil then
          out[key] = tostring(scalar)
        end
      elseif value ~= nil then
        out[key] = tostring(value)
      end
    end
  end
  return out
end

local function read_function_env(entrypoint)
  if type(entrypoint) ~= "string" or entrypoint == "" then
    return {}
  end
  local fn_dir = entrypoint:match("^(.*)/[^/]+$") or "."
  local env_path = fn_dir .. "/fn.env.json"
  local f = io.open(env_path, "rb")
  if not f then
    return {}
  end
  local raw = f:read("*a")
  f:close()
  if type(raw) ~= "string" or raw == "" then
    return {}
  end
  local parsed = cjson.decode(raw)
  return normalize_function_env(parsed)
end

local function merge_event_env(event, fn_env)
  local out_event = {}
  if type(event) == "table" then
    for k, v in pairs(event) do
      out_event[k] = v
    end
  end

  local merged_env = {}
  local incoming_env = out_event.env
  if type(incoming_env) == "table" then
    for k, v in pairs(incoming_env) do
      if type(k) == "string" and k ~= "" and v ~= nil then
        merged_env[k] = tostring(v)
      end
    end
  end
  if type(fn_env) == "table" then
    for k, v in pairs(fn_env) do
      if type(k) == "string" and k ~= "" and v ~= nil then
        merged_env[k] = tostring(v)
      end
    end
  end
  out_event.env = merged_env
  return out_event, merged_env
end

local function with_event_env_scope(env_table, run)
  local prev_env = _current_event_env
  _current_event_env = type(env_table) == "table" and env_table or nil
  local ok, result = pcall(run)
  _current_event_env = prev_env
  return ok, result
end

local function build_sandbox_env(captured_stdout)
  local env = {
    _VERSION = _VERSION,
    assert = assert,
    error = error,
    ipairs = ipairs,
    next = next,
    pairs = pairs,
    pcall = pcall,
    select = select,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    xpcall = xpcall,
    math = math,
    string = string,
    table = table,
    cjson = cjson,
    json = cjson,
    os = {
      getenv = runtime_getenv,
      time = os.time,
      date = os.date,
      clock = os.clock,
      difftime = os.difftime,
    },
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
      end
      captured_stdout[#captured_stdout + 1] = table.concat(parts, "\t")
    end,
  }

  env.require = function(name)
    if name == "cjson" or name == "cjson.safe" then
      return cjson
    end
    error("module not allowed in lua runtime: " .. tostring(name))
  end

  env._G = env
  return env
end

local function load_handler(entrypoint, captured_stdout)
  local chunk, load_err = loadfile(entrypoint)
  if not chunk then
    return nil, "failed to load lua entrypoint: " .. tostring(load_err)
  end

  local env = build_sandbox_env(captured_stdout)
  setfenv(chunk, env)

  local ok_exec, result_or_err = pcall(chunk)
  if not ok_exec then
    return nil, "lua entrypoint error: " .. tostring(result_or_err)
  end

  local handler = nil
  if type(result_or_err) == "function" then
    handler = result_or_err
  elseif type(result_or_err) == "table" then
    if type(result_or_err.handler) == "function" then
      handler = result_or_err.handler
    elseif type(result_or_err.main) == "function" then
      handler = result_or_err.main
    end
  end
  if type(handler) ~= "function" then
    if type(env.handler) == "function" then
      handler = env.handler
    elseif type(env.main) == "function" then
      handler = env.main
    end
  end

  if type(handler) ~= "function" then
    return nil, "lua entrypoint must define handler(event) or main(event)"
  end

  return handler
end

local function normalize_response(raw)
  if type(raw) ~= "table" or not contains_response_fields(raw) then
    return {
      status = 200,
      headers = { ["Content-Type"] = "application/json" },
      body = json_body(raw),
    }
  end

  local out = {
    status = tonumber(raw.status) or 200,
    headers = normalize_headers(raw.headers),
  }

  if type(raw.proxy) == "table" then
    out.proxy = raw.proxy
  end

  if raw.is_base64 == true then
    out.is_base64 = true
    out.body_base64 = type(raw.body_base64) == "string" and raw.body_base64 or ""
    return out
  end

  local body = raw.body
  if type(body) == "table" then
    body = json_body(body)
    if out.headers["Content-Type"] == nil and out.headers["content-type"] == nil then
      out.headers["Content-Type"] = "application/json"
    end
  elseif body == nil then
    body = ""
  elseif type(body) ~= "string" then
    body = tostring(body)
  end

  out.body = body
  return out
end

function M.call(req_obj)
  if type(req_obj) ~= "table" then
    return error_response("invalid lua request payload"), nil, nil
  end

  local fn_name = req_obj.fn
  local version = req_obj.version
  local event = type(req_obj.event) == "table" and req_obj.event or {}
  if type(fn_name) ~= "string" or fn_name == "" then
    return error_response("missing function name"), nil, nil
  end

  local entrypoint, path_err = routes.resolve_function_entrypoint("lua", fn_name, version)
  if not entrypoint then
    return error_response(path_err or "lua function entrypoint not found"), nil, nil
  end

  local fn_env = read_function_env(entrypoint)
  local event_with_env, merged_env = merge_event_env(event, fn_env)

  local captured_stdout = {}
  local handler, handler_err = load_handler(entrypoint, captured_stdout)
  if not handler then
    return error_response(handler_err), nil, nil
  end

  local route_params = type(event_with_env.params) == "table" and event_with_env.params or {}
  local ok_run, result_or_err = with_event_env_scope(merged_env, function()
    return handler(event_with_env, route_params)
  end)
  if not ok_run then
    return error_response("lua handler error: " .. tostring(result_or_err)), nil, nil
  end

  local resp = normalize_response(result_or_err)
  if #captured_stdout > 0 then
    resp.stdout = table.concat(captured_stdout, "\n")
  end
  return resp, nil, nil
end

return M
