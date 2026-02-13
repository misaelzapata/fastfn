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
  guard.write_json(401, { error = "invalid credentials" })
  return
end

local ok, err = auth.set_session_cookie(username)
if not ok then
  guard.write_json(500, { error = err or "failed to set session" })
  return
end

guard.write_json(200, { ok = true, user = username })

