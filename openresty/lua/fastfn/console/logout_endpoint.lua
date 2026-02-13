local guard = require "fastfn.console.guard"
local auth = require "fastfn.console.auth"

if not guard.enforce_api({ skip_login = true }) then
  return
end

if ngx.req.get_method() ~= "POST" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

auth.clear_session_cookie()
guard.write_json(200, { ok = true })

