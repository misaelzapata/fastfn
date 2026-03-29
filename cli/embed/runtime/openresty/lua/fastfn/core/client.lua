local cjson = require "cjson.safe"

local M = {}

local function pack_u32(n)
  local b1 = math.floor(n / 16777216) % 256
  local b2 = math.floor(n / 65536) % 256
  local b3 = math.floor(n / 256) % 256
  local b4 = n % 256
  return string.char(b1, b2, b3, b4)
end

local function unpack_u32(s)
  local b1, b2, b3, b4 = s:byte(1, 4)
  return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end

local function is_timeout(err)
  return err == "timeout"
end

function M.call_unix(socket_uri, req_obj, timeout_ms)
  local payload = cjson.encode(req_obj)
  if not payload then
    return nil, "invalid_request", "failed to encode request"
  end

  local connect_timeout = math.max(50, math.floor(timeout_ms * 0.2))
  local io_timeout = math.max(50, timeout_ms)

  local sock = ngx.socket.tcp()
  sock:settimeouts(connect_timeout, io_timeout, io_timeout)

  local ok, err = sock:connect(socket_uri)
  if not ok then
    if is_timeout(err) then
      return nil, "timeout", "connect timeout"
    end
    return nil, "connect_error", tostring(err)
  end

  local sent, send_err = sock:send(pack_u32(#payload) .. payload)
  if not sent then
    sock:close()
    if is_timeout(send_err) then
      return nil, "timeout", "send timeout"
    end
    return nil, "send_error", tostring(send_err)
  end

  local header, header_err = sock:receive(4)
  if not header then
    sock:close()
    if is_timeout(header_err) then
      return nil, "timeout", "receive header timeout"
    end
    return nil, "receive_error", tostring(header_err)
  end

  local body_len = unpack_u32(header)
  if body_len <= 0 or body_len > 10 * 1024 * 1024 then
    sock:close()
    return nil, "invalid_response", "invalid frame length"
  end

  local body, body_err = sock:receive(body_len)
  sock:close()
  if not body then
    if is_timeout(body_err) then
      return nil, "timeout", "receive body timeout"
    end
    return nil, "receive_error", tostring(body_err)
  end

  local resp = cjson.decode(body)
  if type(resp) ~= "table" then
    return nil, "invalid_response", "response is not JSON object"
  end

  if type(resp.status) ~= "number" then
    return nil, "invalid_response", "missing numeric status"
  end

  if resp.headers ~= nil and type(resp.headers) ~= "table" then
    return nil, "invalid_response", "headers must be an object"
  end

  local is_base64 = resp.is_base64 == true
  if is_base64 then
    if type(resp.body_base64) ~= "string" then
      return nil, "invalid_response", "body_base64 must be a string when is_base64=true"
    end
  else
    if resp.body ~= nil and type(resp.body) ~= "string" then
      return nil, "invalid_response", "body must be a string"
    end
  end

  return {
    status = resp.status,
    headers = resp.headers or {},
    body = resp.body,
    is_base64 = is_base64,
    body_base64 = resp.body_base64,
    proxy = (type(resp.proxy) == "table") and resp.proxy or nil,
  }
end

return M
