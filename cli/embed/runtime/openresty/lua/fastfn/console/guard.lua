local cjson = require "cjson.safe"
local auth = require "fastfn.console.auth"

local M = {}

local function constant_time_eq(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local acc = 0
  for i = 1, #a do
    acc = bit.bor(acc, bit.bxor(string.byte(a, i), string.byte(b, i)))
  end
  return acc == 0
end
local STATE_KEYS = {
  ui_enabled = "console:ui_enabled",
  api_enabled = "console:api_enabled",
  write_enabled = "console:write_enabled",
  local_only = "console:local_only",
  login_enabled = "console:login_enabled",
  login_api_enabled = "console:login_api_enabled",
  public_explore = "console:public_explore",
}

local function state_store()
  return ngx.shared and ngx.shared.fn_cache or nil
end

local function env_bool(name, default_value)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default_value
  end
  raw = string.lower(raw)
  if raw == "1" or raw == "true" or raw == "yes" or raw == "on" then
    return true
  end
  if raw == "0" or raw == "false" or raw == "no" or raw == "off" then
    return false
  end
  return default_value
end

local function read_override(key)
  local store = state_store()
  if not store then
    return nil
  end
  local v = store:get(key)
  if v == nil then
    return nil
  end
  return v == 1
end

local function resolve_flag(flag, env_name, default_value)
  local override = read_override(STATE_KEYS[flag])
  if override ~= nil then
    return override
  end
  return env_bool(env_name, default_value)
end

local function json_error(status, message)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json"
  ngx.say(cjson.encode({ error = message }))
end

function M.ui_enabled()
  return resolve_flag("ui_enabled", "FN_UI_ENABLED", false)
end

function M.api_enabled()
  return resolve_flag("api_enabled", "FN_CONSOLE_API_ENABLED", true)
end

function M.admin_api_enabled()
  return env_bool("FN_ADMIN_API_ENABLED", true)
end

function M.write_enabled()
  return resolve_flag("write_enabled", "FN_CONSOLE_WRITE_ENABLED", false)
end

function M.local_only()
  return resolve_flag("local_only", "FN_CONSOLE_LOCAL_ONLY", true)
end

function M.login_enabled()
  -- For UI, env default is false; state override allowed.
  local override = read_override(STATE_KEYS.login_enabled)
  if override ~= nil then
    return override
  end
  return auth.login_enabled()
end

function M.login_api_enabled()
  local override = read_override(STATE_KEYS.login_api_enabled)
  if override ~= nil then
    return override
  end
  return auth.api_login_enabled()
end

function M.public_explore()
  return resolve_flag("public_explore", "FN_PUBLIC_EXPLORE", false)
end

function M.request_is_local()
  local ip = ngx.var.remote_addr
  if not ip or ip == "" then
    return false
  end

  -- If X-Forwarded-For is present, the request came through a proxy.
  -- NEVER trust it as local — proxied traffic can spoof private IPs.
  local xff = ngx.req.get_headers()["x-forwarded-for"]
  if xff and xff ~= "" then
    ngx.log(ngx.WARN, "[SECURITY] X-Forwarded-For detected (", tostring(xff),
      "), refusing local trust for remote_addr=", ip)
    return false
  end

  if ip == "127.0.0.1" or ip == "::1" then
    return true
  end

  if ip:match("^10%.") or ip:match("^192%.168%.") then
    return true
  end

  local n = tonumber(ip:match("^172%.(%d+)%."))
  if n and n >= 16 and n <= 31 then
    return true
  end

  -- IPv6 local ranges
  local low = ip:lower()
  if low:match("^fc") or low:match("^fd") or low:match("^fe80:") then
    return true
  end

  return false
end

function M.request_has_admin_token()
  local token = os.getenv("FN_ADMIN_TOKEN")
  if not token or token == "" then
    return false
  end
  local provided = ngx.req.get_headers()["x-fn-admin-token"]
  return constant_time_eq(provided, token)
end

function M.request_has_session()
  local sess = auth.read_session()
  return sess ~= nil
end

function M.current_session_user()
  local sess = auth.read_session()
  if type(sess) ~= "table" then
    return nil
  end
  if type(sess.user) ~= "string" or sess.user == "" then
    return nil
  end
  return sess.user
end

function M.enforce_api(opts)
  opts = opts or {}
  local skip_login = opts.skip_login == true

  if not M.api_enabled() then
    json_error(404, "console api disabled")
    return false
  end

  if not M.admin_api_enabled() then
    json_error(404, "admin api disabled")
    return false
  end

  if M.local_only() and not (M.request_is_local() or M.request_has_admin_token()) then
    json_error(403, "console api local-only")
    return false
  end

  if not skip_login and M.login_api_enabled() and not (M.request_has_admin_token() or M.request_has_session()) then
    json_error(401, "login required")
    return false
  end

  if not M.enforce_csrf() then
    return false
  end

  return true
end

function M.enforce_ui()
  if not M.ui_enabled() then
    json_error(404, "console ui disabled")
    return false
  end

  if M.local_only() and not (M.request_is_local() or M.request_has_admin_token()) then
    json_error(403, "console ui local-only")
    return false
  end

  if not M.enforce_csrf() then
    return false
  end

  return true
end

function M.enforce_write()
  if M.request_has_admin_token() then
    return true
  end

  if not M.write_enabled() then
    json_error(403, "console write disabled")
    return false
  end

  if M.local_only() and not M.request_is_local() then
    json_error(403, "console write local-only")
    return false
  end

  return true
end

function M.write_json(status, obj)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json"
  ngx.say(cjson.encode(obj))
end

function M.state_snapshot()
  return {
    ui_enabled = M.ui_enabled(),
    api_enabled = M.api_enabled(),
    admin_api_enabled = M.admin_api_enabled(),
    write_enabled = M.write_enabled(),
    local_only = M.local_only(),
    login_enabled = M.login_enabled(),
    login_api_enabled = M.login_api_enabled(),
    public_explore = M.public_explore(),
    current_user = M.current_session_user(),
  }
end

function M.update_state(payload)
  if type(payload) ~= "table" then
    return nil, "payload must be an object"
  end

  local store = state_store()
  if not store then
    return nil, "state store unavailable"
  end

  for field, key in pairs(STATE_KEYS) do
    local value = payload[field]
    if value ~= nil then
      if type(value) ~= "boolean" then
        return nil, field .. " must be boolean"
      end
      store:set(key, value and 1 or 0)
    end
  end

  return M.state_snapshot()
end

function M.clear_state()
  local store = state_store()
  if not store then
    return nil, "state store unavailable"
  end

  for _, key in pairs(STATE_KEYS) do
    store:delete(key)
  end

  return M.state_snapshot()
end

function M.enforce_body_limit(max_bytes)
  max_bytes = max_bytes or 131072  -- 128KB default
  local cl = tonumber(ngx.req.get_headers()["content-length"])
  if cl and cl > max_bytes then
    M.write_json(413, { error = "payload too large" })
    return false
  end
  return true
end

function M.enforce_csrf()
  local method = ngx.req.get_method()
  if method == "GET" or method == "HEAD" or method == "OPTIONS" then
    return true
  end
  -- Skip CSRF check when authenticating via admin token header
  if M.request_has_admin_token() then
    return true
  end
  local hdr = ngx.req.get_headers()["x-fn-request"]
  if hdr ~= "1" then
    M.write_json(403, { error = "missing CSRF header" })
    return false
  end
  return true
end

return M
