local guard = require "fastfn.console.guard"
local cjson = require "cjson.safe"

local method = ngx.req.get_method()
if method ~= "GET" and method ~= "PUT" and method ~= "PATCH" and method ~= "POST" and method ~= "DELETE" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

if not guard.enforce_api() then
  return
end

if method == "GET" then
  guard.write_json(200, guard.state_snapshot())
  return
end

if not guard.enforce_write() then
  return
end

if method == "DELETE" then
  local cleared, cerr = guard.clear_state()
  if not cleared then
    guard.write_json(500, { error = cerr or "reset failed" })
    return
  end
  guard.write_json(200, cleared)
  return
end

ngx.req.read_body()
local payload = cjson.decode(ngx.req.get_body_data() or "")
if type(payload) ~= "table" then
  guard.write_json(400, { error = "invalid json body" })
  return
end

local updated, err = guard.update_state(payload)
if not updated then
  guard.write_json(400, { error = err or "update failed" })
  return
end

guard.write_json(200, updated)
