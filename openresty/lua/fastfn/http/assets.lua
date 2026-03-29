local M = {}
local fs = require "fastfn.core.fs"
local DEFAULT_MAX_ASSET_BYTES = tonumber(os.getenv("FN_MAX_ASSET_BYTES") or "") or (32 * 1024 * 1024)

function M.path_is_reserved(path)
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

  return matches_prefix("/_fn") or matches_prefix("/console")
end

function M.file_exists(path)
  return fs.is_file(path)
end

function M.read_file(path, max_bytes)
  local byte_limit = tonumber(max_bytes) or DEFAULT_MAX_ASSET_BYTES
  local f, err = io.open(path, "rb")
  if not f then
    return nil, err
  end
  local data = f:read(byte_limit + 1)
  f:close()
  if type(data) ~= "string" then
    return nil, "empty asset body"
  end
  if #data > byte_limit then
    return nil, "asset too large"
  end
  return data
end

function M.file_meta(path)
  return fs.file_meta(path)
end

function M.real_path(path)
  return fs.realpath(path)
end

function M.path_is_under(path, root)
  local file_path = tostring(path or "")
  local root_path = tostring(root or "")
  if file_path == "" or root_path == "" then
    return false
  end
  if file_path == root_path then
    return true
  end
  return file_path:sub(1, #root_path + 1) == (root_path .. "/")
end

function M.file_is_safe_asset(path, assets_cfg)
  if type(path) ~= "string" or path == "" or type(assets_cfg) ~= "table" then
    return false
  end
  local root_real = M.real_path(assets_cfg.abs_dir)
  local file_real = M.real_path(path)
  if type(root_real) ~= "string" or root_real == "" or type(file_real) ~= "string" or file_real == "" then
    return false
  end
  return M.path_is_under(file_real, root_real)
end

function M.http_time(ts, ngx_mod)
  ngx_mod = ngx_mod or ngx
  if ngx_mod and type(ngx_mod.http_time) == "function" then
    return ngx_mod.http_time(ts)
  end
  return tostring(ts)
end

local CONTENT_TYPES = {
  html = "text/html; charset=utf-8",
  css = "text/css; charset=utf-8",
  js = "application/javascript; charset=utf-8",
  mjs = "application/javascript; charset=utf-8",
  json = "application/json",
  map = "application/json",
  txt = "text/plain; charset=utf-8",
  svg = "image/svg+xml; charset=utf-8",
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  ico = "image/x-icon",
  csv = "text/csv; charset=utf-8",
  wasm = "application/wasm",
  woff = "font/woff",
  woff2 = "font/woff2",
  ttf = "font/ttf",
  otf = "font/otf",
  pdf = "application/pdf",
  mp3 = "audio/mpeg",
  mp4 = "video/mp4",
  webm = "video/webm",
  zip = "application/zip",
}

function M.content_type(rel_path)
  local ext = tostring(rel_path or ""):match("%.([A-Za-z0-9]+)$")
  if not ext then
    return "application/octet-stream"
  end
  return CONTENT_TYPES[string.lower(ext)] or "application/octet-stream"
end

function M.name_looks_hashed(rel_path)
  local name = tostring(rel_path or ""):match("([^/]+)$") or ""
  return name:match("[._%-]%x%x%x%x%x%x%x%x%x*[._%-]") ~= nil
    or name:match("[._%-]%x%x%x%x%x%x%x%x%x*%.") ~= nil
end

function M.cache_control(rel_path)
  if M.name_looks_hashed(rel_path) then
    return "public, max-age=31536000, immutable"
  end
  return "public, max-age=0, must-revalidate"
end

function M.is_navigation_request(request_path, headers)
  local path = tostring(request_path or "")
  if path == "" or path == "/" then
    return true
  end
  if path == "/api" or path:find("^/api/", 1, false) ~= nil or path:find("^/api%-", 1, false) ~= nil then
    return false
  end
  local last = path:match("([^/]+)$") or ""
  if last:find("^%.") or last:find("%.[A-Za-z0-9]+$") then
    return false
  end
  local hdrs = type(headers) == "table" and headers or {}
  local accept = tostring(hdrs["accept"] or hdrs["Accept"] or ""):lower()
  if accept:find("text/html", 1, true) ~= nil then
    return true
  end
  if accept == "" or accept:find("*/*", 1, true) ~= nil then
    return true
  end
  local sec_fetch_mode = tostring(hdrs["sec-fetch-mode"] or hdrs["Sec-Fetch-Mode"] or ""):lower()
  if sec_fetch_mode == "navigate" then
    return true
  end
  local sec_fetch_dest = tostring(hdrs["sec-fetch-dest"] or hdrs["Sec-Fetch-Dest"] or ""):lower()
  if sec_fetch_dest == "document" then
    return true
  end
  return false
end

function M.normalize_candidates(request_path, ngx_mod)
  ngx_mod = ngx_mod or ngx
  local raw = type(request_path) == "string" and request_path or "/"
  if raw == "" then
    raw = "/"
  end
  local decoded = ngx_mod and ngx_mod.unescape_uri and ngx_mod.unescape_uri(raw) or raw
  if type(decoded) ~= "string" or decoded == "" or decoded:sub(1, 1) ~= "/" then
    return nil
  end

  local segments = {}
  for segment in decoded:gmatch("[^/]+") do
    if segment == "." or segment == ".." or segment == "" then
      return nil
    end
    if segment:sub(1, 1) == "." or segment:find("\\", 1, true) then
      return nil
    end
    segments[#segments + 1] = segment
  end

  local rel = table.concat(segments, "/")
  if rel == "" then
    return { "index.html" }
  end
  if decoded:sub(-1) == "/" then
    return { rel .. "/index.html" }
  end
  return { rel, rel .. "/index.html" }
end

function M.resolve_file(assets_cfg, request_path, ngx_mod)
  local candidates = M.normalize_candidates(request_path, ngx_mod)
  if type(candidates) ~= "table" then
    return nil, nil
  end
  for _, rel_path in ipairs(candidates) do
    local abs_path = assets_cfg.abs_dir .. "/" .. rel_path
    if M.file_exists(abs_path) and M.file_is_safe_asset(abs_path, assets_cfg) then
      return abs_path, rel_path
    end
  end
  return nil, nil
end

function M.not_modified(headers, etag, mtime, ngx_mod)
  local inm = type(headers) == "table" and (headers["if-none-match"] or headers["If-None-Match"]) or nil
  if type(inm) == "string" and inm ~= "" and inm == etag then
    return true
  end
  local ims = type(headers) == "table" and (headers["if-modified-since"] or headers["If-Modified-Since"]) or nil
  ngx_mod = ngx_mod or ngx
  if type(ims) == "string" and ims ~= "" and mtime and ngx_mod and type(ngx_mod.parse_http_time) == "function" then
    local parsed = ngx_mod.parse_http_time(ims)
    if parsed and parsed >= mtime then
      return true
    end
  end
  return false
end

function M.try_serve(request_path, request_method, assets_cfg, deps)
  deps = deps or {}
  local ngx_mod = deps.ngx or ngx
  local write_response = deps.write_response
  local json_error = deps.json_error
  local allow_spa_fallback = deps.allow_spa_fallback ~= false
  local max_asset_bytes = tonumber(deps.max_asset_bytes) or DEFAULT_MAX_ASSET_BYTES

  if type(assets_cfg) ~= "table" then
    return false
  end
  if request_method ~= "GET" and request_method ~= "HEAD" then
    return false
  end
  if M.path_is_reserved(request_path) then
    return false
  end

  local headers = ngx_mod.req.get_headers()
  local abs_path, rel_path = M.resolve_file(assets_cfg, request_path, ngx_mod)
  if not abs_path and allow_spa_fallback and assets_cfg.not_found_handling == "single-page-application"
      and M.is_navigation_request(request_path, headers) then
    abs_path, rel_path = M.resolve_file(assets_cfg, "/", ngx_mod)
  end
  if not abs_path then
    return false
  end

  local mtime, size = M.file_meta(abs_path)
  if size and size > max_asset_bytes then
    write_response(413, { ["Content-Type"] = "application/json" }, json_error("asset too large"))
    return true
  end

  local resolved_size = size
  local etag = string.format('W/"%s-%s"', tostring(mtime or 0), tostring(resolved_size or 0))
  local response_headers = {
    ["Content-Type"] = M.content_type(rel_path),
    ["Cache-Control"] = M.cache_control(rel_path),
    ["ETag"] = etag,
    ["Content-Length"] = tostring(resolved_size or 0),
  }
  if mtime then
    response_headers["Last-Modified"] = M.http_time(mtime, ngx_mod)
  end

  if M.not_modified(headers, etag, mtime, ngx_mod) then
    write_response(304, response_headers, nil)
    return true
  end

  local body, read_err
  if request_method ~= "HEAD" or resolved_size == nil then
    body, read_err = M.read_file(abs_path, max_asset_bytes)
    if not body then
      local status = read_err == "asset too large" and 413 or 500
      write_response(status, { ["Content-Type"] = "application/json" }, json_error("failed to read asset: " .. tostring(read_err)))
      return true
    end
    if resolved_size == nil then
      resolved_size = #body
      etag = string.format('W/"%s-%s"', tostring(mtime or 0), tostring(resolved_size))
      response_headers["ETag"] = etag
      response_headers["Content-Length"] = tostring(resolved_size)
    end
  end

  if request_method == "HEAD" then
    write_response(200, response_headers, nil)
    return true
  end

  write_response(200, response_headers, body)
  return true
end

return M
