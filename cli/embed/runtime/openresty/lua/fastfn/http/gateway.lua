local cjson = require "cjson.safe"

local routes_mod = require "fastfn.core.routes"
local client = require "fastfn.core.client"
local lua_runtime = require "fastfn.core.lua_runtime"
local limits = require "fastfn.core.limits"
local utils = require "fastfn.core.gateway_utils"
local http_client = require "fastfn.core.http_client"
local invoke_rules = require "fastfn.core.invoke_rules"

local CONC = ngx.shared.fn_conc
local FCACHE = ngx.shared.fn_cache

local function json_error(message)
  return cjson.encode({ error = message }) or "{\"error\":\"internal\"}"
end

local function content_length_limit_exceeded(limit)
  local cl = tonumber(ngx.req.get_headers()["content-length"])
  return cl and cl > limit
end

local function read_body_limited(limit)
  ngx.req.read_body()

  local body = ngx.req.get_body_data()
  if body then
    if #body > limit then
      return nil, "too_large"
    end
    return body
  end

  local body_file = ngx.req.get_body_file()
  if not body_file then
    return nil
  end

  local f = io.open(body_file, "rb")
  if not f then
    return nil, "body_file_open_error"
  end

  local size = f:seek("end")
  f:seek("set", 0)
  if size and size > limit then
    f:close()
    return nil, "too_large"
  end

  local data = f:read("*a")
  f:close()

  if data and #data > limit then
    return nil, "too_large"
  end

  return data
end

local function new_request_id()
  local ts_ms = math.floor(ngx.now() * 1000)
  return string.format("req-%d-%d-%06d", ts_ms, ngx.worker.pid(), math.random(0, 999999))
end

local function extract_user_context(query)
  if type(query) ~= "table" then
    return nil
  end

  local raw = query.__fnctx
  if raw == nil then
    return nil
  end

  query.__fnctx = nil
  if type(raw) == "table" then
    raw = raw[1]
  end
  if type(raw) ~= "string" or raw == "" then
    return nil
  end

  local decoded = ngx.decode_base64(raw)
  if not decoded then
    return nil
  end

  local parsed = cjson.decode(decoded)
  if type(parsed) == "table" then
    return parsed
  end
  return nil
end

local function should_block_runtime(runtime, runtime_cfg)
  local up = routes_mod.runtime_is_up(runtime)
  if up ~= true then
    local ok, reason = routes_mod.check_runtime_health(runtime, runtime_cfg)
    routes_mod.set_runtime_health(runtime, ok, ok and (reason or "ok") or reason)
    return not ok
  end
  return false
end

local function map_runtime_error(runtime, err_code, err_msg)
  local status, message = utils.map_runtime_error(err_code)
  if err_code == "connect_error" then
    routes_mod.set_runtime_health(runtime, false, err_msg)
  end

  if err_code and err_code ~= "timeout" and err_code ~= "connect_error" and err_code ~= "invalid_response" then
    message = message .. ": " .. tostring(err_msg or err_code)
  end

  return status, json_error(message)
end

local function write_response(status, headers, body)
  ngx.status = status
  if headers then
    for k, v in pairs(headers) do
      ngx.header[k] = v
    end
  end
  if body ~= nil then
    ngx.print(body)
  end
end

local function table_set(list)
  local out = {}
  for _, v in ipairs(list or {}) do
    out[tostring(v)] = true
  end
  return out
end

local function host_is_private(host)
  host = tostring(host or ""):lower()
  if host == "localhost" or host == "127.0.0.1" or host == "::1" then
    return true
  end
  if host:match("^10%.") or host:match("^192%.168%.") then
    return true
  end
  local a, b = host:match("^172%.(%d+)%.")
  if a then
    local n = tonumber(a)
    if n and n >= 16 and n <= 31 then
      return true
    end
  end
  if host:match("^169%.254%.") then
    return true
  end
  return false
end

local function sanitize_proxy_headers(raw)
  if type(raw) ~= "table" then
    return {}
  end
  local out = {}
  for k, v in pairs(raw) do
    local key = tostring(k)
    if key:match("^[A-Za-z0-9-]+$") then
      local val = tostring(v)
      if not val:find("[\r\n]") then
        out[key] = val
      end
    end
  end
  return out
end

local function build_proxy_url(proxy, edge_cfg)
  if type(proxy) ~= "table" then
    return nil, "proxy must be an object"
  end
  local url = proxy.url
  if url ~= nil then
    url = tostring(url)
  end

  if url and (url:match("^https?://") ~= nil) then
    return url, nil
  end

  local path = proxy.path
  if path ~= nil then
    path = tostring(path)
  end
  if url and url:sub(1, 1) == "/" then
    path = url
  end

  if not path or path == "" or path:sub(1, 1) ~= "/" then
    return nil, "proxy.url must be absolute (http/https) or proxy.path must start with /"
  end
  if path:find("%.%.", 1, true) then
    return nil, "proxy.path may not include .."
  end

  local base_url = edge_cfg and edge_cfg.base_url
  if type(base_url) ~= "string" or base_url == "" then
    return nil, "edge.base_url is required for relative proxy paths"
  end
  base_url = base_url:gsub("/+$", "")
  return base_url .. path, nil
end

local function proxy_path_is_control_plane(path)
  if type(path) ~= "string" or path == "" then
    return false
  end

  local function matches_prefix(prefix)
    if path == prefix then
      return true
    end
    if path:sub(1, #prefix) ~= prefix then
      return false
    end
    local nextc = path:sub(#prefix + 1, #prefix + 1)
    return nextc == "/" or nextc == "?" or nextc == "#"
  end

  -- Prevent edge proxy from reaching control-plane surfaces.
  return matches_prefix("/_fn") or matches_prefix("/console")
end

local function proxy_allowed(url, edge_cfg)
  if type(url) ~= "string" then
    return false, "invalid url"
  end
  local m = ngx.re.match(url, [[^(https?)://([^/]+)(/.*)?$]], "jo")
  if not m then
    return false, "invalid url"
  end
  local scheme = tostring(m[1]):lower()
  if scheme ~= "http" and scheme ~= "https" then
    return false, "invalid scheme"
  end
  local authority = m[2]
  local host = authority
  local path = m[3] or "/"
  -- strip :port and [v6]
  local ipv6 = host:match("^%[([^%]]+)%]") -- ignore brackets
  if ipv6 then
    host = ipv6
  else
    host = host:match("^([^:]+)") or host
  end

  if proxy_path_is_control_plane(path) then
    return false, "control-plane path not allowed"
  end

  if not (edge_cfg and edge_cfg.allow_private == true) and host_is_private(host) then
    return false, "private host not allowed"
  end

  local allow_hosts = edge_cfg and edge_cfg.allow_hosts or {}
  if type(allow_hosts) ~= "table" then
    allow_hosts = {}
  end
  if #allow_hosts > 0 then
    local set = table_set(allow_hosts)
    if not set[host] and not set[authority] then
      return false, "host not in allowlist"
    end
  end
  return true
end

local function execute_proxy(proxy, edge_cfg, default_timeout_ms)
  local url, uerr = build_proxy_url(proxy, edge_cfg)
  if not url then
    return nil, uerr
  end

  local ok, aerr = proxy_allowed(url, edge_cfg)
  if not ok then
    return nil, "proxy denied: " .. tostring(aerr)
  end

  local method = tostring(proxy.method or ngx.req.get_method() or "GET"):upper()
  if not invoke_rules.ALLOWED_METHODS[method] then
    return nil, "invalid proxy method"
  end

  local headers = sanitize_proxy_headers(proxy.headers)

  local body = proxy.body
  local is_b64 = proxy.is_base64 == true
  if is_b64 then
    local b64 = proxy.body_base64
    if type(b64) ~= "string" or b64 == "" then
      return nil, "proxy.body_base64 must be a non-empty string when proxy.is_base64=true"
    end
    body = ngx.decode_base64(b64)
    if not body then
      return nil, "invalid proxy.body_base64"
    end
  else
    if body ~= nil and type(body) ~= "string" then
      body = tostring(body)
    end
  end

  local timeout_ms = tonumber(proxy.timeout_ms) or default_timeout_ms or 2500
  local max_resp = tonumber(proxy.max_response_bytes) or (edge_cfg and edge_cfg.max_response_bytes) or (1024 * 1024 * 2)

  local resp, err = http_client.request({
    url = url,
    method = method,
    headers = headers,
    body = body,
    timeout_ms = timeout_ms,
    max_body_bytes = max_resp,
  })
  if not resp then
    return nil, "proxy request failed: " .. tostring(err)
  end

  -- Drop hop-by-hop headers; we always return a full buffered body.
  local drop = {
    ["connection"] = true,
    ["keep-alive"] = true,
    ["proxy-authenticate"] = true,
    ["proxy-authorization"] = true,
    ["te"] = true,
    ["trailers"] = true,
    ["transfer-encoding"] = true,
    ["upgrade"] = true,
    ["content-length"] = true,
  }
  local filtered = {}
  for k, v in pairs(resp.headers or {}) do
    local lk = tostring(k):lower()
    if not drop[lk] then
      filtered[k] = v
    end
  end
  resp.headers = filtered

  return resp
end

local function method_is_allowed(request_method, allowed_methods)
  if type(request_method) ~= "string" then
    return false
  end
  request_method = string.upper(request_method)
  if type(allowed_methods) ~= "table" then
    return request_method == "GET"
  end
  for _, m in ipairs(allowed_methods) do
    if string.upper(tostring(m)) == request_method then
      return true
    end
  end
  return false
end

local function allow_header_value(allowed_methods)
  if type(allowed_methods) ~= "table" or #allowed_methods == 0 then
    return "GET"
  end
  return table.concat(allowed_methods, ", ")
end

local function split_host_port(authority)
  local v = tostring(authority or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if v == "" then
    return "", ""
  end
  local ipv6 = v:match("^%[([^%]]+)%]")
  if ipv6 then
    return ipv6, v
  end
  local host = v:match("^([^:]+)") or v
  return host, v
end

local function request_host_values()
  local forwarded = ngx.var.http_x_forwarded_host
  if type(forwarded) == "string" and forwarded ~= "" then
    forwarded = forwarded:match("^%s*([^,]+)")
    local host_only, authority = split_host_port(forwarded)
    if host_only ~= "" then
      return host_only, authority
    end
  end
  local host_hdr = ngx.var.http_host
  if type(host_hdr) == "string" and host_hdr ~= "" then
    local host_only, authority = split_host_port(host_hdr)
    if host_only ~= "" then
      return host_only, authority
    end
  end
  local host_var = ngx.var.host
  local host_only, authority = split_host_port(host_var)
  return host_only, authority
end

local function host_matches_pattern(host, pattern)
  host = tostring(host or ""):lower()
  pattern = tostring(pattern or ""):lower()
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

local function host_is_allowed(allowed_hosts)
  if type(allowed_hosts) ~= "table" or #allowed_hosts == 0 then
    return true
  end
  local host, authority = request_host_values()
  if host == "" and authority == "" then
    return false
  end
  for _, raw in ipairs(allowed_hosts) do
    local allowed = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if allowed ~= "" then
      local allowed_host = split_host_port(allowed)
      if host_matches_pattern(host, allowed_host) or host_matches_pattern(authority, allowed) then
        return true
      end
    end
  end
  return false
end

local request_uri = ngx.var.uri or ""
local compat_name, compat_version = utils.parse_fn_compat_target(request_uri)
local runtime
local fn_name
local requested_version
local path_params
local resolve_err

-- Prefer mapped routes for normal traffic; fall back to /fn/<name> compat paths if present.
runtime, fn_name, requested_version, path_params, resolve_err = routes_mod.resolve_mapped_target(
  request_uri,
  ngx.req.get_method(),
  {
    host = ngx.var.http_host or ngx.var.host,
    x_forwarded_host = ngx.var.http_x_forwarded_host,
  }
)
if not runtime then
  if resolve_err == "host not allowed" then
    write_response(421, { ["Content-Type"] = "application/json" }, json_error(resolve_err))
    return
  end
  if resolve_err then
    write_response(409, { ["Content-Type"] = "application/json" }, json_error(resolve_err))
    return
  end

  if compat_name then
    local compat_runtime, compat_resolved_version = routes_mod.resolve_fn_compat_target(compat_name, compat_version)
    if compat_runtime then
      runtime = compat_runtime
      fn_name = compat_name
      requested_version = compat_resolved_version
      path_params = {}
    end
  end

  if not runtime then
    write_response(404, { ["Content-Type"] = "application/json" }, json_error("not found"))
    return
  end
end

local runtime_cfg = routes_mod.get_runtime_config(runtime)
if not runtime_cfg then
  write_response(404, { ["Content-Type"] = "application/json" }, json_error("unknown runtime"))
  return
end

local policy, policy_err = routes_mod.resolve_function_policy(runtime, fn_name, requested_version)
if not policy then
  write_response(404, { ["Content-Type"] = "application/json" }, json_error(policy_err or "unknown function"))
  return
end

if not host_is_allowed(policy.allow_hosts) then
  write_response(421, { ["Content-Type"] = "application/json" }, json_error("host not allowed"))
  return
end

local req_method = ngx.req.get_method()
if not method_is_allowed(req_method, policy.methods) then
  write_response(405, {
    ["Content-Type"] = "application/json",
    ["Allow"] = allow_header_value(policy.methods),
  }, json_error("method not allowed"))
  return
end

if should_block_runtime(runtime, runtime_cfg) then
  write_response(503, { ["Content-Type"] = "application/json" }, json_error("runtime down"))
  return
end

local timeout_ms = utils.resolve_numeric(policy.timeout_ms, runtime_cfg.timeout_ms, nil, 2500)
local max_concurrency = utils.resolve_numeric(policy.max_concurrency, nil, nil, 0)
local max_body_bytes = utils.resolve_numeric(policy.max_body_bytes, nil, nil, 1024 * 1024)
local pool_enabled = type(policy.worker_pool) == "table" and policy.worker_pool.enabled ~= false
local pool_cfg = type(policy.worker_pool) == "table" and policy.worker_pool or {}
local pool_min_warm = utils.resolve_numeric(pool_cfg.min_warm, nil, nil, 0)
local pool_idle_ttl_seconds = utils.resolve_numeric(pool_cfg.idle_ttl_seconds, nil, nil, 300)
local pool_max_workers = utils.resolve_numeric(pool_cfg.max_workers, max_concurrency, nil, 0)
local pool_max_queue = utils.resolve_numeric(pool_cfg.max_queue, nil, nil, 0)
local pool_queue_timeout_ms = utils.resolve_numeric(pool_cfg.queue_timeout_ms, nil, nil, 0)
local pool_queue_poll_ms = utils.resolve_numeric(pool_cfg.queue_poll_ms, nil, nil, 20)
local pool_overflow_status = utils.resolve_numeric(pool_cfg.overflow_status, nil, nil, 429)
if pool_overflow_status ~= 429 and pool_overflow_status ~= 503 then
  pool_overflow_status = 429
end

if content_length_limit_exceeded(max_body_bytes) then
  write_response(413, { ["Content-Type"] = "application/json" }, json_error("payload too large"))
  return
end

local body, body_err = read_body_limited(max_body_bytes)
if body_err == "too_large" then
  write_response(413, { ["Content-Type"] = "application/json" }, json_error("payload too large"))
  return
end
if body_err == "body_file_open_error" then
  write_response(500, { ["Content-Type"] = "application/json" }, json_error("failed to read request body"))
  return
end

local version_label = requested_version or "default"
local fn_key = runtime .. "/" .. fn_name .. "@" .. version_label
local warm_key = "warm:" .. fn_key
local was_warm = FCACHE and FCACHE:get(warm_key) ~= nil or false
local queued = false
local acquired, acquire_state = limits.try_acquire_pool(CONC, fn_key, pool_max_workers, pool_max_queue)
if not acquired then
  if acquire_state == "queued" then
    queued = true
    local wait_ok, wait_state = limits.wait_for_pool_slot(
      CONC,
      fn_key,
      pool_max_workers,
      pool_queue_timeout_ms,
      pool_queue_poll_ms
    )
    if not wait_ok then
      local status = pool_overflow_status
      local message = "worker pool queue timeout"
      if wait_state ~= "queue_timeout" then
        status = 500
        message = "worker pool queue failure"
      elseif type(routes_mod.record_worker_pool_drop) == "function" then
        routes_mod.record_worker_pool_drop(fn_key, "queue_timeout")
      end
      write_response(status, { ["Content-Type"] = "application/json" }, json_error(message))
      return
    end
    acquired = true
    acquire_state = "acquired_from_queue"
  elseif acquire_state == "overflow" then
    if type(routes_mod.record_worker_pool_drop) == "function" then
      routes_mod.record_worker_pool_drop(fn_key, "overflow")
    end
    write_response(pool_overflow_status, { ["Content-Type"] = "application/json" }, json_error("worker pool overflow"))
    return
  else
    write_response(500, { ["Content-Type"] = "application/json" }, json_error("worker pool gate failure"))
    return
  end
end

local request_id = new_request_id()
local start = ngx.now()

local result = {
  status = 500,
  headers = { ["Content-Type"] = "application/json" },
  body = json_error("internal error"),
}

local ok, run_err = xpcall(function()
  local headers = ngx.req.get_headers()
  local query = ngx.req.get_uri_args()
  local resolved_params = type(path_params) == "table" and path_params or {}
  local user_context = extract_user_context(query)
  local event = {
    id = request_id,
    ts = math.floor(ngx.now() * 1000),
    method = ngx.req.get_method(),
    path = ngx.var.uri,
    raw_path = ngx.var.request_uri,
    query = query,
    params = resolved_params,
    path_params = resolved_params,
    headers = headers,
    body = body,
    client = {
      ip = ngx.var.remote_addr,
      ua = headers["user-agent"],
    },
    context = {
      request_id = request_id,
      runtime = runtime,
      function_name = fn_name,
      version = version_label,
      timeout_ms = timeout_ms,
      max_concurrency = max_concurrency,
      max_body_bytes = max_body_bytes,
      worker_pool = {
        enabled = pool_enabled,
        min_warm = pool_min_warm,
        idle_ttl_seconds = pool_idle_ttl_seconds,
        max_workers = pool_max_workers,
        max_queue = pool_max_queue,
        queue_timeout_ms = pool_queue_timeout_ms,
        queue_poll_ms = pool_queue_poll_ms,
        overflow_status = pool_overflow_status,
      },
      gateway = {
        worker_pid = ngx.worker.pid(),
      },
      debug = {
        enabled = policy.include_debug_headers == true,
      },
      user = user_context,
    },
  }

  local resp, err_code, err_msg
  if routes_mod.runtime_is_in_process(runtime, runtime_cfg) then
    resp, err_code, err_msg = lua_runtime.call({
      fn = fn_name,
      version = requested_version,
      event = event,
    })
  else
    resp, err_code, err_msg = client.call_unix(runtime_cfg.socket, {
      fn = fn_name,
      version = requested_version,
      event = event,
    }, timeout_ms)
  end

  if not resp then
    local status, err_body = map_runtime_error(runtime, err_code, err_msg)
    result.status = status
    result.headers = { ["Content-Type"] = "application/json" }
    if not was_warm then
      result.headers["X-FastFn-Warming"] = "true"
      result.headers["Retry-After"] = "1"
    end
    result.body = err_body
    return
  end

  result.status = resp.status
  result.headers = resp.headers or {}
  if FCACHE and (result.status or 500) < 500 then
    FCACHE:set(warm_key, ngx.now())
  end

  if type(resp.proxy) == "table" then
    local edge_cfg = policy.edge
    if type(edge_cfg) ~= "table" then
      result.status = 502
      result.headers = { ["Content-Type"] = "application/json" }
      result.body = json_error("edge proxy disabled for this function")
      return
    end

    local pres, perr = execute_proxy(resp.proxy, edge_cfg, timeout_ms)
    if not pres then
      result.status = 502
      result.headers = { ["Content-Type"] = "application/json" }
      result.body = json_error("edge proxy failed: " .. tostring(perr))
      ngx.log(ngx.ERR, "edge proxy failed id=", request_id, " route=", fn_key, " err=", tostring(perr))
      return
    end

    result.status = pres.status or 502
    result.headers = pres.headers or {}
    result.body = pres.body or ""
    return
  end

  if resp.is_base64 then
    local decoded = ngx.decode_base64(resp.body_base64)
    if not decoded then
      result.status = 502
      result.headers = { ["Content-Type"] = "application/json" }
      result.body = json_error("invalid runtime response: invalid body_base64")
      return
    end
    result.body = decoded
  else
    result.body = resp.body or ""
  end
end, debug.traceback)

limits.release_pool(CONC, fn_key)

if not ok then
  result.status = 500
  result.headers = { ["Content-Type"] = "application/json" }
  result.body = json_error("gateway exception")
  ngx.log(ngx.ERR, "fn gateway exception id=", request_id, " route=", fn_key, " err=", run_err)
end

local latency_ms = math.floor((ngx.now() - start) * 1000)
ngx.log(
  ngx.INFO,
  "fn invocation id=", request_id,
  " route=", fn_key,
  " runtime=", runtime,
  " status=", result.status,
  " latency_ms=", latency_ms
)

if policy.include_debug_headers == true then
  result.headers["X-Fn-Request-Id"] = request_id
  result.headers["X-Fn-Runtime"] = runtime
  result.headers["X-Fn-Function"] = fn_name
  result.headers["X-Fn-Version"] = version_label
  result.headers["X-Fn-Latency-Ms"] = tostring(latency_ms)
  result.headers["X-Fn-Worker-Pool-Max-Workers"] = tostring(pool_max_workers)
  result.headers["X-Fn-Worker-Pool-Max-Queue"] = tostring(pool_max_queue)
end
if queued then
  result.headers["X-FastFn-Queued"] = "true"
end
result.headers["X-FastFn-Function-State"] = was_warm and "warm" or "cold"
if (not was_warm) and (result.status or 500) < 500 then
  result.headers["X-FastFn-Warmed"] = "true"
end

write_response(result.status, result.headers, result.body)
