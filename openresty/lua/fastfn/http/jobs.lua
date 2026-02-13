local cjson = require "cjson.safe"
local guard = require "fastfn.console.guard"
local jobs = require "fastfn.core.jobs"

if not guard.enforce_api() then
  return
end

local method = ngx.req.get_method()
if method ~= "GET" and method ~= "POST" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

if method == "GET" then
  local args = ngx.req.get_uri_args()
  local limit = args.limit
  guard.write_json(200, { jobs = jobs.list(limit) })
  return
end

if not guard.enforce_write() then
  return
end

ngx.req.read_body()
local payload = cjson.decode(ngx.req.get_body_data() or "")
if type(payload) ~= "table" then
  guard.write_json(400, { error = "invalid json body" })
  return
end

local meta, status, err, headers = jobs.enqueue(payload)
if not meta then
  ngx.status = status or 400
  if type(headers) == "table" then
    for k, v in pairs(headers) do
      ngx.header[k] = v
    end
  end
  guard.write_json(ngx.status, { error = err or "enqueue failed" })
  return
end

ngx.status = status or 201
guard.write_json(ngx.status, meta)

