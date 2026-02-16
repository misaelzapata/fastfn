local M = {}

local function key_for(fn_key)
  return "conc:" .. fn_key
end

local function pool_active_key(fn_key)
  return "pool:active:" .. fn_key
end

local function pool_queue_key(fn_key)
  return "pool:queue:" .. fn_key
end

local function dec_to_zero(dict, key)
  local current = dict:incr(key, -1, 0)
  if current and current <= 0 then
    dict:delete(key)
  end
end

function M.try_acquire(dict, fn_key, limit)
  if not limit or limit <= 0 then
    return true
  end

  local key = key_for(fn_key)
  local current, err = dict:incr(key, 1, 0)
  if not current then
    return false, "counter_error:" .. tostring(err)
  end

  if current > limit then
    dict:incr(key, -1, 0)
    return false, "busy"
  end

  return true
end

function M.release(dict, fn_key)
  local key = key_for(fn_key)
  dec_to_zero(dict, key)
end

function M.try_acquire_pool(dict, fn_key, max_workers, max_queue)
  local workers = tonumber(max_workers) or 0
  if workers <= 0 then
    return true, "unlimited"
  end

  local active_key = pool_active_key(fn_key)
  local active, active_err = dict:incr(active_key, 1, 0)
  if not active then
    return false, "counter_error:" .. tostring(active_err)
  end

  if active <= workers then
    return true, "acquired"
  end

  dec_to_zero(dict, active_key)

  local queue_limit = tonumber(max_queue) or 0
  if queue_limit <= 0 then
    return false, "overflow"
  end

  local queue_key = pool_queue_key(fn_key)
  local queued, queued_err = dict:incr(queue_key, 1, 0)
  if not queued then
    return false, "counter_error:" .. tostring(queued_err)
  end

  if queued > queue_limit then
    dec_to_zero(dict, queue_key)
    return false, "overflow"
  end

  return false, "queued"
end

function M.cancel_pool_queue(dict, fn_key)
  dec_to_zero(dict, pool_queue_key(fn_key))
end

function M.wait_for_pool_slot(dict, fn_key, max_workers, queue_timeout_ms, queue_poll_ms)
  local workers = tonumber(max_workers) or 0
  if workers <= 0 then
    M.cancel_pool_queue(dict, fn_key)
    return true, "unlimited"
  end

  local timeout_ms = tonumber(queue_timeout_ms) or 0
  if timeout_ms <= 0 then
    M.cancel_pool_queue(dict, fn_key)
    return false, "queue_timeout"
  end

  local poll_ms = tonumber(queue_poll_ms) or 20
  if poll_ms < 1 then
    poll_ms = 1
  end
  if poll_ms > 200 then
    poll_ms = 200
  end

  local active_key = pool_active_key(fn_key)
  local deadline = ngx.now() + (timeout_ms / 1000)
  while ngx.now() < deadline do
    ngx.sleep(poll_ms / 1000)

    local active, active_err = dict:incr(active_key, 1, 0)
    if not active then
      M.cancel_pool_queue(dict, fn_key)
      return false, "counter_error:" .. tostring(active_err)
    end
    if active <= workers then
      M.cancel_pool_queue(dict, fn_key)
      return true, "acquired_from_queue"
    end
    dec_to_zero(dict, active_key)
  end

  M.cancel_pool_queue(dict, fn_key)
  return false, "queue_timeout"
end

function M.release_pool(dict, fn_key)
  dec_to_zero(dict, pool_active_key(fn_key))
end

return M
