local cjson = require "cjson.safe"
local guard = require "fastfn.console.guard"
local console = require "fastfn.console.data"

if not guard.enforce_api() then
  return
end

local method = ngx.req.get_method()
if method ~= "GET" and method ~= "PUT" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

local args = ngx.req.get_uri_args()
local runtime = args.runtime
local name = args.name
local version = args.version
if version == "" then
  version = nil
end

if method == "GET" then
  local detail, err = console.function_detail(runtime, name, version, false)
  if not detail then
    guard.write_json(404, { error = err or "not found" })
    return
  end

  guard.write_json(200, {
    runtime = detail.runtime,
    name = detail.name,
    version = detail.version,
    fn_env = detail.fn_env or {},
    metadata = detail.metadata,
    file_path = detail.file_path,
    function_dir = detail.function_dir,
  })
  return
end

if not guard.enforce_write() then
  return
end

ngx.req.read_body()
local raw = ngx.req.get_body_data() or ""
local payload = cjson.decode(raw)
if type(payload) ~= "table" then
  guard.write_json(400, { error = "invalid json body" })
  return
end

local updated, err = console.set_function_env(runtime, name, version, payload)
if not updated then
  guard.write_json(400, { error = err or "update failed" })
  return
end

guard.write_json(200, {
  runtime = updated.runtime,
  name = updated.name,
  version = updated.version,
  fn_env = updated.fn_env or {},
  metadata = updated.metadata,
  file_path = updated.file_path,
  function_dir = updated.function_dir,
})
