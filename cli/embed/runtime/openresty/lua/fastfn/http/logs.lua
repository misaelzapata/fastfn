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
local runtime = args.runtime and tostring(args.runtime) or nil
local fn_name = args.fn and tostring(args.fn) or nil
local version = args.version and tostring(args.version) or nil
local stream = tostring(args.stream or "all")

if lines < 1 then lines = 1 end
if lines > 2000 then lines = 2000 end

local log_name
if file == "error" then
  log_name = "/app/openresty/logs/error.log"
elseif file == "access" then
  log_name = "/app/openresty/logs/access.log"
elseif file == "runtime" then
  log_name = "/app/openresty/logs/runtime.log"
else
  guard.write_json(400, { error = "invalid file" })
  return
end

if stream ~= "all" and stream ~= "stdout" and stream ~= "stderr" then
  guard.write_json(400, { error = "invalid stream" })
  return
end

local function is_non_empty(value)
  return type(value) == "string" and value ~= ""
end

local function line_matches(line)
  if not is_non_empty(line) then
    return false
  end
  if is_non_empty(runtime) and not line:find("[" .. runtime .. "]", 1, true) then
    return false
  end
  if is_non_empty(fn_name) and not line:find("[fn:" .. fn_name .. "@", 1, true) then
    return false
  end
  if is_non_empty(version) and not line:find("@" .. version .. " ", 1, true) then
    return false
  end
  if stream == "stdout" and not line:find(" stdout]", 1, true) then
    return false
  end
  if stream == "stderr" and not line:find(" stderr]", 1, true) then
    return false
  end
  return true
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
  if line ~= "" and line_matches(line) then
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
    runtime = runtime,
    fn = fn_name,
    version = version,
    stream = stream,
    data = out_lines,
  })
  return
end

ngx.status = 200
ngx.header["Content-Type"] = "text/plain; charset=utf-8"
ngx.say(table.concat(out_lines, "\n"))
