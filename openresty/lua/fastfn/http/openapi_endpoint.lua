local cjson = require "cjson.safe"
local routes_mod = require "fastfn.core.routes"
local openapi = require "fastfn.core.openapi"
local console_data = require "fastfn.console.data"

local function docs_enabled()
  local raw = os.getenv("FN_DOCS_ENABLED")
  if raw == nil or raw == "" then
    return true
  end
  raw = string.lower(raw)
  return not (raw == "0" or raw == "false" or raw == "off" or raw == "no")
end

local function env_bool(name, default_value)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default_value
  end
  raw = string.lower(tostring(raw))
  return not (raw == "0" or raw == "false" or raw == "off" or raw == "no")
end

if not docs_enabled() then
  ngx.status = 404
  ngx.header["Content-Type"] = "application/json"
  ngx.say(cjson.encode({ error = "docs disabled" }))
  return
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function first_csv_token(value)
  local raw = trim(value)
  if raw == "" then
    return nil
  end
  local first = raw:match("^([^,]+)")
  return trim(first)
end

local function detect_server_url()
  local forced = trim(os.getenv("FN_PUBLIC_BASE_URL"))
  if forced ~= "" then
    return forced:gsub("/+$", "")
  end

  local xf_proto = first_csv_token(ngx.var.http_x_forwarded_proto)
  local xf_host = first_csv_token(ngx.var.http_x_forwarded_host)
  local scheme = xf_proto or trim(ngx.var.scheme) or "http"
  if scheme == "" then
    scheme = "http"
  end
  local host = xf_host or trim(ngx.var.http_host) or "localhost:8080"
  if host == "" then
    host = "localhost:8080"
  end
  return string.format("%s://%s", scheme, host)
end

local server_url = detect_server_url()

local catalog = routes_mod.discover_functions(false)
local invoke_meta_cache = {}
local function invoke_meta_lookup(runtime, name, version)
  local key = tostring(runtime or "") .. "|" .. tostring(name or "") .. "|" .. tostring(version or "")
  if invoke_meta_cache[key] ~= nil then
    if invoke_meta_cache[key] == false then
      return nil
    end
    return invoke_meta_cache[key]
  end

  local detail, err = console_data.function_detail(runtime, name, version, false)
  if not detail or err then
    invoke_meta_cache[key] = false
    return nil
  end

  local meta = detail.metadata
  if type(meta) == "table" and type(meta.invoke) == "table" then
    invoke_meta_cache[key] = meta.invoke
    return meta.invoke
  end

  invoke_meta_cache[key] = false
  return nil
end

local spec = openapi.build(catalog, {
  server_url = server_url,
  runtime_order = routes_mod.get_runtime_order(),
  include_internal = env_bool("FN_OPENAPI_INCLUDE_INTERNAL", false),
  invoke_meta_lookup = invoke_meta_lookup,
})

ngx.status = 200
ngx.header["Content-Type"] = "application/json"
ngx.say(cjson.encode(spec))
