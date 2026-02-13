local cjson = require "cjson.safe"
local guard = require "fastfn.console.guard"
local assistant = require "fastfn.core.assistant"

if not guard.enforce_api() then
  return
end

if ngx.req.get_method() ~= "POST" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

ngx.req.read_body()
local payload = cjson.decode(ngx.req.get_body_data() or "")
if type(payload) ~= "table" then
  guard.write_json(400, { error = "invalid json body" })
  return
end

-- Treat assistant as a write-level feature (local-only by default, admin token override).
if not guard.enforce_write() then
  return
end

local code, err = assistant.generate({
  runtime = payload.runtime,
  name = payload.name,
  template = payload.template,
  prompt = payload.prompt,
  timeout_ms = payload.timeout_ms,
})
if not code then
  if err == "assistant disabled" then
    guard.write_json(404, { error = "assistant disabled" })
  else
    guard.write_json(400, { error = err or "assistant failed" })
  end
  return
end

guard.write_json(200, {
  runtime = tostring(payload.runtime or ""),
  name = tostring(payload.name or ""),
  template = tostring(payload.template or ""),
  code = code,
})
