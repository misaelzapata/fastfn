local guard = require "fastfn.console.guard"
local console = require "fastfn.console.data"
local cjson = require "cjson.safe"

if not guard.enforce_api() then
  return
end

local method = ngx.req.get_method()
if method ~= "GET" and method ~= "POST" and method ~= "DELETE" then
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

if method == "POST" or method == "DELETE" then
  if not guard.enforce_write() then
    return
  end
end

if method == "POST" then
  ngx.req.read_body()
  local payload = {}
  local raw = ngx.req.get_body_data()
  if raw and raw ~= "" then
    payload = cjson.decode(raw)
    if type(payload) ~= "table" then
      guard.write_json(400, { error = "invalid json body" })
      return
    end
  end

  local created, err = console.create_function(runtime, name, version, payload)
  if not created then
    guard.write_json(400, { error = err or "create failed" })
    return
  end

  guard.write_json(201, created)
  return
end

if method == "DELETE" then
  local deleted, err = console.delete_function(runtime, name, version)
  if not deleted then
    guard.write_json(400, { error = err or "delete failed" })
    return
  end
  guard.write_json(200, deleted)
  return
end

local include_code = tostring(args.include_code or "1") ~= "0"

local detail, err = console.function_detail(runtime, name, version, include_code)
if not detail then
  guard.write_json(404, { error = err or "not found" })
  return
end

guard.write_json(200, detail)
