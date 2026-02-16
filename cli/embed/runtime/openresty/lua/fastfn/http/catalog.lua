local guard = require "fastfn.console.guard"
local console = require "fastfn.console.data"

if not guard.enforce_api() then
  return
end

if ngx.req.get_method() ~= "GET" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

guard.write_json(200, console.catalog())
