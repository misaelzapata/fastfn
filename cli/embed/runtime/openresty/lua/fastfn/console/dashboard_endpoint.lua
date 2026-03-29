local cjson = require "cjson.safe"
local guard = require "fastfn.console.guard"
local console = require "fastfn.console.data"

if not guard.enforce_api() then
  return
end

local method = ngx.req.get_method()
if method ~= "GET" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

-- Aggregate metrics from shared dicts or external systems
local metrics = console.get_dashboard_metrics()
guard.write_json(200, metrics or {
  invocations = {},
  errors = {},
  latency = {}
})
