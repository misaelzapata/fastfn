local M = {}

function M.parse_versioned_target(uri)
  if type(uri) ~= "string" then
    return nil, nil
  end

  local name, version = uri:match("^/([%w_-]+)@([%w_.-]+)$")
  if name then
    return name, version
  end

  return nil, nil
end

function M.resolve_numeric(version_value, runtime_value, default_value, fallback)
  local v = tonumber(version_value)
  if v then
    return v
  end

  v = tonumber(runtime_value)
  if v then
    return v
  end

  v = tonumber(default_value)
  if v then
    return v
  end

  return fallback
end

function M.map_runtime_error(err_code)
  if err_code == "timeout" then
    return 504, "runtime timeout"
  end

  if err_code == "connect_error" then
    return 503, "runtime unavailable"
  end

  if err_code == "invalid_response" then
    return 502, "invalid runtime response"
  end

  return 502, "runtime error"
end

return M
