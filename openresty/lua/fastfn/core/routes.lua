local cjson = require "cjson.safe"
local invoke_rules = require "fastfn.core.invoke_rules"
local home_rules = require "fastfn.core.home"
local watchdog = require "fastfn.core.watchdog"

local M = {}

local CACHE = ngx.shared.fn_cache
local CONC = ngx.shared.fn_conc
local DEFAULT_TIMEOUT_MS = 2500
local DEFAULT_MAX_CONCURRENCY = 20
local DEFAULT_MAX_BODY_BYTES = 1024 * 1024
local DEFAULT_HEALTH_INTERVAL = 2
local DEFAULT_HOT_RELOAD_INTERVAL = 2
local DEFAULT_KEEP_WARM_MIN_WARM = 1
local DEFAULT_KEEP_WARM_PING_SECONDS = 45
local DEFAULT_KEEP_WARM_IDLE_TTL_SECONDS = 300
local DEFAULT_POOL_MIN_WARM = 0
local DEFAULT_POOL_MAX_QUEUE = 0
local DEFAULT_POOL_IDLE_TTL_SECONDS = 300
local DEFAULT_POOL_QUEUE_TIMEOUT_MS = 0
local DEFAULT_POOL_QUEUE_POLL_MS = 20
local DEFAULT_POOL_OVERFLOW_STATUS = 429
local DEFAULT_ZERO_CONFIG_IGNORE_DIRS = {
  "node_modules",
  "vendor",
  "__pycache__",
  ".fastfn",
  ".deps",
  ".rust-build",
  "target",
  "src",
}
local CATALOG_SCAN_LOCK_KEY = "catalog:scan:running"
local CATALOG_WATCHDOG_ACTIVE_KEY = "catalog:watchdog:active"
local CATALOG_WATCHDOG_BACKEND_KEY = "catalog:watchdog:backend"
local CATALOG_WATCHDOG_ERROR_KEY = "catalog:watchdog:error"
local CATALOG_WATCHDOG_LAST_SCAN_KEY = "catalog:watchdog:last_scan_at"
local DEFAULT_METHODS = invoke_rules.DEFAULT_METHODS
local parse_methods = invoke_rules.parse_methods
local ALLOWED_METHODS = invoke_rules.ALLOWED_METHODS
local normalize_single_route = invoke_rules.normalize_route
local parse_invoke_routes = invoke_rules.parse_invoke_routes
local read_json_file
local load_runtime_config
local KNOWN_RUNTIMES = {
  node = true,
  python = true,
  php = true,
  lua = true,
  rust = true,
  go = true,
}
local EXPERIMENTAL_RUNTIMES = {
  rust = true,
  go = true,
}
local ALL_METHODS = { "GET", "POST", "PUT", "PATCH", "DELETE" }

local function normalize_allow_hosts(input)
  local hosts = {}
  local seen = {}

  local function add_host(raw)
    local h = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if h == "" or #h > 200 then
      return
    end
    if h:find("[/%s]") then
      return
    end
    if not h:match("^[a-z0-9%*%-%._:%[%]]+$") then
      return
    end
    if not seen[h] then
      seen[h] = true
      hosts[#hosts + 1] = h
    end
  end

  if type(input) == "string" then
    for token in input:gmatch("[^,]+") do
      add_host(token)
    end
  elseif type(input) == "table" then
    for _, item in ipairs(input) do
      add_host(item)
    end
  end

  if #hosts == 0 then
    return nil
  end
  return hosts
end

local function normalize_host_token(raw)
  local h = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if h == "" then
    return nil
  end
  return h
end

local function split_host_port(authority)
  local v = normalize_host_token(authority)
  if not v then
    return "", ""
  end
  local ipv6 = v:match("^%[([^%]]+)%]")
  if ipv6 then
    return ipv6, v
  end
  local host = v:match("^([^:]+)") or v
  return host, v
end

local function host_matches_pattern(host, pattern)
  host = normalize_host_token(host) or ""
  pattern = normalize_host_token(pattern) or ""
  if host == "" or pattern == "" then
    return false
  end
  if host == pattern then
    return true
  end
  local wildcard = pattern:match("^%*%.(.+)$")
  if wildcard then
    if host == wildcard then
      return false
    end
    return host:sub(-(#wildcard + 1)) == ("." .. wildcard)
  end
  return false
end

local function host_allowlist_matches(allow_hosts, request_host, request_authority)
  if type(allow_hosts) ~= "table" or #allow_hosts == 0 then
    return true
  end
  if request_host == "" and request_authority == "" then
    return false
  end
  for _, raw in ipairs(allow_hosts) do
    local allowed = normalize_host_token(raw)
    if allowed then
      local allowed_host = split_host_port(allowed)
      if host_matches_pattern(request_host, allowed_host) or host_matches_pattern(request_authority, allowed) then
        return true
      end
    end
  end
  return false
end

local function resolve_request_host_values(raw_host, raw_forwarded_host)
  local forwarded = raw_forwarded_host
  if type(forwarded) == "string" and forwarded ~= "" then
    forwarded = forwarded:match("^%s*([^,]+)")
    local host_only, authority = split_host_port(forwarded)
    if host_only ~= "" then
      return host_only, authority
    end
  end

  local host_hdr = raw_host
  if type(host_hdr) == "string" and host_hdr ~= "" then
    local host_only, authority = split_host_port(host_hdr)
    if host_only ~= "" then
      return host_only, authority
    end
  end

  if ngx and ngx.var then
    local host_only, authority = split_host_port(ngx.var.host)
    return host_only, authority
  end
  return "", ""
end

local function host_constraints_overlap(a, b)
  local list_a = type(a) == "table" and a or {}
  local list_b = type(b) == "table" and b or {}

  -- Empty means "all hosts".
  if #list_a == 0 or #list_b == 0 then
    return true
  end

  -- Conservatively treat wildcard patterns as potentially overlapping.
  for _, item in ipairs(list_a) do
    local v = normalize_host_token(item)
    if v and v:find("%*") then
      return true
    end
  end
  for _, item in ipairs(list_b) do
    local v = normalize_host_token(item)
    if v and v:find("%*") then
      return true
    end
  end

  local set_b = {}
  for _, item in ipairs(list_b) do
    local v = normalize_host_token(item)
    if v then
      set_b[v] = true
    end
  end

  for _, item in ipairs(list_a) do
    local v = normalize_host_token(item)
    if v and set_b[v] then
      return true
    end
  end

  return false
end

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

local function normalize_keep_warm(source)
  if type(source) ~= "table" then
    return nil
  end

  local enabled = source.enabled == true
  local min_warm = tonumber(source.min_warm)
  if min_warm then
    min_warm = math.floor(min_warm)
    if min_warm < 0 then
      min_warm = nil
    end
  end

  local ping_every_seconds = tonumber(source.ping_every_seconds)
  if ping_every_seconds then
    ping_every_seconds = math.floor(ping_every_seconds)
    if ping_every_seconds <= 0 then
      ping_every_seconds = nil
    end
  end

  local idle_ttl_seconds = tonumber(source.idle_ttl_seconds)
  if idle_ttl_seconds then
    idle_ttl_seconds = math.floor(idle_ttl_seconds)
    if idle_ttl_seconds <= 0 then
      idle_ttl_seconds = nil
    end
  end

  if not enabled and not min_warm and not ping_every_seconds and not idle_ttl_seconds then
    return nil
  end

  local resolved = {
    enabled = enabled,
    min_warm = min_warm or DEFAULT_KEEP_WARM_MIN_WARM,
    ping_every_seconds = ping_every_seconds or DEFAULT_KEEP_WARM_PING_SECONDS,
    idle_ttl_seconds = idle_ttl_seconds or DEFAULT_KEEP_WARM_IDLE_TTL_SECONDS,
  }

  if not enabled and resolved.min_warm < 1 then
    resolved.min_warm = 0
  end

  return resolved
end

local function normalize_worker_pool(source, fallback_max_workers)
  if type(source) ~= "table" then
    return nil
  end

  local enabled = source.enabled ~= false

  local min_warm = tonumber(source.min_warm)
  if min_warm ~= nil then
    min_warm = math.floor(min_warm)
    if min_warm < 0 then
      min_warm = nil
    end
  end

  local max_workers = tonumber(source.max_workers)
  if max_workers == nil then
    max_workers = tonumber(fallback_max_workers)
  end
  if max_workers ~= nil then
    max_workers = math.floor(max_workers)
    if max_workers < 0 then
      max_workers = nil
    end
  end

  local max_queue = tonumber(source.max_queue)
  if max_queue ~= nil then
    max_queue = math.floor(max_queue)
    if max_queue < 0 then
      max_queue = nil
    end
  end

  local idle_ttl_seconds = tonumber(source.idle_ttl_seconds)
  if idle_ttl_seconds ~= nil then
    idle_ttl_seconds = math.floor(idle_ttl_seconds)
    if idle_ttl_seconds <= 0 then
      idle_ttl_seconds = nil
    end
  end

  local queue_timeout_ms = tonumber(source.queue_timeout_ms)
  if queue_timeout_ms ~= nil then
    queue_timeout_ms = math.floor(queue_timeout_ms)
    if queue_timeout_ms < 0 then
      queue_timeout_ms = nil
    end
  end

  local queue_poll_ms = tonumber(source.queue_poll_ms)
  if queue_poll_ms ~= nil then
    queue_poll_ms = math.floor(queue_poll_ms)
    if queue_poll_ms < 1 then
      queue_poll_ms = nil
    end
  end

  local overflow_status = tonumber(source.overflow_status)
  if overflow_status ~= nil then
    overflow_status = math.floor(overflow_status)
    if overflow_status ~= 429 and overflow_status ~= 503 then
      overflow_status = nil
    end
  end

  if not enabled and not max_workers and not max_queue then
    return nil
  end

  local resolved = {
    enabled = enabled,
    min_warm = min_warm or DEFAULT_POOL_MIN_WARM,
    max_workers = max_workers,
    max_queue = max_queue or DEFAULT_POOL_MAX_QUEUE,
    idle_ttl_seconds = idle_ttl_seconds or DEFAULT_POOL_IDLE_TTL_SECONDS,
    queue_timeout_ms = queue_timeout_ms or DEFAULT_POOL_QUEUE_TIMEOUT_MS,
    queue_poll_ms = queue_poll_ms or DEFAULT_POOL_QUEUE_POLL_MS,
    overflow_status = overflow_status or DEFAULT_POOL_OVERFLOW_STATUS,
  }

  if resolved.max_workers and resolved.max_workers > 0 and resolved.min_warm > resolved.max_workers then
    resolved.min_warm = resolved.max_workers
  end

  return resolved
end

local function warm_state_for_key(full_key, keep_warm_cfg)
  local warm_at = CACHE:get("warm:" .. tostring(full_key))
  if warm_at == nil then
    return "cold", nil
  end

  local idle_ttl = keep_warm_cfg and tonumber(keep_warm_cfg.idle_ttl_seconds) or nil
  if idle_ttl and idle_ttl > 0 then
    local age = ngx.now() - tonumber(warm_at)
    if age > idle_ttl then
      return "stale", warm_at
    end
  end

  return "warm", warm_at
end

local function pool_active_metric_key(full_key)
  return "pool:active:" .. tostring(full_key)
end

local function pool_queue_metric_key(full_key)
  return "pool:queue:" .. tostring(full_key)
end

local function pool_drop_metric_key(full_key, reason)
  return "pool:drops:" .. tostring(reason or "unknown") .. ":" .. tostring(full_key)
end

local function read_nonneg_counter(dict, key)
  if not dict then
    return 0
  end
  local raw = dict:get(key)
  local value = tonumber(raw)
  if not value or value < 0 then
    return 0
  end
  return math.floor(value)
end

local function worker_pool_snapshot(full_key, policy)
  local cfg = type((policy or {}).worker_pool) == "table" and policy.worker_pool or nil
  if not cfg then
    return nil
  end

  local active = read_nonneg_counter(CONC, pool_active_metric_key(full_key))
  local queued = read_nonneg_counter(CONC, pool_queue_metric_key(full_key))
  local drops_overflow = read_nonneg_counter(CONC, pool_drop_metric_key(full_key, "overflow"))
  local drops_timeout = read_nonneg_counter(CONC, pool_drop_metric_key(full_key, "queue_timeout"))
  local overflow_status = math.floor(tonumber(cfg.overflow_status) or DEFAULT_POOL_OVERFLOW_STATUS)
  if overflow_status ~= 429 and overflow_status ~= 503 then
    overflow_status = DEFAULT_POOL_OVERFLOW_STATUS
  end

  return {
    enabled = cfg.enabled ~= false,
    min_warm = math.floor(tonumber(cfg.min_warm) or DEFAULT_POOL_MIN_WARM),
    max_workers = math.floor(tonumber(cfg.max_workers) or 0),
    max_queue = math.floor(tonumber(cfg.max_queue) or DEFAULT_POOL_MAX_QUEUE),
    idle_ttl_seconds = math.floor(tonumber(cfg.idle_ttl_seconds) or DEFAULT_POOL_IDLE_TTL_SECONDS),
    queue_timeout_ms = math.floor(tonumber(cfg.queue_timeout_ms) or DEFAULT_POOL_QUEUE_TIMEOUT_MS),
    queue_poll_ms = math.floor(tonumber(cfg.queue_poll_ms) or DEFAULT_POOL_QUEUE_POLL_MS),
    overflow_status = overflow_status,
    active = active,
    queued = queued,
    queue_drops = {
      overflow = drops_overflow,
      timeout = drops_timeout,
      total = drops_overflow + drops_timeout,
    },
  }
end

function M.record_worker_pool_drop(full_key, reason)
  if type(full_key) ~= "string" or full_key == "" then
    return false
  end
  local kind = tostring(reason or "")
  if kind ~= "overflow" and kind ~= "queue_timeout" then
    return false
  end
  if not CONC then
    return false
  end
  local value, err = CONC:incr(pool_drop_metric_key(full_key, kind), 1, 0)
  return value ~= nil and err == nil
end

local function hot_reload_enabled()
  local raw = os.getenv("FN_HOT_RELOAD")
  if raw == nil or raw == "" then
    return true
  end
  raw = string.lower(raw)
  return not (raw == "0" or raw == "false" or raw == "off" or raw == "no")
end

local function hot_reload_watchdog_enabled()
  local raw = os.getenv("FN_HOT_RELOAD_WATCHDOG")
  if raw == nil or raw == "" then
    return true
  end
  raw = string.lower(raw)
  return not (raw == "0" or raw == "false" or raw == "off" or raw == "no")
end

local function force_url_enabled()
  local raw = os.getenv("FN_FORCE_URL")
  if raw == nil or raw == "" then
    return false
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

local function normalize_zero_config_dir(raw)
  local v = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if v == "" then
    return nil
  end
  if v:find("/", 1, true) or v:find("\\", 1, true) then
    return nil
  end
  if v == "." or v == ".." then
    return nil
  end
  return v
end

local function append_zero_config_ignore_dirs(dst, seen, value)
  local items = {}
  if type(value) == "string" then
    items = split_csv(value)
  elseif type(value) == "table" then
    for _, item in ipairs(value) do
      items[#items + 1] = item
    end
  end

  for _, raw in ipairs(items) do
    local dir = normalize_zero_config_dir(raw)
    if dir and not seen[dir] then
      seen[dir] = true
      dst[#dst + 1] = dir
    end
  end
end

local function load_zero_config_ignore_dirs(functions_root)
  local out = {}
  local seen = {}

  append_zero_config_ignore_dirs(out, seen, DEFAULT_ZERO_CONFIG_IGNORE_DIRS)

  local root_cfg = read_json_file(functions_root .. "/fn.config.json")
  if type(root_cfg) == "table" then
    local discovery = root_cfg.zero_config
    if type(discovery) ~= "table" then
      discovery = root_cfg.discovery
    end
    if type(discovery) ~= "table" then
      discovery = root_cfg.routing
    end
    if type(discovery) == "table" then
      append_zero_config_ignore_dirs(out, seen, discovery.ignore_dirs)
    end
    append_zero_config_ignore_dirs(out, seen, root_cfg.zero_config_ignore_dirs)
  end

  append_zero_config_ignore_dirs(out, seen, os.getenv("FN_ZERO_CONFIG_IGNORE_DIRS"))
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

local function list_files(path)
  local cmd = string.format("find %s -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null", shell_quote(path))
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

local function file_exists(path)
  local f, err = io.open(path, "rb")
  if not f then
    return false
  end
  -- On Linux, io.open succeeds on directories; detect by attempting a read.
  local _, read_err = f:read(0)
  f:close()
  if read_err then
    return false
  end
  return true
end

local function has_app_file(path)
  local cmd = string.format(
    "find %s -mindepth 1 -maxdepth 1 -type f \\( -name 'app.py' -o -name 'handler.py' -o -name 'main.py' -o -name 'app.js' -o -name 'handler.js' -o -name 'index.js' -o -name 'app.ts' -o -name 'handler.ts' -o -name 'index.ts' -o -name 'app.php' -o -name 'handler.php' -o -name 'index.php' -o -name 'app.lua' -o -name 'handler.lua' -o -name 'main.lua' -o -name 'index.lua' -o -name 'app.rs' -o -name 'handler.rs' -o -name 'app.go' -o -name 'handler.go' -o -name 'main.go' \\) -print -quit 2>/dev/null",
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

local function has_valid_config_entrypoint(path)
  local cfg = read_json_file(path .. "/fn.config.json")
  if type(cfg) ~= "table" then
    return false
  end
  local entry = cfg.entrypoint
  if type(entry) ~= "string" or entry == "" then
    return false
  end
  local full = path .. "/" .. entry
  return file_exists(full)
end

local function detect_runtime_from_file(file_path)
  local ext = tostring(file_path):match("%.([A-Za-z0-9]+)$")
  if not ext then
    return nil
  end
  ext = string.lower(ext)
  if ext == "js" or ext == "ts" then
    return "node"
  end
  if ext == "py" then
    return "python"
  end
  if ext == "php" then
    return "php"
  end
  if ext == "lua" then
    return "lua"
  end
  if ext == "rs" then
    return "rust"
  end
  if ext == "go" then
    return "go"
  end
  return nil
end

local function is_safe_relative_path(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  if path:sub(1, 1) == "/" then
    return false
  end
  if path:find("\\", 1, true) or path:find("//", 1, true) then
    return false
  end
  for segment in path:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      return false
    end
  end
  return true
end

local function runtime_entrypoint_candidates(runtime)
  if runtime == "python" then
    return { "app.py", "handler.py", "main.py" }
  end
  if runtime == "node" then
    return { "app.js", "handler.js", "index.js", "app.ts", "handler.ts", "index.ts" }
  end
  if runtime == "php" then
    return { "app.php", "handler.php", "index.php" }
  end
  if runtime == "lua" then
    return { "app.lua", "handler.lua", "main.lua", "index.lua" }
  end
  if runtime == "rust" then
    return { "app.rs", "handler.rs" }
  end
  if runtime == "go" then
    return { "app.go", "handler.go", "main.go" }
  end
  return {}
end

local function resolve_runtime_file_target(functions_root, runtime, fn_name)
  if not is_safe_relative_path(fn_name) then
    return nil
  end
  local full = tostring(functions_root or "") .. "/" .. runtime .. "/" .. fn_name
  if file_exists(full) then
    return full
  end
  return nil
end

local function resolve_runtime_function_dir(functions_root, runtime, fn_name, version)
  if not is_safe_relative_path(fn_name) then
    return nil
  end
  local dir = tostring(functions_root or "") .. "/" .. runtime .. "/" .. fn_name
  if version ~= nil and version ~= "" then
    if not tostring(version):match("^[a-zA-Z0-9_.-]+$") then
      return nil
    end
    dir = dir .. "/" .. version
  end
  if dir_exists(dir) then
    return dir
  end
  return nil
end

function M.resolve_function_entrypoint(runtime, fn_name, version)
  if type(runtime) ~= "string" or runtime == "" then
    return nil, "runtime required"
  end
  if type(fn_name) ~= "string" or fn_name == "" then
    return nil, "function name required"
  end

  local cfg = load_runtime_config(false)
  local functions_root = cfg.functions_root
  if type(functions_root) ~= "string" or functions_root == "" then
    return nil, "functions root not configured"
  end

  local direct_file = fn_name:find("/", 1, true) ~= nil or fn_name:match("%.[A-Za-z0-9]+$") ~= nil
  if direct_file then
    local target = resolve_runtime_file_target(functions_root, runtime, fn_name)
    if target then
      return target
    end
    -- Fall through: name may contain "/" as a namespace separator (e.g. "user/func")
    -- and still be a directory-based function, so try directory resolution next.
  end

  local dir = resolve_runtime_function_dir(functions_root, runtime, fn_name, version)
  if not dir then
    return nil, "function directory not found"
  end

  local fn_cfg = read_json_file(dir .. "/fn.config.json")
  local entrypoint = type(fn_cfg) == "table" and fn_cfg.entrypoint or nil
  if type(entrypoint) == "string" and entrypoint ~= "" then
    if not is_safe_relative_path(entrypoint) then
      return nil, "invalid entrypoint path"
    end
    local configured = dir .. "/" .. entrypoint
    if file_exists(configured) then
      return configured
    end
  end

  for _, candidate in ipairs(runtime_entrypoint_candidates(runtime)) do
    local full = dir .. "/" .. candidate
    if file_exists(full) then
      return full
    end
  end

  for _, file in ipairs(list_files(dir)) do
    local base = basename(file)
    if base and detect_runtime_from_file(base) == runtime then
      return file
    end
  end

  return nil, "entrypoint not found"
end

local function should_ignore_file_base(base)
  local lower = string.lower(tostring(base or ""))
  if lower:match("%.test$") or lower:match("%.spec$") then
    return true
  end
  return lower:sub(1, 1) == "_"
end

local function split_file_tokens(base)
  local out = {}
  local cur = {}
  local bracket_depth = 0
  for i = 1, #base do
    local ch = base:sub(i, i)
    if ch == "[" then
      bracket_depth = bracket_depth + 1
      cur[#cur + 1] = ch
    elseif ch == "]" then
      if bracket_depth > 0 then
        bracket_depth = bracket_depth - 1
      end
      cur[#cur + 1] = ch
    elseif ch == "." and bracket_depth == 0 then
      local token = table.concat(cur):gsub("^%s+", ""):gsub("%s+$", "")
      if token ~= "" then
        out[#out + 1] = token
      end
      cur = {}
    else
      cur[#cur + 1] = ch
    end
  end
  local last = table.concat(cur):gsub("^%s+", ""):gsub("%s+$", "")
  if last ~= "" then
    out[#out + 1] = last
  end
  if #out == 0 then
    return { base }
  end
  return out
end

local function parse_method_and_tokens(base_no_ext)
  local method = "GET"
  local explicit = false
  local parts = split_file_tokens(base_no_ext)
  if #parts >= 1 then
    local head = string.lower(parts[1])
    if head == "get" then
      method = "GET"
      explicit = true
      table.remove(parts, 1)
    elseif head == "post" then
      method = "POST"
      explicit = true
      table.remove(parts, 1)
    elseif head == "put" then
      method = "PUT"
      explicit = true
      table.remove(parts, 1)
    elseif head == "patch" then
      method = "PATCH"
      explicit = true
      table.remove(parts, 1)
    elseif head == "delete" then
      method = "DELETE"
      explicit = true
      table.remove(parts, 1)
    end
  end
  return method, parts, explicit
end

local function is_explicit_fn_config(cfg)
  if type(cfg) ~= "table" or next(cfg) == nil then
    return false
  end
  if type(cfg.runtime) == "string" and cfg.runtime ~= "" then
    return true
  end
  if type(cfg.name) == "string" and cfg.name ~= "" then
    return true
  end
  if type(cfg.entrypoint) == "string" and cfg.entrypoint ~= "" then
    return true
  end
  local invoke = cfg.invoke
  if type(invoke) == "table" and type(invoke.routes) == "table" and #invoke.routes > 0 then
    return true
  end
  return false
end

local function resolve_inherited_allow_hosts(abs_dir, rel_dir)
  local cur_abs = abs_dir
  local cur_rel = rel_dir or "."
  while true do
    local cfg = read_json_file(cur_abs .. "/fn.config.json")
    if type(cfg) == "table" and next(cfg) ~= nil and not is_explicit_fn_config(cfg) then
      local invoke = cfg.invoke
      if type(invoke) == "table" and invoke.allow_hosts ~= nil then
        local hosts = normalize_allow_hosts(invoke.allow_hosts)
        if hosts then
          return hosts
        end
      end
    end

    if cur_rel == "." or cur_rel == "" then
      break
    end

    cur_abs = cur_abs:match("^(.*)/[^/]+$") or cur_abs
    cur_rel = cur_rel:match("^(.*)/[^/]+$") or "."
  end
  return nil
end

local function normalize_route_token(segment)
  local s = tostring(segment or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then
    return nil
  end
  local lower = string.lower(s)
  if lower == "index" or lower == "handler" or lower == "app" or lower == "main" then
    return nil
  end
  local opt = s:match("^%[%[%.%.%.([A-Za-z0-9_]+)%]%]$")
  if opt then
    return ":" .. string.lower(opt) .. "*"
  end
  local catch_all = s:match("^%[%.%.%.([A-Za-z0-9_]+)%]$")
  if catch_all then
    return ":" .. string.lower(catch_all) .. "*"
  end
  local dyn = s:match("^%[([A-Za-z0-9_]+)%]$")
  if dyn then
    return ":" .. string.lower(dyn)
  end
  lower = lower:gsub("_+", "-")
  lower = lower:gsub("[^a-z0-9-]+", "-")
  lower = lower:gsub("^-+", ""):gsub("-+$", "")
  if lower == "" then
    return nil
  end
  return lower
end

-- Canonicalize a function name into a safe public URL segment.
-- This is used by internal tooling (for example /_fn/invoke) to synthesize a
-- stable route template even when public routing is ambiguous (for example
-- two runtimes claim the same canonical path).
function M.canonical_route_segment_for_name(name)
  local s = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then
    return nil
  end
  -- For namespaced names, normalize each segment individually and
  -- preserve "/" so api/v1/users becomes api/v1/users (not api-v1-users).
  local parts = {}
  for seg in s:gmatch("[^/]+") do
    local lower = string.lower(seg)
    lower = lower:gsub("_+", "-")
    lower = lower:gsub("[^a-z0-9-]+", "-")
    lower = lower:gsub("^-+", ""):gsub("-+$", "")
    if lower ~= "" then
      parts[#parts + 1] = lower
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "/")
end

local function is_optional_catchall_token(segment)
  return tostring(segment or ""):match("^%[%[%.%.%.[A-Za-z0-9_]+%]%]$") ~= nil
end

local function split_rel_segments(rel)
  local out = {}
  local norm = tostring(rel or ""):gsub("^%./", "")
  if norm == "" or norm == "." then
    return out
  end
  for part in norm:gmatch("[^/]+") do
    local token = normalize_route_token(part)
    if token then
      out[#out + 1] = token
    end
  end
  return out
end

local function dynamic_route_sort_key(mapped_route)
  local static_segments = 0
  local dynamic_segments = 0
  local catchall_segments = 0
  local total_segments = 0
  for seg in tostring(mapped_route or ""):gmatch("[^/]+") do
    if seg ~= "" then
      total_segments = total_segments + 1
      if seg == "*" then
        catchall_segments = catchall_segments + 1
      elseif seg:sub(1, 1) == ":" then
        if seg:sub(-1) == "*" then
          catchall_segments = catchall_segments + 1
        else
          dynamic_segments = dynamic_segments + 1
        end
      else
        static_segments = static_segments + 1
      end
    end
  end
  return static_segments, total_segments, catchall_segments, dynamic_segments
end

local function sort_dynamic_routes(mapped_routes)
  local keys = {}
  for mapped_route, _ in pairs(mapped_routes or {}) do
    if mapped_route:find(":") or mapped_route:find("*", 1, true) then
      keys[#keys + 1] = mapped_route
    end
  end
  table.sort(keys, function(a, b)
    local as, at, ac, ad = dynamic_route_sort_key(a)
    local bs, bt, bc, bd = dynamic_route_sort_key(b)
    if as ~= bs then
      return as > bs
    end
    if at ~= bt then
      return at > bt
    end
    if ac ~= bc then
      return ac < bc
    end
    if ad ~= bd then
      return ad > bd
    end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function normalize_home_alias_target_route(rel_dir, raw)
  local value = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if value == "" then
    return nil
  end
  if value:find("^[Hh][Tt][Tt][Pp][Ss]?://") then
    return nil
  end

  if value:sub(1, 1) == "/" then
    return normalize_single_route(value)
  end

  local segments = split_rel_segments(rel_dir)
  for token in tostring(value):gmatch("[^/]+") do
    local normalized = normalize_route_token(token)
    if normalized then
      segments[#segments + 1] = normalized
    end
  end
  local route = "/" .. table.concat(segments, "/")
  return normalize_single_route(route)
end

local function maybe_add_directory_home_alias(cfg, rel_dir, discovered)
  if type(cfg) ~= "table" then
    return
  end
  local spec = home_rules.extract_home_spec(cfg)
  if type(spec) ~= "table" or type(spec.home_function) ~= "string" then
    return
  end

  local folder_segments = split_rel_segments(rel_dir)
  local folder_route = "/" .. table.concat(folder_segments, "/")
  folder_route = normalize_single_route(folder_route)
  if not folder_route or folder_route == "/" then
    return
  end

  local target_route = normalize_home_alias_target_route(rel_dir, spec.home_function)
  if not target_route or target_route == "/" or target_route == folder_route then
    return
  end

  local existing_alias = nil
  local matched_target = nil
  for _, item in ipairs(discovered) do
    if item.route == folder_route then
      existing_alias = item
    end
    if item.route == target_route and not matched_target then
      matched_target = item
    end
  end
  if existing_alias or not matched_target then
    return
  end

  discovered[#discovered + 1] = {
    route = folder_route,
    runtime = matched_target.runtime,
    target = matched_target.target,
    methods = matched_target.methods,
    allow_hosts = matched_target.allow_hosts,
  }
end

local function detect_file_based_routes_in_dir(abs_dir, rel_dir)
  local cfg = read_json_file(abs_dir .. "/fn.config.json")
  if is_explicit_fn_config(cfg) then
    return {}
  end

  local allow_hosts = resolve_inherited_allow_hosts(abs_dir, rel_dir)
  local overlay_methods = nil
  if type(cfg) == "table" then
    local invoke = cfg.invoke
    if type(invoke) == "table" then
      overlay_methods = parse_methods(invoke.methods)
    end
  end

  local discovered = {}
  for _, file_path in ipairs(list_files(abs_dir)) do
    local filename = basename(file_path)
    local lower_name = string.lower(filename)
    if lower_name:sub(-5) ~= ".d.ts" then
      local runtime = detect_runtime_from_file(filename)
      if runtime then
        local base_no_ext = filename:gsub("%.[^.]+$", "")
        if not should_ignore_file_base(base_no_ext) then
          local method, file_tokens, method_explicit = parse_method_and_tokens(base_no_ext)
          local methods = { method }
          if not method_explicit and overlay_methods then
            methods = overlay_methods
          end
          local segments = split_rel_segments(rel_dir)
          for _, t in ipairs(file_tokens) do
            local normalized = normalize_route_token(t)
            if normalized then
              segments[#segments + 1] = normalized
            end
          end
          local route = "/" .. table.concat(segments, "/")
          route = normalize_single_route(route)
          if route and route ~= "/" then
            local rel_file = filename
            if rel_dir and rel_dir ~= "" and rel_dir ~= "." then
              rel_file = rel_dir .. "/" .. filename
            end
            discovered[#discovered + 1] = {
              route = route,
              runtime = runtime,
              target = rel_file,
              methods = methods,
              allow_hosts = allow_hosts,
            }

            if #file_tokens > 0 and is_optional_catchall_token(file_tokens[#file_tokens]) then
              local base_segments = split_rel_segments(rel_dir)
              for i = 1, (#file_tokens - 1) do
                local normalized_base = normalize_route_token(file_tokens[i])
                if normalized_base then
                  base_segments[#base_segments + 1] = normalized_base
                end
              end
              local base_route = "/" .. table.concat(base_segments, "/")
              base_route = normalize_single_route(base_route)
                if base_route and base_route ~= "/" then
                  discovered[#discovered + 1] = {
                    route = base_route,
                    runtime = runtime,
                    target = rel_file,
                    methods = methods,
                    allow_hosts = allow_hosts,
                  }
                end
              end
            end
          end
        end
    end
  end
  maybe_add_directory_home_alias(cfg, rel_dir, discovered)
  return discovered
end

read_json_file = function(path)
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

local function detect_manifest_routes_in_dir(abs_dir, rel_dir)
  local manifest = read_json_file(abs_dir .. "/fn.routes.json")
  if type(manifest) ~= "table" or type(manifest.routes) ~= "table" then
    return {}, false
  end

  local discovered = {}
  for route_def, target in pairs(manifest.routes) do
    if type(route_def) == "string" and type(target) == "string" and target ~= "" then
      local methods_str, path = route_def:match("^([A-Z, ]+)%s+(.+)$")
      if not path then
        path = route_def:gsub("^%s+", "")
        methods_str = nil
      end
      path = normalize_single_route(path)
      if path then
        local methods
        if methods_str then
          methods = {}
          for m in methods_str:gmatch("[A-Z]+") do
            methods[#methods + 1] = m
          end
        else
          methods = DEFAULT_METHODS
        end

        local runtime = detect_runtime_from_file(target) or "node"
        local rel_target = target
        if rel_dir and rel_dir ~= "" and rel_dir ~= "." then
          rel_target = rel_dir .. "/" .. target
        end

        discovered[#discovered + 1] = {
          route = path,
          runtime = runtime,
          target = rel_target,
          methods = methods,
        }
      end
    end
  end
  return discovered, true
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

  local worker_pool = normalize_worker_pool(obj.worker_pool, obj.max_concurrency)
  if worker_pool then
    out.worker_pool = worker_pool
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
  if type(invoke) == "table" and invoke.allow_hosts ~= nil then
    local allow_hosts = normalize_allow_hosts(invoke.allow_hosts)
    if allow_hosts then
      out.allow_hosts = allow_hosts
    end
  end
  -- By default, route conflicts are resolved safely and do not silently override
  -- existing mappings. Setting force-url explicitly opts into overriding lower-priority
  -- route claims. Supports both top-level and invoke-scoped keys.
  local force_url = false
  if obj["force-url"] == true or obj.force_url == true or obj.forceUrl == true then
    force_url = true
  end
  if type(invoke) == "table" and (invoke["force-url"] == true or invoke.force_url == true or invoke.forceUrl == true) then
    force_url = true
  end
  if force_url then
    out.force_url = true
  end

  local schedule = obj.schedule
  if type(schedule) == "table" then
    local enabled = schedule.enabled == true
    local every_seconds = schedule.every_seconds
    local cron = schedule.cron
    local timezone = schedule.timezone or schedule.tz
    local retry = schedule.retry
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

    if cron ~= nil then
      if type(cron) ~= "string" then
        cron = nil
      else
        cron = cron:gsub("^%s+", ""):gsub("%s+$", "")
        if cron == "" then
          cron = nil
        end
      end
    end

    if timezone ~= nil then
      if type(timezone) ~= "string" then
        timezone = nil
      else
        timezone = timezone:gsub("^%s+", ""):gsub("%s+$", "")
        if timezone == "" then
          timezone = nil
        else
          local lower = timezone:lower()
          if lower == "utc" or lower == "local" or timezone == "Z" or timezone:match("^[+-]%d%d:?%d%d$") then
            -- keep supported timezones
          else
            timezone = nil
          end
        end
      end
    end

    local method = schedule.method
    if method ~= nil then
      method = tostring(method):upper()
      if not ALLOWED_METHODS[method] then
        method = nil
      end
    end

    local retry_out = nil
    if retry ~= nil then
      if retry == true then
        retry_out = true
      elseif retry == false then
        retry_out = false
      elseif type(retry) == "table" then
        local r = {}
        if retry.enabled ~= nil then
          r.enabled = retry.enabled == true
        end

        local attempts = tonumber(retry.max_attempts or retry.maxAttempts or retry.attempts)
        if attempts ~= nil then
          attempts = math.floor(attempts)
          if attempts < 1 then
            attempts = 1
          end
          if attempts > 10 then
            attempts = 10
          end
          r.max_attempts = attempts
        end

        local base_delay = tonumber(retry.base_delay_seconds or retry.baseDelaySeconds or retry.delay_seconds or retry.delaySeconds)
        if base_delay ~= nil then
          if base_delay < 0 then
            base_delay = 0
          end
          if base_delay > 3600 then
            base_delay = 3600
          end
          r.base_delay_seconds = base_delay
        end

        local max_delay = tonumber(retry.max_delay_seconds or retry.maxDelaySeconds)
        if max_delay ~= nil then
          if max_delay < 0 then
            max_delay = 0
          end
          if max_delay > 3600 then
            max_delay = 3600
          end
          r.max_delay_seconds = max_delay
        end

        local jitter = tonumber(retry.jitter)
        if jitter ~= nil then
          if jitter < 0 then
            jitter = 0
          end
          if jitter > 0.5 then
            jitter = 0.5
          end
          r.jitter = jitter
        end

        if next(r) ~= nil then
          retry_out = r
        end
      end
    end

    local sched = { enabled = enabled }
    if every_seconds then
      sched.every_seconds = every_seconds
    end
    if cron then
      sched.cron = cron
    end
    if timezone then
      sched.timezone = timezone
    end
    if retry_out ~= nil then
      sched.retry = retry_out
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

  local keep_warm = normalize_keep_warm(obj.keep_warm)
  if keep_warm then
    out.keep_warm = keep_warm
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

load_runtime_config = function(force)
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
      if runtime_name
        and runtime_name:match("^[a-zA-Z0-9_-]+$")
        and KNOWN_RUNTIMES[runtime_name]
        and not EXPERIMENTAL_RUNTIMES[runtime_name]
      then
        runtime_names[#runtime_names + 1] = runtime_name
      end
    end
    if #runtime_names == 0 then
      runtime_names = { "node", "python", "php", "lua" }
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
      if runtime == "lua" then
        runtimes[runtime] = {
          socket = "inprocess:lua",
          timeout_ms = runtime_timeout_ms,
          in_process = true,
        }
      else
        local socket = socket_map[runtime] or ("unix:" .. socket_base .. "/fn-" .. runtime .. ".sock")
        runtimes[runtime] = {
          socket = socket,
          timeout_ms = runtime_timeout_ms,
        }
      end
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
    zero_config = {
      ignore_dirs = load_zero_config_ignore_dirs(functions_root),
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
  if type(socket_uri) ~= "string" or socket_uri == "" then
    return false, "missing runtime socket"
  end
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

function M.runtime_is_in_process(runtime, runtime_cfg)
  if runtime == "lua" then
    return true
  end
  return type(runtime_cfg) == "table" and runtime_cfg.in_process == true
end

function M.check_runtime_health(runtime, runtime_cfg)
  local cfg = runtime_cfg or M.get_runtime_config(runtime)
  if M.runtime_is_in_process(runtime, cfg) then
    return true, "in-process"
  end
  if type(cfg) ~= "table" then
    return false, "runtime config missing"
  end
  return M.check_runtime_socket(cfg.socket, cfg.timeout_ms or 250)
end

function M.healthcheck_once(cfg)
  local config = cfg or load_runtime_config(false)
  for runtime, rt_cfg in pairs(config.runtimes or {}) do
    local ok, reason = M.check_runtime_health(runtime, rt_cfg)
    M.set_runtime_health(runtime, ok, ok and (reason or "ok") or reason)
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
  local global_force_url = force_url_enabled()

  local catalog = {
    generated_at = ngx.now(),
    functions_root = functions_root,
    runtimes = {},
    mapped_routes = {},
    mapped_route_conflicts = {},
    dynamic_routes = {},
  }

  local function same_target(a, runtime, fn_name, version)
    if type(a) ~= "table" then
      return false
    end
    return a.runtime == runtime and a.fn_name == fn_name and (a.version or nil) == (version or nil)
  end

  local function methods_overlap(a, b)
    if not a or not b then return true end -- nil means ALL methods
    local map = {}
    for _, m in ipairs(a) do map[m] = true end
    for _, m in ipairs(b) do
      if map[m] then return true end
    end
    return false
  end

  local function register_route(route, runtime, fn_name, version, methods, source_rank, allow_hosts, force_url)
    if type(route) ~= "string" or route == "" then
      return
    end
    if type(runtime) ~= "string" or not ((cfg.runtimes or {})[runtime]) then
      return
    end
    if catalog.mapped_route_conflicts[route] then
      return
    end
    
    local new_entry = {
      runtime = runtime,
      fn_name = fn_name,
      version = version,
      methods = methods,
      source_rank = tonumber(source_rank) or 1,
      allow_hosts = normalize_allow_hosts(allow_hosts),
      force_url = force_url == true,
    }

    local current_list = catalog.mapped_routes[route]
    if not current_list then
      catalog.mapped_routes[route] = { new_entry }
      return
    end

    -- Check for conflicts with existing entries
    -- Precedence: config/policy (3) > manifest (2) > file-based (1)
    -- force-url is only meaningful for config/policy routes: it allows overriding
    -- existing lower-priority claims. Without force-url, policy routes never
    -- silently override an already-mapped URL.
    local to_remove = {}
    for _, existing in ipairs(current_list) do
      if not same_target(existing, runtime, fn_name, version) then
        if methods_overlap(existing.methods, methods)
          and host_constraints_overlap(existing.allow_hosts, new_entry.allow_hosts) then
          local er = tonumber(existing.source_rank) or 1
          local nr = tonumber(new_entry.source_rank) or 1
          if er == nr then
            if nr == 3 then
              local ef = existing.force_url == true
              local nf = new_entry.force_url == true
              if nf and not ef then
                to_remove[existing] = true
              elseif ef and not nf then
                return
              else
                -- Same priority and overlap on different target => real conflict.
                catalog.mapped_routes[route] = nil
                catalog.mapped_route_conflicts[route] = true
                return
              end
            else
              -- Same priority and overlap on different target => real conflict.
              catalog.mapped_routes[route] = nil
              catalog.mapped_route_conflicts[route] = true
              return
            end
          elseif er > nr then
            -- Existing has higher precedence; ignore new route.
            return
          else
            -- New has higher precedence; remove lower-priority overlapping entries.
            -- Policy routes only override if explicitly forced.
            if nr == 3 and new_entry.force_url ~= true then
              -- Keep existing mapping; still allow the new entry to be appended so
              -- it can serve non-overlapping methods/hosts on the same route.
            else
              to_remove[existing] = true
            end
          end
        end
      end
    end

    if next(to_remove) ~= nil then
      local filtered = {}
      for _, existing in ipairs(current_list) do
        if not to_remove[existing] then
          filtered[#filtered + 1] = existing
        end
      end
      current_list = filtered
      catalog.mapped_routes[route] = current_list
    end

    -- No conflict, append.
    table.insert(current_list, new_entry)
  end


	  do
	    local root_manifest_routes, root_has_manifest = detect_manifest_routes_in_dir(functions_root, ".")
	    if root_has_manifest then
	      for _, item in ipairs(root_manifest_routes) do
	        register_route(item.route, item.runtime, item.target, nil, item.methods, 2)
	      end
	    end
	  end

	  -- Collect runtime names to skip them in zero-config discovery (they have their own scan).
	  local runtime_dirs = {}
	  for rt, _ in pairs(cfg.runtimes or {}) do
	    runtime_dirs[rt] = true
	  end
  local zero_config_ignore_dirs = {}
  for _, dir_name in ipairs(((cfg.zero_config or {}).ignore_dirs) or {}) do
    local normalized = normalize_zero_config_dir(dir_name)
    if normalized then
      zero_config_ignore_dirs[normalized] = true
    end
  end

  local function should_skip_zero_config_dir(name)
    local lower = string.lower(tostring(name or ""))
    if lower == "" then
      return true
    end
    if lower:sub(1, 1) == "." then
      return true
    end
    if zero_config_ignore_dirs[lower] then
      return true
    end
    return false
  end

  local function runtime_root_exposes_routes(abs_dir, rel_dir, depth)
    if depth > 6 then
      return false
    end

    local manifest_routes, manifest_found = detect_manifest_routes_in_dir(abs_dir, rel_dir)
    if manifest_found and #manifest_routes > 0 then
      return true
    end

    local file_routes = detect_file_based_routes_in_dir(abs_dir, rel_dir)
    if #file_routes > 0 then
      return true
    end

    for _, child_dir in ipairs(list_dirs(abs_dir)) do
      local child_name = basename(child_dir)
      if child_name and not should_skip_zero_config_dir(child_name) then
        local child_rel = (rel_dir and rel_dir ~= "" and rel_dir ~= ".")
          and (rel_dir .. "/" .. child_name)
          or child_name
        if runtime_root_exposes_routes(child_dir, child_rel, depth + 1) then
          return true
        end
      end
    end

    return false
  end

  local function should_skip_runtime_named_root_dir(sub_dir, sub_name)
    if not runtime_dirs[sub_name] then
      return false
    end
    -- If a runtime-named root directory exposes file-based or manifest routes
    -- (for example next-style/php/get.export.php), keep it in zero-config scan.
    if runtime_root_exposes_routes(sub_dir, sub_name, 0) then
      return false
    end
    -- Otherwise treat it as runtime-scoped compatibility layout and skip here.
    return true
  end

	  local function discover_zero_config_dir(abs_dir, rel_dir, depth)
	    if depth > 6 then
	      return
    end

    local has_manifest = false
    local manifest_routes, manifest_found = detect_manifest_routes_in_dir(abs_dir, rel_dir)
    if manifest_found then
      has_manifest = true
      for _, item in ipairs(manifest_routes) do
        register_route(item.route, item.runtime, item.target, nil, item.methods, 2)
      end
    end

    local file_routes = detect_file_based_routes_in_dir(abs_dir, rel_dir)
    for _, item in ipairs(file_routes) do
      register_route(item.route, item.runtime, item.target, nil, item.methods, 1, item.allow_hosts)
    end

	    local fn_cfg = read_json_file(abs_dir .. "/fn.config.json")
	    local has_explicit_cfg = is_explicit_fn_config(fn_cfg)
	    local is_leaf = has_manifest or has_explicit_cfg

	    if is_leaf and rel_dir ~= "." then
	      return
	    end

		    for _, sub_dir in ipairs(list_dirs(abs_dir)) do
		      local sub_name = basename(sub_dir)
		      if sub_name and not should_skip_zero_config_dir(sub_name) then
	        -- Skip runtime-named directories at root level only when they look like
	        -- runtime-scoped compatibility roots (not file-routed namespaces).
	        local skip_runtime_root = false
	        if depth == 0 and runtime_dirs[sub_name] then
          skip_runtime_root = should_skip_runtime_named_root_dir(sub_dir, sub_name)
        end
        if not skip_runtime_root then
          local sub_rel = (rel_dir and rel_dir ~= "" and rel_dir ~= ".") and (rel_dir .. "/" .. sub_name) or sub_name
          discover_zero_config_dir(sub_dir, sub_rel, depth + 1)
        end
      end
    end
  end
  discover_zero_config_dir(functions_root, ".", 0)

  for _, runtime in ipairs(sorted_keys(cfg.runtimes or {})) do
    local runtime_dir = functions_root .. "/" .. runtime
    local runtime_entry = {
      functions = {},
    }

    local function register_runtime_function(fn_dir, fn_name)
        local fn_entry = {
          has_default = has_app_file(fn_dir) or has_valid_config_entrypoint(fn_dir),
          versions = {},
          policy = normalize_policy(read_json_file(fn_dir .. "/fn.config.json")),
          versions_policy = {},
        }

        for _, ver_dir in ipairs(list_dirs(fn_dir)) do
          local ver = basename(ver_dir)
          if ver and ver:match("^[a-zA-Z0-9_.-]+$") and (has_app_file(ver_dir) or has_valid_config_entrypoint(ver_dir)) then
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
            local root_allow_hosts = fn_entry.policy and fn_entry.policy.allow_hosts or nil
            local root_force_url = fn_entry.policy and fn_entry.policy.force_url or nil
            if #policy_routes == 0 then
              -- For namespaced names (e.g., "api/v1/users"), normalize each
              -- segment individually and preserve the "/" structure so the
              -- route becomes /api/v1/users (Next.js-style), NOT /api-v1-users.
              local parts = {}
              for seg in fn_name:gmatch("[^/]+") do
                local norm = normalize_route_token(seg)
                if norm then
                  parts[#parts + 1] = norm
                end
              end
              local canonical_name = #parts > 0 and table.concat(parts, "/") or fn_name
              policy_routes = { "/" .. canonical_name, "/" .. canonical_name .. "/*" }
            end
            for _, route in ipairs(policy_routes) do
              register_route(route, runtime, fn_name, nil, root_methods, 3, root_allow_hosts, root_force_url or global_force_url)
            end
          end

          for _, ver in ipairs(fn_entry.versions) do
            local ver_policy = (fn_entry.versions_policy or {})[ver] or {}
            local ver_methods = ver_policy.methods or (fn_entry.policy and fn_entry.policy.methods) or DEFAULT_METHODS
            local ver_allow_hosts = ver_policy.allow_hosts or (fn_entry.policy and fn_entry.policy.allow_hosts) or nil
            -- Version-scoped configs should not be able to "take over" an existing URL mapping by
            -- themselves. This keeps per-version routing additive by default. Operators can still
            -- force all policy routes globally via FN_FORCE_URL=1 / `fastfn dev --force-url`.
            for _, route in ipairs(ver_policy.routes or {}) do
              register_route(route, runtime, fn_name, ver, ver_methods, 3, ver_allow_hosts, global_force_url)
            end
          end
        end
    end

    -- Recursive discovery supports nested namespaces (e.g., user/api/v1/fn).
    -- Depth controlled by FN_NAMESPACE_DEPTH (default 3, max 5).
    local max_ns_depth = tonumber(os.getenv("FN_NAMESPACE_DEPTH")) or 3
    if max_ns_depth < 1 then max_ns_depth = 1 end
    if max_ns_depth > 5 then max_ns_depth = 5 end

    local function looks_like_version_label(name)
      local s = tostring(name or "")
      return s:match("^v%d[%w_.-]*$") ~= nil or s:match("^%d[%w_.-]*$") ~= nil
    end

    local function has_versioned_runtime_children(dir)
      local seen_version = false
      for _, child in ipairs(list_dirs(dir)) do
        local child_name = basename(child)
        if child_name and child_name:match("^[A-Za-z0-9_.-]+$") then
          if has_app_file(child) or has_valid_config_entrypoint(child) then
            if looks_like_version_label(child_name) then
              seen_version = true
            else
              return false
            end
          end
        end
      end
      return seen_version
    end

    local function discover_runtime_dir(dir, prefix, depth)
      for _, sub in ipairs(list_dirs(dir)) do
        local name = basename(sub)
        if name and name:match("^[a-zA-Z0-9_-]+$") then
          if has_app_file(sub) or has_valid_config_entrypoint(sub) or has_versioned_runtime_children(sub) then
            local fn_name = prefix ~= "" and (prefix .. "/" .. name) or name
            register_runtime_function(sub, fn_name)
          elseif depth < max_ns_depth then
            local next_prefix = prefix ~= "" and (prefix .. "/" .. name) or name
            discover_runtime_dir(sub, next_prefix, depth + 1)
          end
        end
      end
    end
    discover_runtime_dir(runtime_dir, "", 1)

    catalog.runtimes[runtime] = runtime_entry
  end

  catalog.dynamic_routes = sort_dynamic_routes(catalog.mapped_routes)

  CACHE:set("catalog:raw", cjson.encode(catalog))
  CACHE:set("catalog:scanned_at", ngx.now())
  return catalog
end

local function contains_method_local(list, m)
  if not list then
    return true
  end
  for _, v in ipairs(list) do
    if v == m then
      return true
    end
  end
  return false
end

local function compile_dynamic_route_pattern(mapped_route)
  if mapped_route == "/" then
    return "^/$", {}
  end

  local parts = {}
  local names = {}
  local used_names = {}
  for seg in tostring(mapped_route):gmatch("[^/]+") do
    local name, catch_all = seg:match("^:([A-Za-z0-9_]+)(%*?)$")
    if name then
      used_names[name] = true
      names[#names + 1] = name
      if catch_all == "*" then
        parts[#parts + 1] = "(.+)"
      else
        parts[#parts + 1] = "([^/]+)"
      end
    elseif seg == "*" then
      local wildcard_name = "wildcard"
      if used_names[wildcard_name] then
        local i = 2
        while used_names[wildcard_name .. tostring(i)] do
          i = i + 1
        end
        wildcard_name = wildcard_name .. tostring(i)
      end
      used_names[wildcard_name] = true
      names[#names + 1] = wildcard_name
      parts[#parts + 1] = "(.+)"
    else
      parts[#parts + 1] = seg:gsub("([%^%$%(%)%%%.%[%]%+%-%?%*])", "%%%1")
    end
  end

  return "^/" .. table.concat(parts, "/") .. "$", names
end

local function extract_dynamic_route_params(mapped_route, path)
  local pattern, names = compile_dynamic_route_pattern(mapped_route)
  local captures = { tostring(path or ""):match(pattern) }
  if #captures == 0 then
    return nil
  end

  local params = {}
  local unescape = ngx and ngx.unescape_uri
  for i, name in ipairs(names) do
    local v = captures[i]
    if v ~= nil then
      if unescape then
        params[name] = unescape(v)
      else
        params[name] = v
      end
    end
  end
  return params
end

function M.resolve_mapped_target(path, method, host_ctx)
  local route = normalize_single_route(path)
  if not route then
    return nil, nil, nil, nil, nil
  end
  local request_host, request_authority = resolve_request_host_values(
    type(host_ctx) == "table" and host_ctx.host or nil,
    type(host_ctx) == "table" and host_ctx.x_forwarded_host or nil
  )
  local saw_host_mismatch = false
  -- Use hot-reload cache; avoid full filesystem rescans on every request.
  local catalog = M.discover_functions(false)

  -- 1. Try Exact Match
  local entries = (catalog.mapped_routes or {})[route]
  if entries then
    for _, entry in ipairs(entries) do
      if contains_method_local(entry.methods, method) then
        if host_allowlist_matches(entry.allow_hosts, request_host, request_authority) then
          return entry.runtime, entry.fn_name, entry.version, {}, nil
        end
        if type(entry.allow_hosts) == "table" and #entry.allow_hosts > 0 then
          saw_host_mismatch = true
        end
      end
    end
  end

  -- 2. Try Pattern Matching (Dynamic Routes)
  local dynamic_routes = type(catalog.dynamic_routes) == "table" and catalog.dynamic_routes or sort_dynamic_routes(catalog.mapped_routes)
  for _, mapped_route in ipairs(dynamic_routes) do
    local route_entries = (catalog.mapped_routes or {})[mapped_route]
    if route_entries then
      local params = extract_dynamic_route_params(mapped_route, route)
      if params ~= nil then
        for _, entry in ipairs(route_entries) do
          if contains_method_local(entry.methods, method) then
            if host_allowlist_matches(entry.allow_hosts, request_host, request_authority) then
              return entry.runtime, entry.fn_name, entry.version, params, nil
            end
            if type(entry.allow_hosts) == "table" and #entry.allow_hosts > 0 then
              saw_host_mismatch = true
            end
          end
        end
      end
    end
  end

  if saw_host_mismatch then
    return nil, nil, nil, nil, "host not allowed"
  end

  return nil, nil, nil, nil, nil
end

function M.resolve_function_policy(runtime, fn_name, version)
  local defaults = M.get_defaults()
  local catalog = M.discover_functions(false)
  local runtime_entry = (catalog.runtimes or {})[runtime]
  if not runtime_entry then
    return nil, "unknown runtime"
  end

  local functions = runtime_entry.functions or {}
  local fn_entry = functions[fn_name]
  
  -- Fallback: If map lookup fails, try iterating (in case it became a sequence)
  if not fn_entry then
    -- Check if it's a direct file path (Zero-Config / fn.routes.json)
    if fn_name:find("/") or fn_name:match("%.[a-z0-9]+$") then
       local dir_rel = fn_name:match("^(.*)/[^/]+$") or "."
       local overlay_stack = {}
       local cur_rel = dir_rel
       while true do
         local abs_dir = (catalog.functions_root or "") .. ((cur_rel == "." or cur_rel == "") and "" or ("/" .. cur_rel))
         local cfg_obj = read_json_file(abs_dir .. "/fn.config.json")
         if type(cfg_obj) == "table" and next(cfg_obj) ~= nil and not is_explicit_fn_config(cfg_obj) then
           local overlay = normalize_policy(cfg_obj)
           if type(overlay) == "table" and next(overlay) ~= nil then
             overlay_stack[#overlay_stack + 1] = overlay
           end
         end
         if cur_rel == "." or cur_rel == "" then
           break
         end
         cur_rel = cur_rel:match("^(.*)/[^/]+$") or "."
       end

       local policy = { methods = ALL_METHODS }
       for i = #overlay_stack, 1, -1 do
         for k, v in pairs(overlay_stack[i]) do
           policy[k] = v
         end
       end
       -- Synthetic entry
       fn_entry = {
         has_default = true,
         policy = policy,
       }
     else
       return nil, "unknown function"
     end
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
  local allow_hosts = ver_policy.allow_hosts or root_policy.allow_hosts

  local resolved = {
    timeout_ms = tonumber(ver_policy.timeout_ms or root_policy.timeout_ms or defaults.timeout_ms) or DEFAULT_TIMEOUT_MS,
    max_concurrency = tonumber(ver_policy.max_concurrency or root_policy.max_concurrency or defaults.max_concurrency) or DEFAULT_MAX_CONCURRENCY,
    max_body_bytes = tonumber(ver_policy.max_body_bytes or root_policy.max_body_bytes or defaults.max_body_bytes) or DEFAULT_MAX_BODY_BYTES,
    include_debug_headers = (ver_policy.include_debug_headers == true) or (root_policy.include_debug_headers == true),
    methods = methods,
  }
  if type(allow_hosts) == "table" then
    resolved.allow_hosts = {}
    for _, host in ipairs(allow_hosts) do
      resolved.allow_hosts[#resolved.allow_hosts + 1] = host
    end
  end

  local worker_pool = normalize_worker_pool(ver_policy.worker_pool or root_policy.worker_pool, resolved.max_concurrency)
  if worker_pool then
    resolved.worker_pool = worker_pool
  end

  local keep_warm = normalize_keep_warm(ver_policy.keep_warm or root_policy.keep_warm)
  if keep_warm then
    resolved.keep_warm = keep_warm
  end

  -- Rust/Go handlers may compile on first invoke; avoid first-hit timeouts.
  if runtime == "rust" or runtime == "go"
    or (type(fn_name) == "string" and (fn_name:match("%.rs$") or fn_name:match("%.go$")))
  then
    if (resolved.timeout_ms or 0) < 180000 then
      resolved.timeout_ms = 180000
    end
  end

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

function M.resolve_named_target(fn_name, version)
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
      watchdog = {
        enabled = hot_reload_watchdog_enabled(),
        active = CACHE:get(CATALOG_WATCHDOG_ACTIVE_KEY) == 1,
        backend = CACHE:get(CATALOG_WATCHDOG_BACKEND_KEY),
        last_scan_at = CACHE:get(CATALOG_WATCHDOG_LAST_SCAN_KEY),
        error = CACHE:get(CATALOG_WATCHDOG_ERROR_KEY),
      },
    },
    routing = {
      mapped_routes = mapped_count,
      mapped_route_conflicts = mapped_conflicts,
    },
    functions = {
      summary = {
        total = 0,
        warm = 0,
        stale = 0,
        cold = 0,
        keep_warm_enabled = 0,
        pool_enabled = 0,
        pool_active = 0,
        pool_queued = 0,
        pool_queue_drops = 0,
        pool_queue_overflow_drops = 0,
        pool_queue_timeout_drops = 0,
      },
      states = {},
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

  for runtime, rt_entry in pairs((catalog and catalog.runtimes) or {}) do
    for fn_name, fn_entry in pairs((rt_entry and rt_entry.functions) or {}) do
      local function add_function_state(version)
        local key = runtime .. "/" .. fn_name .. "@" .. (version or "default")
        local policy = M.resolve_function_policy(runtime, fn_name, version) or {}
        local keep_warm_cfg = type(policy.keep_warm) == "table" and policy.keep_warm or nil
        local pool_state = worker_pool_snapshot(key, policy)
        local state, warm_at = warm_state_for_key(key, keep_warm_cfg)
        local row = {
          runtime = runtime,
          name = fn_name,
          version = version or nil,
          key = key,
          state = state,
          warm_at = warm_at,
          keep_warm = keep_warm_cfg,
          worker_pool = pool_state,
        }
        out.functions.states[#out.functions.states + 1] = row
        out.functions.summary.total = out.functions.summary.total + 1
        if keep_warm_cfg and keep_warm_cfg.enabled == true and tonumber(keep_warm_cfg.min_warm or 0) > 0 then
          out.functions.summary.keep_warm_enabled = out.functions.summary.keep_warm_enabled + 1
        end
        if state == "warm" then
          out.functions.summary.warm = out.functions.summary.warm + 1
        elseif state == "stale" then
          out.functions.summary.stale = out.functions.summary.stale + 1
        else
          out.functions.summary.cold = out.functions.summary.cold + 1
        end
        if pool_state then
          if pool_state.enabled == true then
            out.functions.summary.pool_enabled = out.functions.summary.pool_enabled + 1
          end
          out.functions.summary.pool_active = out.functions.summary.pool_active + (tonumber(pool_state.active) or 0)
          out.functions.summary.pool_queued = out.functions.summary.pool_queued + (tonumber(pool_state.queued) or 0)
          local drops = pool_state.queue_drops or {}
          local drops_overflow = tonumber(drops.overflow) or 0
          local drops_timeout = tonumber(drops.timeout) or 0
          out.functions.summary.pool_queue_overflow_drops = out.functions.summary.pool_queue_overflow_drops + drops_overflow
          out.functions.summary.pool_queue_timeout_drops = out.functions.summary.pool_queue_timeout_drops + drops_timeout
          out.functions.summary.pool_queue_drops = out.functions.summary.pool_queue_drops + drops_overflow + drops_timeout
        end
      end

      if fn_entry.has_default then
        add_function_state(nil)
      end
      for _, ver in ipairs(fn_entry.versions or {}) do
        add_function_state(ver)
      end
    end
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

  local init_cfg = load_runtime_config(true)
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

  local watchdog_started = false
  if hot_reload_enabled() and hot_reload_watchdog_enabled() then
    local ok_watch, watch_meta_or_err = watchdog.start({
      root = init_cfg.functions_root,
      poll_interval_s = tonumber(os.getenv("FN_HOT_RELOAD_WATCHDOG_POLL")) or 0.20,
      debounce_ms = tonumber(os.getenv("FN_HOT_RELOAD_DEBOUNCE_MS")) or 150,
      on_change = function()
        local acquired = CACHE:add(CATALOG_SCAN_LOCK_KEY, ngx.now(), 2)
        if not acquired then
          return
        end
        local ok_scan, scan_err = pcall(M.discover_functions, true)
        CACHE:delete(CATALOG_SCAN_LOCK_KEY)
        if not ok_scan then
          ngx.log(ngx.ERR, "catalog watchdog reload failed: ", tostring(scan_err))
          return
        end
        CACHE:set(CATALOG_WATCHDOG_LAST_SCAN_KEY, ngx.now())
      end,
    })
    if ok_watch then
      watchdog_started = true
      CACHE:set(CATALOG_WATCHDOG_ACTIVE_KEY, 1)
      CACHE:set(CATALOG_WATCHDOG_BACKEND_KEY, tostring((watch_meta_or_err or {}).backend or "watchdog"))
      CACHE:delete(CATALOG_WATCHDOG_ERROR_KEY)
      ngx.log(ngx.INFO, "catalog watchdog enabled backend=", tostring((watch_meta_or_err or {}).backend or "watchdog"))
    else
      CACHE:set(CATALOG_WATCHDOG_ACTIVE_KEY, 0)
      CACHE:set(CATALOG_WATCHDOG_ERROR_KEY, tostring(watch_meta_or_err))
      ngx.log(ngx.WARN, "catalog watchdog unavailable: ", tostring(watch_meta_or_err), "; falling back to interval hot reload")
    end
  else
    CACHE:set(CATALOG_WATCHDOG_ACTIVE_KEY, 0)
  end

  if hot_reload_enabled() and not watchdog_started then
    local hot_interval = tonumber(os.getenv("FN_HOT_RELOAD_INTERVAL")) or DEFAULT_HOT_RELOAD_INTERVAL
    if hot_interval < 1 then
      hot_interval = DEFAULT_HOT_RELOAD_INTERVAL
    end

    local ok_hot, hot_err = ngx.timer.every(hot_interval, function(premature)
      if premature then
        return
      end
      local acquired = CACHE:add(CATALOG_SCAN_LOCK_KEY, ngx.now(), math.max(2, hot_interval))
      if not acquired then
        return
      end
      local ok_scan, scan_err = pcall(M.discover_functions, true)
      CACHE:delete(CATALOG_SCAN_LOCK_KEY)
      if not ok_scan then
        ngx.log(ngx.ERR, "catalog hot reload failed: ", tostring(scan_err))
      end
    end)

    if not ok_hot then
      ngx.log(ngx.ERR, "failed to start catalog hot reload timer: ", hot_err)
    end
  end
end

return M
