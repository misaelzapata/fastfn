local routes = require "fastfn.core.routes"
local client = require "fastfn.core.client"
local lua_runtime = require "fastfn.core.lua_runtime"
local limits = require "fastfn.core.limits"
local utils = require "fastfn.core.gateway_utils"

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

local function run_scheduled_invocation(runtime, name, version, schedule, policy, trigger_type)
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
        trigger = {
          type = trigger,
          every_seconds = tonumber(schedule.every_seconds) or nil,
        },
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

local function dispatch_schedule_invocation(runtime, name, version, sched, now_ts)
  local key = fn_key(runtime, name, version)
  local next_key = state_key(key, "next")
  local policy = routes.resolve_function_policy(runtime, name, version) or {}
  local every = math.floor(tonumber(sched.every_seconds) or 1)
  if every < 1 then
    every = 1
  end

  local timeout_s = math.ceil((tonumber(policy.timeout_ms) or 2500) / 1000)
  local lock_ttl = math.floor(math.max(2, every * 2, timeout_s + 5))
  if not try_acquire_schedule_lock(key, lock_ttl) then
    return
  end

  -- Reserve next run before dispatch to avoid duplicate queueing.
  CACHE:set(next_key, now_ts + every)

  local ok_timer, timer_err = ngx.timer.at(0, function(premature)
    if premature then
      release_schedule_lock(key)
      return
    end

    local ok_run, status, err = pcall(function()
      return run_scheduled_invocation(runtime, name, version, sched, policy)
    end)

    CACHE:set(state_key(key, "last"), now_s())
    if ok_run then
      CACHE:set(state_key(key, "last_status"), status)
      CACHE:set(state_key(key, "last_error"), err or "")
    else
      CACHE:set(state_key(key, "last_status"), 500)
      CACHE:set(state_key(key, "last_error"), "scheduler invocation error")
      ngx.log(ngx.ERR, "scheduler invocation failed for ", key, ": ", tostring(status))
    end

    release_schedule_lock(key)
  end)

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
          if type(sched) == "table" and sched.enabled == true and tonumber(sched.every_seconds) and tonumber(sched.every_seconds) > 0 then
            local key = fn_key(runtime, name, nil)
            local next_key = state_key(key, "next")
            local next_ts = CACHE:get(next_key)
            if not next_ts then
              next_ts = compute_next_ts(now_ts, sched.every_seconds)
              if next_ts then
                CACHE:set(next_key, next_ts)
              end
            end
            if next_ts and now_ts >= next_ts then
              dispatch_schedule_invocation(runtime, name, nil, sched, now_ts)
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
          if type(sched) == "table" and sched.enabled == true and tonumber(sched.every_seconds) and tonumber(sched.every_seconds) > 0 then
            local key = fn_key(runtime, name, ver)
            local next_key = state_key(key, "next")
            local next_ts = CACHE:get(next_key)
            if not next_ts then
              next_ts = compute_next_ts(now_ts, sched.every_seconds)
              if next_ts then
                CACHE:set(next_key, next_ts)
              end
            end
            if next_ts and now_ts >= next_ts then
              dispatch_schedule_invocation(runtime, name, ver, sched, now_ts)
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
end

return M
