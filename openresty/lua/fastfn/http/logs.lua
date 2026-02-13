local guard = require "fastfn.console.guard"
local cjson = require "cjson.safe"

if not guard.enforce_api() then
  return
end

if ngx.req.get_method() ~= "GET" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

local args = ngx.req.get_uri_args()
local file = tostring(args.file or "error")
local lines = tonumber(args.lines) or 200
local format = tostring(args.format or "text")

if lines < 1 then lines = 1 end
if lines > 2000 then lines = 2000 end

local log_name
if file == "error" then
  log_name = "/app/openresty/logs/error.log"
elseif file == "access" then
  log_name = "/app/openresty/logs/access.log"
else
  guard.write_json(400, { error = "invalid file" })
  return
end

local function read_tail(path, max_bytes)
  local f = io.open(path, "rb")
  if not f then return nil, "log not found" end
  local size = f:seek("end")
  if not size then
    f:close()
    return nil, "seek failed"
  end
  local start = size - max_bytes
  if start < 0 then start = 0 end
  f:seek("set", start)
  local data = f:read("*a") or ""
  f:close()
  return data
end

local chunk, err = read_tail(log_name, 256 * 1024)
if not chunk then
  guard.write_json(404, { error = err or "log not found" })
  return
end

local all = {}
for line in chunk:gmatch("([^\n]*)\n?") do
  if line ~= "" then
    all[#all + 1] = line
  end
end

local start_idx = #all - lines + 1
if start_idx < 1 then start_idx = 1 end
local out_lines = {}
for i = start_idx, #all do
  out_lines[#out_lines + 1] = all[i]
end

if format == "json" then
  guard.write_json(200, {
    file = file,
    lines = #out_lines,
    data = out_lines,
  })
  return
end

ngx.status = 200
ngx.header["Content-Type"] = "text/plain; charset=utf-8"
ngx.say(table.concat(out_lines, "\n"))
