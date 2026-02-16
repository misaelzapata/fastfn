local cjson = require "cjson.safe"
local guard = require "fastfn.console.guard"
local console = require "fastfn.console.data"

if not guard.enforce_api() then
  return
end

local method = ngx.req.get_method()
if method ~= "GET" and method ~= "POST" and method ~= "DELETE" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

if method == "GET" then
  -- In a real implementation this would fetch from a secrets store (e.g. Vault or encrypted JSON)
  -- Current implementation reads from console.data backing store.
  local secrets = console.list_secrets() or {}
  guard.write_json(200, secrets)
  return
end

-- Write operations
if not guard.enforce_write() then
  return
end

if method == "POST" then
  ngx.req.read_body()
  local payload = cjson.decode(ngx.req.get_body_data() or "")
  if type(payload) ~= "table" or not payload.key or not payload.value then
    guard.write_json(400, { error = "invalid json body: require key/value" })
    return
  end
  
  local ok, err = console.set_secret(payload.key, payload.value)
  if not ok then
      guard.write_json(500, { error = err or "failed to set secret" })
      return
  end
  guard.write_json(201, { status = "created", key = payload.key })
  return
end

if method == "DELETE" then
  local args = ngx.req.get_uri_args()
  local key = args.key
  if not key then
      guard.write_json(400, { error = "missing key parameter" })
      return
  end
  
  local ok, err = console.delete_secret(key)
  if not ok then
      guard.write_json(500, { error = err or "failed to delete secret" })
      return
  end
  guard.write_json(200, { status = "deleted", key = key })
  return
end
