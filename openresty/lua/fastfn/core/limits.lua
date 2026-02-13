local M = {}

local function key_for(fn_key)
  return "conc:" .. fn_key
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
  local current = dict:incr(key, -1, 0)
  if current and current <= 0 then
    dict:delete(key)
  end
end

return M
