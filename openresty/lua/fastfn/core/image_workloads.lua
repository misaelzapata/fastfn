local cjson = require "cjson.safe"

local M = {}

local function read_json_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" then
    return nil
  end
  local parsed = cjson.decode(raw)
  if type(parsed) ~= "table" then
    return nil
  end
  return parsed
end

local function state_path()
  local path = tostring(os.getenv("FN_IMAGE_WORKLOADS_STATE_PATH") or "")
  if path == "" then
    return nil
  end
  return path
end

local function load_state()
  local path = state_path()
  if not path then
    return {
      apps = {},
      services = {},
    }
  end
  local parsed = read_json_file(path)
  if type(parsed) ~= "table" then
    return {
      apps = {},
      services = {},
    }
  end
  parsed.apps = type(parsed.apps) == "table" and parsed.apps or {}
  parsed.services = type(parsed.services) == "table" and parsed.services or {}
  return parsed
end

local function sorted_keys(tbl)
  local out = {}
  for key, _ in pairs(tbl or {}) do
    out[#out + 1] = key
  end
  table.sort(out)
  return out
end

local function route_matches(route, request_path)
  route = tostring(route or "")
  request_path = tostring(request_path or "")
  if request_path == "" then
    request_path = "/"
  end
  if route == "" then
    return false
  end
  if route == request_path then
    return true
  end
  if route:sub(-2) == "/*" then
    local prefix = route:sub(1, -3)
    if prefix == "" then
      return request_path:sub(1, 1) == "/"
    end
    return request_path == prefix or request_path:sub(1, #prefix + 1) == prefix .. "/"
  end
  return false
end

local function workload_public_endpoints(workload)
  if type(workload) ~= "table" then
    return {}
  end
  if type(workload.public_endpoints) == "table" and #workload.public_endpoints > 0 then
    return workload.public_endpoints
  end
  local routes = type(workload.routes) == "table" and workload.routes or {}
  if #routes == 0 then
    return {}
  end
  local host = tostring(workload.host or "")
  local port = tonumber(workload.port)
  if host == "" or not port or port < 1 then
    return {}
  end
  return {
    {
      name = "default",
      protocol = "http",
      host = host,
      port = port,
      routes = routes,
      allow_hosts = {},
      allow_cidrs = {},
    },
  }
end

function M.function_env()
  local state = load_state()
  local env = {}
  for _, service_name in ipairs(sorted_keys(state.services)) do
    local service = state.services[service_name]
    local service_env = type(service) == "table" and type(service.function_env) == "table" and service.function_env or {}
    for key, value in pairs(service_env) do
      env[tostring(key)] = tostring(value)
    end
  end
  return env
end

function M.public_http_candidates(request_path)
  local state = load_state()
  local candidates = {}

  for _, kind in ipairs({ "apps", "services" }) do
    for _, workload_name in ipairs(sorted_keys(state[kind])) do
      local workload = state[kind][workload_name]
      for _, endpoint in ipairs(workload_public_endpoints(workload)) do
        if tostring(endpoint.protocol or "http") == "http" then
          local routes = type(endpoint.routes) == "table" and endpoint.routes or {}
          for _, route in ipairs(routes) do
            if route_matches(route, request_path) then
              candidates[#candidates + 1] = {
                kind = kind == "apps" and "app" or "service",
                name = workload_name,
                workload = workload,
                endpoint = endpoint,
                route = route,
                route_length = #tostring(route),
              }
            end
          end
        end
      end
    end
  end

  return candidates
end

function M.match_app(request_path)
  local best
  local best_score = -1
  for _, candidate in ipairs(M.public_http_candidates(request_path)) do
    if candidate.kind == "app" then
      local score = tonumber(candidate.route_length) or 0
      if score > best_score then
        best = candidate.workload
        best_score = score
      end
    end
  end
  return best
end

function M.health_snapshot()
  local state = load_state()
  return {
    apps = state.apps or {},
    services = state.services or {},
  }
end

return M
