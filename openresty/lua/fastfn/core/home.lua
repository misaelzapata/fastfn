local cjson = require("cjson.safe")

local M = {}

local function trim(value)
  local s = tostring(value or "")
  s = s:gsub("^%s+", "")
  s = s:gsub("%s+$", "")
  return s
end

local function first_non_empty(...)
  for i = 1, select("#", ...) do
    local v = trim(select(i, ...))
    if v ~= "" then
      return v
    end
  end
  return nil
end

local function is_http_url(value)
  local lower = string.lower(tostring(value or ""))
  return lower:sub(1, 7) == "http://" or lower:sub(1, 8) == "https://"
end

local function normalize_local_target(raw)
  local value = trim(raw)
  if value == "" then
    return nil, nil, "empty"
  end
  if is_http_url(value) then
    return nil, nil, "must be a local path"
  end

  local path, args = value:match("^([^?]*)%??(.*)$")
  path = trim(path)
  if path == "" then
    return nil, nil, "missing path"
  end

  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end

  path = path:gsub("//+", "/")
  if #path > 1 then
    path = path:gsub("/+$", "")
  end

  if path == "/" then
    return nil, nil, "cannot point to /"
  end
  if path:find("..", 1, true) then
    return nil, nil, "invalid path"
  end

  if args == "" then
    args = nil
  end
  return path, args, nil
end

local function normalize_redirect_target(raw)
  local value = trim(raw)
  if value == "" then
    return nil, "empty"
  end

  if is_http_url(value) then
    return value, nil
  end

  local path, args, err = normalize_local_target(value)
  if not path then
    return nil, err
  end

  if args and args ~= "" then
    return path .. "?" .. args, nil
  end
  return path, nil
end

function M.extract_home_spec(cfg)
  if type(cfg) ~= "table" then
    return nil
  end

  local out = {
    home_function = nil,
    home_redirect = nil,
  }

  local function merge_home_value(value)
    if type(value) == "string" then
      out.home_function = out.home_function or first_non_empty(value)
      return
    end
    if type(value) ~= "table" then
      return
    end

    out.home_function = out.home_function or first_non_empty(
      value["function"],
      value.route,
      value.path,
      value.target,
      value["home-route"],
      value.home_route
    )

    out.home_redirect = out.home_redirect or first_non_empty(
      value.redirect,
      value.url,
      value.location
    )
  end

  merge_home_value(cfg.home)

  if not out.home_function and not out.home_redirect then
    local invoke = cfg.invoke
    if type(invoke) == "table" then
      merge_home_value(invoke.home)
      if not out.home_function and not out.home_redirect then
        merge_home_value(invoke["home-route"])
      end
      if not out.home_function and not out.home_redirect then
        merge_home_value(invoke.home_route)
      end
    end
  end

  if not out.home_function and not out.home_redirect then
    return nil
  end
  return out
end

local function read_json_file(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local raw = fh:read("*a")
  fh:close()
  if not raw or raw == "" then
    return nil
  end
  local obj = cjson.decode(raw)
  if type(obj) ~= "table" then
    return nil
  end
  return obj
end

function M.resolve_home_action(functions_root)
  local warnings = {}

  local function push_warning(msg)
    warnings[#warnings + 1] = tostring(msg)
  end

  local env_function = os.getenv("FN_HOME_FUNCTION")
  if env_function and trim(env_function) ~= "" then
    local path, args, err = normalize_local_target(env_function)
    if path then
      return {
        mode = "function",
        path = path,
        args = args,
        source = "env:FN_HOME_FUNCTION",
        warnings = warnings,
      }
    end
    push_warning("FN_HOME_FUNCTION ignored: " .. tostring(err))
  end

  local env_redirect = os.getenv("FN_HOME_REDIRECT")
  if env_redirect and trim(env_redirect) ~= "" then
    local location, err = normalize_redirect_target(env_redirect)
    if location then
      return {
        mode = "redirect",
        location = location,
        source = "env:FN_HOME_REDIRECT",
        warnings = warnings,
      }
    end
    push_warning("FN_HOME_REDIRECT ignored: " .. tostring(err))
  end

  local root = trim(functions_root or os.getenv("FN_FUNCTIONS_ROOT") or "")
  if root ~= "" then
    local cfg = read_json_file(root .. "/fn.config.json")
    local spec = M.extract_home_spec(cfg)
    if spec then
      if spec.home_function then
        local path, args, err = normalize_local_target(spec.home_function)
        if path then
          return {
            mode = "function",
            path = path,
            args = args,
            source = "config:fn.config.json",
            warnings = warnings,
          }
        end
        push_warning("fn.config.json home.function ignored: " .. tostring(err))
      end
      if spec.home_redirect then
        local location, err = normalize_redirect_target(spec.home_redirect)
        if location then
          return {
            mode = "redirect",
            location = location,
            source = "config:fn.config.json",
            warnings = warnings,
          }
        end
        push_warning("fn.config.json home.redirect ignored: " .. tostring(err))
      end
    end
  end

  return {
    mode = "default",
    source = "builtin",
    warnings = warnings,
  }
end

return M
