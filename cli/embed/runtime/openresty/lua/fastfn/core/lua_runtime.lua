local cjson = require "cjson.safe"
local routes = require "fastfn.core.routes"

local M = {}

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

local function build_sandbox_env()
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

local function load_handler(entrypoint)
  local chunk, load_err = loadfile(entrypoint)
  if not chunk then
    return nil, "failed to load lua entrypoint: " .. tostring(load_err)
  end

  local env = build_sandbox_env()
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

  local handler, handler_err = load_handler(entrypoint)
  if not handler then
    return error_response(handler_err), nil, nil
  end

  local ok_run, result_or_err = pcall(handler, event)
  if not ok_run then
    return error_response("lua handler error: " .. tostring(result_or_err)), nil, nil
  end

  return normalize_response(result_or_err), nil, nil
end

return M
