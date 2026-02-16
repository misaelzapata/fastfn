local cjson = require "cjson.safe"

local M = {}

local COOKIE_NAME = "fastfn_session"
local DEFAULT_TTL_S = 12 * 60 * 60

local function env_bool(name, default_value)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default_value
  end
  raw = string.lower(tostring(raw))
  if raw == "0" or raw == "false" or raw == "off" or raw == "no" then
    return false
  end
  if raw == "1" or raw == "true" or raw == "yes" or raw == "on" then
    return true
  end
  return default_value
end

local function env_str(name)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return nil
  end
  return tostring(raw)
end

local function env_num(name, default_value)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default_value
  end
  local n = tonumber(raw)
  if not n then
    return default_value
  end
  return n
end

function M.login_enabled()
  return env_bool("FN_CONSOLE_LOGIN_ENABLED", false)
end

function M.api_login_enabled()
  return env_bool("FN_CONSOLE_LOGIN_API", false)
end

function M.cookie_name()
  return COOKIE_NAME
end

function M.username()
  return env_str("FN_CONSOLE_LOGIN_USERNAME")
end

function M.password()
  return env_str("FN_CONSOLE_LOGIN_PASSWORD")
end

local function session_secret()
  -- Prefer a dedicated secret; fall back to admin token if present.
  return env_str("FN_CONSOLE_SESSION_SECRET") or env_str("FN_ADMIN_TOKEN")
end

local function hmac(secret, payload)
  -- Built-in OpenResty primitive.
  local sig = ngx.hmac_sha1(secret, payload)
  return ngx.encode_base64(sig)
end

local function parse_cookies()
  local raw = ngx.var.http_cookie or ""
  local out = {}
  for part in raw:gmatch("([^;]+)") do
    local k, v = part:match("^%s*([^=]+)%s*=%s*(.*)%s*$")
    if k and v then
      out[k] = v
    end
  end
  return out
end

function M.read_session()
  local secret = session_secret()
  if not secret or secret == "" then
    return nil, "session secret not configured"
  end

  local cookies = parse_cookies()
  local token = cookies[COOKIE_NAME]
  if not token or token == "" then
    return nil, "no session"
  end

  local p64, sig64 = token:match("^([^%.]+)%.([^%.]+)$")
  if not p64 or not sig64 then
    return nil, "invalid session token"
  end

  local payload = ngx.decode_base64(p64)
  if not payload then
    return nil, "invalid session payload"
  end

  local expected = hmac(secret, payload)
  if expected ~= sig64 then
    return nil, "invalid session signature"
  end

  local obj = cjson.decode(payload)
  if type(obj) ~= "table" then
    return nil, "invalid session json"
  end

  local exp = tonumber(obj.exp)
  if not exp or exp <= 0 then
    return nil, "invalid session exp"
  end
  if exp < ngx.time() then
    return nil, "session expired"
  end

  if type(obj.user) ~= "string" or obj.user == "" then
    return nil, "invalid session user"
  end

  return { user = obj.user, exp = exp }
end

function M.set_session_cookie(user)
  local secret = session_secret()
  if not secret or secret == "" then
    return nil, "session secret not configured"
  end
  if type(user) ~= "string" or user == "" then
    return nil, "invalid user"
  end

  local ttl = env_num("FN_CONSOLE_SESSION_TTL_S", DEFAULT_TTL_S)
  if not ttl or ttl <= 0 then
    ttl = DEFAULT_TTL_S
  end
  ttl = math.floor(ttl)

  local exp = ngx.time() + ttl
  local payload = cjson.encode({ user = user, exp = exp })
  if not payload then
    return nil, "failed to encode session"
  end
  local p64 = ngx.encode_base64(payload)
  local sig64 = hmac(secret, payload)
  local token = p64 .. "." .. sig64

  local cookie = string.format("%s=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d", COOKIE_NAME, token, ttl)
  ngx.header["Set-Cookie"] = cookie
  return true
end

function M.clear_session_cookie()
  ngx.header["Set-Cookie"] = string.format("%s=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0", COOKIE_NAME)
  return true
end

return M

