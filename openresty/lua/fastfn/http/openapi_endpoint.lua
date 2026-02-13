local cjson = require "cjson.safe"
local routes_mod = require "fastfn.core.routes"
local openapi = require "fastfn.core.openapi"

local host = ngx.var.http_host or "localhost:8080"
local server_url = string.format("%s://%s", ngx.var.scheme or "http", host)

local catalog = routes_mod.discover_functions(false)
local spec = openapi.build(catalog, {
  server_url = server_url,
  runtime_order = routes_mod.get_runtime_order(),
})

ngx.status = 200
ngx.header["Content-Type"] = "application/json"
ngx.say(cjson.encode(spec))
