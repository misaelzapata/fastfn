local routes = require "fastfn.core.routes"
local client = require "fastfn.core.client"
local lua_runtime = require "fastfn.core.lua_runtime"
local limits = require "fastfn.core.limits"
local utils = require "fastfn.core.gateway_utils"
local cjson = require "cjson.safe"

local M = {}

local CACHE = ngx.shared.fn_cache
local CONC = ngx.shared.fn_conc

local DEFAULT_TICK_SECONDS = 1
local DEFAULT_SCHEDULE_MAX_BODY_BYTES = 1024 * 1024
local DEFAULT_KEEP_WARM_PING_SECONDS = 45
local DEFAULT_KEEP_WARM_IDLE_TTL_SECONDS = 300
local DEFAULT_POOL_MIN_WARM = 0
local DEFAULT_POOL_MAX_QUEUE = 0
local DEFAULT_POOL_IDLE_TTL_SECONDS = 300
local DEFAULT_POOL_QUEUE_TIMEOUT_MS = 0
local DEFAULT_POOL_QUEUE_POLL_MS = 20
local DEFAULT_POOL_OVERFLOW_STATUS = 429
local LOG_BODY_MAX = 800
local TICK_LOCK_KEY = "sched:tick:running"
local MAX_CRON_LOOKAHEAD_MINUTES = 366 * 24 * 60 * 2 -- 2 years

local DEFAULT_RETRY_MAX_ATTEMPTS = 3
local DEFAULT_RETRY_BASE_DELAY_SECONDS = 1
local DEFAULT_RETRY_MAX_DELAY_SECONDS = 30
local DEFAULT_RETRY_JITTER = 0.2

local DEFAULT_PERSIST_INTERVAL_SECONDS = 15
local DEFAULT_STATE_FILE_NAME = "scheduler-state.json"
local MAX_PERSISTED_ERROR_LEN = 2000

local function now_s()
  return ngx.now()
end

local function new_request_id()
  local ts_ms = math.floor(now_s() * 1000)
  return string.format("sched-%d-%d-%06d", ts_ms, ngx.worker.pid(), math.random(0, 999999))
end

local function fn_key(runtime, name, version)
  local v = version or "default"
  return runtime .. "/" .. name .. "@" .. v
end

local function state_key(key, suffix)
  return "sched:" .. key .. ":" .. suffix
end

local function warm_key(key)
  return "warm:" .. key
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function dirname(path)
  local p = tostring(path or "")
  local dir = p:match("^(.*)/[^/]+$") or ""
  if dir == "" then
    return "."
  end
  return dir
end

local function ensure_dir(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local ok = os.execute(string.format("mkdir -p %s", shell_quote(path)))
  return ok == true or ok == 0
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  return raw
end

local function write_file_atomic(path, raw)
  local dir = dirname(path)
  if not ensure_dir(dir) then
    return false, "failed to create state dir"
  end

  local tmp = string.format("%s.tmp.%d.%06d", path, ngx.worker.pid(), math.random(0, 999999))
  local f, err = io.open(tmp, "wb")
  if not f then
    return false, tostring(err or "open tmp failed")
  end
  f:write(raw)
  f:close()

  local ok_rename = os.rename(tmp, path)
  if ok_rename then
    return true
  end

  local ok_mv = os.execute(string.format("mv -f %s %s", shell_quote(tmp), shell_quote(path)))
  if ok_mv == true or ok_mv == 0 then
    return true
  end

  pcall(os.remove, tmp)
  return false, "failed to move state file into place"
end

local function normalize_functions_root(root)
  if type(root) ~= "string" then
    return nil
  end
  local out = root:gsub("/+$", "")
  if out == "" then
    return nil
  end
  return out
end

local function scheduler_state_path(functions_root)
  local override = os.getenv("FN_SCHEDULER_STATE_PATH")
  if override ~= nil and tostring(override) ~= "" then
    return tostring(override)
  end
  local root = normalize_functions_root(functions_root)
  if not root then
    return nil
  end
  return root .. "/.fastfn/" .. DEFAULT_STATE_FILE_NAME
end

local function env_flag(name, default_value)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default_value
  end
  local v = tostring(raw):lower()
  if v == "1" or v == "true" or v == "yes" or v == "on" then
    return true
  end
  if v == "0" or v == "false" or v == "no" or v == "off" then
    return false
  end
  return default_value
end

local function scheduler_persist_enabled()
  return env_flag("FN_SCHEDULER_PERSIST_ENABLED", true)
end

local function scheduler_persist_interval_seconds()
  local v = tonumber(os.getenv("FN_SCHEDULER_PERSIST_INTERVAL")) or DEFAULT_PERSIST_INTERVAL_SECONDS
  if v < 5 then
    v = 5
  end
  if v > 3600 then
    v = 3600
  end
  return math.floor(v)
end

local function table_is_object(v)
  return type(v) == "table" and next(v) ~= nil
end

local function should_block_runtime(runtime, runtime_cfg)
  local up = routes.runtime_is_up(runtime)
  if up ~= true then
    local ok, reason = routes.check_runtime_health(runtime, runtime_cfg)
    routes.set_runtime_health(runtime, ok, ok and (reason or "ok") or reason)
    return not ok
  end
  return false
end

local function pick_policy_method(methods)
  if type(methods) ~= "table" or #methods == 0 then
    return "GET"
  end

  local first = tostring(methods[1]):upper()
  for _, m in ipairs(methods) do
    local up = tostring(m):upper()
    if up == "GET" then
      return "GET"
    end
    if first == "" then
      first = up
    end
  end
  if first == "" then
    return "GET"
  end
  return first
end

local function scheduler_worker_pool_context(policy)
  local max_concurrency = tonumber((policy or {}).max_concurrency) or 0
  local has_cfg = type((policy or {}).worker_pool) == "table"
  local cfg = has_cfg and policy.worker_pool or {}

  local min_warm = math.floor(tonumber(cfg.min_warm) or DEFAULT_POOL_MIN_WARM)
  if min_warm < 0 then
    min_warm = DEFAULT_POOL_MIN_WARM
  end

  local idle_ttl_seconds = math.floor(tonumber(cfg.idle_ttl_seconds) or DEFAULT_POOL_IDLE_TTL_SECONDS)
  if idle_ttl_seconds < 1 then
    idle_ttl_seconds = DEFAULT_POOL_IDLE_TTL_SECONDS
  end

  local max_workers = math.floor(tonumber(cfg.max_workers) or max_concurrency)
  if max_workers < 0 then
    max_workers = 0
  end

  local max_queue = math.floor(tonumber(cfg.max_queue) or DEFAULT_POOL_MAX_QUEUE)
  if max_queue < 0 then
    max_queue = DEFAULT_POOL_MAX_QUEUE
  end

  local queue_timeout_ms = math.floor(tonumber(cfg.queue_timeout_ms) or DEFAULT_POOL_QUEUE_TIMEOUT_MS)
  if queue_timeout_ms < 0 then
    queue_timeout_ms = DEFAULT_POOL_QUEUE_TIMEOUT_MS
  end

  local queue_poll_ms = math.floor(tonumber(cfg.queue_poll_ms) or DEFAULT_POOL_QUEUE_POLL_MS)
  if queue_poll_ms < 1 then
    queue_poll_ms = DEFAULT_POOL_QUEUE_POLL_MS
  end

  local overflow_status = math.floor(tonumber(cfg.overflow_status) or DEFAULT_POOL_OVERFLOW_STATUS)
  if overflow_status ~= 429 and overflow_status ~= 503 then
    overflow_status = DEFAULT_POOL_OVERFLOW_STATUS
  end

  return {
    enabled = has_cfg and cfg.enabled ~= false or false,
    min_warm = min_warm,
    max_workers = max_workers,
    max_queue = max_queue,
    idle_ttl_seconds = idle_ttl_seconds,
    queue_timeout_ms = queue_timeout_ms,
    queue_poll_ms = queue_poll_ms,
    overflow_status = overflow_status,
  }
end

local function run_scheduled_invocation(runtime, name, version, schedule, policy, trigger_type, trigger_meta)
  local rt_cfg = routes.get_runtime_config(runtime)
  if not rt_cfg then
    return 404, "unknown runtime"
  end

  if should_block_runtime(runtime, rt_cfg) then
    return 503, "runtime down"
  end

  local method = tostring(schedule.method or "GET"):upper()
  local allowed = false
  for _, m in ipairs(policy.methods or { "GET" }) do
    if tostring(m):upper() == method then
      allowed = true
      break
    end
  end
  if not allowed then
    return 405, "method not allowed by function policy"
  end

  local body = schedule.body
  if body ~= nil and type(body) ~= "string" then
    body = tostring(body)
  end
  local max_body_bytes = tonumber(policy.max_body_bytes) or DEFAULT_SCHEDULE_MAX_BODY_BYTES
  if body and #body > max_body_bytes then
    return 413, "payload too large"
  end

  local version_label = version or "default"
  local key = fn_key(runtime, name, version)
  local trigger = tostring(trigger_type or "schedule")
  local acquired, acquire_err = limits.try_acquire(CONC, key, tonumber(policy.max_concurrency) or 0)
  if not acquired then
    if acquire_err == "busy" then
      return 429, "busy"
    end
    return 500, "concurrency gate failure"
  end

  local request_id = new_request_id()
  local start = now_s()

  local route = "/fn/" .. name
  if version and version ~= "" then
    route = route .. "@" .. version
  end

  local ok_call, resp_or_err_code, err_code, err_msg = xpcall(function()
    local event = {
      id = request_id,
      ts = math.floor(now_s() * 1000),
      method = method,
      path = route,
      raw_path = route,
      query = type(schedule.query) == "table" and schedule.query or {},
      headers = type(schedule.headers) == "table" and schedule.headers or {},
      body = body,
      client = {
        ip = "127.0.0.1",
        ua = "fastfn-scheduler",
      },
      context = {
        request_id = request_id,
        runtime = runtime,
        function_name = name,
        version = version_label,
        timeout_ms = tonumber(policy.timeout_ms) or 2500,
        max_concurrency = tonumber(policy.max_concurrency) or 0,
        max_body_bytes = max_body_bytes,
        worker_pool = scheduler_worker_pool_context(policy),
        trigger = (function()
          local out = {
            type = trigger,
            every_seconds = tonumber(schedule.every_seconds) or nil,
          }
          if type(schedule.cron) == "string" and schedule.cron ~= "" then
            out.cron = schedule.cron
          end
          if type(schedule.timezone) == "string" and schedule.timezone ~= "" and schedule.timezone:lower() ~= "local" then
            out.timezone = schedule.timezone
          end
          if type(trigger_meta) == "table" then
            for k, v in pairs(trigger_meta) do
              if out[k] == nil then
                out[k] = v
              end
            end
          end
          return out
        end)(),
        user = type(schedule.context) == "table" and schedule.context or nil,
      },
    }

    if routes.runtime_is_in_process(runtime, rt_cfg) then
      return lua_runtime.call({
        fn = name,
        version = version,
        event = event,
      })
    end
    return client.call_unix(rt_cfg.socket, {
      fn = name,
      version = version,
      event = event,
    }, tonumber(policy.timeout_ms) or 2500)
  end, debug.traceback)

  limits.release(CONC, key)

  if not ok_call then
    ngx.log(ngx.ERR, trigger, " exception id=", request_id, " fn=", key, " err=", tostring(resp_or_err_code))
    return 500, "scheduler exception"
  end

  local resp = resp_or_err_code
  if not resp then
    local status, message = utils.map_runtime_error(err_code)
    ngx.log(
      ngx.ERR,
      "fn schedule runtime error id=", request_id,
      " fn=", key,
      " trigger=", trigger,
      " err_code=", tostring(err_code),
      " err_msg=", tostring(err_msg),
      " mapped_status=", tostring(status),
      " mapped_msg=", tostring(message)
    )
    if err_code == "connect_error" then
      routes.set_runtime_health(runtime, false, err_msg)
    end
    return status, message
  end

  local latency_ms = math.floor((now_s() - start) * 1000)
  ngx.log(ngx.INFO, "fn ", trigger, " id=", request_id, " fn=", key, " status=", resp.status, " latency_ms=", latency_ms)
  local status_num = tonumber(resp.status) or 200
  if status_num < 500 then
    CACHE:set(warm_key(key), now_s())
  end
  if status_num >= 400 then
    local body = ""
    if type(resp.body) == "string" then
      body = resp.body
      if #body > LOG_BODY_MAX then
        body = body:sub(1, LOG_BODY_MAX) .. "...<truncated>"
      end
    end
    ngx.log(
      ngx.ERR,
      "fn ", trigger, " non-2xx id=", request_id,
      " fn=", key,
      " status=", tostring(status_num),
      " latency_ms=", tostring(latency_ms),
      " body=", body
    )
  end

  return status_num, nil
end

local function effective_schedule(root_policy, ver_policy)
  if type(ver_policy) == "table" and type(ver_policy.schedule) == "table" then
    return ver_policy.schedule
  end
  if type(root_policy) == "table" and type(root_policy.schedule) == "table" then
    return root_policy.schedule
  end
  return nil
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_timezone_offset(tz)
  local raw = trim(tz)
  if raw == "" then
    return nil
  end
  local lower = raw:lower()
  if lower == "local" then
    return nil
  end
  if lower == "utc" or raw == "Z" then
    return 0
  end
  local sign, hh, mm = raw:match("^([+-])(%d%d):?(%d%d)$")
  if not sign then
    return nil, "unsupported timezone"
  end
  local h = tonumber(hh)
  local m = tonumber(mm)
  if not h or not m or h > 23 or m > 59 then
    return nil, "invalid timezone"
  end
  local seconds = (h * 3600) + (m * 60)
  if sign == "-" then
    seconds = -seconds
  end
  return seconds
end

local function cron_value(token, names, allow_sunday_7)
  local raw = trim(token)
  if raw == "" then
    return nil, "empty token"
  end
  local up = raw:upper()
  if names and names[up] ~= nil then
    return tonumber(names[up])
  end
  local n = tonumber(up)
  if allow_sunday_7 and n == 7 then
    return 0
  end
  if n == nil then
    return nil, "invalid number"
  end
  return n
end

local function cron_field(raw, min_v, max_v, names, allow_sunday_7)
  local text = trim(raw)
  if text == "*" or text == "?" then
    local values = {}
    local set = {}
    for v = min_v, max_v do
      values[#values + 1] = v
      set[v] = true
    end
    return { any = true, values = values, set = set }
  end

  local set = {}
  local any = false
  for part in text:gmatch("[^,]+") do
    local chunk = trim(part)
    if chunk ~= "" then
      if chunk == "*" or chunk == "?" then
        any = true
        break
      end

      local base, step = chunk:match("^(.+)%/(%d+)$")
      if base == nil then
        base = chunk
        step = nil
      end
      local step_n = tonumber(step) or 1
      if step_n < 1 then
        return nil, "invalid step"
      end

      local function add_value(v)
        local n = tonumber(v)
        if n == nil or n < min_v or n > max_v then
          return nil, "value out of range"
        end
        set[n] = true
        return true
      end

      base = trim(base)
      if base == "*" or base == "?" then
        for v = min_v, max_v, step_n do
          local ok, err = add_value(v)
          if not ok then
            return nil, err
          end
        end
      else
        local a_raw, b_raw = base:match("^(.+)%-(.+)$")
        if a_raw then
          local a, err_a = cron_value(a_raw, names, allow_sunday_7)
          if a == nil then
            return nil, err_a
          end
          local b, err_b = cron_value(b_raw, names, allow_sunday_7)
          if b == nil then
            return nil, err_b
          end
          if a > b then
            a, b = b, a
          end
          for v = a, b, step_n do
            local ok, err = add_value(v)
            if not ok then
              return nil, err
            end
          end
        else
          local v, err_v = cron_value(base, names, allow_sunday_7)
          if v == nil then
            return nil, err_v
          end
          local ok, err = add_value(v)
          if not ok then
            return nil, err
          end
        end
      end
    end
  end

  if any then
    local values = {}
    local full = {}
    for v = min_v, max_v do
      values[#values + 1] = v
      full[v] = true
    end
    return { any = true, values = values, set = full }
  end

  local values = {}
  for v = min_v, max_v do
    if set[v] then
      values[#values + 1] = v
    end
  end
  if #values == 0 then
    return nil, "empty field"
  end
  return { any = false, values = values, set = set }
end

local function parse_cron(expr)
  local text = trim(expr)
  if text == "" then
    return nil, "empty cron"
  end

  local macros = {
    ["@yearly"] = "0 0 0 1 1 *",
    ["@annually"] = "0 0 0 1 1 *",
    ["@monthly"] = "0 0 0 1 * *",
    ["@weekly"] = "0 0 0 * * 0",
    ["@daily"] = "0 0 0 * * *",
    ["@midnight"] = "0 0 0 * * *",
    ["@hourly"] = "0 0 * * * *",
  }
  local macro = macros[text:lower()]
  if macro then
    text = macro
  end

  local parts = {}
  for part in text:gmatch("%S+") do
    parts[#parts + 1] = part
  end

  local sec_raw, min_raw, hour_raw, dom_raw, mon_raw, dow_raw
  if #parts == 5 then
    sec_raw = "0"
    min_raw = parts[1]
    hour_raw = parts[2]
    dom_raw = parts[3]
    mon_raw = parts[4]
    dow_raw = parts[5]
  elseif #parts == 6 then
    sec_raw = parts[1]
    min_raw = parts[2]
    hour_raw = parts[3]
    dom_raw = parts[4]
    mon_raw = parts[5]
    dow_raw = parts[6]
  else
    return nil, "cron must have 5 or 6 fields"
  end

  local months = {
    JAN = 1, FEB = 2, MAR = 3, APR = 4, MAY = 5, JUN = 6,
    JUL = 7, AUG = 8, SEP = 9, OCT = 10, NOV = 11, DEC = 12,
  }
  local days = {
    SUN = 0, MON = 1, TUE = 2, WED = 3, THU = 4, FRI = 5, SAT = 6,
  }

  local sec, sec_err = cron_field(sec_raw, 0, 59, nil, false)
  if not sec then
    return nil, "seconds: " .. tostring(sec_err)
  end
  local mins, min_err = cron_field(min_raw, 0, 59, nil, false)
  if not mins then
    return nil, "minutes: " .. tostring(min_err)
  end
  local hours, hour_err = cron_field(hour_raw, 0, 23, nil, false)
  if not hours then
    return nil, "hours: " .. tostring(hour_err)
  end
  local dom, dom_err = cron_field(dom_raw, 1, 31, nil, false)
  if not dom then
    return nil, "day_of_month: " .. tostring(dom_err)
  end
  local mon, mon_err = cron_field(mon_raw, 1, 12, months, false)
  if not mon then
    return nil, "month: " .. tostring(mon_err)
  end
  local dow, dow_err = cron_field(dow_raw, 0, 6, days, true)
  if not dow then
    return nil, "day_of_week: " .. tostring(dow_err)
  end

  return {
    seconds = sec,
    minutes = mins,
    hours = hours,
    dom = dom,
    mon = mon,
    dow = dow,
  }
end

local function cron_date_fields(ts, tz_offset_seconds)
  local t = ts
  local utc = false
  if tz_offset_seconds ~= nil then
    utc = true
    t = ts + tz_offset_seconds
  end
  local fields = utc and os.date("!*t", t) or os.date("*t", t)
  if type(fields) ~= "table" then
    return nil, "invalid date"
  end
  fields._dow0 = (tonumber(fields.wday) or 1) - 1
  if fields._dow0 < 0 then
    fields._dow0 = 0
  end
  if fields._dow0 > 6 then
    fields._dow0 = fields._dow0 % 7
  end
  return fields
end

local function cron_day_matches(spec, fields)
  local dom_any = spec.dom.any == true
  local dow_any = spec.dow.any == true
  local dom_match = spec.dom.set[tonumber(fields.day) or -1] == true
  local dow_match = spec.dow.set[tonumber(fields._dow0) or -1] == true
  if dom_any and dow_any then
    return true
  end
  if dom_any then
    return dow_match
  end
  if dow_any then
    return dom_match
  end
  -- Vixie cron semantics: DOM and DOW are OR when both are restricted.
  return dom_match or dow_match
end

local function compute_next_cron_ts(from_ts, cron_expr, timezone, inclusive)
  local spec, err = parse_cron(cron_expr)
  if not spec then
    return nil, err
  end

  local tz_offset, tz_err = parse_timezone_offset(timezone)
  if tz_err then
    return nil, tz_err
  end

  local from = tonumber(from_ts) or 0
  local start = math.floor(from)
  if inclusive then
    if from > start then
      start = start + 1
    end
  else
    start = start + 1
  end

  local minute_start = start - (start % 60)
  local start_sec = start % 60
  local sec_values = spec.seconds.values

  local function pick_second(is_first_minute)
    if type(sec_values) ~= "table" or #sec_values == 0 then
      return nil
    end
    if not is_first_minute then
      return sec_values[1]
    end
    for _, v in ipairs(sec_values) do
      if tonumber(v) and tonumber(v) >= start_sec then
        return v
      end
    end
    return nil
  end

  for i = 0, MAX_CRON_LOOKAHEAD_MINUTES do
    local minute_ts = minute_start + (i * 60)
    local sec = pick_second(i == 0)
    if sec ~= nil then
      local fields, f_err = cron_date_fields(minute_ts, tz_offset)
      if not fields then
        return nil, f_err
      end

      local m = tonumber(fields.min)
      local h = tonumber(fields.hour)
      local mon = tonumber(fields.month)
      if spec.minutes.set[m] and spec.hours.set[h] and spec.mon.set[mon] and cron_day_matches(spec, fields) then
        return minute_ts + tonumber(sec), nil
      end
    end
  end

  return nil, "cron lookahead exceeded"
end

local function effective_keep_warm(root_policy, ver_policy)
  local source = nil
  if type(ver_policy) == "table" and type(ver_policy.keep_warm) == "table" then
    source = ver_policy.keep_warm
  elseif type(root_policy) == "table" and type(root_policy.keep_warm) == "table" then
    source = root_policy.keep_warm
  end
  if type(source) ~= "table" then
    return nil
  end

  local enabled = source.enabled == true
  local min_warm = math.floor(tonumber(source.min_warm) or 1)
  if min_warm < 0 then
    min_warm = 0
  end
  if not enabled or min_warm <= 0 then
    return nil
  end

  local ping_every_seconds = math.floor(tonumber(source.ping_every_seconds) or DEFAULT_KEEP_WARM_PING_SECONDS)
  if ping_every_seconds < 1 then
    ping_every_seconds = DEFAULT_KEEP_WARM_PING_SECONDS
  end
  local idle_ttl_seconds = math.floor(tonumber(source.idle_ttl_seconds) or DEFAULT_KEEP_WARM_IDLE_TTL_SECONDS)
  if idle_ttl_seconds < 1 then
    idle_ttl_seconds = DEFAULT_KEEP_WARM_IDLE_TTL_SECONDS
  end

  return {
    enabled = true,
    min_warm = min_warm,
    ping_every_seconds = ping_every_seconds,
    idle_ttl_seconds = idle_ttl_seconds,
  }
end

local function compute_next_ts(now_ts, every_seconds)
  local every = tonumber(every_seconds)
  if not every or every <= 0 then
    return nil
  end
  every = math.floor(every)
  -- Align to the next boundary to keep schedules stable across reloads.
  local base = math.floor(now_ts / every) * every
  return base + every
end

local function schedule_retry_config(raw)
  if raw == nil or raw == false then
    return { enabled = false }
  end
  if raw == true then
    raw = {}
  end
  if type(raw) ~= "table" then
    return { enabled = false }
  end
  if raw.enabled == false then
    return { enabled = false }
  end

  local max_attempts = tonumber(raw.max_attempts or raw.maxAttempts or raw.attempts) or DEFAULT_RETRY_MAX_ATTEMPTS
  max_attempts = math.floor(max_attempts)
  if max_attempts < 1 then
    max_attempts = 1
  end
  if max_attempts > 10 then
    max_attempts = 10
  end

  local base_delay = tonumber(raw.base_delay_seconds or raw.baseDelaySeconds or raw.delay_seconds or raw.delaySeconds)
    or DEFAULT_RETRY_BASE_DELAY_SECONDS
  if base_delay < 0 then
    base_delay = 0
  end
  if base_delay > 3600 then
    base_delay = 3600
  end

  local max_delay = tonumber(raw.max_delay_seconds or raw.maxDelaySeconds) or DEFAULT_RETRY_MAX_DELAY_SECONDS
  if max_delay < base_delay then
    max_delay = base_delay
  end
  if max_delay > 3600 then
    max_delay = 3600
  end

  local jitter = tonumber(raw.jitter) or DEFAULT_RETRY_JITTER
  if jitter < 0 then
    jitter = 0
  end
  if jitter > 0.5 then
    jitter = 0.5
  end

  return {
    enabled = true,
    max_attempts = max_attempts,
    base_delay_seconds = base_delay,
    max_delay_seconds = max_delay,
    jitter = jitter,
  }
end

local function retry_delay_seconds(cfg, attempt_idx)
  local base = tonumber(cfg.base_delay_seconds) or DEFAULT_RETRY_BASE_DELAY_SECONDS
  local max_delay = tonumber(cfg.max_delay_seconds) or DEFAULT_RETRY_MAX_DELAY_SECONDS
  local delay = base * (2 ^ math.max(0, (tonumber(attempt_idx) or 1) - 1))
  if delay > max_delay then
    delay = max_delay
  end
  local jitter = tonumber(cfg.jitter) or 0
  if jitter > 0 and delay > 0 then
    local wiggle = delay * jitter
    delay = delay + ((math.random() * (2 * wiggle)) - wiggle)
    if delay < 0 then
      delay = 0
    end
  end
  return delay
end

local function status_retryable(status)
  local code = tonumber(status) or 0
  if code == 0 then
    return true
  end
  if code == 429 or code == 503 then
    return true
  end
  if code >= 500 then
    return true
  end
  return false
end

local function schedule_lock_key(key)
  return state_key(key, "running")
end

local function try_acquire_schedule_lock(key, ttl_seconds)
  local ttl = tonumber(ttl_seconds) or 30
  if ttl < 2 then
    ttl = 2
  end
  local ok = CACHE:add(schedule_lock_key(key), now_s(), ttl)
  return ok == true
end

local function release_schedule_lock(key)
  CACHE:delete(schedule_lock_key(key))
end

local function dispatch_schedule_invocation(runtime, name, version, sched, now_ts, opts)
  if type(opts) ~= "table" then
    opts = {}
  end
  local key = fn_key(runtime, name, version)
  local next_key = state_key(key, "next")
  local policy = routes.resolve_function_policy(runtime, name, version) or {}

  local timeout_s = math.ceil((tonumber(policy.timeout_ms) or 2500) / 1000)
  local retry_cfg = schedule_retry_config(sched.retry)
  local attempt_start = tonumber(opts.attempt) or 1
  if attempt_start < 1 then
    attempt_start = 1
  end
  if retry_cfg.enabled then
    if attempt_start > retry_cfg.max_attempts then
      attempt_start = retry_cfg.max_attempts
    end
  else
    attempt_start = 1
  end
  local is_retry = attempt_start > 1
  local retry_window_s = 0
  if retry_cfg.enabled and retry_cfg.max_attempts > 1 then
    for i = 1, (retry_cfg.max_attempts - 1) do
      retry_window_s = retry_window_s + retry_delay_seconds(retry_cfg, i)
    end
    retry_window_s = retry_window_s + (timeout_s * retry_cfg.max_attempts)
  end

  local lock_ttl = timeout_s + 10 + math.floor(retry_window_s)
  local every = tonumber(sched.every_seconds)
  if every and every > 0 then
    every = math.floor(every)
    lock_ttl = math.floor(math.max(2, every * 2, lock_ttl))
  else
    lock_ttl = math.floor(math.max(60, lock_ttl))
  end
  if not try_acquire_schedule_lock(key, lock_ttl) then
    return
  end

  if is_retry then
    CACHE:delete(state_key(key, "retry_due"))
    CACHE:delete(state_key(key, "retry_attempt"))
  end

  -- Reserve next run before dispatch to avoid duplicate queueing (only on the
  -- first attempt). When resuming retries (ex: after restart), keep the already
  -- computed next schedule if present.
  if not is_retry then
    local next_ts = nil
    local next_err = nil
    if every and every > 0 then
      next_ts = compute_next_ts(now_ts, every)
    elseif type(sched.cron) == "string" and sched.cron ~= "" then
      next_ts, next_err = compute_next_cron_ts(now_ts, sched.cron, sched.timezone, false)
    end
    if next_ts then
      CACHE:set(next_key, next_ts)
    else
      CACHE:set(next_key, now_ts + 60)
      CACHE:set(state_key(key, "last"), now_s())
      CACHE:set(state_key(key, "last_status"), 500)
      CACHE:set(state_key(key, "last_error"), "invalid schedule: " .. tostring(next_err or "missing trigger"))
      release_schedule_lock(key)
      return
    end
  else
    local existing_next = CACHE:get(next_key)
    if not existing_next then
      local next_ts = nil
      local next_err = nil
      if every and every > 0 then
        next_ts = compute_next_ts(now_ts, every)
      elseif type(sched.cron) == "string" and sched.cron ~= "" then
        next_ts, next_err = compute_next_cron_ts(now_ts, sched.cron, sched.timezone, false)
      end
      if next_ts then
        CACHE:set(next_key, next_ts)
      else
        CACHE:set(next_key, now_ts + 60)
        CACHE:set(state_key(key, "last"), now_s())
        CACHE:set(state_key(key, "last_status"), 500)
        CACHE:set(state_key(key, "last_error"), "invalid schedule: " .. tostring(next_err or "missing trigger"))
        release_schedule_lock(key)
        return
      end
    end
  end

  local function run_attempt(premature, attempt)
    if premature then
      release_schedule_lock(key)
      return
    end

    local attempt_num = tonumber(attempt) or 1
    if attempt_num < 1 then
      attempt_num = 1
    end

    CACHE:delete(state_key(key, "retry_due"))
    CACHE:delete(state_key(key, "retry_attempt"))

    local ok_run, status, err = pcall(function()
      return run_scheduled_invocation(runtime, name, version, sched, policy, "schedule", {
        attempt = attempt_num,
        max_attempts = retry_cfg.enabled and retry_cfg.max_attempts or nil,
      })
    end)

    CACHE:set(state_key(key, "last"), now_s())
    if not ok_run then
      CACHE:set(state_key(key, "last_status"), 500)
      CACHE:set(state_key(key, "last_error"), "scheduler invocation error")
      ngx.log(ngx.ERR, "scheduler invocation failed for ", key, ": ", tostring(status))
      release_schedule_lock(key)
      return
    end

    CACHE:set(state_key(key, "last_status"), status)
    CACHE:set(state_key(key, "last_error"), err or "")

    if retry_cfg.enabled and attempt_num < retry_cfg.max_attempts and status_retryable(status) then
      local delay = retry_delay_seconds(retry_cfg, attempt_num)
      local retry_due = now_s() + delay
      CACHE:set(state_key(key, "retry_due"), retry_due)
      CACHE:set(state_key(key, "retry_attempt"), attempt_num + 1)
      CACHE:set(
        state_key(key, "last_error"),
        string.format("retrying %d/%d in %.2fs: %s", attempt_num + 1, retry_cfg.max_attempts, delay, tostring(err or status))
      )
      local ok_timer, timer_err = ngx.timer.at(delay, run_attempt, attempt_num + 1)
      if not ok_timer then
        CACHE:set(state_key(key, "last_status"), 500)
        CACHE:set(state_key(key, "last_error"), "failed to schedule retry: " .. tostring(timer_err))
        ngx.log(ngx.ERR, "failed to start schedule retry timer for ", key, ": ", tostring(timer_err))
        -- Leave retry_due/retry_attempt in cache so the next scheduler tick can resume.
        release_schedule_lock(key)
      end
      return
    end

    CACHE:delete(state_key(key, "retry_due"))
    CACHE:delete(state_key(key, "retry_attempt"))
    release_schedule_lock(key)
  end

  local ok_timer, timer_err = ngx.timer.at(0, run_attempt, attempt_start)
  if not ok_timer then
    release_schedule_lock(key)
    CACHE:set(state_key(key, "last"), now_ts)
    CACHE:set(state_key(key, "last_status"), 500)
    CACHE:set(state_key(key, "last_error"), "failed to schedule invocation")
    ngx.log(ngx.ERR, "failed to start schedule invocation timer for ", key, ": ", tostring(timer_err))
  end
end

local function dispatch_keep_warm_invocation(runtime, name, version, keep_warm, now_ts)
  local key = fn_key(runtime, name, version)
  local policy = routes.resolve_function_policy(runtime, name, version) or {}
  local ping_every = math.floor(tonumber(keep_warm.ping_every_seconds) or DEFAULT_KEEP_WARM_PING_SECONDS)
  if ping_every < 1 then
    ping_every = DEFAULT_KEEP_WARM_PING_SECONDS
  end
  local idle_ttl = math.floor(tonumber(keep_warm.idle_ttl_seconds) or DEFAULT_KEEP_WARM_IDLE_TTL_SECONDS)
  if idle_ttl < 1 then
    idle_ttl = DEFAULT_KEEP_WARM_IDLE_TTL_SECONDS
  end

  local warm_at = CACHE:get(warm_key(key))
  local next_key = state_key(key, "keep_warm_next")
  local last_ping = CACHE:get(next_key)
  if not last_ping then
    last_ping = now_ts + ping_every
    CACHE:set(next_key, last_ping)
  end

  local due = false
  if warm_at == nil then
    due = true
  else
    local age = now_ts - tonumber(warm_at)
    if age >= idle_ttl then
      due = true
    elseif now_ts >= tonumber(last_ping) then
      due = true
    end
  end

  if not due then
    return
  end

  local timeout_s = math.ceil((tonumber(policy.timeout_ms) or 2500) / 1000)
  local lock_ttl = math.floor(math.max(2, ping_every + 2, timeout_s + 5))
  local lock_key = key .. ":keep_warm"
  if not try_acquire_schedule_lock(lock_key, lock_ttl) then
    return
  end

  CACHE:set(next_key, now_ts + ping_every)
  local ping = {
    method = pick_policy_method(policy.methods),
    query = { __fastfn_keep_warm = "1" },
    headers = { ["x-fastfn-trigger"] = "keep_warm" },
  }

  local ok_timer, timer_err = ngx.timer.at(0, function(premature)
    if premature then
      release_schedule_lock(lock_key)
      return
    end

    local ok_run, status, err = pcall(function()
      return run_scheduled_invocation(runtime, name, version, ping, policy, "keep_warm")
    end)

    CACHE:set(state_key(key, "keep_warm_last"), now_s())
    if ok_run then
      CACHE:set(state_key(key, "keep_warm_last_status"), status)
      CACHE:set(state_key(key, "keep_warm_last_error"), err or "")
    else
      CACHE:set(state_key(key, "keep_warm_last_status"), 500)
      CACHE:set(state_key(key, "keep_warm_last_error"), "keep_warm invocation error")
      ngx.log(ngx.ERR, "keep_warm invocation failed for ", key, ": ", tostring(status))
    end

    release_schedule_lock(lock_key)
  end)

  if not ok_timer then
    release_schedule_lock(lock_key)
    CACHE:set(state_key(key, "keep_warm_last"), now_ts)
    CACHE:set(state_key(key, "keep_warm_last_status"), 500)
    CACHE:set(state_key(key, "keep_warm_last_error"), "failed to schedule keep_warm invocation")
    ngx.log(ngx.ERR, "failed to start keep_warm timer for ", key, ": ", tostring(timer_err))
  end
end

local function tick_once()
  -- Guard against overlapping ticks when a scheduled function runs longer
  -- than the timer interval. This avoids duplicate schedule dispatches.
  local tick_lock_ok = CACHE:add(TICK_LOCK_KEY, now_s(), 30)
  if not tick_lock_ok then
    return
  end

  local ok_tick, tick_err = pcall(function()
  local cfg = routes.get_config()
  local catalog = routes.discover_functions(false)
  local now_ts = now_s()

  for runtime, rt_entry in pairs(catalog.runtimes or {}) do
    if (cfg.runtimes or {})[runtime] then
      for name, fn_entry in pairs(rt_entry.functions or {}) do
        local root_policy = fn_entry.policy or {}

        -- default version
        if fn_entry.has_default then
          local sched = effective_schedule(root_policy, nil)
          if type(sched) == "table" and sched.enabled == true and ((tonumber(sched.every_seconds) and tonumber(sched.every_seconds) > 0) or (type(sched.cron) == "string" and sched.cron ~= "")) then
            local key = fn_key(runtime, name, nil)
            local next_key = state_key(key, "next")
            local retry_cfg = schedule_retry_config(sched.retry)
            local retry_due_key = state_key(key, "retry_due")
            local retry_attempt_key = state_key(key, "retry_attempt")
            local retry_due = CACHE:get(retry_due_key)
            local retry_attempt = CACHE:get(retry_attempt_key)

            if not retry_cfg.enabled then
              if retry_due ~= nil then
                CACHE:delete(retry_due_key)
              end
              if retry_attempt ~= nil then
                CACHE:delete(retry_attempt_key)
              end
              retry_due = nil
              retry_attempt = nil
            end

            if retry_due ~= nil then
              local due = tonumber(retry_due)
              if not due then
                CACHE:delete(retry_due_key)
                CACHE:delete(retry_attempt_key)
              elseif now_ts >= due then
                local attempt = tonumber(retry_attempt) or 2
                if attempt < 2 then
                  attempt = 2
                end
                dispatch_schedule_invocation(runtime, name, nil, sched, now_ts, { attempt = attempt })
              end
            else
              local next_ts = CACHE:get(next_key)
              if not next_ts then
                if tonumber(sched.every_seconds) and tonumber(sched.every_seconds) > 0 then
                  next_ts = compute_next_ts(now_ts, sched.every_seconds)
                else
                  local err = nil
                  next_ts, err = compute_next_cron_ts(now_ts, sched.cron, sched.timezone, false)
                  if not next_ts then
                    CACHE:set(state_key(key, "last"), now_ts)
                    CACHE:set(state_key(key, "last_status"), 500)
                    CACHE:set(state_key(key, "last_error"), "invalid cron: " .. tostring(err))
                    next_ts = now_ts + 60
                  end
                end
                if next_ts then
                  CACHE:set(next_key, next_ts)
                end
              end
              if next_ts and now_ts >= next_ts then
                dispatch_schedule_invocation(runtime, name, nil, sched, now_ts)
              end
            end
          end
          local keep_warm = effective_keep_warm(root_policy, nil)
          if keep_warm then
            dispatch_keep_warm_invocation(runtime, name, nil, keep_warm, now_ts)
          end
        end

        -- versions
        for _, ver in ipairs(fn_entry.versions or {}) do
          local ver_policy = (fn_entry.versions_policy or {})[ver] or {}
          local sched = effective_schedule(root_policy, ver_policy)
          if type(sched) == "table" and sched.enabled == true and ((tonumber(sched.every_seconds) and tonumber(sched.every_seconds) > 0) or (type(sched.cron) == "string" and sched.cron ~= "")) then
            local key = fn_key(runtime, name, ver)
            local next_key = state_key(key, "next")
            local retry_cfg = schedule_retry_config(sched.retry)
            local retry_due_key = state_key(key, "retry_due")
            local retry_attempt_key = state_key(key, "retry_attempt")
            local retry_due = CACHE:get(retry_due_key)
            local retry_attempt = CACHE:get(retry_attempt_key)

            if not retry_cfg.enabled then
              if retry_due ~= nil then
                CACHE:delete(retry_due_key)
              end
              if retry_attempt ~= nil then
                CACHE:delete(retry_attempt_key)
              end
              retry_due = nil
              retry_attempt = nil
            end

            if retry_due ~= nil then
              local due = tonumber(retry_due)
              if not due then
                CACHE:delete(retry_due_key)
                CACHE:delete(retry_attempt_key)
              elseif now_ts >= due then
                local attempt = tonumber(retry_attempt) or 2
                if attempt < 2 then
                  attempt = 2
                end
                dispatch_schedule_invocation(runtime, name, ver, sched, now_ts, { attempt = attempt })
              end
            else
              local next_ts = CACHE:get(next_key)
              if not next_ts then
                if tonumber(sched.every_seconds) and tonumber(sched.every_seconds) > 0 then
                  next_ts = compute_next_ts(now_ts, sched.every_seconds)
                else
                  local err = nil
                  next_ts, err = compute_next_cron_ts(now_ts, sched.cron, sched.timezone, false)
                  if not next_ts then
                    CACHE:set(state_key(key, "last"), now_ts)
                    CACHE:set(state_key(key, "last_status"), 500)
                    CACHE:set(state_key(key, "last_error"), "invalid cron: " .. tostring(err))
                    next_ts = now_ts + 60
                  end
                end
                if next_ts then
                  CACHE:set(next_key, next_ts)
                end
              end
              if next_ts and now_ts >= next_ts then
                dispatch_schedule_invocation(runtime, name, ver, sched, now_ts)
              end
            end
          end
          local keep_warm = effective_keep_warm(root_policy, ver_policy)
          if keep_warm then
            dispatch_keep_warm_invocation(runtime, name, ver, keep_warm, now_ts)
          end
        end
      end
    end
  end
  end)

  CACHE:delete(TICK_LOCK_KEY)
  if not ok_tick then
    error(tick_err)
  end
end

function M.snapshot()
  local out = {
    ts = now_s(),
    schedules = {},
    keep_warm = {},
  }

  local cfg = routes.get_config()
  local catalog = routes.discover_functions(false)

  for runtime, rt_entry in pairs(catalog.runtimes or {}) do
    if (cfg.runtimes or {})[runtime] then
      for name, fn_entry in pairs(rt_entry.functions or {}) do
        local root_policy = fn_entry.policy or {}

        local function add(version, sched)
          local key = fn_key(runtime, name, version)
          out.schedules[#out.schedules + 1] = {
            runtime = runtime,
            name = name,
            version = version or nil,
            key = key,
            schedule = sched,
            state = {
              next = CACHE:get(state_key(key, "next")),
              retry_due = CACHE:get(state_key(key, "retry_due")),
              retry_attempt = CACHE:get(state_key(key, "retry_attempt")),
              last = CACHE:get(state_key(key, "last")),
              last_status = CACHE:get(state_key(key, "last_status")),
              last_error = CACHE:get(state_key(key, "last_error")),
            },
          }
        end

        local function add_keep_warm(version, kw)
          local key = fn_key(runtime, name, version)
          local warm_at = CACHE:get(warm_key(key))
          local idle_ttl = tonumber((kw or {}).idle_ttl_seconds) or DEFAULT_KEEP_WARM_IDLE_TTL_SECONDS
          local state = "cold"
          if warm_at then
            local age = now_s() - tonumber(warm_at)
            if age > idle_ttl then
              state = "stale"
            else
              state = "warm"
            end
          end
          out.keep_warm[#out.keep_warm + 1] = {
            runtime = runtime,
            name = name,
            version = version or nil,
            key = key,
            keep_warm = kw,
            state = {
              warm_state = state,
              warm_at = warm_at,
              next = CACHE:get(state_key(key, "keep_warm_next")),
              last = CACHE:get(state_key(key, "keep_warm_last")),
              last_status = CACHE:get(state_key(key, "keep_warm_last_status")),
              last_error = CACHE:get(state_key(key, "keep_warm_last_error")),
            },
          }
        end

        if fn_entry.has_default then
          local sched = effective_schedule(root_policy, nil)
          if type(sched) == "table" and sched.enabled == true then
            add(nil, sched)
          end
          local keep_warm = effective_keep_warm(root_policy, nil)
          if keep_warm then
            add_keep_warm(nil, keep_warm)
          end
        end

        for _, ver in ipairs(fn_entry.versions or {}) do
          local ver_policy = (fn_entry.versions_policy or {})[ver] or {}
          local sched = effective_schedule(root_policy, ver_policy)
          if type(sched) == "table" and sched.enabled == true then
            add(ver, sched)
          end
          local keep_warm = effective_keep_warm(root_policy, ver_policy)
          if keep_warm then
            add_keep_warm(ver, keep_warm)
          end
        end
      end
    end
  end

  return out
end

local function truncate_error(value)
  if type(value) ~= "string" then
    return ""
  end
  if #value <= MAX_PERSISTED_ERROR_LEN then
    return value
  end
  return value:sub(1, MAX_PERSISTED_ERROR_LEN) .. "...<truncated>"
end

local function restore_persisted_state()
  if not scheduler_persist_enabled() then
    return false, "scheduler persistence disabled"
  end

  local cfg = routes.get_config() or {}
  local state_path = scheduler_state_path(cfg.functions_root)
  if not state_path then
    return false, "scheduler state path unavailable"
  end

  local raw = read_file(state_path)
  if not raw or raw == "" then
    return false, "scheduler state file missing"
  end

  local obj = cjson.decode(raw)
  if type(obj) ~= "table" then
    return false, "invalid scheduler state json"
  end

  local function restore_entry(key, st)
    if type(key) ~= "string" or key == "" or type(st) ~= "table" then
      return
    end

    local function set_num(suffix, v)
      local n = tonumber(v)
      if n ~= nil then
        CACHE:set(state_key(key, suffix), n)
      end
    end

    local function set_str(suffix, v)
      if v == nil then
        return
      end
      CACHE:set(state_key(key, suffix), truncate_error(tostring(v)))
    end

    set_num("next", st.next)
    set_num("retry_due", st.retry_due)
    set_num("retry_attempt", st.retry_attempt)
    set_num("last", st.last)
    set_num("last_status", st.last_status)
    set_str("last_error", st.last_error)

    local warm_at = tonumber(st.warm_at)
    if warm_at ~= nil then
      CACHE:set(warm_key(key), warm_at)
    end
  end

  local schedules = obj.schedules
  if type(schedules) == "table" then
    for key, st in pairs(schedules) do
      restore_entry(key, st)
    end
  end

  local keep_warm = obj.keep_warm
  if type(keep_warm) == "table" then
    for key, st in pairs(keep_warm) do
      if type(key) == "string" and type(st) == "table" then
        local function set_num(suffix, v)
          local n = tonumber(v)
          if n ~= nil then
            CACHE:set(state_key(key, suffix), n)
          end
        end

        local function set_str(suffix, v)
          if v == nil then
            return
          end
          CACHE:set(state_key(key, suffix), truncate_error(tostring(v)))
        end

        set_num("keep_warm_next", st.next)
        set_num("keep_warm_last", st.last)
        set_num("keep_warm_last_status", st.last_status)
        set_str("keep_warm_last_error", st.last_error)

        local warm_at = tonumber(st.warm_at)
        if warm_at ~= nil then
          CACHE:set(warm_key(key), warm_at)
        end
      end
    end
  end

  return true, nil
end

function M.persist_now()
  if not scheduler_persist_enabled() then
    return true, "scheduler persistence disabled"
  end

  local cfg = routes.get_config() or {}
  local state_path = scheduler_state_path(cfg.functions_root)
  if not state_path then
    return false, "scheduler state path unavailable"
  end

  local snap = M.snapshot()
  local out = {
    version = 1,
    saved_at = now_s(),
    schedules = {},
    keep_warm = {},
  }

  for _, row in ipairs(snap.schedules or {}) do
    local key = row.key
    if type(key) == "string" and key ~= "" then
      local st = row.state or {}
      out.schedules[key] = {
        next = st.next,
        retry_due = st.retry_due,
        retry_attempt = st.retry_attempt,
        last = st.last,
        last_status = st.last_status,
        last_error = truncate_error(st.last_error or ""),
        warm_at = CACHE:get(warm_key(key)),
      }
    end
  end

  for _, row in ipairs(snap.keep_warm or {}) do
    local key = row.key
    if type(key) == "string" and key ~= "" then
      local st = row.state or {}
      out.keep_warm[key] = {
        warm_at = st.warm_at,
        next = st.next,
        last = st.last,
        last_status = st.last_status,
        last_error = truncate_error(st.last_error or ""),
      }
    end
  end

  local raw, enc_err = cjson.encode(out)
  if not raw then
    return false, tostring(enc_err or "failed to encode scheduler state")
  end

  return write_file_atomic(state_path, raw)
end

function M.init()
  if ngx.worker.id() ~= 0 then
    return
  end

  local enabled_raw = os.getenv("FN_SCHEDULER_ENABLED")
  if enabled_raw ~= nil and enabled_raw ~= "" then
    local v = string.lower(tostring(enabled_raw))
    if v == "0" or v == "false" or v == "off" or v == "no" then
      ngx.log(ngx.NOTICE, "scheduler disabled via FN_SCHEDULER_ENABLED")
      return
    end
  end

  local persisted = false
  if scheduler_persist_enabled() then
    local ok_restore, restore_ok, restore_err = pcall(restore_persisted_state)
    if ok_restore and restore_ok then
      persisted = true
      ngx.log(ngx.NOTICE, "scheduler state restored from disk")
    elseif ok_restore and restore_err and tostring(restore_err):find("missing", 1, true) then
      -- no-op
    elseif not ok_restore then
      ngx.log(ngx.ERR, "scheduler state restore failed: ", tostring(restore_ok))
    elseif restore_err then
      ngx.log(ngx.WARN, "scheduler state restore skipped: ", tostring(restore_err))
    end
  end

  local interval = tonumber(os.getenv("FN_SCHEDULER_INTERVAL")) or DEFAULT_TICK_SECONDS
  if interval < 1 then
    interval = DEFAULT_TICK_SECONDS
  end

  local ok, err = ngx.timer.every(interval, function(premature)
    if premature then
      return
    end
    local ok2, err2 = pcall(tick_once)
    if not ok2 then
      ngx.log(ngx.ERR, "scheduler tick failed: ", tostring(err2))
    end
  end)
  if not ok then
    ngx.log(ngx.ERR, "failed to start scheduler timer: ", tostring(err))
  end

  if scheduler_persist_enabled() then
    local cfg = routes.get_config() or {}
    local state_path = scheduler_state_path(cfg.functions_root)
    if state_path then
      local persist_interval = scheduler_persist_interval_seconds()
      local ok_persist, err_persist = ngx.timer.every(persist_interval, function(premature)
        if premature then
          return
        end
        local ok_write, write_ok, write_err = pcall(M.persist_now)
        if not ok_write then
          ngx.log(ngx.ERR, "scheduler state persist failed: ", tostring(write_ok))
        elseif not write_ok and write_err then
          ngx.log(ngx.WARN, "scheduler state persist skipped: ", tostring(write_err))
        end
      end)
      if not ok_persist then
        ngx.log(ngx.ERR, "failed to start scheduler persist timer: ", tostring(err_persist))
      elseif persisted then
        -- Write back soon after start so restarts keep warm state even if the
        -- scheduler does not run for a while.
        local ok_at, err_at = ngx.timer.at(1, function(premature)
          if premature then
            return
          end
          local ok_write, write_ok, write_err = pcall(M.persist_now)
          if not ok_write then
            ngx.log(ngx.ERR, "scheduler state persist failed: ", tostring(write_ok))
          elseif not write_ok and write_err then
            ngx.log(ngx.WARN, "scheduler state persist skipped: ", tostring(write_err))
          end
        end)
        if not ok_at then
          ngx.log(ngx.WARN, "failed to queue initial scheduler persist: ", tostring(err_at))
        end
      end
    end
  end
end

return M
