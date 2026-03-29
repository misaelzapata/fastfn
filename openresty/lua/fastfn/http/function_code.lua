local cjson = require "cjson.safe"
local guard = require "fastfn.console.guard"
local console = require "fastfn.console.data"

if not guard.enforce_api() then
  return
end

if ngx.req.get_method() ~= "PUT" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

if not guard.enforce_write() then
  return
end

local args = ngx.req.get_uri_args()
local runtime = args.runtime
local name = args.name
local version = args.version
if version == "" then
  version = nil
end

ngx.req.read_body()
local raw = ngx.req.get_body_data() or ""
local payload = cjson.decode(raw)
if type(payload) ~= "table" then
  guard.write_json(400, { error = "invalid json body" })
  return
end

local updated, err = console.set_function_code(runtime, name, version, payload)
if not updated then
  guard.write_json(400, { error = err or "update failed" })
  return
end

guard.write_json(200, {
  runtime = updated.runtime,
  name = updated.name,
  version = updated.version,
  file_path = updated.file_path,
  function_dir = updated.function_dir,
  code = updated.code or "",
  code_truncated = updated.code_truncated == true,
  metadata = updated.metadata,
  policy = updated.policy,
})
