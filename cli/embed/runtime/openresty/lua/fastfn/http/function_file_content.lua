local cjson = require "cjson.safe"
local guard = require "fastfn.console.guard"
local console = require "fastfn.console.data"

if not guard.enforce_api() then
  return
end

local method = ngx.req.get_method()
local args = ngx.req.get_uri_args()
local runtime = args.runtime
local name = args.name
local path = args.path
local version = args.version
if version == "" then
  version = nil
end

if not runtime or not name then
  guard.write_json(400, { error = "runtime and name required" })
  return
end

if method == "GET" then
  -- Read file content
  if not path or path == "" then
    guard.write_json(400, { error = "path required" })
    return
  end
  local result, err = console.read_function_file(runtime, name, path, version)
  if not result then
    guard.write_json(404, { error = err or "not found" })
    return
  end
  guard.write_json(200, result)

elseif method == "PUT" then
  -- Write file content
  ngx.req.read_body()
  local body = ngx.req.get_body_data()
  local payload = cjson.decode(body or "")
  if not payload or not payload.path then
    guard.write_json(400, { error = "path and content required in JSON body" })
    return
  end
  local result, err = console.write_function_file(
    runtime, name, payload.path, payload.content or "", version
  )
  if not result then
    guard.write_json(400, { error = err or "write failed" })
    return
  end
  guard.write_json(200, result)

elseif method == "DELETE" then
  -- Delete file
  if not path or path == "" then
    guard.write_json(400, { error = "path required" })
    return
  end
  local result, err = console.delete_function_file(runtime, name, path, version)
  if not result then
    guard.write_json(400, { error = err or "delete failed" })
    return
  end
  guard.write_json(200, result)

else
  guard.write_json(405, { error = "method not allowed" })
end
