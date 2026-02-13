local guard = require "fastfn.console.guard"

if not guard.enforce_ui() then
  return
end

local path = ngx.var.uri or ""
local rel_path = path:match("^/console/assets/([a-zA-Z0-9_./-]+)$")
if not rel_path or rel_path:find("%.%.", 1, true) then
  ngx.status = 404
  ngx.say("not found")
  return
end

if not (rel_path:match("%.css$") or rel_path:match("%.js$")) then
  ngx.status = 404
  ngx.say("not found")
  return
end

local prefix = ngx.config.prefix() or ""
local asset_path = prefix .. "console/" .. rel_path
local f, err = io.open(asset_path, "rb")
if not f then
  ngx.status = 404
  ngx.say("asset not found: " .. tostring(err))
  return
end

local body = f:read("*a")
f:close()

if rel_path:match("%.css$") then
  ngx.header["Content-Type"] = "text/css; charset=utf-8"
else
  ngx.header["Content-Type"] = "application/javascript; charset=utf-8"
end
ngx.header["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
ngx.header["Pragma"] = "no-cache"
ngx.header["Expires"] = "0"

ngx.status = 200
ngx.print(body or "")
