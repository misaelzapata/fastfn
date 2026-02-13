local cjson = require "cjson.safe"
local invoke_rules = require "fastfn.core.invoke_rules"

local M = {}

local CACHE = ngx.shared.fn_cache
local DEFAULT_TIMEOUT_MS = 2500
local DEFAULT_MAX_CONCURRENCY = 20
local DEFAULT_MAX_BODY_BYTES = 1024 * 1024
local DEFAULT_HEALTH_INTERVAL = 2
local DEFAULT_HOT_RELOAD_INTERVAL = 2
local DEFAULT_METHODS = invoke_rules.DEFAULT_METHODS
local parse_methods = invoke_rules.parse_methods
local ALLOWED_METHODS = invoke_rules.ALLOWED_METHODS
local normalize_single_route = invoke_rules.normalize_route
local parse_invoke_routes = invoke_rules.parse_invoke_routes
local function normalize_edge(obj)
  if type(obj) ~= "table" then
    return nil
  end

  local base_url = obj.base_url
  if base_url ~= nil then
    if type(base_url) ~= "string" then
      base_url = tostring(base_url)
    end
    base_url = base_url:gsub("%s+$", ""):gsub("^%s+", "")
    if base_url == "" then
      base_url = nil
    end
  end

  local allow_hosts = obj.allow_hosts
  local hosts = {}
  if type(allow_hosts) == "table" then
    local seen = {}
    for _, v in ipairs(allow_hosts) do
      local h = tostring(v):gsub("^%s+", ""):gsub("%s+$", "")
      if h ~= "" and #h <= 200 and not seen[h] then
        seen[h] = true
        hosts[#hosts + 1] = h
      end
    end
  end

  local allow_private = obj.allow_private == true
  local max_response_bytes = tonumber(obj.max_response_bytes)
  if max_response_bytes and max_response_bytes > 0 then
    max_response_bytes = math.floor(max_response_bytes)
  else
    max_response_bytes = nil
  end

  if not base_url and #hosts == 0 and not allow_private and not max_response_bytes then
    return nil
  end

  return {
    base_url = base_url,
    allow_hosts = hosts,
    allow_private = allow_private,
    max_response_bytes = max_response_bytes,
  }
end

local function hot_reload_enabled()
  local raw = os.getenv("FN_HOT_RELOAD")
  if raw == nil or raw == "" then
    return true
  end
  raw = string.lower(raw)
  return not (raw == "0" or raw == "false" or raw == "off" or raw == "no")
end

local function split_csv(raw)
  local out = {}
  for part in tostring(raw or ""):gmatch("[^,]+") do
    local v = part:gsub("^%s+", ""):gsub("%s+$", "")
    if v ~= "" then
      out[#out + 1] = v
    end
  end
  return out
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sorted_keys(tbl)
  local keys = {}
  for k, _ in pairs(tbl or {}) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local function basename(path)
  return tostring(path):match("([^/]+)$")
end

local function dir_exists(path)
  if not path or path == "" then
    return false
  end
  local cmd = string.format("[ -d %s ] && echo 1 || true", shell_quote(path))
  local p = io.popen(cmd)
  if not p then
    return false
  end
  local out = p:read("*l")
  p:close()
  return out == "1"
end

local function list_dirs(path)
  local cmd = string.format("find %s -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null", shell_quote(path))
  local p = io.popen(cmd)
  if not p then
    return {}
  end

  local out = {}
  for line in p:lines() do
    out[#out + 1] = line
  end
  p:close()
  table.sort(out)
  return out
end

local function has_app_file(path)
  local cmd = string.format(
    "find %s -mindepth 1 -maxdepth 1 -type f \\( -name 'app.py' -o -name 'handler.py' -o -name 'app.js' -o -name 'handler.js' -o -name 'app.ts' -o -name 'handler.ts' -o -name 'app.php' -o -name 'handler.php' -o -name 'app.rs' -o -name 'handler.rs' \\) -print -quit 2>/dev/null",
    shell_quote(path)
  )
  local p = io.popen(cmd)
  if not p then
    return false
  end
  local first = p:read("*l")
  p:close()
  return first ~= nil
end

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

  local obj = cjson.decode(raw)
  if type(obj) ~= "table" then
    return nil
  end

  return obj
end

local function normalize_policy(obj)
  local out = {}
  if type(obj) ~= "table" then
    return out
  end

  if type(obj.group) == "string" then
    local v = obj.group:gsub("^%s+", ""):gsub("%s+$", "")
    if v ~= "" and #v <= 80 then
      out.group = v
    end
  end

  local timeout_ms = tonumber(obj.timeout_ms)
  if timeout_ms and timeout_ms > 0 then
    out.timeout_ms = timeout_ms
  end

  local max_concurrency = tonumber(obj.max_concurrency)
  if max_concurrency and max_concurrency >= 0 then
    out.max_concurrency = max_concurrency
  end

  local max_body_bytes = tonumber(obj.max_body_bytes)
  if max_body_bytes and max_body_bytes > 0 then
    out.max_body_bytes = max_body_bytes
  end

  if obj.include_debug_headers == true then
    out.include_debug_headers = true
  end

  local response = obj.response
  if type(response) == "table" then
    if response.include_debug_headers == true then
      out.include_debug_headers = true
    end
  end

  local invoke = obj.invoke
  if type(invoke) == "table" and invoke.methods ~= nil then
    local methods = parse_methods(invoke.methods)
    if methods then
      out.methods = methods
    end
  end
  local routes = parse_invoke_routes(invoke)
  if routes ~= nil then
    out.routes = routes
  end

  local schedule = obj.schedule
  if type(schedule) == "table" then
    local enabled = schedule.enabled == true
    local every_seconds = schedule.every_seconds
    if every_seconds ~= nil then
      local v = tonumber(every_seconds)
      if not v or v <= 0 then
        -- ignore invalid schedules instead of breaking discovery
        v = nil
      else
        v = math.floor(v)
      end
      every_seconds = v
    end

    local method = schedule.method
    if method ~= nil then
      method = tostring(method):upper()
      if not ALLOWED_METHODS[method] then
        method = nil
      end
    end

    local sched = { enabled = enabled }
    if every_seconds then
      sched.every_seconds = every_seconds
    end
    if method then
      sched.method = method
    end
    if type(schedule.query) == "table" then
      sched.query = schedule.query
    end
    if type(schedule.headers) == "table" then
      sched.headers = schedule.headers
    end
    if schedule.body ~= nil then
      if type(schedule.body) == "string" then
        sched.body = schedule.body
      else
        sched.body = tostring(schedule.body)
      end
    end
    if type(schedule.context) == "table" then
      sched.context = schedule.context
    end

    out.schedule = sched
  end

  local shared_deps = obj.shared_deps
  if type(shared_deps) == "table" then
    local packs = {}
    local seen = {}
    for _, v in ipairs(shared_deps) do
      local s = tostring(v)
      if s:match("^[a-zA-Z0-9_-]+$") and not seen[s] then
        seen[s] = true
        packs[#packs + 1] = s
      end
    end
    out.shared_deps = packs
  end

  local edge = normalize_edge(obj.edge)
  if edge then
    out.edge = edge
  end

  return out
end

local function detect_functions_root()
  local explicit = os.getenv("FN_FUNCTIONS_ROOT")
  if explicit and explicit ~= "" then
    return explicit
  end

  local pwd = os.getenv("PWD")
  local candidates = {
    "/app/srv/fn/functions",
    (pwd and (pwd .. "/srv/fn/functions") or nil),
    "/srv/fn/functions",
  }

  for _, c in ipairs(candidates) do
    if c and dir_exists(c) then
      return c
    end
  end

  return "/srv/fn/functions"
end

local function detect_socket_base_dir()
  local explicit = os.getenv("FN_SOCKET_BASE_DIR")
  if explicit and explicit ~= "" then
    return explicit
  end

  if dir_exists("/sockets") then
    return "/sockets"
  end

  return "/tmp/fastfn"
end

local function load_runtime_config(force)
  if not force then
    local raw = CACHE:get("runtime:config")
    if raw then
      local parsed = cjson.decode(raw)
      if parsed then
        return parsed
      end
    end
  end

  local functions_root = detect_functions_root()
  local runtime_names = split_csv(os.getenv("FN_RUNTIMES") or "")
  if #runtime_names == 0 then
    for _, runtime_dir in ipairs(list_dirs(functions_root)) do
      local runtime_name = basename(runtime_dir)
      if runtime_name and runtime_name:match("^[a-zA-Z0-9_-]+$") then
        runtime_names[#runtime_names + 1] = runtime_name
      end
    end
    table.sort(runtime_names)
  end

  local socket_base = detect_socket_base_dir()
  local runtime_timeout_ms = tonumber(os.getenv("FN_DEFAULT_TIMEOUT_MS")) or DEFAULT_TIMEOUT_MS

  local socket_map = {}
  local socket_map_raw = os.getenv("FN_RUNTIME_SOCKETS")
  if socket_map_raw and socket_map_raw ~= "" then
    local parsed = cjson.decode(socket_map_raw)
    if type(parsed) == "table" then
      socket_map = parsed
    end
  end

  local runtimes = {}
  for _, runtime in ipairs(runtime_names) do
    if runtime:match("^[a-zA-Z0-9_-]+$") then
      local socket = socket_map[runtime] or ("unix:" .. socket_base .. "/fn-" .. runtime .. ".sock")
      runtimes[runtime] = {
        socket = socket,
        timeout_ms = runtime_timeout_ms,
      }
    end
  end

  local cfg = {
    functions_root = functions_root,
    socket_base_dir = socket_base,
    runtime_order = runtime_names,
    defaults = {
      timeout_ms = runtime_timeout_ms,
      max_concurrency = tonumber(os.getenv("FN_DEFAULT_MAX_CONCURRENCY")) or DEFAULT_MAX_CONCURRENCY,
      max_body_bytes = tonumber(os.getenv("FN_DEFAULT_MAX_BODY_BYTES")) or DEFAULT_MAX_BODY_BYTES,
    },
    runtimes = runtimes,
  }

  CACHE:set("runtime:config", cjson.encode(cfg))
  CACHE:set("runtime:loaded_at", ngx.now())

  return cfg
end

function M.get_config()
  return load_runtime_config(false)
end

function M.reload()
  local cfg = load_runtime_config(true)
  M.healthcheck_once(cfg)
  local catalog = M.discover_functions(true)
  return { config = cfg, catalog = catalog }
end

function M.get_defaults()
  local cfg = load_runtime_config(false)
  return cfg.defaults or {}
end

function M.get_runtime_config(runtime)
  local cfg = load_runtime_config(false)
  return (cfg.runtimes or {})[runtime]
end

function M.get_runtime_order()
  local cfg = load_runtime_config(false)
  return cfg.runtime_order or {}
end

function M.set_runtime_health(runtime, up, reason)
  CACHE:set("rt:" .. runtime .. ":up", up and 1 or 0)
  CACHE:set("rt:" .. runtime .. ":ts", ngx.now())
  CACHE:set("rt:" .. runtime .. ":reason", reason or "ok")
end

function M.runtime_is_up(runtime)
  local up = CACHE:get("rt:" .. runtime .. ":up")
  if up == nil then
    return nil
  end
  return up == 1
end

function M.runtime_status(runtime)
  local up = CACHE:get("rt:" .. runtime .. ":up")
  local ts = CACHE:get("rt:" .. runtime .. ":ts")
  local reason = CACHE:get("rt:" .. runtime .. ":reason")
  if up == nil then
    return { up = nil, ts = ts, reason = reason }
  end
  return { up = up == 1, ts = ts, reason = reason }
end

function M.check_runtime_socket(socket_uri, timeout_ms)
  local sock = ngx.socket.tcp()
  local connect_timeout = math.max(25, math.floor((timeout_ms or 250) * 0.5))
  sock:settimeouts(connect_timeout, connect_timeout, connect_timeout)
  local ok, err = sock:connect(socket_uri)
  if ok then
    sock:close()
    return true
  end
  return false, tostring(err)
end

function M.healthcheck_once(cfg)
  local config = cfg or load_runtime_config(false)
  for runtime, rt_cfg in pairs(config.runtimes or {}) do
    local timeout_ms = tonumber(rt_cfg.timeout_ms) or 250
    local ok, err = M.check_runtime_socket(rt_cfg.socket, timeout_ms)
    M.set_runtime_health(runtime, ok, ok and "ok" or err)
  end
end

function M.discover_functions(force)
  if not force then
    local raw = CACHE:get("catalog:raw")
    if raw then
      local parsed = cjson.decode(raw)
      if parsed then
        return parsed
      end
    end
  end

  local cfg = load_runtime_config(false)
  local functions_root = cfg.functions_root

  local catalog = {
    generated_at = ngx.now(),
    functions_root = functions_root,
    runtimes = {},
    mapped_routes = {},
    mapped_route_conflicts = {},
  }

  local function same_target(a, runtime, fn_name, version)
    if type(a) ~= "table" then
      return false
    end
    return a.runtime == runtime and a.fn_name == fn_name and (a.version or nil) == (version or nil)
  end

  local function register_route(route, runtime, fn_name, version, methods)
    if type(route) ~= "string" or route == "" then
      return
    end
    if catalog.mapped_route_conflicts[route] then
      return
    end
    local current = catalog.mapped_routes[route]
    if current then
      if same_target(current, runtime, fn_name, version) then
        return
      end
      catalog.mapped_routes[route] = nil
      catalog.mapped_route_conflicts[route] = true
      return
    end
    catalog.mapped_routes[route] = {
      runtime = runtime,
      fn_name = fn_name,
      version = version,
      methods = methods,
    }
  end

  for _, runtime in ipairs(sorted_keys(cfg.runtimes or {})) do
    local runtime_dir = functions_root .. "/" .. runtime
    local runtime_entry = {
      functions = {},
    }

    for _, fn_dir in ipairs(list_dirs(runtime_dir)) do
      local fn_name = basename(fn_dir)
      if fn_name and fn_name:match("^[a-zA-Z0-9_-]+$") then
        local fn_entry = {
          has_default = has_app_file(fn_dir),
          versions = {},
          policy = normalize_policy(read_json_file(fn_dir .. "/fn.config.json")),
          versions_policy = {},
        }

        for _, ver_dir in ipairs(list_dirs(fn_dir)) do
          local ver = basename(ver_dir)
          if ver and ver:match("^[a-zA-Z0-9_.-]+$") and has_app_file(ver_dir) then
            fn_entry.versions[#fn_entry.versions + 1] = ver
            fn_entry.versions_policy[ver] = normalize_policy(read_json_file(ver_dir .. "/fn.config.json"))
          end
        end

        table.sort(fn_entry.versions)

        if fn_entry.has_default or #fn_entry.versions > 0 then
          runtime_entry.functions[fn_name] = fn_entry

          if fn_entry.has_default then
            local root_methods = fn_entry.policy and fn_entry.policy.methods or DEFAULT_METHODS
            local policy_routes = (fn_entry.policy and fn_entry.policy.routes) or {}
            if #policy_routes == 0 then
              policy_routes = { "/" .. fn_name, "/" .. fn_name .. "/*" }
            end
            for _, route in ipairs(policy_routes) do
              register_route(route, runtime, fn_name, nil, root_methods)
            end
          end

          for _, ver in ipairs(fn_entry.versions) do
            local ver_policy = (fn_entry.versions_policy or {})[ver] or {}
            local ver_methods = ver_policy.methods or (fn_entry.policy and fn_entry.policy.methods) or DEFAULT_METHODS
            for _, route in ipairs(ver_policy.routes or {}) do
              register_route(route, runtime, fn_name, ver, ver_methods)
            end
          end
        end
      end
    end

    catalog.runtimes[runtime] = runtime_entry
  end

  CACHE:set("catalog:raw", cjson.encode(catalog))
  CACHE:set("catalog:scanned_at", ngx.now())
  return catalog
end

function M.resolve_mapped_target(path)
  local route = normalize_single_route(path)
  if not route then
    return nil, nil, nil
  end
  local catalog = M.discover_functions(false)
  if (catalog.mapped_route_conflicts or {})[route] then
    return nil, nil, nil, "ambiguous mapped route"
  end
  local entry = (catalog.mapped_routes or {})[route]
  if not entry then
    return nil, nil, nil
  end
  return entry.runtime, entry.fn_name, entry.version
end

function M.resolve_function_policy(runtime, fn_name, version)
  local defaults = M.get_defaults()
  local catalog = M.discover_functions(false)
  local runtime_entry = (catalog.runtimes or {})[runtime]
  if not runtime_entry then
    return nil, "unknown runtime"
  end

  local fn_entry = (runtime_entry.functions or {})[fn_name]
  if not fn_entry then
    return nil, "unknown function"
  end

  if version then
    local found = false
    for _, v in ipairs(fn_entry.versions or {}) do
      if v == version then
        found = true
        break
      end
    end
    if not found then
      return nil, "unknown version"
    end
  else
    if not fn_entry.has_default then
      return nil, "default version not available"
    end
  end

  local root_policy = fn_entry.policy or {}
  local ver_policy = (version and fn_entry.versions_policy and fn_entry.versions_policy[version]) or {}
  local methods = ver_policy.methods or root_policy.methods or DEFAULT_METHODS

  local resolved = {
    timeout_ms = tonumber(ver_policy.timeout_ms or root_policy.timeout_ms or defaults.timeout_ms) or DEFAULT_TIMEOUT_MS,
    max_concurrency = tonumber(ver_policy.max_concurrency or root_policy.max_concurrency or defaults.max_concurrency) or DEFAULT_MAX_CONCURRENCY,
    max_body_bytes = tonumber(ver_policy.max_body_bytes or root_policy.max_body_bytes or defaults.max_body_bytes) or DEFAULT_MAX_BODY_BYTES,
    include_debug_headers = (ver_policy.include_debug_headers == true) or (root_policy.include_debug_headers == true),
    methods = methods,
  }

  local edge = ver_policy.edge or root_policy.edge
  if type(edge) == "table" then
    resolved.edge = {
      base_url = edge.base_url,
      allow_private = edge.allow_private == true,
      max_response_bytes = edge.max_response_bytes,
      allow_hosts = {},
    }
    if type(edge.allow_hosts) == "table" then
      for _, host in ipairs(edge.allow_hosts) do
        resolved.edge.allow_hosts[#resolved.edge.allow_hosts + 1] = host
      end
    end
  end

  return resolved
end

function M.resolve_legacy_target(fn_name, version)
  local catalog = M.discover_functions(false)
  local order = M.get_runtime_order()

  local function runtime_has_version(rt, name, ver)
    local fn_entry = (((catalog.runtimes or {})[rt] or {}).functions or {})[name]
    if not fn_entry then
      return false
    end
    for _, v in ipairs(fn_entry.versions or {}) do
      if v == ver then
        return true
      end
    end
    return false
  end

  local function runtime_has_default(rt, name)
    local fn_entry = (((catalog.runtimes or {})[rt] or {}).functions or {})[name]
    return fn_entry and fn_entry.has_default or false
  end

  local matches = {}
  if version then
    for _, rt in ipairs(order) do
      if runtime_has_version(rt, fn_name, version) then
        matches[#matches + 1] = rt
      end
    end
    if #matches > 0 then
      -- Prefer first runtime in configured order (stable)
      return matches[1], version
    end
    return nil, nil
  end

  for _, rt in ipairs(order) do
    if runtime_has_default(rt, fn_name) then
      matches[#matches + 1] = rt
    end
  end
  if #matches > 0 then
    -- Prefer first runtime in configured order (stable)
    return matches[1], nil
  end
  return nil, nil
end

function M.health_snapshot()
  local cfg = load_runtime_config(false)
  local catalog = M.discover_functions(false)
  local mapped_count = 0
  for _, _ in pairs((catalog and catalog.mapped_routes) or {}) do
    mapped_count = mapped_count + 1
  end
  local mapped_conflicts = 0
  for _, _ in pairs((catalog and catalog.mapped_route_conflicts) or {}) do
    mapped_conflicts = mapped_conflicts + 1
  end
  local out = {
    config_loaded_at = CACHE:get("runtime:loaded_at"),
    defaults = cfg.defaults,
    functions_root = cfg.functions_root,
    socket_base_dir = cfg.socket_base_dir,
    runtime_order = cfg.runtime_order,
    hot_reload = {
      enabled = hot_reload_enabled(),
      last_catalog_scan_at = CACHE:get("catalog:scanned_at"),
    },
    routing = {
      mapped_routes = mapped_count,
      mapped_route_conflicts = mapped_conflicts,
    },
    runtimes = {},
  }

  for runtime, rt_cfg in pairs(cfg.runtimes or {}) do
    out.runtimes[runtime] = {
      socket = rt_cfg.socket,
      timeout_ms = rt_cfg.timeout_ms,
      health = M.runtime_status(runtime),
    }
  end

  return out
end

function M.health_json()
  return cjson.encode(M.health_snapshot()) or "{}"
end

function M.init()
  if ngx.worker.id() ~= 0 then
    return
  end

  load_runtime_config(true)
  M.discover_functions(true)

  local interval = tonumber(os.getenv("FN_HEALTH_INTERVAL")) or DEFAULT_HEALTH_INTERVAL
  if interval < 1 then
    interval = DEFAULT_HEALTH_INTERVAL
  end

  local ok_once, once_err = ngx.timer.at(0, function(premature)
    if premature then
      return
    end
    M.healthcheck_once(load_runtime_config(false))
  end)
  if not ok_once then
    ngx.log(ngx.ERR, "failed to schedule initial health timer: ", once_err)
  end

  local ok, timer_err = ngx.timer.every(interval, function(premature)
    if premature then
      return
    end
    M.healthcheck_once(load_runtime_config(false))
  end)
  if not ok then
    ngx.log(ngx.ERR, "failed to start health timer: ", timer_err)
  end

  if hot_reload_enabled() then
    local hot_interval = tonumber(os.getenv("FN_HOT_RELOAD_INTERVAL")) or DEFAULT_HOT_RELOAD_INTERVAL
    if hot_interval < 1 then
      hot_interval = DEFAULT_HOT_RELOAD_INTERVAL
    end

    local ok_hot, hot_err = ngx.timer.every(hot_interval, function(premature)
      if premature then
        return
      end
      M.discover_functions(true)
    end)

    if not ok_hot then
      ngx.log(ngx.ERR, "failed to start catalog hot reload timer: ", hot_err)
    end
  end
end

return M
