local routes = require "fastfn.core.routes"
local guard = require "fastfn.console.guard"

if ngx.req.get_method() ~= "POST" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

if not guard.enforce_api() then
  return
end


local ok, result_or_err = pcall(routes.reload)
if not ok then
  guard.write_json(500, { error = "reload failed: " .. tostring(result_or_err) })
  return
end

local result = result_or_err or {}
local cfg = result.config or {}
local catalog = result.catalog or {}

guard.write_json(200, {
  ok = true,
  reloaded_at = ngx.now(),
  functions_root = cfg.functions_root,
  runtime_order = cfg.runtime_order,
  catalog_generated_at = catalog.generated_at,
})
