local cjson = require "cjson.safe"
local guard = require "fastfn.console.guard"
local routes = require "fastfn.core.routes"

if not guard.enforce_api() then
  return
end

if ngx.req.get_method() ~= "POST" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

ngx.req.read_body()
local payload = cjson.decode(ngx.req.get_body_data() or "")
if type(payload) ~= "table" then
  guard.write_json(400, { error = "invalid json body" })
  return
end

local name = payload.name
local version = payload.version
local runtime = payload.runtime
local method = string.upper(tostring(payload.method or "GET"))
local context = payload.context

if version == cjson.null or version == "" then
  version = nil
end
if runtime == cjson.null or runtime == "" then
  runtime = nil
end

if type(name) ~= "string" then
  guard.write_json(400, { error = "name is required" })
  return
end
if runtime ~= nil and (type(runtime) ~= "string" or runtime == "") then
  guard.write_json(400, { error = "runtime must be a non-empty string when provided" })
  return
end

if method ~= "GET" and method ~= "POST" and method ~= "PUT" and method ~= "PATCH" and method ~= "DELETE" then
  guard.write_json(400, { error = "unsupported method" })
  return
end

local resolved_runtime = runtime
local resolved_version = version

if resolved_runtime then
  local policy, perr = routes.resolve_function_policy(resolved_runtime, name, resolved_version)
  if not policy then
    routes.discover_functions(true)
    policy, perr = routes.resolve_function_policy(resolved_runtime, name, resolved_version)
    if not policy then
      guard.write_json(404, { error = perr or "unknown function or version" })
      return
    end
  end
else
  local resolve_err
  resolved_runtime, resolved_version, resolve_err = routes.resolve_legacy_target(name, resolved_version)
  if not resolved_runtime then
    routes.discover_functions(true)
    resolved_runtime, resolved_version, resolve_err = routes.resolve_legacy_target(name, resolved_version)
  end
  if not resolved_runtime then
    if resolve_err then
      guard.write_json(409, { error = resolve_err })
      return
    end
    guard.write_json(404, { error = "unknown function or version" })
    return
  end
end

local policy, policy_err = routes.resolve_function_policy(resolved_runtime, name, resolved_version)
if not policy then
  guard.write_json(404, { error = policy_err or "unknown function or version" })
  return
end

local allowed = {}
local allowed_set = {}
for _, m in ipairs(type(policy.methods) == "table" and policy.methods or { "GET" }) do
  local mm = string.upper(tostring(m))
  if mm ~= "" and not allowed_set[mm] then
    allowed_set[mm] = true
    allowed[#allowed + 1] = mm
  end
end
if not allowed_set[method] then
  guard.write_json(405, { error = "method not allowed", allowed_methods = allowed })
  return
end

local uri = "/fn/" .. name
if type(resolved_version) == "string" and resolved_version ~= "" then
  uri = uri .. "@" .. resolved_version
end

local query = type(payload.query) == "table" and payload.query or {}
local body = payload.body
if body ~= nil and type(body) ~= "string" then
  local encoded = cjson.encode(body)
  if not encoded then
    guard.write_json(400, { error = "body must be a string or JSON-encodable value" })
    return
  end
  body = encoded
end

if context ~= nil then
  if type(context) ~= "table" then
    guard.write_json(400, { error = "context must be an object" })
    return
  end
  local encoded_ctx = cjson.encode(context)
  if not encoded_ctx then
    guard.write_json(400, { error = "context is not JSON-encodable" })
    return
  end
  query.__fnctx = ngx.encode_base64(encoded_ctx)
end

local start = ngx.now()
local res = ngx.location.capture(uri, {
  method = ({
    GET = ngx.HTTP_GET,
    POST = ngx.HTTP_POST,
    PUT = ngx.HTTP_PUT,
    PATCH = ngx.HTTP_PATCH,
    DELETE = ngx.HTTP_DELETE,
  })[method] or ngx.HTTP_GET,
  args = query,
  body = type(body) == "string" and body or nil,
  copy_all_vars = true,
})
local elapsed_ms = math.floor((ngx.now() - start) * 1000)

if not res then
  guard.write_json(502, { error = "failed to invoke function" })
  return
end

local headers = {}
for k, v in pairs(res.header or {}) do
  if type(k) == "string" then
    headers[k] = v
  end
end

local content_type = headers["Content-Type"] or headers["content-type"] or ""
local is_text_like = string.find(string.lower(content_type), "json", 1, true)
  or string.find(string.lower(content_type), "text/", 1, true)
  or content_type == ""

if is_text_like then
  guard.write_json(200, {
    status = res.status,
    latency_ms = elapsed_ms,
    headers = headers,
    body = res.body or "",
  })
  return
end

guard.write_json(200, {
  status = res.status,
  latency_ms = elapsed_ms,
  headers = headers,
  is_base64 = true,
  body_base64 = ngx.encode_base64(res.body or ""),
})
