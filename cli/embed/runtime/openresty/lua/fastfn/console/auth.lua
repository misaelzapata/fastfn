local cjson = require "cjson.safe"

local M = {}

local COOKIE_NAME = "fastfn_session"
local DEFAULT_TTL_S = 12 * 60 * 60
local MAX_SECRET_FILE_BYTES = 8192
local MIN_PBKDF2_ITERATIONS = 100000

local function env_bool(name, default_value)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default_value
  end
  raw = string.lower(tostring(raw))
  if raw == "0" or raw == "false" or raw == "off" or raw == "no" then
    return false
  end
  if raw == "1" or raw == "true" or raw == "yes" or raw == "on" then
    return true
  end
  return default_value
end

local function env_str(name)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return nil
  end
  return tostring(raw)
end

local function trim_trailing_newlines(raw)
  if type(raw) ~= "string" then
    return raw
  end
  return (raw:gsub("[\r\n]+$", ""))
end

local function read_secret_file(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local fh, err = io.open(path, "rb")
  if not fh then
    if ngx and ngx.log then
      ngx.log(ngx.WARN, "[console.auth] failed to read secret file ", tostring(path), ": ", tostring(err))
    end
    return nil
  end

  local data = fh:read(MAX_SECRET_FILE_BYTES + 1)
  fh:close()
  if type(data) ~= "string" or data == "" then
    return nil
  end
  if #data > MAX_SECRET_FILE_BYTES then
    if ngx and ngx.log then
      ngx.log(ngx.WARN, "[console.auth] secret file too large: ", tostring(path))
    end
    return nil
  end
  return trim_trailing_newlines(data)
end

local function env_secret(name, file_name)
  local raw = env_str(name)
  if raw ~= nil then
    return raw
  end
  return read_secret_file(env_str(file_name))
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

function M.login_enabled()
  return env_bool("FN_CONSOLE_LOGIN_ENABLED", false)
end

function M.api_login_enabled()
  return env_bool("FN_CONSOLE_LOGIN_API", false)
end

function M.cookie_name()
  return COOKIE_NAME
end

function M.username()
  return env_str("FN_CONSOLE_LOGIN_USERNAME")
end

function M.password()
  return env_secret("FN_CONSOLE_LOGIN_PASSWORD", "FN_CONSOLE_LOGIN_PASSWORD_FILE")
end

function M.password_hash()
  return env_secret("FN_CONSOLE_LOGIN_PASSWORD_HASH", "FN_CONSOLE_LOGIN_PASSWORD_HASH_FILE")
end

local function session_secret()
  return env_secret("FN_CONSOLE_SESSION_SECRET", "FN_CONSOLE_SESSION_SECRET_FILE")
end

local function constant_time_eq(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local acc = 0
  for i = 1, #a do
    acc = bit.bor(acc, bit.bxor(string.byte(a, i), string.byte(b, i)))
  end
  return acc == 0
end

local function hex_encode(raw)
  local out = {}
  for i = 1, #raw do
    out[#out + 1] = string.format("%02x", string.byte(raw, i))
  end
  return table.concat(out)
end

local function hex_decode(raw)
  if type(raw) ~= "string" or raw == "" or (#raw % 2) ~= 0 or raw:find("[^%x]") then
    return nil
  end
  return (raw:gsub("(%x%x)", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function sha256_hex(raw)
  if type(raw) ~= "string" or type(ngx.sha256_bin) ~= "function" then
    return nil
  end
  local digest = ngx.sha256_bin(raw)
  if type(digest) ~= "string" then
    return nil
  end
  return hex_encode(digest)
end

local function log_invalid_password_hash(raw)
  if ngx and ngx.log then
    ngx.log(ngx.WARN, "[console.auth] invalid FN_CONSOLE_LOGIN_PASSWORD_HASH format: ", tostring(raw or ""))
  end
end

local function sha256_bin(raw)
  if type(raw) ~= "string" or type(ngx.sha256_bin) ~= "function" then
    return nil
  end
  return ngx.sha256_bin(raw)
end

local function xor_with_byte(raw, n)
  local out = {}
  for i = 1, #raw do
    out[i] = string.char(bit.bxor(string.byte(raw, i), n))
  end
  return table.concat(out)
end

local function xor_bytes(left, right)
  if type(left) ~= "string" or type(right) ~= "string" or #left ~= #right then
    return nil
  end
  local out = {}
  for i = 1, #left do
    out[i] = string.char(bit.bxor(string.byte(left, i), string.byte(right, i)))
  end
  return table.concat(out)
end

local function hmac_sha256(key, payload)
  if type(key) ~= "string" or type(payload) ~= "string" then
    return nil
  end
  if #key > 64 then
    key = sha256_bin(key)
    if not key then
      return nil
    end
  end
  if #key < 64 then
    key = key .. string.rep("\0", 64 - #key)
  end
  local inner = sha256_bin(xor_with_byte(key, 0x36) .. payload)
  if not inner then
    return nil
  end
  return sha256_bin(xor_with_byte(key, 0x5c) .. inner)
end

local function u32be(n)
  local b1 = math.floor(n / 16777216) % 256
  local b2 = math.floor(n / 65536) % 256
  local b3 = math.floor(n / 256) % 256
  local b4 = n % 256
  return string.char(b1, b2, b3, b4)
end

local function pbkdf2_sha256_bin(password, salt, iterations, dk_len)
  if type(password) ~= "string" or type(salt) ~= "string" then
    return nil
  end
  iterations = tonumber(iterations)
  dk_len = tonumber(dk_len) or 32
  if not iterations or iterations < 1 or dk_len < 1 then
    return nil
  end
  local hlen = 32
  local blocks = math.ceil(dk_len / hlen)
  local chunks = {}
  for block = 1, blocks do
    local u = hmac_sha256(password, salt .. u32be(block))
    if not u then
      return nil
    end
    local t = u
    for _ = 2, iterations do
      u = hmac_sha256(password, u)
      if not u then
        return nil
      end
      t = xor_bytes(t, u)
      if not t then
        return nil
      end
    end
    chunks[#chunks + 1] = t
  end
  return table.concat(chunks):sub(1, dk_len)
end

local function parsed_password_hash()
  local raw_hash = M.password_hash()
  if not raw_hash then
    return nil
  end

  local raw = tostring(raw_hash)
  local lower = raw:lower()
  if lower:sub(1, 14) == "pbkdf2-sha256:" then
    local iterations_raw, salt_hex, digest_hex = raw:match("^pbkdf2%-sha256:(%d+):([A-Fa-f0-9]+):([A-Fa-f0-9]+)$")
    local iterations = tonumber(iterations_raw)
    local salt = hex_decode(salt_hex or "")
    local digest = hex_decode(digest_hex or "")
    if not iterations or iterations < MIN_PBKDF2_ITERATIONS or not salt or not digest then
      log_invalid_password_hash(raw)
      return { kind = "invalid" }
    end
    return {
      kind = "pbkdf2-sha256",
      iterations = iterations,
      salt = salt,
      salt_hex = string.lower(salt_hex),
      digest = digest,
      digest_hex = string.lower(digest_hex),
    }
  end

  local digest_hex = lower
  if digest_hex:sub(1, 7) == "sha256:" then
    digest_hex = digest_hex:sub(8)
  end
  if hex_decode(digest_hex) then
    return {
      kind = "sha256",
      digest_hex = digest_hex,
    }
  end

  log_invalid_password_hash(raw)
  return { kind = "invalid" }
end

local function credentials_fingerprint()
  local user = M.username()
  if type(user) ~= "string" or user == "" then
    return nil
  end

  local parsed_hash = parsed_password_hash()
  if parsed_hash then
    if parsed_hash.kind == "pbkdf2-sha256" then
      return string.format(
        "pbkdf2-sha256:%d:%s:%s:%s",
        parsed_hash.iterations,
        parsed_hash.salt_hex,
        parsed_hash.digest_hex,
        user
      )
    end
    if parsed_hash.kind == "sha256" then
      return "sha256:" .. parsed_hash.digest_hex .. ":" .. user
    end
    return nil
  end

  local expected_password = M.password()
  if not expected_password then
    return nil
  end

  local password_hash = sha256_hex(expected_password)
  if not password_hash then
    return nil
  end
  return "sha256:" .. password_hash .. ":" .. user
end

local function hmac(secret, payload)
  -- Built-in OpenResty primitive.
  local sig = ngx.hmac_sha1(secret, payload)
  return ngx.encode_base64(sig)
end

function M.constant_time_eq(a, b)
  return constant_time_eq(a, b)
end

function M.credentials_configured()
  if M.username() == nil then
    return false
  end
  if M.password_hash() ~= nil then
    local parsed_hash = parsed_password_hash()
    return parsed_hash ~= nil and parsed_hash.kind ~= "invalid"
  end
  return M.password() ~= nil
end

function M.verify_password(password)
  if type(password) ~= "string" then
    return false
  end

  local parsed_hash = parsed_password_hash()
  if parsed_hash then
    if parsed_hash.kind == "pbkdf2-sha256" then
      local derived = pbkdf2_sha256_bin(password, parsed_hash.salt, parsed_hash.iterations, #parsed_hash.digest)
      return type(derived) == "string" and constant_time_eq(derived, parsed_hash.digest)
    end
    if parsed_hash.kind == "sha256" then
      local actual_hash = sha256_hex(password)
      if not actual_hash then
        return false
      end
      return constant_time_eq(actual_hash, parsed_hash.digest_hex)
    end
    return false
  end

  local expected_password = M.password()
  if not expected_password then
    return false
  end
  return constant_time_eq(password, expected_password)
end

local function parse_cookies()
  local raw = ngx.var.http_cookie or ""
  local out = {}
  for part in raw:gmatch("([^;]+)") do
    local k, v = part:match("^%s*([^=]+)%s*=%s*(.*)%s*$")
    if k and v then
      out[k] = v
    end
  end
  return out
end

function M.read_session()
  local secret = session_secret()
  if not secret or secret == "" then
    return nil, "session secret not configured"
  end

  local cookies = parse_cookies()
  local token = cookies[COOKIE_NAME]
  if not token or token == "" then
    return nil, "no session"
  end

  local p64, sig64 = token:match("^([^%.]+)%.([^%.]+)$")
  if not p64 or not sig64 then
    return nil, "invalid session token"
  end

  local payload = ngx.decode_base64(p64)
  if not payload then
    return nil, "invalid session payload"
  end

  local expected = hmac(secret, payload)
  if not constant_time_eq(expected, sig64) then
    return nil, "invalid session signature"
  end

  local obj = cjson.decode(payload)
  if type(obj) ~= "table" then
    return nil, "invalid session json"
  end

  local exp = tonumber(obj.exp)
  if not exp or exp <= 0 then
    return nil, "invalid session exp"
  end
  if exp < ngx.time() then
    return nil, "session expired"
  end

  if type(obj.user) ~= "string" or obj.user == "" then
    return nil, "invalid session user"
  end

  local configured_user = M.username()
  if configured_user and not constant_time_eq(obj.user, configured_user) then
    return nil, "session user mismatch"
  end

  local expected_fingerprint = credentials_fingerprint()
  if type(obj.cred_v1) == "string" and expected_fingerprint and not constant_time_eq(obj.cred_v1, expected_fingerprint) then
    return nil, "session credentials changed"
  end

  return { user = obj.user, exp = exp }
end

local function session_cookie_suffix(max_age)
  local secure = (ngx.var.scheme == "https") and "; Secure" or ""
  return string.format("; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d%s", max_age, secure)
end

function M.set_session_cookie(user)
  local secret = session_secret()
  if not secret or secret == "" then
    return nil, "session secret not configured"
  end
  if type(user) ~= "string" or user == "" then
    return nil, "invalid user"
  end

  local ttl = env_num("FN_CONSOLE_SESSION_TTL_S", DEFAULT_TTL_S)
  if not ttl or ttl <= 0 then
    ttl = DEFAULT_TTL_S
  end
  ttl = math.floor(ttl)

  local exp = ngx.time() + ttl
  local payload_obj = { user = user, exp = exp }
  local fingerprint = credentials_fingerprint()
  if fingerprint then
    payload_obj.cred_v1 = fingerprint
  end
  local payload = cjson.encode(payload_obj)
  if not payload then
    return nil, "failed to encode session"
  end
  local p64 = ngx.encode_base64(payload)
  local sig64 = hmac(secret, payload)
  local token = p64 .. "." .. sig64

  local cookie = string.format("%s=%s%s", COOKIE_NAME, token, session_cookie_suffix(ttl))
  ngx.header["Set-Cookie"] = cookie
  return true
end

function M.clear_session_cookie()
  ngx.header["Set-Cookie"] = string.format("%s=%s", COOKIE_NAME, session_cookie_suffix(0))
  return true
end

return M
