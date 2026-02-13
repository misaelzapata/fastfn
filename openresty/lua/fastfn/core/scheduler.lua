local routes = require "fastfn.core.routes"
local client = require "fastfn.core.client"
local limits = require "fastfn.core.limits"
local utils = require "fastfn.core.gateway_utils"

local M = {}

local CACHE = ngx.shared.fn_cache
local CONC = ngx.shared.fn_conc

local DEFAULT_TICK_SECONDS = 1
local DEFAULT_SCHEDULE_MAX_BODY_BYTES = 1024 * 1024
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

local function table_is_object(v)
  return type(v) == "table" and next(v) ~= nil
end

local function should_block_runtime(runtime, runtime_cfg)
  local up = routes.runtime_is_up(runtime)
  if up ~= true then
    local ok, err = routes.check_runtime_socket(runtime_cfg.socket, runtime_cfg.timeout_ms or 250)
    routes.set_runtime_health(runtime, ok, ok and "ok" or err)
    return not ok
  end
  return false
end

local function run_scheduled_invocation(runtime, name, version, schedule, policy)
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
        trigger = {
          type = "schedule",
          every_seconds = tonumber(schedule.every_seconds) or 0,
        },
        user = type(schedule.context) == "table" and schedule.context or nil,
      },
    }

    return client.call_unix(rt_cfg.socket, {
      fn = name,
      version = version,
      event = event,
    }, tonumber(policy.timeout_ms) or 2500)
  end, debug.traceback)

  limits.release(CONC, key)

  if not ok_call then
    ngx.log(ngx.ERR, "scheduler exception id=", request_id, " fn=", key, " err=", tostring(resp_or_err_code))
    return 500, "scheduler exception"
  end

  local resp = resp_or_err_code
  if not resp then
    local status, message = utils.map_runtime_error(err_code)
    ngx.log(
      ngx.ERR,
      "fn schedule runtime error id=", request_id,
      " fn=", key,
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
  ngx.log(ngx.INFO, "fn schedule id=", request_id, " fn=", key, " status=", resp.status, " latency_ms=", latency_ms)
  local status_num = tonumber(resp.status) or 200
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
      "fn schedule non-2xx id=", request_id,
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
              local lock_ttl = math.floor(math.max(2, (tonumber(sched.every_seconds) or 1) * 2))
              if try_acquire_schedule_lock(key, lock_ttl) then
                local every = math.floor(tonumber(sched.every_seconds) or 1)
                -- Reserve the next tick before invoking the function. This prevents
                -- back-to-back duplicate dispatches when the invocation is long or
                -- when another scheduler tick arrives while this one is still running.
                CACHE:set(next_key, now_ts + every)
                local ok_run, status, err = pcall(function()
                  local policy = routes.resolve_function_policy(runtime, name, nil) or {}
                  return run_scheduled_invocation(runtime, name, nil, sched, policy)
                end)
                CACHE:set(state_key(key, "last"), now_ts)
                if ok_run then
                  CACHE:set(state_key(key, "last_status"), status)
                  CACHE:set(state_key(key, "last_error"), err or "")
                else
                  CACHE:set(state_key(key, "last_status"), 500)
                  CACHE:set(state_key(key, "last_error"), "scheduler invocation error")
                  ngx.log(ngx.ERR, "scheduler invocation failed for ", key, ": ", tostring(status))
                end
                release_schedule_lock(key)
              end
            end
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
              local lock_ttl = math.floor(math.max(2, (tonumber(sched.every_seconds) or 1) * 2))
              if try_acquire_schedule_lock(key, lock_ttl) then
                local every = math.floor(tonumber(sched.every_seconds) or 1)
                -- Reserve the next tick before invoking the function. This prevents
                -- back-to-back duplicate dispatches when the invocation is long or
                -- when another scheduler tick arrives while this one is still running.
                CACHE:set(next_key, now_ts + every)
                local ok_run, status, err = pcall(function()
                  local policy = routes.resolve_function_policy(runtime, name, ver) or {}
                  return run_scheduled_invocation(runtime, name, ver, sched, policy)
                end)
                CACHE:set(state_key(key, "last"), now_ts)
                if ok_run then
                  CACHE:set(state_key(key, "last_status"), status)
                  CACHE:set(state_key(key, "last_error"), err or "")
                else
                  CACHE:set(state_key(key, "last_status"), 500)
                  CACHE:set(state_key(key, "last_error"), "scheduler invocation error")
                  ngx.log(ngx.ERR, "scheduler invocation failed for ", key, ": ", tostring(status))
                end
                release_schedule_lock(key)
              end
            end
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

        if fn_entry.has_default then
          local sched = effective_schedule(root_policy, nil)
          if type(sched) == "table" and sched.enabled == true then
            add(nil, sched)
          end
        end

        for _, ver in ipairs(fn_entry.versions or {}) do
          local ver_policy = (fn_entry.versions_policy or {})[ver] or {}
          local sched = effective_schedule(root_policy, ver_policy)
          if type(sched) == "table" and sched.enabled == true then
            add(ver, sched)
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
