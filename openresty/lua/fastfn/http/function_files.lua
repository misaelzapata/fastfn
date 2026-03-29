local cjson = require "cjson.safe"
local guard = require "fastfn.console.guard"
local console = require "fastfn.console.data"

if not guard.enforce_api() then
  return
end

if ngx.req.get_method() ~= "GET" then
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

local result, err = console.function_files(runtime, name, version)
if not result then
  guard.write_json(404, { error = err or "not found" })
  return
end

guard.write_json(200, result)
