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

local mode = string.lower(tostring(payload.mode or "generate"))
if mode ~= "generate" and mode ~= "chat" and mode ~= "auto" then
  guard.write_json(400, { error = "mode must be generate, chat, or auto" })
  return
end

-- Chat mode is read-like (no writes); code generation remains write-gated.
if mode ~= "chat" then
  if not guard.enforce_write() then
    return
  end
end

local text, err, resolved_mode = assistant.generate({
  runtime = payload.runtime,
  name = payload.name,
  template = payload.template,
  prompt = payload.prompt,
  timeout_ms = payload.timeout_ms,
  mode = mode,
  current_code = payload.current_code,
  chat_history = payload.chat_history,
  test_result = payload.test_result,
})
if not text then
  if err == "assistant disabled" then
    guard.write_json(404, { error = "assistant disabled" })
  else
    guard.write_json(400, { error = err or "assistant failed" })
  end
  return
end

local out = {
  runtime = tostring(payload.runtime or ""),
  name = tostring(payload.name or ""),
  template = tostring(payload.template or ""),
  mode = tostring(resolved_mode or mode),
}
if tostring(resolved_mode or mode) == "chat" then
  out.message = text
else
  out.code = text
end

guard.write_json(200, out)
