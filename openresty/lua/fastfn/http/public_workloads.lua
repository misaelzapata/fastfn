local bit = require "bit"

local M = {}
local parse_ip_bytes

function M.sanitize_request_headers(raw)
  if type(raw) ~= "table" then
    return {}
  end
  local out = {}
  local drop = {
    host = true,
    connection = true,
    ["content-length"] = true,
    ["transfer-encoding"] = true,
    expect = true,
  }
  for k, v in pairs(raw) do
    local key = tostring(k)
    if not drop[key:lower()] and not key:find("[\r\n]") then
      local val = tostring(v)
      if not val:find("[\r\n]") then
        out[key] = val
      end
    end
  end
  return out
end

function M.split_host_port(authority)
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

function M.request_host_values(ngx)
  local forwarded = ngx.var.http_x_forwarded_host
  if type(forwarded) == "string" and forwarded ~= "" then
    forwarded = forwarded:match("^%s*([^,]+)")
    local host_only, authority = M.split_host_port(forwarded)
    if host_only ~= "" then
      return host_only, authority
    end
  end
  local host_hdr = ngx.var.http_host
  if type(host_hdr) == "string" and host_hdr ~= "" then
    local host_only, authority = M.split_host_port(host_hdr)
    if host_only ~= "" then
      return host_only, authority
    end
  end
  local host_var = ngx.var.host
  local host_only, authority = M.split_host_port(host_var)
  return host_only, authority
end

function M.host_matches_pattern(host, pattern)
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

function M.request_client_ip(ngx)
  local remote_addr = tostring(ngx.var.remote_addr or "")
  local trusted_raw = tostring(os.getenv("FN_TRUSTED_PROXY_CIDRS") or "")
  if trusted_raw == "" then
    return remote_addr
  end

  local trusted = {}
  for item in trusted_raw:gmatch("([^,]+)") do
    item = tostring(item or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if item ~= "" then
      trusted[#trusted + 1] = item
    end
  end
  if #trusted == 0 or not M.cidrs_allow_ip(trusted, remote_addr) then
    return remote_addr
  end

  local forwarded = tostring(ngx.var.http_x_forwarded_for or ""):match("^%s*([^,]+)")
  forwarded = tostring(forwarded or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if forwarded == "" then
    return remote_addr
  end
  local addr, family = parse_ip_bytes(forwarded)
  if not addr or not family then
    return remote_addr
  end
  return forwarded
end

local function parse_ipv4(value)
  local octets = {}
  for item in tostring(value or ""):gmatch("([0-9]+)") do
    octets[#octets + 1] = tonumber(item)
  end
  if #octets ~= 4 then
    return nil
  end
  for _, octet in ipairs(octets) do
    if not octet or octet < 0 or octet > 255 then
      return nil
    end
  end
  return octets
end

local function split_ipv6_words(raw)
  if raw == "" then
    return {}
  end
  local out = {}
  for part in raw:gmatch("([^:]+)") do
    out[#out + 1] = part
  end
  return out
end

local function parse_ipv6(value)
  local raw = tostring(value or ""):lower()
  if raw == "" then
    return nil
  end
  local zone = raw:find("%%", 1, true)
  if zone then
    raw = raw:sub(1, zone - 1)
  end
  local left, right = raw:match("^(.-)::(.-)$")
  if left and right and right:find("::", 1, true) then
    return nil
  end

  local function normalize_words(words)
    local out = {}
    for _, word in ipairs(words) do
      if word:find("%.", 1, true) then
        local ipv4 = parse_ipv4(word)
        if not ipv4 then
          return nil
        end
        out[#out + 1] = string.format("%x", ipv4[1] * 256 + ipv4[2])
        out[#out + 1] = string.format("%x", ipv4[3] * 256 + ipv4[4])
      else
        if not word:match("^[0-9a-f]+$") or #word > 4 then
          return nil
        end
        out[#out + 1] = word
      end
    end
    return out
  end

  local left_words = normalize_words(split_ipv6_words(left or raw))
  if not left_words then
    return nil
  end
  local right_words = {}
  if left then
    right_words = normalize_words(split_ipv6_words(right))
    if not right_words then
      return nil
    end
  elseif #left_words ~= 8 then
    return nil
  end

  local words = {}
  if left then
    local zeros = 8 - (#left_words + #right_words)
    if zeros < 1 then
      return nil
    end
    for _, word in ipairs(left_words) do
      words[#words + 1] = word
    end
    for _ = 1, zeros do
      words[#words + 1] = "0"
    end
    for _, word in ipairs(right_words) do
      words[#words + 1] = word
    end
  else
    words = left_words
  end

  if #words ~= 8 then
    return nil
  end

  local bytes = {}
  for _, word in ipairs(words) do
    local num = tonumber(word, 16)
    if not num or num < 0 or num > 65535 then
      return nil
    end
    bytes[#bytes + 1] = math.floor(num / 256)
    bytes[#bytes + 1] = num % 256
  end
  return bytes
end

parse_ip_bytes = function(raw)
  local ipv4 = parse_ipv4(raw)
  if ipv4 then
    return ipv4, 4
  end
  local ipv6 = parse_ipv6(raw)
  if ipv6 then
    return ipv6, 6
  end
  return nil, nil
end

function M.cidr_contains_ip(cidr, raw_ip)
  local prefix = tostring(cidr or "")
  local slash = prefix:find("/", 1, true)
  if not slash then
    return false
  end
  local addr_raw = prefix:sub(1, slash - 1)
  local bits_raw = prefix:sub(slash + 1)
  local network, family = parse_ip_bytes(addr_raw)
  local addr, ip_family = parse_ip_bytes(raw_ip)
  local bits = tonumber(bits_raw)
  if not network or not addr or family ~= ip_family or not bits then
    return false
  end
  local max_bits = family == 4 and 32 or 128
  if bits < 0 or bits > max_bits then
    return false
  end
  local full_bytes = math.floor(bits / 8)
  local remainder = bits % 8
  for idx = 1, full_bytes do
    if network[idx] ~= addr[idx] then
      return false
    end
  end
  if remainder == 0 then
    return true
  end
  local mask = 256 - 2 ^ (8 - remainder)
  return bit.band(network[full_bytes + 1], mask) == bit.band(addr[full_bytes + 1], mask)
end

function M.cidrs_allow_ip(allow_cidrs, raw_ip)
  if type(allow_cidrs) ~= "table" or #allow_cidrs == 0 then
    return true
  end
  raw_ip = tostring(raw_ip or "")
  if raw_ip == "" then
    return false
  end
  for _, cidr in ipairs(allow_cidrs) do
    if M.cidr_contains_ip(cidr, raw_ip) then
      return true
    end
  end
  return false
end

function M.host_allowlist_score(allow_hosts, request_host, request_authority)
  if type(allow_hosts) ~= "table" or #allow_hosts == 0 then
    return true, 0
  end
  local best = -1
  for _, raw in ipairs(allow_hosts) do
    local allowed = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if allowed ~= "" then
      local allowed_host, allowed_authority = M.split_host_port(allowed)
      if request_authority ~= "" and allowed_authority == request_authority then
        best = math.max(best, 300)
      elseif request_host ~= "" and allowed_host == request_host then
        best = math.max(best, 200)
      elseif M.host_matches_pattern(request_host, allowed_host) or M.host_matches_pattern(request_authority, allowed) then
        best = math.max(best, 100)
      end
    end
  end
  return best >= 0, math.max(best, 0)
end

function M.match_public_workload(candidates, request_host, request_authority, client_ip)
  local best_workload
  local best_endpoint
  local best_score = -1
  local denied_reason = nil
  local denied_score = -1

  for _, candidate in ipairs(candidates or {}) do
    local endpoint = type(candidate.endpoint) == "table" and candidate.endpoint or {}
    local host_ok, host_score = M.host_allowlist_score(endpoint.allow_hosts, request_host, request_authority)
    local cidr_ok = M.cidrs_allow_ip(endpoint.allow_cidrs, client_ip)
    local route_score = tonumber(candidate.route_length) or 0
    local total_score = route_score * 1000 + host_score

    if host_ok and cidr_ok then
      if total_score > best_score then
        best_workload = candidate.workload
        best_endpoint = endpoint
        best_score = total_score
      end
    elseif total_score > denied_score then
      denied_score = total_score
      denied_reason = host_ok and "ip not allowed" or "host not allowed"
    end
  end

  return best_workload, best_endpoint, denied_reason
end

return M
