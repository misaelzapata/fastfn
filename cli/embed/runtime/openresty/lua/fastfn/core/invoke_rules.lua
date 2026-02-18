local M = {}

M.DEFAULT_METHODS = { "GET" }
M.ALLOWED_METHODS = {
  GET = true,
  POST = true,
  PUT = true,
  PATCH = true,
  DELETE = true,
}
M.RESERVED_ROUTE_PREFIXES = {
  "/_fn",
  "/console",
}
M.RESERVED_ROUTE_EXACT = {
  ["/"] = true,
}

local function copy_list(input)
  local out = {}
  for _, v in ipairs(type(input) == "table" and input or {}) do
    out[#out + 1] = v
  end
  return out
end

function M.parse_methods(raw)
  local seen = {}
  local out = {}

  local function add_method(v)
    local m = tostring(v):upper()
    if M.ALLOWED_METHODS[m] and not seen[m] then
      seen[m] = true
      out[#out + 1] = m
    end
  end

  if type(raw) == "table" then
    for _, v in ipairs(raw) do
      add_method(v)
    end
  elseif type(raw) == "string" then
    for token in raw:gmatch("[A-Za-z]+") do
      add_method(token)
    end
  end

  if #out == 0 then
    return nil
  end
  return out
end

function M.normalized_methods(raw, fallback)
  local parsed = M.parse_methods(raw)
  if parsed and #parsed > 0 then
    return parsed
  end
  return copy_list(fallback or M.DEFAULT_METHODS)
end

function M.route_is_reserved(route)
  if M.RESERVED_ROUTE_EXACT[route] then
    return true
  end
  for _, p in ipairs(M.RESERVED_ROUTE_PREFIXES) do
    if route == p or route:sub(1, #p + 1) == (p .. "/") then
      return true
    end
  end
  return false
end

function M.normalize_route(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local route = raw:gsub("^%s+", ""):gsub("%s+$", "")
  if route == "" or route:sub(1, 1) ~= "/" then
    return nil
  end
  route = route:gsub("//+", "/")
  if #route > 1 then
    route = route:gsub("/+$", "")
    if route == "" then
      route = "/"
    end
  end
  if route:find("%.%.", 1, true) then
    return nil
  end
  if M.route_is_reserved(route) then
    return nil
  end
  return route
end

function M.parse_route_list(input, max_items)
  local seen = {}
  local out = {}

  local function add(v)
    local route = M.normalize_route(v)
    if route and not seen[route] then
      seen[route] = true
      out[#out + 1] = route
      if max_items and #out >= max_items then
        return true
      end
    end
    return false
  end

  if type(input) == "string" then
    add(input)
  elseif type(input) == "table" then
    for _, v in ipairs(input) do
      if add(v) then
        break
      end
    end
  end

  return out
end

function M.parse_invoke_routes(invoke)
  if type(invoke) ~= "table" then
    return nil
  end

  local routes = {}
  local seen = {}

  local function merge(list)
    for _, route in ipairs(list) do
      if not seen[route] then
        seen[route] = true
        routes[#routes + 1] = route
      end
    end
  end

  if invoke.route ~= nil then
    merge(M.parse_route_list(invoke.route))
  end
  if type(invoke.routes) == "table" then
    merge(M.parse_route_list(invoke.routes))
  end

  if #routes == 0 then
    if invoke.route ~= nil or type(invoke.routes) == "table" then
      return {}
    end
    return nil
  end
  return routes
end

return M
