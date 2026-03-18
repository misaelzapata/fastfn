local cjson = require "cjson.safe"
local guard = require "fastfn.console.guard"
local auth = require "fastfn.console.auth"

if not guard.enforce_api({ skip_login = true }) then
  return
end

if ngx.req.get_method() ~= "POST" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

if not auth.login_enabled() then
  guard.write_json(404, { error = "login disabled" })
  return
end

-- Brute-force protection: track failed attempts per IP
local LOGIN_MAX_ATTEMPTS = 5
local LOGIN_WINDOW_S = 300  -- 5 minutes

local function login_rate_key(ip)
  return "login:fail:" .. (ip or "unknown")
end

local client_ip = ngx.var.remote_addr or "unknown"
local rate_store = ngx.shared.fn_cache
if rate_store then
  local fail_count = rate_store:get(login_rate_key(client_ip))
  if type(fail_count) == "number" and fail_count >= LOGIN_MAX_ATTEMPTS then
    guard.write_json(429, { error = "too many login attempts, try again later" })
    return
  end
end

if not guard.enforce_body_limit() then
  return
end

ngx.req.read_body()
local payload = cjson.decode(ngx.req.get_body_data() or "")
if type(payload) ~= "table" then
  guard.write_json(400, { error = "invalid json body" })
  return
end

local username = payload.username
local password = payload.password
if type(username) ~= "string" or username == "" or type(password) ~= "string" then
  guard.write_json(400, { error = "username and password are required" })
  return
end

local expected_user = auth.username()
local expected_pass = auth.password()
if not expected_user or not expected_pass then
  guard.write_json(500, { error = "login is enabled but credentials are not configured" })
  return
end

if username ~= expected_user or password ~= expected_pass then
  if rate_store then
    local key = login_rate_key(client_ip)
    local newval, err = rate_store:incr(key, 1, 0, LOGIN_WINDOW_S)
    if not newval and err then
      ngx.log(ngx.WARN, "[login] failed to track login attempt: ", err)
    end
  end
  guard.write_json(401, { error = "invalid credentials" })
  return
end

local ok, err = auth.set_session_cookie(username)
if not ok then
  guard.write_json(500, { error = err or "failed to set session" })
  return
end

guard.write_json(200, { ok = true, user = username })

