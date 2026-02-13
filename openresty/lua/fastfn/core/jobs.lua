local cjson = require "cjson.safe"

local client = require "fastfn.core.client"
local limits = require "fastfn.core.limits"
local routes = require "fastfn.core.routes"
local utils = require "fastfn.core.gateway_utils"

local M = {}

local CACHE = ngx.shared.fn_cache
local CONC = ngx.shared.fn_conc

local DEFAULT_POLL_INTERVAL = 1
local DEFAULT_MAX_CONCURRENCY = 2
local DEFAULT_MAX_RESULT_BYTES = 256 * 1024
local DEFAULT_MAX_ATTEMPTS = 1
local DEFAULT_RETRY_DELAY_MS = 1000

local function env_bool(name, default_value)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default_value
  end
  raw = string.lower(tostring(raw))
  if raw == "0" or raw == "false" or raw == "off" or raw == "no" then
    return false
  end
  if raw == "1" or raw == "true" or raw == "on" or raw == "yes" then
    return true
  end
  return default_value
end

local function env_num(name, default_value)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default_value
  end
  local n = tonumber(raw)
  if not n then
    return default_value
  end
  return n
end

local function now_ms()
  return math.floor(ngx.now() * 1000)
end

local function jobs_enabled()
  return env_bool("FN_JOBS_ENABLED", true)
end

local function jobs_poll_interval()
  local n = env_num("FN_JOBS_POLL_INTERVAL", DEFAULT_POLL_INTERVAL)
  if not n or n <= 0 then
    return DEFAULT_POLL_INTERVAL
  end
  return n
end

local function jobs_max_concurrency()
  local n = env_num("FN_JOBS_MAX_CONCURRENCY", DEFAULT_MAX_CONCURRENCY)
  if not n or n <= 0 then
    return DEFAULT_MAX_CONCURRENCY
  end
  return math.floor(n)
end

local function jobs_max_result_bytes()
  local n = env_num("FN_JOBS_MAX_RESULT_BYTES", DEFAULT_MAX_RESULT_BYTES)
  if not n or n <= 0 then
    return DEFAULT_MAX_RESULT_BYTES
  end
  return math.floor(n)
end

local function jobs_dir()
  local cfg = routes.get_config()
  return tostring(cfg.functions_root) .. "/.fastfn/jobs"
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function ensure_dir(path)
  os.execute(string.format("mkdir -p %s", shell_quote(path)))
end

local function write_file_atomic(path, data)
  local tmp = path .. ".tmp." .. tostring(ngx.worker.pid()) .. "." .. tostring(math.random(0, 999999))
  local f, err = io.open(tmp, "wb")
  if not f then
    return nil, err
  end
  f:write(data)
  f:close()
  local ok = os.execute(string.format("mv %s %s", shell_quote(tmp), shell_quote(path)))
  return ok == true or ok == 0
end

local function read_file(path, max_bytes)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data
  if max_bytes then
    data = f:read(max_bytes + 1)
  else
    data = f:read("*a")
  end
  f:close()
  if not data then
    return nil
  end
  if max_bytes and #data > max_bytes then
    return data:sub(1, max_bytes), true
  end
  return data, false
end

local function job_meta_key(id)
  return "job:" .. id .. ":meta"
end

local function job_cancel_key(id)
  return "job:" .. id .. ":cancel"
end

local function queue_head_key()
  return "jobs:q:head"
end

local function queue_tail_key()
  return "jobs:q:tail"
end

local function queue_item_key(seq)
  return "jobs:q:" .. tostring(seq)
end

local function recent_tail_key()
  return "jobs:recent:tail"
end

local function recent_item_key(seq)
  return "jobs:recent:" .. tostring(seq)
end

local function active_key()
  return "jobs:active"
end

local function new_job_id()
  local ts = now_ms()
  local seq = CACHE:incr("jobs:id", 1, 0)
  return string.format("job-%d-%d-%06d", ts, seq, math.random(0, 999999))
end

local function normalize_body(payload_body)
  if payload_body == nil or payload_body == cjson.null then
    return ""
  end
  if type(payload_body) == "string" then
    return payload_body
  end
  local encoded = cjson.encode(payload_body)
  if not encoded then
    return nil, "body must be a string or JSON-encodable value"
  end
  return encoded
end

local function normalize_method(raw)
  local m = string.upper(tostring(raw or "GET"))
  if m ~= "GET" and m ~= "POST" and m ~= "PUT" and m ~= "PATCH" and m ~= "DELETE" then
    return nil, "unsupported method"
  end
  return m
end

local function ensure_name(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil, "name is required"
  end
  if not raw:match("^[a-zA-Z0-9_-]+$") then
    return nil, "invalid name"
  end
  return raw
end

local function ensure_version(raw)
  if raw == nil or raw == "" or raw == cjson.null then
    return nil
  end
  if type(raw) ~= "string" or not raw:match("^[a-zA-Z0-9_.-]+$") then
    return nil, "invalid version"
  end
  return raw
end

local function ensure_runtime(raw)
  if raw == nil or raw == "" or raw == cjson.null then
    return nil
  end
  if type(raw) ~= "string" or not raw:match("^[a-zA-Z0-9_-]+$") then
    return nil, "invalid runtime"
  end
  return raw
end

local function allow_header_value(methods)
  if type(methods) ~= "table" or #methods == 0 then
    return "GET"
  end
  return table.concat(methods, ", ")
end

local function method_allowed(method, methods)
  if type(methods) ~= "table" or #methods == 0 then
    return method == "GET"
  end
  for _, m in ipairs(methods) do
    if string.upper(tostring(m)) == method then
      return true
    end
  end
  return false
end

local function set_meta(id, meta)
  CACHE:set(job_meta_key(id), cjson.encode(meta))
end

local function get_meta(id)
  local raw = CACHE:get(job_meta_key(id))
  if not raw then
    return nil
  end
  local obj = cjson.decode(raw)
  if type(obj) ~= "table" then
    return nil
  end
  return obj
end

local function mark_recent(id)
  local tail = CACHE:incr(recent_tail_key(), 1, 0)
  CACHE:set(recent_item_key(tail), id)
  local keep = 250
  local drop = tail - keep
  if drop > 0 then
    CACHE:delete(recent_item_key(drop))
  end
end

local function enqueue_id(id)
  local tail = CACHE:incr(queue_tail_key(), 1, 0)
  CACHE:set(queue_item_key(tail), id)
end

local function dequeue_id()
  local head = CACHE:get(queue_head_key()) or 0
  local tail = CACHE:get(queue_tail_key()) or 0
  if head >= tail then
    return nil
  end
  local next_head = head + 1
  local id = CACHE:get(queue_item_key(next_head))
  CACHE:set(queue_head_key(), next_head)
  CACHE:delete(queue_item_key(next_head))
  return id
end

local function spec_path(id)
  return jobs_dir() .. "/" .. id .. ".spec.json"
end

local function result_path(id)
  return jobs_dir() .. "/" .. id .. ".result.json"
end

local function write_spec(id, spec)
  ensure_dir(jobs_dir())
  local raw = cjson.encode(spec) or "{}"
  return write_file_atomic(spec_path(id), raw .. "\n")
end

local function read_spec(id)
  local raw = read_file(spec_path(id), 2 * 1024 * 1024)
  if not raw then
    return nil
  end
  local obj = cjson.decode(raw)
  if type(obj) ~= "table" then
    return nil
  end
  return obj
end

local function write_result(id, result)
  ensure_dir(jobs_dir())
  local raw = cjson.encode(result) or "{}"
  local maxb = jobs_max_result_bytes()
  if #raw > maxb then
    raw = raw:sub(1, maxb)
    result.truncated = true
    raw = cjson.encode(result) or raw
    if #raw > maxb then
      raw = raw:sub(1, maxb)
    end
  end
  return write_file_atomic(result_path(id), raw .. "\n")
end

local function runtime_is_down(runtime, rt_cfg)
  local up = routes.runtime_is_up(runtime)
  if up ~= true then
    local ok, err = routes.check_runtime_socket(rt_cfg.socket, rt_cfg.timeout_ms or 250)
    routes.set_runtime_health(runtime, ok, ok and "ok" or err)
    return not ok
  end
  return false
end

local function invoke_one(spec)
  local name = spec.name
  local runtime = spec.runtime
  local version = spec.version
  local method = spec.method
  local query = spec.query or {}
  local headers = spec.headers or {}
  local body = spec.body or ""
  local user_context = spec.context

  local runtime_cfg = routes.get_runtime_config(runtime)
  if not runtime_cfg then
    return nil, 404, "unknown runtime"
  end

  local policy, perr = routes.resolve_function_policy(runtime, name, version)
  if not policy then
    return nil, 404, perr or "unknown function"
  end
  if not method_allowed(method, policy.methods) then
    return nil, 405, "method not allowed", { Allow = allow_header_value(policy.methods) }
  end

  if runtime_is_down(runtime, runtime_cfg) then
    return nil, 503, "runtime down"
  end

  local max_body_bytes = utils.resolve_numeric(policy.max_body_bytes, nil, nil, 1024 * 1024)
  if type(body) == "string" and #body > max_body_bytes then
    return nil, 413, "payload too large"
  end

  local timeout_ms = utils.resolve_numeric(policy.timeout_ms, runtime_cfg.timeout_ms, nil, 2500)
  local max_concurrency = utils.resolve_numeric(policy.max_concurrency, nil, nil, 0)

  local version_label = version or "default"
  local fn_key = runtime .. "/" .. name .. "@" .. version_label
  local acquired, acquire_err = limits.try_acquire(CONC, fn_key, max_concurrency)
  if not acquired then
    if acquire_err == "busy" then
      return nil, 429, "busy"
    end
    return nil, 500, "concurrency gate failure"
  end

  local request_id = spec.request_id
  local start = ngx.now()
  local resp, err_code, err_msg = client.call_unix(runtime_cfg.socket, {
    fn = name,
    version = version,
    event = {
      id = request_id,
      ts = now_ms(),
      method = method,
      path = "/_fn/jobs",
      raw_path = "/_fn/jobs",
      query = query,
      headers = headers,
      body = body,
      client = { ip = "127.0.0.1", ua = "fastfn-jobs" },
      context = {
        request_id = request_id,
        runtime = runtime,
        function_name = name,
        version = version_label,
        timeout_ms = timeout_ms,
        max_concurrency = max_concurrency,
        max_body_bytes = max_body_bytes,
        gateway = { worker_pid = ngx.worker.pid() },
        debug = { enabled = policy.include_debug_headers == true },
        user = type(user_context) == "table" and user_context or nil,
      },
    },
  }, timeout_ms)

  limits.release(CONC, fn_key)

  local elapsed_ms = math.floor((ngx.now() - start) * 1000)
  if not resp then
    local status, msg = utils.map_runtime_error(err_code)
    return nil, status, msg .. ": " .. tostring(err_msg), nil, elapsed_ms
  end

  return resp, resp.status, nil, nil, elapsed_ms
end

local function run_job(premature, id)
  if premature then
    return
  end

  local meta = get_meta(id)
  if not meta then
    CACHE:incr(active_key(), -1, 0)
    return
  end
  if CACHE:get(job_cancel_key(id)) == 1 then
    meta.status = "canceled"
    meta.updated_at_ms = now_ms()
    set_meta(id, meta)
    CACHE:incr(active_key(), -1, 0)
    return
  end

  meta.status = "running"
  meta.updated_at_ms = now_ms()
  meta.attempt = (tonumber(meta.attempt) or 0) + 1
  set_meta(id, meta)

  local spec = read_spec(id) or {}
  spec.request_id = spec.request_id or id

  local ok, resp, status, err_msg, extra_headers, elapsed_ms = xpcall(function()
    local r, st, emsg, hdrs, ms = invoke_one(spec)
    return r, st, emsg, hdrs, ms
  end, function(e)
    return nil, 500, tostring(e), nil, 0
  end)

  local result = {
    id = id,
    status = 500,
    headers = { ["Content-Type"] = "application/json" },
    body = cjson.encode({ error = "internal error" }) or "{\"error\":\"internal\"}",
    is_base64 = false,
    body_base64 = nil,
    latency_ms = elapsed_ms or 0,
  }

  if ok then
    if resp and type(resp) == "table" then
      result.status = resp.status
      result.headers = resp.headers or {}
      if resp.is_base64 == true then
        result.is_base64 = true
        result.body_base64 = resp.body_base64 or ""
        result.body = nil
      else
        result.body = resp.body or ""
      end
    else
      result.status = tonumber(status) or 500
      if type(extra_headers) == "table" and extra_headers.Allow then
        result.headers = { ["Content-Type"] = "application/json", ["Allow"] = extra_headers.Allow }
      end
      result.body = cjson.encode({ error = tostring(err_msg or "error") }) or "{\"error\":\"error\"}"
    end
  else
    result.status = 500
    result.body = cjson.encode({ error = tostring(resp or "error") }) or "{\"error\":\"error\"}"
  end

  write_result(id, result)

  if result.status >= 200 and result.status < 500 then
    meta.status = "done"
    meta.result_status = result.status
    meta.updated_at_ms = now_ms()
    set_meta(id, meta)
    CACHE:incr(active_key(), -1, 0)
    return
  end

  meta.last_error = tostring(err_msg or ("HTTP " .. tostring(result.status)))
  meta.result_status = result.status
  meta.updated_at_ms = now_ms()

  local max_attempts = tonumber(meta.max_attempts) or DEFAULT_MAX_ATTEMPTS
  if meta.attempt < max_attempts then
    meta.status = "queued"
    meta.next_run_at_ms = now_ms() + (tonumber(meta.retry_delay_ms) or DEFAULT_RETRY_DELAY_MS)
    set_meta(id, meta)
    enqueue_id(id)
    CACHE:incr(active_key(), -1, 0)
    return
  end

  meta.status = "failed"
  set_meta(id, meta)
  CACHE:incr(active_key(), -1, 0)
end

local function process_queue(premature)
  if premature then
    return
  end
  if not jobs_enabled() then
    return
  end
  if ngx.worker.id() ~= 0 then
    return
  end

  local maxc = jobs_max_concurrency()
  local active = CACHE:get(active_key()) or 0
  local slots = maxc - active
  if slots <= 0 then
    return
  end

  for _ = 1, slots do
    local id = dequeue_id()
    if not id then
      return
    end
    local meta = get_meta(id)
    if not meta then
      goto continue
    end
    if meta.status ~= "queued" then
      goto continue
    end
    local next_run = tonumber(meta.next_run_at_ms or 0) or 0
    if next_run > now_ms() then
      enqueue_id(id)
      goto continue
    end
    CACHE:incr(active_key(), 1, 0)
    local ok = ngx.timer.at(0, run_job, id)
    if not ok then
      CACHE:incr(active_key(), -1, 0)
      meta.status = "failed"
      meta.last_error = "failed to schedule timer"
      meta.updated_at_ms = now_ms()
      set_meta(id, meta)
    end
    ::continue::
  end
end

function M.init()
  if ngx.worker.id() ~= 0 then
    return
  end
  if not jobs_enabled() then
    return
  end
  ensure_dir(jobs_dir())
  ngx.timer.every(jobs_poll_interval(), process_queue)
end

function M.enqueue(payload)
  if not jobs_enabled() then
    return nil, 404, "jobs disabled"
  end
  if type(payload) ~= "table" then
    return nil, 400, "payload must be an object"
  end

  local name, nerr = ensure_name(payload.name)
  if not name then
    return nil, 400, nerr
  end
  local version, verr = ensure_version(payload.version)
  if verr then
    return nil, 400, verr
  end
  local runtime, rerr = ensure_runtime(payload.runtime)
  if rerr then
    return nil, 400, rerr
  end
  local method, merr = normalize_method(payload.method)
  if not method then
    return nil, 400, merr
  end

  local resolved_runtime = runtime
  local resolved_version = version
  if resolved_runtime then
    local policy = routes.resolve_function_policy(resolved_runtime, name, resolved_version)
    if not policy then
      routes.discover_functions(true)
      policy = routes.resolve_function_policy(resolved_runtime, name, resolved_version)
      if not policy then
        return nil, 404, "unknown function or version"
      end
    end
  else
    local resolve_err
    resolved_runtime, resolved_version, resolve_err = routes.resolve_legacy_target(name, resolved_version)
    if not resolved_runtime then
      routes.discover_functions(true)
      resolved_runtime, resolved_version, resolve_err = routes.resolve_legacy_target(name, resolved_version)
    end
    if not resolved_runtime then
      if resolve_err then
        return nil, 409, resolve_err
      end
      return nil, 404, "unknown function or version"
    end
  end

  local policy, perr = routes.resolve_function_policy(resolved_runtime, name, resolved_version)
  if not policy then
    return nil, 404, perr or "unknown function or version"
  end
  if not method_allowed(method, policy.methods) then
    return nil, 405, "method not allowed", { Allow = allow_header_value(policy.methods) }
  end

  local body, berr = normalize_body(payload.body)
  if not body then
    return nil, 400, berr
  end

  local max_body_bytes = tonumber(policy.max_body_bytes) or DEFAULT_MAX_RESULT_BYTES
  if #body > max_body_bytes then
    return nil, 413, "payload too large"
  end

  local query = type(payload.query) == "table" and payload.query or {}
  local headers = type(payload.headers) == "table" and payload.headers or {}
  local context = payload.context
  if context ~= nil and type(context) ~= "table" then
    return nil, 400, "context must be an object"
  end

  local max_attempts = tonumber(payload.max_attempts) or DEFAULT_MAX_ATTEMPTS
  if max_attempts < 1 then
    max_attempts = 1
  end
  local retry_delay_ms = tonumber(payload.retry_delay_ms) or DEFAULT_RETRY_DELAY_MS
  if retry_delay_ms < 0 then
    retry_delay_ms = DEFAULT_RETRY_DELAY_MS
  end

  local id = new_job_id()
  local meta = {
    id = id,
    status = "queued",
    created_at_ms = now_ms(),
    updated_at_ms = now_ms(),
    runtime = resolved_runtime,
    name = name,
    version = resolved_version,
    method = method,
    attempt = 0,
    max_attempts = max_attempts,
    retry_delay_ms = retry_delay_ms,
  }
  set_meta(id, meta)
  mark_recent(id)

  local spec = {
    runtime = resolved_runtime,
    name = name,
    version = resolved_version,
    method = method,
    query = query,
    headers = headers,
    body = body,
    context = context,
  }
  local ok, werr = write_spec(id, spec)
  if not ok then
    meta.status = "failed"
    meta.last_error = "failed to write job spec: " .. tostring(werr)
    meta.updated_at_ms = now_ms()
    set_meta(id, meta)
    return meta, 500
  end

  enqueue_id(id)
  return meta, 201
end

function M.list(limit)
  local n = tonumber(limit) or 50
  if n < 1 then
    n = 1
  end
  if n > 200 then
    n = 200
  end
  local tail = CACHE:get(recent_tail_key()) or 0
  local out = {}
  for i = tail, math.max(1, tail - n + 1), -1 do
    local id = CACHE:get(recent_item_key(i))
    if id then
      local meta = get_meta(id)
      if meta then
        out[#out + 1] = meta
      end
    end
  end
  return out
end

function M.get(id)
  return get_meta(id)
end

function M.cancel(id)
  local meta = get_meta(id)
  if not meta then
    return nil, 404, "job not found"
  end
  if meta.status ~= "queued" then
    return nil, 409, "job is not queued"
  end
  CACHE:set(job_cancel_key(id), 1)
  meta.status = "canceled"
  meta.updated_at_ms = now_ms()
  set_meta(id, meta)
  return meta, 200
end

function M.read_result(id)
  local raw = read_file(result_path(id), 2 * 1024 * 1024)
  if not raw then
    return nil
  end
  local obj = cjson.decode(raw)
  if type(obj) ~= "table" then
    return nil
  end
  return obj
end

return M

