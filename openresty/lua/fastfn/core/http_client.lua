local M = {}

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function parse_host_port(authority, scheme)
  authority = tostring(authority or "")
  local host, port

  -- IPv6 in brackets: [::1]:443
  local ipv6_host, ipv6_port = authority:match("^%[([^%]]+)%]:(%d+)$")
  if ipv6_host then
    host = ipv6_host
    port = tonumber(ipv6_port)
    return host, port
  end
  local ipv6_only = authority:match("^%[([^%]]+)%]$")
  if ipv6_only then
    host = ipv6_only
    port = nil
    return host, port
  end

  local h, p = authority:match("^([^:]+):(%d+)$")
  if h then
    host = h
    port = tonumber(p)
    return host, port
  end

  host = authority
  port = nil
  if scheme == "https" then
    port = 443
  else
    port = 80
  end
  return host, port
end

local function parse_url(url)
  url = tostring(url or "")
  local m = ngx.re.match(url, [[^(https?)://([^/]+)(/.*)?$]], "jo")
  if not m then
    return nil, "invalid_url"
  end
  local scheme = lower(m[1])
  local authority = m[2]
  local path = m[3] or "/"
  if path == "" then
    path = "/"
  end
  local host, port = parse_host_port(authority, scheme)
  if not host or host == "" then
    return nil, "invalid_host"
  end
  return {
    scheme = scheme,
    authority = authority,
    host = host,
    port = port,
    path = path,
  }
end

local function read_line(sock)
  -- receive("*l") drops trailing \r\n but keeps \r; normalize it.
  local line, err = sock:receive("*l")
  if not line then
    return nil, err
  end
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end
  return line
end

local function read_headers(sock)
  local headers = {}
  while true do
    local line, err = read_line(sock)
    if not line then
      return nil, err
    end
    if line == "" then
      break
    end
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k then
      local key = lower(trim(k))
      local val = trim(v)
      if headers[key] == nil then
        headers[key] = val
      else
        -- preserve multiple headers as a comma-separated string (good enough for our use cases).
        headers[key] = tostring(headers[key]) .. ", " .. val
      end
    end
  end
  return headers
end

local function read_exact(sock, n)
  if n <= 0 then
    return ""
  end
  local data, err = sock:receive(n)
  if not data then
    return nil, err
  end
  return data
end

local function read_chunked(sock, max_bytes)
  local chunks = {}
  local total = 0
  while true do
    local line, err = read_line(sock)
    if not line then
      return nil, err
    end
    local hex = line:match("^%s*([0-9A-Fa-f]+)")
    if not hex then
      return nil, "invalid_chunk_size"
    end
    local size = tonumber(hex, 16)
    if not size then
      return nil, "invalid_chunk_size"
    end
    if size == 0 then
      -- consume trailing headers (ignored) and final CRLF
      local _, herr = read_headers(sock)
      if herr then
        return nil, herr
      end
      break
    end
    if max_bytes and total + size > max_bytes then
      return nil, "response_too_large"
    end
    local part, perr = read_exact(sock, size)
    if not part then
      return nil, perr
    end
    chunks[#chunks + 1] = part
    total = total + #part
    -- consume CRLF after each chunk
    local _, cerr = read_exact(sock, 2)
    if cerr then
      return nil, cerr
    end
  end
  return table.concat(chunks)
end

local function read_to_close(sock, max_bytes)
  local chunks = {}
  local total = 0
  while true do
    local part, err, partial = sock:receive(8192)
    local data = part or partial
    if data and data ~= "" then
      total = total + #data
      if max_bytes and total > max_bytes then
        return nil, "response_too_large"
      end
      chunks[#chunks + 1] = data
    end
    if part then
      -- keep reading
    else
      if err == "closed" then
        break
      end
      if err then
        return nil, err
      end
    end
  end
  return table.concat(chunks)
end

local function env_bool(name, default_value)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default_value
  end
  raw = lower(raw)
  if raw == "1" or raw == "true" or raw == "yes" or raw == "on" then
    return true
  end
  if raw == "0" or raw == "false" or raw == "no" or raw == "off" then
    return false
  end
  return default_value
end

-- opts:
--   url (required)
--   method (default GET)
--   headers (table)
--   body (string)
--   timeout_ms (number)
--   max_body_bytes (number) response limit
--   verify_tls (bool, default from env FN_HTTP_VERIFY_TLS=1)
function M.request(opts)
  if type(opts) ~= "table" then
    return nil, "invalid_options"
  end
  local parsed, perr = parse_url(opts.url)
  if not parsed then
    return nil, perr
  end

  local method = tostring(opts.method or "GET"):upper()
  local headers = opts.headers
  if headers ~= nil and type(headers) ~= "table" then
    return nil, "invalid_headers"
  end
  headers = headers or {}

  local body = opts.body
  if body ~= nil and type(body) ~= "string" then
    body = tostring(body)
  end

  local timeout_ms = tonumber(opts.timeout_ms) or 2500
  if timeout_ms < 50 then
    timeout_ms = 50
  end

  local connect_timeout = math.max(50, math.floor(timeout_ms * 0.2))
  local io_timeout = math.max(50, timeout_ms)

  local sock = ngx.socket.tcp()
  sock:settimeouts(connect_timeout, io_timeout, io_timeout)

  local ok, err = sock:connect(parsed.host, parsed.port)
  if not ok then
    return nil, "connect_error:" .. tostring(err)
  end

  if parsed.scheme == "https" then
    local verify = opts.verify_tls
    if verify == nil then
      verify = env_bool("FN_HTTP_VERIFY_TLS", true)
    end
    local sess, serr = sock:sslhandshake(nil, parsed.host, verify)
    if not sess then
      sock:close()
      return nil, "tls_error:" .. tostring(serr)
    end
  end

  local req_lines = {}
  req_lines[#req_lines + 1] = string.format("%s %s HTTP/1.1", method, parsed.path)
  req_lines[#req_lines + 1] = "Host: " .. parsed.authority
  req_lines[#req_lines + 1] = "Connection: close"

  local has_content_length = false
  for k, v in pairs(headers) do
    local key = tostring(k)
    local val = tostring(v)
    if lower(key) == "content-length" then
      has_content_length = true
    end
    req_lines[#req_lines + 1] = key .. ": " .. val
  end

  if body ~= nil and not has_content_length then
    req_lines[#req_lines + 1] = "Content-Length: " .. tostring(#body)
  end
  req_lines[#req_lines + 1] = ""
  req_lines[#req_lines + 1] = ""
  local head = table.concat(req_lines, "\r\n")

  local bytes, send_err = sock:send(head)
  if not bytes then
    sock:close()
    return nil, "send_error:" .. tostring(send_err)
  end
  if body ~= nil then
    local ok2, berr = sock:send(body)
    if not ok2 then
      sock:close()
      return nil, "send_error:" .. tostring(berr)
    end
  end

  local status_line, slerr = read_line(sock)
  if not status_line then
    sock:close()
    return nil, "receive_error:" .. tostring(slerr)
  end

  local status = tonumber(status_line:match("^HTTP/%d+%.%d+%s+(%d%d%d)"))
  if not status then
    sock:close()
    return nil, "invalid_status_line"
  end

  local resp_headers, herr = read_headers(sock)
  if not resp_headers then
    sock:close()
    return nil, "receive_error:" .. tostring(herr)
  end

  local max_body_bytes = tonumber(opts.max_body_bytes)
  local te = lower(resp_headers["transfer-encoding"] or "")
  local cl = tonumber(resp_headers["content-length"] or "")

  local resp_body
  if te:find("chunked", 1, true) then
    resp_body, err = read_chunked(sock, max_body_bytes)
    if not resp_body then
      sock:close()
      return nil, tostring(err)
    end
  elseif cl ~= nil then
    if max_body_bytes and cl > max_body_bytes then
      sock:close()
      return nil, "response_too_large"
    end
    resp_body, err = read_exact(sock, cl)
    if not resp_body then
      sock:close()
      return nil, "receive_error:" .. tostring(err)
    end
  else
    resp_body, err = read_to_close(sock, max_body_bytes)
    if not resp_body then
      sock:close()
      return nil, tostring(err)
    end
  end

  sock:close()
  return {
    status = status,
    headers = resp_headers,
    body = resp_body or "",
  }
end

return M

