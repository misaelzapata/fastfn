#!/usr/bin/env resty

local REPO_ROOT = os.getenv("FASTFN_REPO_ROOT") or "/app"
package.path = REPO_ROOT .. "/openresty/lua/?.lua;" .. REPO_ROOT .. "/openresty/lua/?/init.lua;" .. package.path
local ORIGINAL_STDERR = io.stderr

local luacov_config = os.getenv("LUACOV_CONFIG")
if luacov_config and luacov_config ~= "" then
  -- OpenResty patches coroutine.wrap() in ways that can break luacov's
  -- per-thread hook probe in this runner context.
  coroutine.wrap = function(fn)
    return function(...)
      local ok, a, b, c, d = pcall(fn, ...)
      if not ok then error(a) end
      return a, b, c, d
    end
  end
  local ok, err = pcall(require, "luacov")
  if not ok then
    io.stderr:write("FAIL: unable to load luacov: " .. tostring(err) .. "\n")
    os.exit(1)
  end
end

local function fail(msg)
  (io.stderr or ORIGINAL_STDERR):write("FAIL: " .. msg .. "\n")
  os.exit(1)
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or "assert_eq") .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
  end
end

local function assert_true(v, msg)
  if not v then
    fail(msg or "assert_true failed")
  end
end

local function shell_quote(path)
  return string.format("%q", tostring(path))
end

local function command_ok(ok)
  return ok == true or ok == 0
end

local function mkdir_p(path)
  local ok = os.execute("mkdir -p " .. shell_quote(path))
  assert_true(command_ok(ok), "mkdir failed: " .. tostring(path))
end

local function rm_rf(path)
  local ok = os.execute("rm -rf " .. shell_quote(path))
  assert_true(command_ok(ok), "rm -rf failed: " .. tostring(path))
end

local function write_file(path, data)
  local f = io.open(path, "wb")
  if not f then
    fail("cannot write " .. tostring(path))
  end
  f:write(data)
  f:close()
end

local function reset_shared_dict(dict)
  if not dict then
    return
  end
  if dict.flush_all then
    dict:flush_all()
  end
  if dict.flush_expired then
    dict:flush_expired()
  end
end

local function new_shared_dict()
  local store = {}
  return {
    get = function(_, key)
      return store[key]
    end,
    set = function(_, key, value)
      store[key] = value
      return true
    end,
    delete = function(_, key)
      store[key] = nil
      return true
    end,
    add = function(_, key, value, _ttl)
      if store[key] ~= nil then
        return false, "exists"
      end
      store[key] = value
      return true
    end,
    incr = function(_, key, amount, init)
      local current = tonumber(store[key])
      if current == nil then
        current = tonumber(init) or 0
      end
      current = current + (tonumber(amount) or 0)
      store[key] = current
      return current
    end,
    flush_all = function()
      for k in pairs(store) do
        store[k] = nil
      end
      return true
    end,
    flush_expired = function()
      return 0
    end,
  }
end

local function with_fake_ngx(run)
  local original_ngx = _G.ngx
  local now_value = 1000
  local fn_cache = new_shared_dict()
  local fn_conc = new_shared_dict()

  _G.ngx = {
    shared = {
      fn_cache = fn_cache,
      fn_conc = fn_conc,
    },
    status = 200,
    header = {},
    say = function() end,
    req = {
      get_method = function()
        return "GET"
      end,
      get_headers = function()
        return {}
      end,
      read_body = function() end,
      get_body_data = function()
        return ""
      end,
      get_uri_args = function()
        return {}
      end,
    },
    now = function()
      return now_value
    end,
    time = function()
      return now_value
    end,
    var = {
      host = "localhost",
      remote_addr = "127.0.0.1",
    },
    escape_uri = function(s)
      return tostring(s)
    end,
    unescape_uri = function(s)
      return tostring(s)
    end,
    socket = {
      tcp = function()
        return {
          settimeouts = function() end,
          connect = function()
            return nil, "connect refused"
          end,
          close = function() end,
        }
      end,
    },
    timer = {
      at = function(_, fn, ...)
        if type(fn) == "function" then
          fn(false, ...)
        end
        return true
      end,
      every = function(_, _fn)
        return true
      end,
    },
    worker = {
      id = function()
        return 0
      end,
      pid = function()
        return 1
      end,
    },
    log = function() end,
    ERR = "ERR",
    WARN = "WARN",
    INFO = "INFO",
  }

  local function set_now(v)
    now_value = tonumber(v) or now_value
  end

  local ok, err = pcall(run, fn_cache, fn_conc, set_now)
  _G.ngx = original_ngx
  if not ok then
    fail(err)
  end
end

local function with_env(overrides, run)
  local original_getenv = os.getenv
  os.getenv = function(name)
    if type(overrides) == "table" and rawget(overrides, name) ~= nil then
      local value = overrides[name]
      if value == false then
        return nil
      end
      return tostring(value)
    end
    return original_getenv(name)
  end
  local ok, err = pcall(run)
  os.getenv = original_getenv
  if not ok then
    error(err)
  end
end

local function with_module_stubs(stubs, run)
  local saved = {}
  for name, value in pairs(stubs or {}) do
    saved[name] = package.loaded[name]
    package.loaded[name] = value
  end
  local ok, err = pcall(run)
  for name, old in pairs(saved) do
    package.loaded[name] = old
  end
  if not ok then
    error(err)
  end
end

local function get_upvalue(fn, wanted_name)
  if type(fn) ~= "function" then
    return nil, nil
  end
  for idx = 1, 256 do
    local name, value = debug.getupvalue(fn, idx)
    if not name then
      break
    end
    if name == wanted_name then
      return value, idx
    end
  end
  return nil, nil
end

local function set_upvalue(fn, wanted_name, new_value)
  if type(fn) ~= "function" then
    return false, nil
  end
  local current, idx = get_upvalue(fn, wanted_name)
  if not idx then
    return false, nil
  end
  debug.setupvalue(fn, idx, new_value)
  return true, current
end

local function get_nested_upvalue(fn, ...)
  local current = fn
  for idx = 1, select("#", ...) do
    current = get_upvalue(current, select(idx, ...))
    if current == nil then
      return nil
    end
  end
  return current
end

local function with_upvalue(fn, wanted_name, new_value, run)
  local ok_set, old_value = set_upvalue(fn, wanted_name, new_value)
  assert_true(ok_set, "missing upvalue: " .. tostring(wanted_name))
  local ok, err = pcall(run, old_value)
  set_upvalue(fn, wanted_name, old_value)
  if not ok then
    error(err)
  end
end

local function exercise_call_external_runtime(call_external_runtime, label)
  assert_true(type(call_external_runtime) == "function", label .. " call_external_runtime upvalue available")

  local function invoke_with(routes_override, client_override, runtime_cfg)
    local resp, code, msg
    with_upvalue(call_external_runtime, "routes", routes_override, function()
      with_upvalue(call_external_runtime, "client", client_override, function()
        resp, code, msg = call_external_runtime("python", runtime_cfg, { fn = "demo", event = {} }, 100)
      end)
    end)
    return resp, code, msg
  end

  local fallback_events = {}
  local fallback_routes = {
    check_runtime_health = function()
      fallback_events[#fallback_events + 1] = "check"
      return true, "ok"
    end,
    set_runtime_health = function(_runtime, ok, reason)
      fallback_events[#fallback_events + 1] = "runtime:" .. tostring(ok) .. ":" .. tostring(reason)
    end,
  }

  local fb_resp1, fb_code1, fb_msg1 = invoke_with(
    fallback_routes,
    { call_unix = function() return nil, "connect_error", "down" end },
    { socket = "unix:/tmp/" .. label .. "-fallback.sock", timeout_ms = 100 }
  )
  assert_eq(fb_resp1, nil, label .. " fallback socket resp")
  assert_eq(fb_code1, "connect_error", label .. " fallback socket code")
  assert_eq(fb_msg1, "down", label .. " fallback socket msg")
  assert_true(#fallback_events >= 2, label .. " fallback socket should update health")

  fallback_events = {}
  local fb_resp2, fb_code2, fb_msg2 = invoke_with(
    fallback_routes,
    { call_unix = function() return nil, "connect_error", "down" end },
    {}
  )
  assert_eq(fb_resp2, nil, label .. " fallback empty-config resp")
  assert_eq(fb_code2, "connect_error", label .. " fallback empty-config code")
  assert_eq(fb_msg2, "runtime unavailable", label .. " fallback empty-config msg")
  assert_eq(#fallback_events, 0, label .. " fallback empty-config should short-circuit")

  local active_events = {}
  local active_routes = {
    get_runtime_sockets = function(_runtime, cfg)
      return { cfg.socket }
    end,
    pick_runtime_socket = function(_runtime, cfg, tried)
      if tried[1] then
        return nil, nil, "single", "runtime unavailable"
      end
      return cfg.socket, 1, "single"
    end,
    set_runtime_socket_health = function(_runtime, idx, uri, up, reason)
      active_events[#active_events + 1] = "socket:" .. tostring(idx) .. ":" .. tostring(uri) .. ":" .. tostring(up) .. ":" .. tostring(reason)
      return true
    end,
    check_runtime_health = function()
      active_events[#active_events + 1] = "check"
      return true, "ok"
    end,
    set_runtime_health = function(_runtime, ok, reason)
      active_events[#active_events + 1] = "runtime:" .. tostring(ok) .. ":" .. tostring(reason)
    end,
  }

  local ok_resp, ok_code, ok_msg = invoke_with(
    active_routes,
    { call_unix = function() return { status = 200, headers = {}, body = "" } end },
    { socket = "unix:/tmp/" .. label .. "-ok.sock", timeout_ms = 100 }
  )
  assert_true(type(ok_resp) == "table", label .. " explicit socket helpers success resp")
  assert_eq(ok_code, nil, label .. " explicit socket helpers success code")
  assert_eq(ok_msg, nil, label .. " explicit socket helpers success msg")
  assert_true(type(active_events[1]) == "string" and active_events[1]:find("socket:", 1, true) == 1, label .. " explicit socket helpers success socket health")
  assert_true(type(active_events[#active_events]) == "string" and active_events[#active_events]:find("runtime:true:ok", 1, true) ~= nil, label .. " explicit socket helpers success runtime health")

  active_events = {}
  local timeout_resp, timeout_code, timeout_msg = invoke_with(
    active_routes,
    { call_unix = function() return nil, "timeout", "too slow" end },
    { socket = "unix:/tmp/" .. label .. "-timeout.sock", timeout_ms = 100 }
  )
  assert_eq(timeout_resp, nil, label .. " explicit socket helpers timeout resp")
  assert_eq(timeout_code, "timeout", label .. " explicit socket helpers timeout code")
  assert_eq(timeout_msg, "too slow", label .. " explicit socket helpers timeout msg")
  assert_eq(#active_events, 0, label .. " explicit socket helpers timeout should not touch health")

  local unhealthy_events = {}
  local unhealthy_routes = {
    get_runtime_sockets = active_routes.get_runtime_sockets,
    pick_runtime_socket = active_routes.pick_runtime_socket,
    set_runtime_socket_health = function(_runtime, idx, uri, up, reason)
      unhealthy_events[#unhealthy_events + 1] = "socket:" .. tostring(idx) .. ":" .. tostring(uri) .. ":" .. tostring(up) .. ":" .. tostring(reason)
      return true
    end,
    check_runtime_health = function()
      unhealthy_events[#unhealthy_events + 1] = "check"
      return false, "down"
    end,
    set_runtime_health = function(_runtime, ok, reason)
      unhealthy_events[#unhealthy_events + 1] = "runtime:" .. tostring(ok) .. ":" .. tostring(reason)
    end,
  }

  local down_resp, down_code, down_msg = invoke_with(
    unhealthy_routes,
    { call_unix = function() return nil, "connect_error", "down" end },
    { socket = "unix:/tmp/" .. label .. "-down.sock", timeout_ms = 100 }
  )
  assert_eq(down_resp, nil, label .. " explicit socket helpers unhealthy resp")
  assert_eq(down_code, "connect_error", label .. " explicit socket helpers unhealthy code")
  assert_eq(down_msg, "down", label .. " explicit socket helpers unhealthy msg")
  assert_true(type(unhealthy_events[1]) == "string" and unhealthy_events[1]:find("socket:", 1, true) == 1, label .. " explicit socket helpers unhealthy socket health")
  assert_true(type(unhealthy_events[#unhealthy_events]) == "string" and unhealthy_events[#unhealthy_events]:find("runtime:false:down", 1, true) ~= nil, label .. " explicit socket helpers unhealthy runtime health")
end

local function assert_explicit_root_beta_catalog(routes, catalog)
  assert_true(type((((catalog.runtimes or {}).node or {}).functions or {}).beta) == "table", "discover_functions keeps explicit root beta function")
  assert_true(type((((catalog.mapped_routes or {})["/beta"] or {})[1])) == "table", "discover_functions maps explicit root beta route")
  assert_eq((((catalog.mapped_routes or {})["/beta"] or {})[1]).fn_name, "beta", "discover_functions maps explicit root beta to named function")
  assert_true(type((((catalog.mapped_routes or {})["/beta/stats"] or {})[1])) == "table", "discover_functions keeps explicit beta mixed route")
  assert_eq((((catalog.mapped_routes or {})["/beta/stats"] or {})[1]).fn_name, "beta/get.stats.js", "discover_functions keeps explicit beta mixed route target")

  local beta_rt, beta_target = routes.resolve_mapped_target("/beta", "GET", { host = "localhost" })
  assert_eq(beta_rt, "node", "explicit root beta route runtime")
  assert_eq(beta_target, "beta", "explicit root beta route target")

  local beta_stats_rt, beta_stats_target = routes.resolve_mapped_target("/beta/stats", "GET", { host = "localhost" })
  assert_eq(beta_stats_rt, "node", "explicit root beta mixed route runtime")
  assert_eq(beta_stats_target, "beta/get.stats.js", "explicit root beta mixed route target")

  local named_runtime = routes.resolve_named_target("beta", nil)
  assert_eq(named_runtime, "node", "resolve_named_target explicit root beta")
end

local function assert_explicit_root_beta_entrypoints(routes)
  local root_beta_entry, root_beta_err = routes.resolve_function_entrypoint("node", "beta", nil)
  assert_true(root_beta_entry ~= nil, root_beta_err or "resolve_function_entrypoint explicit root beta")
  assert_true(root_beta_entry:find("/beta/handler.js", 1, true) ~= nil, "resolve_function_entrypoint explicit root beta path")

  local root_beta_stats_entry, root_beta_stats_err = routes.resolve_function_entrypoint("node", "beta/get.stats.js", nil)
  assert_true(root_beta_stats_entry ~= nil, root_beta_stats_err or "resolve_function_entrypoint explicit root beta mixed file")
  assert_true(root_beta_stats_entry:find("/beta/get.stats.js", 1, true) ~= nil, "resolve_function_entrypoint explicit root beta mixed path")
end

local function assert_explicit_root_project_helpers(functions_root, detect_file_based_routes_in_dir, resolve_runtime_file_target, resolve_runtime_function_dir, cjson)
  mkdir_p(functions_root .. "/explicit-beta")
  write_file(functions_root .. "/explicit-beta/fn.config.json", cjson.encode({ name = "beta" }) .. "\n")
  write_file(functions_root .. "/explicit-beta/handler.js", "exports.handler = async () => ({ status: 200, body: 'beta' });\n")
  write_file(functions_root .. "/explicit-beta/get.stats.js", "exports.handler = async () => ({ status: 200, body: 'stats' });\n")

  local explicit_routes = detect_file_based_routes_in_dir(functions_root .. "/explicit-beta", "explicit-beta")
  local stats_found = false
  local bad_alias_found = false
  for _, entry in ipairs(explicit_routes or {}) do
    if entry.route == "/explicit-beta/stats" and entry.target == "explicit-beta/get.stats.js" then
      stats_found = true
    end
    if entry.route == "/explicit-beta" and entry.target == "explicit-beta/handler.js" then
      bad_alias_found = true
    end
  end

  assert_true(stats_found, "detect_file_based_routes_in_dir keeps explicit mixed route")
  assert_eq(bad_alias_found, false, "detect_file_based_routes_in_dir skips explicit default alias")
  local explicit_mixed_routes = detect_file_based_routes_in_dir(functions_root .. "/explicit-beta", "explicit-beta", true, "explicit-beta")
  local mixed_bad_alias_found = false
  for _, entry in ipairs(explicit_mixed_routes or {}) do
    if entry.route == "/explicit-beta" and entry.target == "explicit-beta/handler.js" then
      mixed_bad_alias_found = true
    end
  end
  assert_eq(mixed_bad_alias_found, false, "detect_file_based_routes_in_dir suppresses explicit default alias in mixed mode")
  assert_true(resolve_runtime_file_target(functions_root, "node", "explicit-beta/get.stats.js") ~= nil, "resolve_runtime_file_target falls back to root project file")
  assert_true(resolve_runtime_function_dir(functions_root, "node", "explicit-beta", nil) ~= nil, "resolve_runtime_function_dir falls back to root project dir")
end

local function assert_routes_internal_helper_coverage(root, functions_root, routes, discover_functions, resolve_entry, resolve_runtime_file_target, resolve_runtime_function_dir, cache, cjson)
  local detect_runtime_from_dir = get_upvalue(discover_functions, "detect_runtime_from_dir")
  local explicit_function_name = get_upvalue(discover_functions, "explicit_function_name")
  local local_assets_directory_for_dir = get_upvalue(discover_functions, "local_assets_directory_for_dir")
  local discover_list_dirs = get_upvalue(discover_functions, "list_dirs")
  local discover_basename = get_upvalue(discover_functions, "basename")
  local discover_has_single_entry_file = get_upvalue(discover_functions, "has_single_entry_file")
  local discover_read_json_file = get_upvalue(discover_functions, "read_json_file")
  local discover_is_explicit_fn_config = get_upvalue(discover_functions, "is_explicit_fn_config")
  local resolve_root_file_target = get_upvalue(resolve_runtime_file_target, "resolve_root_file_target")
  local resolve_root_function_dir = get_upvalue(resolve_runtime_function_dir, "resolve_root_function_dir")
  local resolve_catalog_function_dir = get_upvalue(resolve_entry, "resolve_catalog_function_dir")

  local function clear_route_cache()
    cache:delete("runtime:config")
    cache:delete("catalog:raw")
    cache:delete("catalog:scanned_at")
  end

  assert_true(type(detect_runtime_from_dir) == "function", "detect_runtime_from_dir helper")
  assert_true(type(explicit_function_name) == "function", "explicit_function_name helper")
  assert_true(type(local_assets_directory_for_dir) == "function", "local_assets_directory_for_dir helper")
  assert_true(type(resolve_root_file_target) == "function", "resolve_root_file_target helper")
  assert_true(type(resolve_root_function_dir) == "function", "resolve_root_function_dir helper")
  assert_true(type(resolve_catalog_function_dir) == "function", "resolve_catalog_function_dir helper")

  assert_eq(detect_runtime_from_dir(functions_root, { runtime = " python " }), "python", "detect_runtime_from_dir uses configured runtime")
  assert_eq(detect_runtime_from_dir(functions_root, { entrypoint = "custom.php" }), "php", "detect_runtime_from_dir infers from entrypoint")
  assert_eq(detect_runtime_from_dir(root .. "/missing-runtime-dir", {}), nil, "detect_runtime_from_dir nil when nothing matches")
  assert_eq(explicit_function_name(root .. "/fallback-name", {}), "fallback-name", "explicit_function_name falls back to basename")

  write_file(functions_root .. "/root-file-target.js", "exports.handler = async () => ({ status: 200, body: 'root-file-target' });\n")
  mkdir_p(functions_root .. "/root-versioned/v1")
  assert_true(resolve_root_file_target(functions_root, "root-file-target.js") ~= nil, "resolve_root_file_target resolves direct root file")
  assert_eq(resolve_root_file_target(functions_root, "../bad.js"), nil, "resolve_root_file_target rejects unsafe path")
  assert_eq(resolve_root_function_dir(functions_root, "../bad", nil), nil, "resolve_root_function_dir rejects unsafe path")
  assert_eq(resolve_root_function_dir(functions_root, "root-versioned", "bad/version"), nil, "resolve_root_function_dir rejects invalid version")
  assert_true(resolve_root_function_dir(functions_root, "root-versioned", "v1") ~= nil, "resolve_root_function_dir resolves versioned root dir")

  assert_eq(local_assets_directory_for_dir(nil), nil, "local_assets_directory_for_dir rejects nil path")
  mkdir_p(functions_root .. "/assets-helper/public")
  write_file(functions_root .. "/assets-helper/fn.config.json", cjson.encode({
    assets = {
      directory = "public",
    },
  }) .. "\n")
  assert_eq(local_assets_directory_for_dir(functions_root .. "/assets-helper"), "public", "local_assets_directory_for_dir returns configured assets dir")

  mkdir_p(functions_root .. "/catalog-source")
  write_file(functions_root .. "/catalog-source/fn.config.json", cjson.encode({
    name = "catalog-only",
    runtime = "node",
  }) .. "\n")
  write_file(functions_root .. "/catalog-source/handler.js", "exports.handler = async () => ({ status: 200, body: 'catalog-only' });\n")
  mkdir_p(functions_root .. "/trimmed-explicit")
  write_file(functions_root .. "/trimmed-explicit/fn.config.json", cjson.encode({
    name = "  trim-beta  ",
    runtime = " node ",
  }) .. "\n")
  write_file(functions_root .. "/trimmed-explicit/handler.js", "exports.handler = async () => ({ status: 200, body: 'trim-beta' });\n")
  mkdir_p(functions_root .. "/broken-beta")
  write_file(functions_root .. "/broken-beta/fn.config.json", "{ not-json }\n")
  write_file(functions_root .. "/broken-beta/handler.js", "exports.handler = async () => ({ status: 200, body: 'broken-beta' });\n")
  with_env({
    FN_FUNCTIONS_ROOT = functions_root,
    FN_RUNTIMES = "node,python,lua",
  }, function()
    clear_route_cache()
    local catalog = routes.discover_functions(true)
    assert_true(type(catalog) == "table", "discover_functions catalog helper root")
    assert_eq(routes.resolve_function_source_dir(nil, "catalog-only", catalog), nil, "resolve_function_source_dir rejects invalid runtime")
    assert_true(type((((catalog.runtimes or {}).node or {}).functions or {})["trim-beta"]) == "table", "discover_functions trims explicit runtime/name config")
    assert_eq(routes.resolve_function_source_dir("node", "catalog-only", catalog), "catalog-source", "resolve_function_source_dir uses source_dir fallback")
    assert_eq(routes.resolve_function_source_dir("node", "missing-source", catalog), nil, "resolve_function_source_dir returns nil when source_dir is absent")
    local catalog_dir = resolve_catalog_function_dir(functions_root, "node", "catalog-only", nil)
    assert_true(type(catalog_dir) == "string" and catalog_dir:find("/catalog-source", 1, true) ~= nil, "resolve_catalog_function_dir uses source_dir fallback")
    local catalog_entry, catalog_entry_err = resolve_entry("node", "catalog-only", nil)
    assert_true(catalog_entry ~= nil, catalog_entry_err or "resolve_function_entrypoint catalog source_dir fallback")
    assert_true(catalog_entry:find("/catalog-source/handler.js", 1, true) ~= nil, "resolve_function_entrypoint catalog source_dir path")
    local broken_rt, broken_target = routes.resolve_mapped_target("/broken-beta", "GET", { host = "localhost" })
    assert_eq(broken_rt, "node", "discover_functions keeps malformed fn.config file route runtime")
    assert_eq(broken_target, "broken-beta/handler.js", "discover_functions keeps malformed fn.config file target")
  end)

  local prev_discover_functions = routes.discover_functions
  local ok_discover_fail, err_discover_fail = pcall(function()
    routes.discover_functions = function()
      error("boom")
    end
    assert_eq(resolve_catalog_function_dir(functions_root, "node", "catalog-only", nil), nil, "resolve_catalog_function_dir handles discover failure")
  end)
  routes.discover_functions = prev_discover_functions
  if not ok_discover_fail then
    error(err_discover_fail)
  end

  local root_config_dir = root .. "/root-config-discovery"
  rm_rf(root_config_dir)
  mkdir_p(root_config_dir)
  write_file(root_config_dir .. "/fn.config.json", cjson.encode({
    runtime = "python",
  }) .. "\n")
  write_file(root_config_dir .. "/handler.py", "def handler(event):\n    return {'status': 200, 'body': 'root-config'}\n")
  with_env({
    FN_FUNCTIONS_ROOT = root_config_dir,
    FN_RUNTIMES = "python",
  }, function()
    clear_route_cache()
    local catalog = routes.discover_functions(true)
    local root_name = root_config_dir:match("([^/]+)$")
    assert_eq((((((catalog.runtimes or {}).python or {}).functions or {})[root_name] or {}).source_dir), ".", "discover_functions root explicit source_dir dot")
    assert_eq(routes.resolve_function_source_dir("python", root_name, catalog), ".", "resolve_function_source_dir handles root explicit source dir")
  end)

  local root_entrypoint_dir = root .. "/root-entrypoint-discovery"
  rm_rf(root_entrypoint_dir)
  mkdir_p(root_entrypoint_dir)
  write_file(root_entrypoint_dir .. "/fn.config.json", cjson.encode({
    entrypoint = "custom.php",
  }) .. "\n")
  write_file(root_entrypoint_dir .. "/custom.php", "<?php\nfunction handler($event) { return ['status' => 200, 'body' => 'root-entrypoint']; }\n")
  with_env({
    FN_FUNCTIONS_ROOT = root_entrypoint_dir,
    FN_RUNTIMES = "php",
  }, function()
    clear_route_cache()
    local catalog = routes.discover_functions(true)
    local root_name = root_entrypoint_dir:match("([^/]+)$")
    assert_true(type((((catalog.runtimes or {}).php or {}).functions or {})[root_name]) == "table", "discover_functions infers runtime from root entrypoint")
  end)

  local spaced_root = root .. "/zero config spaced"
  rm_rf(spaced_root)
  mkdir_p(spaced_root)
  write_file(spaced_root .. "/fn.config.json", cjson.encode({
    runtime = "node",
  }) .. "\n")
  write_file(spaced_root .. "/handler.js", "exports.handler = async () => ({ status: 200, body: 'spaced-root' });\n")
  with_env({
    FN_FUNCTIONS_ROOT = spaced_root,
    FN_RUNTIMES = "node",
  }, function()
    clear_route_cache()
    local spaced_catalog = routes.discover_functions(true)
    assert_true(type(spaced_catalog) == "table", "discover_functions handles root basename with spaces")
  end)

  local disabled_runtime_root = root .. "/disabled-runtime-root"
  rm_rf(disabled_runtime_root)
  mkdir_p(disabled_runtime_root)
  write_file(disabled_runtime_root .. "/fn.config.json", cjson.encode({
    runtime = "rust",
  }) .. "\n")
  write_file(disabled_runtime_root .. "/handler.js", "exports.handler = async () => ({ status: 200, body: 'disabled-runtime' });\n")
  with_env({
    FN_FUNCTIONS_ROOT = disabled_runtime_root,
    FN_RUNTIMES = "node",
  }, function()
    clear_route_cache()
    local disabled_catalog = routes.discover_functions(true)
    local root_name = disabled_runtime_root:match("([^/]+)$")
    assert_eq((((disabled_catalog.runtimes or {}).node or {}).functions or {})[root_name], nil, "discover_functions skips explicit root outside enabled runtimes")
  end)

  local duplicate_root = root .. "/duplicate-explicit-root"
  rm_rf(duplicate_root)
  mkdir_p(duplicate_root .. "/node/dup-name")
  mkdir_p(duplicate_root .. "/dup-source")
  write_file(duplicate_root .. "/node/dup-name/handler.js", "exports.handler = async () => ({ status: 200, body: 'runtime-dup' });\n")
  write_file(duplicate_root .. "/dup-source/fn.config.json", cjson.encode({
    runtime = "node",
    name = "dup-name",
  }) .. "\n")
  write_file(duplicate_root .. "/dup-source/handler.js", "exports.handler = async () => ({ status: 200, body: 'root-dup' });\n")
  with_env({
    FN_FUNCTIONS_ROOT = duplicate_root,
    FN_RUNTIMES = "node",
  }, function()
    clear_route_cache()
    local dup_catalog = routes.discover_functions(true)
    assert_true(type(dup_catalog) == "table", "discover_functions duplicate explicit root catalog")
    local dup_entry, dup_err = routes.resolve_function_entrypoint("node", "dup-name", nil)
    assert_true(dup_entry ~= nil, dup_err or "resolve_function_entrypoint runtime scoped duplicate wins")
    assert_true(dup_entry:find("/node/dup-name/handler.js", 1, true) ~= nil, "resolve_function_entrypoint keeps runtime scoped duplicate")
  end)

  local bogus_cfg_root = root .. "/bogus-cfg-root"
  rm_rf(bogus_cfg_root)
  mkdir_p(bogus_cfg_root)
  write_file(bogus_cfg_root .. "/handler.js", "exports.handler = async () => ({ status: 200, body: 'bogus-cfg' });\n")
  with_upvalue(discover_functions, "read_json_file", function(path)
    if path == bogus_cfg_root .. "/fn.config.json" then
      return "oops"
    end
    return discover_read_json_file(path)
  end, function()
    with_upvalue(discover_functions, "is_explicit_fn_config", function(obj)
      if obj == "oops" then
        return true
      end
      return discover_is_explicit_fn_config(obj)
    end, function()
      with_env({
        FN_FUNCTIONS_ROOT = bogus_cfg_root,
        FN_RUNTIMES = "node",
      }, function()
        clear_route_cache()
        local bogus_catalog = routes.discover_functions(true)
        assert_true(type(bogus_catalog) == "table", "discover_functions tolerates defensive non-table explicit cfg")
      end)
    end)
  end)

  local blank_name_root = root .. "/blank-name-root"
  rm_rf(blank_name_root)
  mkdir_p(blank_name_root)
  write_file(blank_name_root .. "/fn.config.json", cjson.encode({
    runtime = "node",
  }) .. "\n")
  write_file(blank_name_root .. "/handler.js", "exports.handler = async () => ({ status: 200, body: 'blank-name' });\n")
  with_upvalue(discover_functions, "basename", function(path)
    if path == blank_name_root then
      return ""
    end
    return discover_basename(path)
  end, function()
    with_env({
      FN_FUNCTIONS_ROOT = blank_name_root,
      FN_RUNTIMES = "node",
    }, function()
      clear_route_cache()
      local blank_catalog = routes.discover_functions(true)
      assert_true(type(blank_catalog) == "table", "discover_functions skips empty explicit root name")
    end)
  end)

  local invalid_name_root = root .. "/invalid-name-root"
  rm_rf(invalid_name_root)
  mkdir_p(invalid_name_root)
  write_file(invalid_name_root .. "/fn.config.json", cjson.encode({
    runtime = "node",
  }) .. "\n")
  write_file(invalid_name_root .. "/handler.js", "exports.handler = async () => ({ status: 200, body: 'invalid-name' });\n")
  with_upvalue(discover_functions, "basename", function(path)
    if path == invalid_name_root then
      return "../unsafe-name"
    end
    return discover_basename(path)
  end, function()
    with_env({
      FN_FUNCTIONS_ROOT = invalid_name_root,
      FN_RUNTIMES = "node",
    }, function()
      clear_route_cache()
      local invalid_name_catalog = routes.discover_functions(true)
      assert_true(type(invalid_name_catalog) == "table", "discover_functions handles unsafe basename fallback")
    end)
  end)

  local synthetic_relative_root = root .. "/synthetic-relative-root"
  local outside_relative_dir = root .. "/outside-relative-dir"
  rm_rf(synthetic_relative_root)
  rm_rf(outside_relative_dir)
  mkdir_p(synthetic_relative_root .. "/node")
  mkdir_p(outside_relative_dir)
  with_upvalue(discover_functions, "list_dirs", function(path)
    if path == synthetic_relative_root .. "/node" then
      return { "", synthetic_relative_root, outside_relative_dir }
    end
    return discover_list_dirs(path)
  end, function()
    with_upvalue(discover_functions, "basename", function(path)
      if path == "" then
        return "blank"
      end
      if path == synthetic_relative_root then
        return "root-alias"
      end
      if path == outside_relative_dir then
        return "outside-alias"
      end
      return discover_basename(path)
    end, function()
      with_upvalue(discover_functions, "has_single_entry_file", function(path)
        if path == "" or path == synthetic_relative_root or path == outside_relative_dir then
          return true
        end
        return discover_has_single_entry_file(path)
      end, function()
        with_upvalue(discover_functions, "read_json_file", function(path)
          if path == "/fn.config.json" or path == synthetic_relative_root .. "/fn.config.json" or path == outside_relative_dir .. "/fn.config.json" then
            return {}
          end
          return discover_read_json_file(path)
        end, function()
          with_env({
            FN_FUNCTIONS_ROOT = synthetic_relative_root,
            FN_RUNTIMES = "node",
          }, function()
            clear_route_cache()
            local synthetic_catalog = routes.discover_functions(true)
            assert_eq((((((synthetic_catalog.runtimes or {}).node or {}).functions or {}).blank or {}).source_dir), nil, "discover_functions handles empty function dir source")
            assert_eq((((((synthetic_catalog.runtimes or {}).node or {}).functions or {})["root-alias"] or {}).source_dir), ".", "discover_functions handles root source dir alias")
            assert_eq((((((synthetic_catalog.runtimes or {}).node or {}).functions or {})["outside-alias"] or {}).source_dir), nil, "discover_functions ignores source dirs outside functions root")
          end)
        end)
      end)
    end)
  end)
end

local function assert_parse_method_tokens(parse_method_and_tokens, base, expected_method, expected_explicit, expected_ambiguous, expected_first_part, label)
  local method, parts, explicit, ambiguous = parse_method_and_tokens(base)
  assert_eq(method, expected_method, label .. " method")
  assert_eq(explicit, expected_explicit, label .. " explicit")
  assert_eq(ambiguous, expected_ambiguous, label .. " ambiguous flag")
  assert_true(type(parts) == "table" and #parts >= 1, label .. " parts")
  if expected_first_part ~= nil then
    assert_eq(parts[1], expected_first_part, label .. " first part")
  end
end

local function assert_compiled_dynamic_route_pattern(compile_dynamic_route_pattern, route, expected_pattern, expected_names, label)
  local pattern, names = compile_dynamic_route_pattern(route)
  if expected_pattern ~= nil then
    assert_eq(pattern, expected_pattern, label .. " pattern")
  else
    assert_true(type(pattern) == "string", label .. " pattern type")
  end
  assert_true(type(names) == "table" and #names == expected_names, label .. " names")
  return pattern, names
end

local function test_gateway_utils()
  local utils = require("fastfn.core.gateway_utils")

  local n0, v0 = utils.parse_versioned_target(false)
  assert_eq(n0, nil, "parse invalid non-string name")
  assert_eq(v0, nil, "parse invalid non-string version")

  local name, version = utils.parse_versioned_target("/hello@v2")
  assert_eq(name, "hello", "parse versioned name")
  assert_eq(version, "v2", "parse version")

  local n2 = utils.parse_versioned_target("/hello")
  assert_eq(n2, nil, "parse invalid (no version)")

  local n3 = utils.parse_versioned_target("/fn/hello@v2")
  assert_eq(n3, nil, "parse invalid (/fn prefix)")

  local n4 = utils.parse_versioned_target("/bad/path")
  assert_eq(n4, nil, "parse invalid")

  assert_eq(utils.resolve_numeric("1500", nil, 2500, 999), 1500, "resolve version")
  assert_eq(utils.resolve_numeric(nil, "2200", 2500, 999), 2200, "resolve runtime")
  assert_eq(utils.resolve_numeric(nil, nil, "2500", 999), 2500, "resolve defaults")
  assert_eq(utils.resolve_numeric(nil, nil, nil, 999), 999, "resolve fallback")

  local s1, m1 = utils.map_runtime_error("timeout")
  assert_eq(s1, 504, "timeout status")
  assert_eq(m1, "runtime timeout", "timeout message")

  local s2 = utils.map_runtime_error("connect_error")
  assert_eq(s2, 503, "connect status")

  local s3 = utils.map_runtime_error("invalid_response")
  assert_eq(s3, 502, "invalid response status")

  local s4 = utils.map_runtime_error("other")
  assert_eq(s4, 502, "fallback status")
  local _, m4 = utils.map_runtime_error("other")
  assert_eq(m4, "runtime error", "fallback message")
end

local function test_fn_limits()
  local limits = require("fastfn.core.limits")

  local store = {}
  local dict = {
    incr = function(_, key, amount, init)
      if store[key] == nil then
        store[key] = init or 0
      end
      store[key] = store[key] + amount
      return store[key]
    end,
    get = function(_, key)
      return store[key]
    end,
    delete = function(_, key)
      store[key] = nil
    end,
  }

  local ok1, err1 = limits.try_acquire(dict, "python/hello@default", 2)
  assert_true(ok1, "first acquire")
  assert_eq(err1, nil, "first acquire err")

  local ok2 = limits.try_acquire(dict, "python/hello@default", 2)
  assert_true(ok2, "second acquire")

  local ok3, err3 = limits.try_acquire(dict, "python/hello@default", 2)
  assert_eq(ok3, false, "third acquire blocked")
  assert_eq(err3, "busy", "third acquire busy")

  limits.release(dict, "python/hello@default")
  local ok4 = limits.try_acquire(dict, "python/hello@default", 2)
  assert_true(ok4, "acquire after release")

  limits.release(dict, "python/hello@default")
  limits.release(dict, "python/hello@default")

  -- Worker pool semantics (per runtime/function/version key)
  local p1, s1 = limits.try_acquire_pool(dict, "node/slow@default", 1, 1)
  assert_true(p1, "pool first acquire")
  assert_eq(s1, "acquired", "pool first acquire state")

  local p2, s2 = limits.try_acquire_pool(dict, "node/slow@default", 1, 1)
  assert_eq(p2, false, "pool second should queue")
  assert_eq(s2, "queued", "pool queued state")

  local p3, s3 = limits.try_acquire_pool(dict, "node/slow@default", 1, 1)
  assert_eq(p3, false, "pool third should overflow")
  assert_eq(s3, "overflow", "pool overflow state")

  local wait_ok, wait_state = limits.wait_for_pool_slot(dict, "node/slow@default", 1, 20, 5)
  assert_eq(wait_ok, false, "pool queued wait timeout")
  assert_eq(wait_state, "queue_timeout", "pool timeout state")

  limits.release_pool(dict, "node/slow@default")
  local p4, s4 = limits.try_acquire_pool(dict, "node/slow@default", 1, 1)
  assert_true(p4, "pool acquire after release")
  assert_eq(s4, "acquired", "pool state after release")
  limits.release_pool(dict, "node/slow@default")

  local ok_unlimited = limits.try_acquire(dict, "python/free@default", 0)
  assert_true(ok_unlimited, "acquire should allow unlimited limit")

  local error_dict = {
    incr = function()
      return nil, "boom"
    end,
    delete = function() end,
  }
  local ok_err, err_err = limits.try_acquire(error_dict, "python/err@default", 1)
  assert_eq(ok_err, false, "acquire should fail on counter error")
  assert_true(type(err_err) == "string" and err_err:find("counter_error:boom", 1, true) ~= nil, "acquire counter error message")

  local pu, su = limits.try_acquire_pool(dict, "node/free@default", 0, 0)
  assert_eq(pu, true, "pool unlimited should acquire")
  assert_eq(su, "unlimited", "pool unlimited state")

  local pe, se = limits.try_acquire_pool(error_dict, "node/err@default", 1, 1)
  assert_eq(pe, false, "pool should fail on active counter error")
  assert_true(type(se) == "string" and se:find("counter_error:boom", 1, true) ~= nil, "pool active counter error message")

  local queue_error_dict = {
    incr = function(_, key)
      if tostring(key):find("pool:active:", 1, true) ~= nil then
        return 2
      end
      return nil, "queueboom"
    end,
    delete = function() end,
  }
  local pq, sq = limits.try_acquire_pool(queue_error_dict, "node/queueerr@default", 1, 1)
  assert_eq(pq, false, "pool should fail on queue counter error")
  assert_true(type(sq) == "string" and sq:find("counter_error:queueboom", 1, true) ~= nil, "pool queue counter error message")

  local wu, wus = limits.wait_for_pool_slot(dict, "node/free@default", 0, 10, 5)
  assert_eq(wu, true, "wait pool unlimited should pass")
  assert_eq(wus, "unlimited", "wait pool unlimited state")

  local wto, wtos = limits.wait_for_pool_slot(dict, "node/timeout@default", 1, 0, 5)
  assert_eq(wto, false, "wait pool zero timeout should fail")
  assert_eq(wtos, "queue_timeout", "wait pool zero timeout state")

  local wait_error_dict = {
    incr = function(_, key)
      if tostring(key):find("pool:active:", 1, true) ~= nil then
        return nil, "activeboom"
      end
      return 1
    end,
    delete = function() end,
  }
  local we, wes = limits.wait_for_pool_slot(wait_error_dict, "node/activeerr@default", 1, 5, 1)
  assert_eq(we, false, "wait pool should fail on active counter error")
  assert_true(type(wes) == "string" and wes:find("counter_error:activeboom", 1, true) ~= nil, "wait pool active counter error message")

  local wait_store = {}
  local wait_dict = {
    incr = function(_, key, amount, init)
      if wait_store[key] == nil then
        wait_store[key] = init or 0
      end
      wait_store[key] = wait_store[key] + amount
      return wait_store[key]
    end,
    delete = function(_, key)
      wait_store[key] = nil
    end,
  }
  local wa, was = limits.wait_for_pool_slot(wait_dict, "node/queued@default", 1, 20, 0)
  assert_eq(wa, true, "wait pool should acquire from queue when slot opens")
  assert_eq(was, "acquired_from_queue", "wait pool acquired from queue state")

  local overflow_dict = {
    incr = function(_, key)
      if tostring(key):find("pool:active:", 1, true) ~= nil then
        return 2
      end
      return 1
    end,
    delete = function() end,
  }
  local po, pos = limits.try_acquire_pool(overflow_dict, "node/noqueue@default", 1, 0)
  assert_eq(po, false, "pool overflow should trigger when queue disabled")
  assert_eq(pos, "overflow", "pool overflow state when queue disabled")

  local wh, whs = limits.wait_for_pool_slot(wait_dict, "node/highpoll@default", 1, 20, 999)
  assert_eq(wh, true, "wait pool high poll should still acquire")
  assert_eq(whs, "acquired_from_queue", "wait pool high poll acquired state")
end

local function test_invoke_rules()
  local rules = require("fastfn.core.invoke_rules")

  local methods = rules.parse_methods({ "get", "POST", "BAD", "post" })
  assert_true(type(methods) == "table", "methods table")
  assert_eq(methods[1], "GET", "parse methods get")
  assert_eq(methods[2], "POST", "parse methods post")
  assert_eq(methods[3], nil, "parse methods dedupe")

  local normalized = rules.normalized_methods(nil, { "GET" })
  assert_eq(normalized[1], "GET", "normalized fallback")
  local normalized_bad = rules.normalized_methods("??", { "POST" })
  assert_eq(normalized_bad[1], "POST", "normalized fallback when parse invalid")

  local methods_from_string = rules.parse_methods("get post delete unknown")
  assert_eq(methods_from_string[1], "GET", "parse methods string get")
  assert_eq(methods_from_string[2], "POST", "parse methods string post")
  assert_eq(methods_from_string[3], "DELETE", "parse methods string delete")

  assert_true(rules.route_is_reserved("/") == true, "reserved root route")
  assert_true(rules.route_is_reserved("/console/ui") == true, "reserved console route")
  assert_true(rules.route_is_reserved("/public") == false, "public route not reserved")

  assert_true(rules.normalize_route("/api/hello") == "/api/hello", "normalize valid route")
  assert_true(rules.normalize_route(nil) == nil, "normalize non-string route")
  assert_true(rules.normalize_route(" /api//hello// ") == "/api/hello", "normalize collapses duplicate and trailing slash")
  assert_true(rules.normalize_route("api/hello") == nil, "normalize invalid route")
  assert_true(rules.normalize_route("/_fn/health") == nil, "normalize reserved route")
  assert_true(rules.normalize_route("/api/../bad") == nil, "normalize rejects dot-dot traversal")
  assert_true(rules.normalize_route("/api/%.%./bad") == "/api/%.%./bad", "normalize allows literal percent-dot sequences")

  local list_limited = rules.parse_route_list({ "/a", "/b", "/c" }, 2)
  assert_eq(#list_limited, 2, "route list max items")
  assert_eq(list_limited[1], "/a", "route list first")
  assert_eq(list_limited[2], "/b", "route list second")

  local list_string = rules.parse_route_list("/single")
  assert_eq(#list_string, 1, "route list string count")
  assert_eq(list_string[1], "/single", "route list string value")

  local invoke_routes = rules.parse_invoke_routes({ route = "/api/a", routes = { "/api/a", "/api/b" } })
  assert_eq(invoke_routes[1], "/api/a", "invoke routes first")
  assert_eq(invoke_routes[2], "/api/b", "invoke routes second")

  local invoke_invalid = rules.parse_invoke_routes({ route = "/_fn/hidden", routes = { "bad" } })
  assert_true(type(invoke_invalid) == "table" and #invoke_invalid == 0, "invoke routes invalid but explicit should return empty list")

  local invoke_none = rules.parse_invoke_routes({})
  assert_eq(invoke_none, nil, "invoke routes missing should return nil")
  assert_eq(rules.parse_invoke_routes("bad"), nil, "invoke routes non-table should return nil")
end

local function test_home_rules()
  local cjson = require("cjson.safe")
  local home = require("fastfn.core.home")

  local uniq = tostring(math.floor((ngx and ngx.now and ngx.now() or os.time()) * 1000000))
  local root = "/tmp/fastfn-lua-home-" .. uniq
  rm_rf(root)
  mkdir_p(root)

  with_env({ FN_HOME_FUNCTION = "/landing", FN_HOME_REDIRECT = false }, function()
    local action = home.resolve_home_action(root)
    assert_eq(action.mode, "function", "home env function mode")
    assert_eq(action.path, "/landing", "home env function path")
    assert_eq(action.source, "env:FN_HOME_FUNCTION", "home env function source")
  end)

  with_env({ FN_HOME_FUNCTION = "portal/dashboard?tab=main", FN_HOME_REDIRECT = false }, function()
    local action = home.resolve_home_action(root)
    assert_eq(action.mode, "function", "home env relative mode")
    assert_eq(action.path, "/portal/dashboard", "home env relative path")
    assert_eq(action.args, "tab=main", "home env relative args")
  end)

  with_env({ FN_HOME_FUNCTION = "/", FN_HOME_REDIRECT = "/_fn/docs" }, function()
    local action = home.resolve_home_action(root)
    assert_eq(action.mode, "redirect", "home fallback to redirect when function invalid")
    assert_eq(action.location, "/_fn/docs", "home fallback redirect location")
  end)

  with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = "https://example.com/docs" }, function()
    local action = home.resolve_home_action(root)
    assert_eq(action.mode, "redirect", "home env external redirect mode")
    assert_eq(action.location, "https://example.com/docs", "home env external redirect location")
  end)

  write_file(
    root .. "/fn.config.json",
    cjson.encode({
      home = {
        route = "welcome",
      },
    }) .. "\n"
  )

  with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = false }, function()
    local action = home.resolve_home_action(root)
    assert_eq(action.mode, "function", "home config route mode")
    assert_eq(action.path, "/welcome", "home config route path")
    assert_eq(action.source, "config:fn.config.json", "home config source")
  end)

  write_file(
    root .. "/fn.config.json",
    cjson.encode({
      home = {
        redirect = "/_fn/docs",
      },
    }) .. "\n"
  )

  with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = false }, function()
    local action = home.resolve_home_action(root)
    assert_eq(action.mode, "redirect", "home config redirect mode")
    assert_eq(action.location, "/_fn/docs", "home config redirect location")
  end)

  local invoke_home = home.extract_home_spec({
    invoke = {
      home = {
        route = "dashboard",
      },
    },
  })
  assert_eq(invoke_home.home_function, "dashboard", "extract invoke.home route")

  local invoke_home_alias = home.extract_home_spec({
    invoke = {
      home_route = "admin",
    },
  })
  assert_eq(invoke_home_alias.home_function, "admin", "extract invoke.home_route alias")

  local home_string = home.extract_home_spec({ home = "landing" })
  assert_eq(home_string.home_function, "landing", "extract home string")

  local home_redirect = home.extract_home_spec({ home = { url = "https://example.com" } })
  assert_eq(home_redirect.home_redirect, "https://example.com", "extract home redirect url")
  assert_eq(home.extract_home_spec(nil), nil, "extract home nil config")

  local normalize_local_target = get_upvalue(home.resolve_home_action, "normalize_local_target")
  local normalize_redirect_target = get_upvalue(home.resolve_home_action, "normalize_redirect_target")
  assert_true(type(normalize_local_target) == "function", "home normalize_local_target helper")
  assert_true(type(normalize_redirect_target) == "function", "home normalize_redirect_target helper")
  local lp, _la, le = normalize_local_target("")
  assert_eq(lp, nil, "normalize_local_target empty path")
  assert_eq(le, "empty", "normalize_local_target empty error")
  local rl, re = normalize_redirect_target("")
  assert_eq(rl, nil, "normalize_redirect_target empty location")
  assert_eq(re, "empty", "normalize_redirect_target empty error")

  with_env({ FN_HOME_FUNCTION = "https://example.com/bad", FN_HOME_REDIRECT = "/" }, function()
    local action = home.resolve_home_action(root .. "/missing")
    assert_eq(action.mode, "default", "invalid env values should fallback to default")
    assert_eq(action.source, "builtin", "invalid env fallback source")
    assert_true(type(action.warnings) == "table" and #action.warnings >= 2, "invalid env should emit warnings")
  end)

  write_file(root .. "/fn.config.json", "{bad json")
  with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = false }, function()
    local action = home.resolve_home_action(root)
    assert_eq(action.mode, "default", "invalid config json should fallback to default")
    assert_eq(action.source, "builtin", "invalid config source builtin")
  end)

  with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = false, FN_FUNCTIONS_ROOT = false }, function()
    local action = home.resolve_home_action("")
    assert_eq(action.mode, "default", "empty root should fallback to default")
    assert_eq(action.source, "builtin", "empty root source builtin")
  end)

  with_env({ FN_HOME_FUNCTION = "?tab=1", FN_HOME_REDIRECT = false, FN_FUNCTIONS_ROOT = false }, function()
    local action = home.resolve_home_action("")
    assert_eq(action.mode, "default", "missing path env function should fallback")
    assert_true(type(action.warnings) == "table" and #action.warnings >= 1, "missing path warning expected")
  end)

  with_env({ FN_HOME_FUNCTION = "/admin/../panel", FN_HOME_REDIRECT = false, FN_FUNCTIONS_ROOT = false }, function()
    local action = home.resolve_home_action("")
    assert_eq(action.mode, "default", "invalid path env function should fallback")
    assert_true(type(action.warnings) == "table" and #action.warnings >= 1, "invalid path warning expected")
  end)

  with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = "/guide?tab=intro", FN_FUNCTIONS_ROOT = false }, function()
    local action = home.resolve_home_action("")
    assert_eq(action.mode, "redirect", "redirect with query should be accepted")
    assert_eq(action.location, "/guide?tab=intro", "redirect query should be preserved")
  end)

  write_file(root .. "/fn.config.json", "")
  with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = false }, function()
    local action = home.resolve_home_action(root)
    assert_eq(action.mode, "default", "empty config file should fallback to default")
  end)

  write_file(
    root .. "/fn.config.json",
    cjson.encode({
      home = {
        ["function"] = "?config-bad",
        redirect = "/",
      },
    }) .. "\n"
  )
  with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = false }, function()
    local action = home.resolve_home_action(root)
    assert_eq(action.mode, "default", "invalid config home targets should fallback")
    assert_true(type(action.warnings) == "table" and #action.warnings >= 2, "invalid config should emit warnings")
  end)

  rm_rf(root)
end

local function test_openapi_builder()
  local openapi = require("fastfn.core.openapi")
  local function find_param(params, name)
    for _, p in ipairs(params or {}) do
      if p.name == name then
        return p
      end
    end
    return nil
  end
  local function has_required(schema, key)
    for _, name in ipairs((schema and schema.required) or {}) do
      if name == key then
        return true
      end
    end
    return false
  end

  local spec = openapi.build({
    runtimes = {
      python = {
        functions = {
          hello = { has_default = true, versions = { "v2" }, policy = { methods = { "GET" } }, versions_policy = { v2 = { methods = { "GET" } } } },
          ["risk-score"] = { has_default = true, versions = {}, policy = { methods = { "GET", "POST" } }, versions_policy = {} },
        },
      },
      node = {
        functions = {
          hello = { has_default = true, versions = {}, policy = { methods = { "GET" } }, versions_policy = {} },
        },
      },
      php = {
        functions = {
          ["php-profile"] = { has_default = true, versions = {}, policy = { methods = { "GET" } }, versions_policy = {} },
        },
      },
      rust = {
        functions = {
          ["rust-profile"] = { has_default = true, versions = {}, policy = { methods = { "GET" } }, versions_policy = {} },
        },
      },
    },
    mapped_routes = {
      ["/api/hello"] = {
        { runtime = "python", fn_name = "hello", version = nil, methods = { "GET" } },
      },
      ["/api/hello-v2"] = {
        { runtime = "python", fn_name = "hello", version = "v2", methods = { "GET" } },
      },
      ["/api/dispatch"] = {
        { runtime = "python", fn_name = "hello", version = nil, methods = { "GET" } },
        { runtime = "python", fn_name = "risk-score", version = nil, methods = { "POST" } },
      },
      ["/api/users/:id"] = {
        { runtime = "python", fn_name = "risk-score", version = nil, methods = { "GET" } },
      },
      ["/api/blog/:slug*"] = {
        { runtime = "python", fn_name = "hello", version = nil, methods = { "GET" } },
      },
    },
  }, {
    server_url = "http://localhost:8080",
    title = "Test API",
    version = "test",
    include_internal = true,
  })

  assert_eq(spec.openapi, "3.1.0", "openapi version")
  assert_eq(spec.info.title, "Test API", "openapi title")
  assert_eq(spec.info.version, "test", "openapi info version")

  for p, _ in pairs(spec.paths or {}) do
    assert_true(type(p) ~= "string" or p:sub(1, 4) ~= "/fn/", "OpenAPI must not export /fn/* routes")
  end
  assert_true(spec.paths["/api/hello"] ~= nil, "mapped route path")
  assert_true(spec.paths["/api/hello-v2"] ~= nil, "mapped version route path")
  assert_true(spec.paths["/api/dispatch"] ~= nil, "mapped route multi-entry path")
  assert_true(spec.paths["/api/users/{id}"] ~= nil, "mapped dynamic route path")
  assert_true(spec.paths["/api/blog/{slug}"] ~= nil, "mapped catch-all route path")
  assert_true(spec.paths["/api/users/:id"] == nil, "colon dynamic path should not be exported")
  assert_true(spec.paths["/_fn/health"] ~= nil, "health path")
  assert_true(spec.paths["/_fn/reload"] ~= nil, "reload path")
  assert_true(spec.paths["/_fn/reload"].get ~= nil, "reload get exists")
  assert_true(spec.paths["/_fn/reload"].post ~= nil, "reload post exists")
  assert_true(spec.paths["/_fn/schedules"] ~= nil, "schedules path")
  assert_true(spec.paths["/_fn/ui-state"] ~= nil, "ui-state path")
  assert_true(spec.paths["/_fn/ui-state"].post ~= nil, "ui-state post exists")
  assert_true(spec.paths["/_fn/ui-state"].patch ~= nil, "ui-state patch exists")
  assert_true(spec.paths["/_fn/ui-state"].delete ~= nil, "ui-state delete exists")
  assert_true(spec.paths["/api/hello"].get.summary:find("python/hello", 1, true) ~= nil, "mapped summary includes target")
  assert_true(type(spec.paths["/api/hello"].get.tags) == "table", "mapped tags exists")
  assert_eq(spec.paths["/api/hello"].get.tags[1], "functions", "mapped tags primary")
  assert_eq(spec.paths["/api/hello"].get.tags[2], nil, "mapped tags should avoid file/function tag fanout")
  assert_true(spec.paths["/api/hello"].get.summary:find("unknown/unknown", 1, true) == nil, "mapped summary should not be unknown")
  assert_true(spec.paths["/api/dispatch"].get.summary:find("python/hello", 1, true) ~= nil, "dispatch GET target summary")
  assert_true(spec.paths["/api/dispatch"].post.summary:find("python/risk-score", 1, true) ~= nil, "dispatch POST target summary")
  assert_true(spec.paths["/api/users/{id}"].get.parameters ~= nil, "dynamic route should expose path parameters")
  assert_eq(spec.paths["/api/users/{id}"].get.parameters[1].name, "id", "dynamic path param name")
  assert_eq(spec.paths["/api/users/{id}"].get.parameters[1]["in"], "path", "dynamic path param in")
  assert_true(spec.paths["/api/blog/{slug}"].get.parameters ~= nil, "catch-all route should expose path parameters")
  assert_eq(spec.paths["/api/blog/{slug}"].get.parameters[1].name, "slug", "catch-all param name")

  local fn_get_runtime = find_param(spec.paths["/_fn/function"].get.parameters, "runtime")
  local fn_get_name = find_param(spec.paths["/_fn/function"].get.parameters, "name")
  local fn_get_version = find_param(spec.paths["/_fn/function"].get.parameters, "version")
  local fn_get_include = find_param(spec.paths["/_fn/function"].get.parameters, "include_code")
  assert_true(fn_get_runtime ~= nil and fn_get_runtime["in"] == "query" and fn_get_runtime.required == true, "function get runtime query param")
  assert_true(fn_get_name ~= nil and fn_get_name["in"] == "query" and fn_get_name.required == true, "function get name query param")
  assert_true(fn_get_version ~= nil and fn_get_version["in"] == "query" and fn_get_version.required == false, "function get version query param")
  assert_true(fn_get_include ~= nil and fn_get_include["in"] == "query", "function get include_code query param")
  assert_eq(fn_get_include.schema.default, "1", "function get include_code default")

  local cfg_put_runtime = find_param(spec.paths["/_fn/function-config"].put.parameters, "runtime")
  local cfg_put_name = find_param(spec.paths["/_fn/function-config"].put.parameters, "name")
  assert_true(cfg_put_runtime ~= nil and cfg_put_runtime.required == true, "function-config put runtime required")
  assert_true(cfg_put_name ~= nil and cfg_put_name.required == true, "function-config put name required")

  local logs_file = find_param(spec.paths["/_fn/logs"].get.parameters, "file")
  local logs_lines = find_param(spec.paths["/_fn/logs"].get.parameters, "lines")
  local logs_format = find_param(spec.paths["/_fn/logs"].get.parameters, "format")
  local logs_runtime = find_param(spec.paths["/_fn/logs"].get.parameters, "runtime")
  local logs_fn = find_param(spec.paths["/_fn/logs"].get.parameters, "fn")
  local logs_version = find_param(spec.paths["/_fn/logs"].get.parameters, "version")
  local logs_stream = find_param(spec.paths["/_fn/logs"].get.parameters, "stream")
  assert_true(logs_file ~= nil and logs_file["in"] == "query", "logs file query param")
  assert_true(logs_lines ~= nil and logs_lines["in"] == "query", "logs lines query param")
  assert_true(logs_format ~= nil and logs_format["in"] == "query", "logs format query param")
  assert_true(logs_runtime ~= nil and logs_runtime["in"] == "query", "logs runtime query param")
  assert_true(logs_fn ~= nil and logs_fn["in"] == "query", "logs fn query param")
  assert_true(logs_version ~= nil and logs_version["in"] == "query", "logs version query param")
  assert_true(logs_stream ~= nil and logs_stream["in"] == "query", "logs stream query param")
  assert_eq(logs_file.schema.default, "error", "logs file default")
  assert_eq(logs_lines.schema.default, 200, "logs lines default")
  assert_eq(logs_format.schema.default, "text", "logs format default")
  assert_eq(logs_stream.schema.default, "all", "logs stream default")

  local jobs_limit = find_param(spec.paths["/_fn/jobs"].get.parameters, "limit")
  assert_true(jobs_limit ~= nil and jobs_limit["in"] == "query", "jobs limit query param")
  assert_eq(jobs_limit.schema.default, 50, "jobs limit default")

  local jobs_post_schema = spec.paths["/_fn/jobs"].post.requestBody.content["application/json"].schema
  assert_true(has_required(jobs_post_schema, "runtime"), "jobs enqueue runtime required")
  assert_true(has_required(jobs_post_schema, "name"), "jobs enqueue name required")
  assert_eq((jobs_post_schema.properties.method or {}).default, "GET", "jobs enqueue method default")
  assert_eq((jobs_post_schema.properties.max_attempts or {}).default, 1, "jobs enqueue max_attempts default")
  assert_eq((jobs_post_schema.properties.retry_delay_ms or {}).default, 1000, "jobs enqueue retry_delay default")
  assert_true(jobs_post_schema.properties.route ~= nil, "jobs enqueue route field")
  assert_true(jobs_post_schema.properties.params ~= nil, "jobs enqueue params field")
  assert_true(spec.paths["/_fn/jobs/{id}/result"].get.responses["202"] ~= nil, "jobs result pending response")

  local invoke_schema = spec.paths["/_fn/invoke"].post.requestBody.content["application/json"].schema
  assert_true(has_required(invoke_schema, "runtime"), "invoke runtime required")
  assert_true(has_required(invoke_schema, "name"), "invoke name required")
  assert_eq((invoke_schema.properties.method or {}).default, "GET", "invoke method default")
  assert_true(invoke_schema.properties.route ~= nil, "invoke route field")
  assert_true(invoke_schema.properties.params ~= nil, "invoke params field")
end

local function test_openapi_internal_helpers_and_public_mode()
  local openapi = require("fastfn.core.openapi")

  local route_to_openapi_path_and_parameters = get_upvalue(openapi.build, "route_to_openapi_path_and_parameters")
  local mapped_route_entries = get_upvalue(openapi.build, "mapped_route_entries")
  local operation_template = get_upvalue(openapi.build, "operation_template")
  local build_request_body = get_upvalue(operation_template, "build_request_body")
  local append_query_parameters = get_upvalue(operation_template, "append_query_parameters")
  local methods_operations = get_upvalue(openapi.build, "methods_operations")

  assert_true(type(route_to_openapi_path_and_parameters) == "function", "openapi route helper")
  assert_true(type(mapped_route_entries) == "function", "openapi mapped entry helper")
  assert_true(type(operation_template) == "function", "openapi operation helper")
  assert_true(type(build_request_body) == "function", "openapi request body helper")
  assert_true(type(append_query_parameters) == "function", "openapi query helper")

  local p0, params0 = route_to_openapi_path_and_parameters("")
  assert_eq(p0, nil, "empty route maps to nil")
  assert_true(type(params0) == "table" and #params0 == 0, "empty route params")

  local p1, params1 = route_to_openapi_path_and_parameters("/")
  assert_eq(p1, "/", "root route maps to root")
  assert_true(type(params1) == "table" and #params1 == 0, "root route params")

  local p2, params2 = route_to_openapi_path_and_parameters("/api/*/*/:id")
  assert_eq(p2, "/api/{wildcard}/{wildcard2}/{id}", "wildcard route conversion")
  assert_true(type(params2) == "table" and #params2 == 3, "wildcard route params count")
  assert_eq(params2[1].name, "wildcard", "first wildcard name")
  assert_eq(params2[2].name, "wildcard2", "second wildcard name")
  assert_eq(params2[3].name, "id", "named path parameter")
  local p3, _ = route_to_openapi_path_and_parameters("/api/*/*/*")
  assert_eq(p3, "/api/{wildcard}/{wildcard2}/{wildcard3}", "third wildcard should increment suffix")
  local p4, _ = route_to_openapi_path_and_parameters("////")
  assert_eq(p4, "/", "all-slashes route maps to root")

  local entries_nil = mapped_route_entries(nil)
  assert_true(type(entries_nil) == "table" and #entries_nil == 0, "mapped entries nil")
  local entries_compat = mapped_route_entries({ runtime = "node", fn_name = "demo", methods = { "GET" } })
  assert_true(type(entries_compat) == "table" and #entries_compat == 1, "mapped entries compat shape")
  local entries_array = mapped_route_entries({ "bad", { runtime = "node", fn_name = "demo2", methods = { "POST" } } })
  assert_true(type(entries_array) == "table" and #entries_array == 1, "mapped entries array shape")

  local body_get = build_request_body("get", {})
  assert_eq(body_get, nil, "GET should not build request body")
  local body_default = build_request_body("post", nil)
  assert_true(type(body_default) == "table", "default body for write methods")
  local body_default_empty = build_request_body("post", { body_example = "" })
  assert_true(type(body_default_empty) == "table", "empty body example falls back to default body")

  local original_math_type = math.type
  math.type = function()
    return "integer"
  end
  local body_integer = build_request_body("post", {
    body_example = "2",
    content_type = "application/json",
  })
  math.type = original_math_type
  assert_eq(body_integer.content["application/json"].schema.type, "integer", "math.type integer branch")

  local body_json = build_request_body("post", {
    body_example = " {\"ok\":true} ",
    content_type = "application/json",
  })
  assert_eq(body_json.content["application/json"].schema.type, "object", "json body schema")

  local body_json_non_string = build_request_body("patch", {
    body_example = { ok = true, list = { 1, 2 } },
    content_type = "application/json",
  })
  assert_eq(body_json_non_string.content["application/json"].schema.type, "object", "json object body schema")
  local body_json_whitespace = build_request_body("patch", {
    body_example = "    ",
    content_type = "application/json",
  })
  assert_eq(body_json_whitespace.content["application/json"].examples.primary.value, "    ", "blank json body kept as raw")
  local body_json_invalid = build_request_body("patch", {
    body_example = "{bad-json",
    content_type = "application/json",
  })
  assert_eq(body_json_invalid.content["application/json"].examples.primary.value, "{bad-json", "invalid json body kept as raw")

  local body_text = build_request_body("put", {
    body_example = { ok = true },
    content_type = "text/plain",
  })
  assert_eq(body_text.content["text/plain"].schema.type, "string", "non-json body schema")
  local body_text_coerce = build_request_body("delete", {
    body_example = io.stdout,
    content_type = "text/plain",
  })
  assert_true(type(body_text_coerce.content["text/plain"].examples.primary.value) == "string", "non-json fallback tostring branch")

  local body_json_default_type = build_request_body("post", {
    body_example = "{\"ok\":true}",
    content_type = "   ",
  })
  assert_eq(body_json_default_type.content["application/json"].schema.type, "object", "blank content-type defaults to json")

  local op = { parameters = { { name = "present", ["in"] = "query" } } }
  append_query_parameters(op, {
    query_example = {
      present = "keep",
      flag = true,
      count = 2,
      ratio = 2.5,
      payload = { nested = "ok" },
      items = { 1, 2 },
    },
  })
  assert_true(type(op.parameters) == "table" and #op.parameters >= 6, "query params appended")

  local templ = operation_template("node", "demo", nil, "post", {}, {
    summary = "  custom summary  ",
    body_example = "x",
    content_type = "text/plain",
  })
  assert_eq(templ.summary, "POST custom summary", "operation summary override")
  assert_true(type(templ.requestBody) == "table", "operation request body exists")

  if type(methods_operations) == "function" then
    local ops = methods_operations("node", "hello", nil, { "GET", "POST" }, {}, function()
      return {
        query_example = { name = "world" },
        body_example = "{\"hello\":\"world\"}",
        content_type = "application/json",
      }
    end)
    assert_true(type(ops) == "table" and ops.get ~= nil and ops.post ~= nil, "methods_operations helper")
  end

  local spec_public = openapi.build({
    runtimes = {
      node = {
        functions = {
          demo = {
            has_default = true,
            versions = {},
            policy = { methods = { "GET", "POST" } },
            versions_policy = {},
          },
        },
      },
    },
    mapped_routes = {
      ["/public/:id/*"] = { runtime = "node", fn_name = "demo", version = nil, methods = { "GET", "POST" } },
    },
  }, {
    include_internal = false,
    invoke_meta_lookup = function(runtime, name, version)
      return {
        summary = runtime .. ":" .. name .. ":" .. tostring(version or "default"),
        query_example = {
          active = true,
          tries = 3,
          ratio = 2.25,
          payload = { nested = "ok" },
          list = { 1, 2 },
        },
        body_example = "{\"demo\":true}",
        content_type = "application/json",
      }
    end,
  })

  assert_true(spec_public.paths["/_fn/health"] == nil, "public mode strips internal paths")
  assert_true(type(spec_public.tags) == "table" and #spec_public.tags == 1, "public mode strips internal tag")
  assert_true(spec_public.paths["/public/{id}/{wildcard}"] ~= nil, "public mapped route exists")
  assert_true(spec_public.paths["/public/{id}/{wildcard}"].get ~= nil, "public GET route exists")
  assert_true(spec_public.paths["/public/{id}/{wildcard}"].post ~= nil, "public POST route exists")
end

local function test_ui_state_endpoint_guards()
  local original_ngx = _G.ngx
  local original_guard = package.loaded["fastfn.console.guard"]

  local calls = { enforce_api = 0, enforce_write = 0, write_json = 0 }
  package.loaded["fastfn.console.guard"] = {
    enforce_api = function()
      calls.enforce_api = calls.enforce_api + 1
      return true
    end,
    enforce_write = function()
      calls.enforce_write = calls.enforce_write + 1
      return false
    end,
    state_snapshot = function()
      return { ui_enabled = true }
    end,
    clear_state = function()
      return { ui_enabled = true }
    end,
    update_state = function()
      return { ui_enabled = true }
    end,
    write_json = function(status)
      calls.write_json = calls.write_json + 1
      calls.last_status = status
    end,
  }

  _G.ngx = {
    req = {
      get_method = function() return "PUT" end,
      read_body = function() end,
      get_body_data = function() return "{}" end,
    },
  }
  dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  assert_eq(calls.enforce_api, 1, "ui-state should enforce api")
  assert_eq(calls.enforce_write, 1, "ui-state should enforce write on mutating methods")
  assert_eq(calls.write_json, 0, "ui-state should stop when write guard denies")

  calls.enforce_api = 0
  calls.enforce_write = 0
  calls.write_json = 0
  _G.ngx.req.get_method = function() return "GET" end
  dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  assert_eq(calls.enforce_api, 1, "ui-state get should enforce api")
  assert_eq(calls.enforce_write, 0, "ui-state get should not enforce write")
  assert_eq(calls.write_json, 1, "ui-state get should return snapshot")
  assert_eq(calls.last_status, 200, "ui-state get status")

  package.loaded["fastfn.console.guard"] = original_guard
  _G.ngx = original_ngx
end

local function test_ui_state_endpoint_full_behavior()
  with_fake_ngx(function(cache, _conc, _set_now)
    local cjson = require("cjson.safe")

    with_module_stubs({
      ["fastfn.console.auth"] = {
        login_enabled = function()
          return false
        end,
        api_login_enabled = function()
          return false
        end,
        read_session = function()
          return nil
        end,
      },
    }, function()
      reset_shared_dict(cache)

      package.loaded["fastfn.console.guard"] = nil
      require("fastfn.console.guard")

      local out = ""
      ngx.say = function(s)
        out = out .. tostring(s)
      end
      ngx.req.read_body = function() end
      ngx.req.get_headers = function()
        return { ["x-fn-admin-token"] = "secret" }
      end

      with_env({
        FN_CONSOLE_API_ENABLED = "1",
        FN_ADMIN_API_ENABLED = "1",
        FN_CONSOLE_WRITE_ENABLED = "1",
        FN_CONSOLE_LOCAL_ONLY = "1",
        FN_ADMIN_TOKEN = "secret",
      }, function()
        -- Method not allowed
        out = ""
        ngx.status = 0
        ngx.req.get_method = function()
          return "OPTIONS"
        end
        dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
        assert_eq(ngx.status, 405, "ui-state method not allowed status")
        assert_true((cjson.decode(out) or {}).error == "method not allowed", "ui-state method not allowed error")

        -- GET snapshot
        out = ""
        ngx.status = 0
        ngx.req.get_method = function()
          return "GET"
        end
        dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
        assert_eq(ngx.status, 200, "ui-state get status")
        assert_true(type((cjson.decode(out) or {}).api_enabled) == "boolean", "ui-state snapshot shape")

        -- PUT invalid JSON
        out = ""
        ngx.status = 0
        ngx.req.get_method = function()
          return "PUT"
        end
        ngx.req.get_body_data = function()
          return "{bad"
        end
        dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
        assert_eq(ngx.status, 400, "ui-state invalid json status")
        assert_true((cjson.decode(out) or {}).error == "invalid json body", "ui-state invalid json error")

        -- PUT update_state
        out = ""
        ngx.status = 0
        ngx.req.get_method = function()
          return "PUT"
        end
        ngx.req.get_body_data = function()
          return "{\"ui_enabled\":true}"
        end
        dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
        assert_eq(ngx.status, 200, "ui-state put status")
        assert_eq((cjson.decode(out) or {}).ui_enabled, true, "ui-state put updates state")

        -- DELETE clear_state
        out = ""
        ngx.status = 0
        ngx.req.get_method = function()
          return "DELETE"
        end
        dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
        assert_eq(ngx.status, 200, "ui-state delete status")
      end)
    end)
  end)
end

local function test_ui_state_endpoint_error_paths()
  local original_ngx = _G.ngx
  local original_guard = package.loaded["fastfn.console.guard"]

  local calls = {}
  package.loaded["fastfn.console.guard"] = {
    enforce_api = function()
      return false
    end,
    enforce_write = function()
      return true
    end,
    enforce_body_limit = function()
      return true
    end,
    state_snapshot = function()
      return { ok = true }
    end,
    clear_state = function()
      return nil, "clear failed"
    end,
    update_state = function()
      return nil, "update failed"
    end,
    write_json = function(status, payload)
      calls[#calls + 1] = { status = status, payload = payload }
    end,
  }

  _G.ngx = {
    req = {
      get_method = function()
        return "GET"
      end,
      read_body = function() end,
      get_body_data = function()
        return "{}"
      end,
    },
  }

  dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  assert_eq(#calls, 0, "ui-state should stop when enforce_api fails")

  package.loaded["fastfn.console.guard"].enforce_api = function()
    return true
  end

  _G.ngx.req.get_method = function()
    return "DELETE"
  end
  dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  assert_eq(calls[#calls].status, 500, "ui-state should return 500 when clear_state fails")

  _G.ngx.req.get_method = function()
    return "PATCH"
  end
  dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  assert_eq(calls[#calls].status, 400, "ui-state should return 400 when update_state fails")

  package.loaded["fastfn.console.guard"] = original_guard
  _G.ngx = original_ngx
end

local function test_console_guard_state_snapshot_current_user()
  with_fake_ngx(function()
    with_module_stubs({
      ["fastfn.console.auth"] = {
        login_enabled = function() return true end,
        api_login_enabled = function() return true end,
        read_session = function() return { user = "qa-user", exp = 999999 } end,
      },
    }, function()
      package.loaded["fastfn.console.guard"] = nil
      local guard = require("fastfn.console.guard")

      local snap = guard.state_snapshot()
      assert_eq(snap.login_enabled, true, "guard snapshot login_enabled")
      assert_eq(snap.login_api_enabled, true, "guard snapshot login_api_enabled")
      assert_eq(snap.current_user, "qa-user", "guard snapshot current_user")

      package.loaded["fastfn.console.guard"] = nil
    end)
  end)
end

local function test_console_guard_enforcement_and_state_overrides()
  with_fake_ngx(function(cache, _conc, _set_now)
    local cjson = require("cjson.safe")

    with_module_stubs({
      ["fastfn.console.auth"] = {
        login_enabled = function()
          return true
        end,
        api_login_enabled = function()
          return true
        end,
        read_session = function()
          return nil
        end,
      },
    }, function()
      package.loaded["fastfn.console.guard"] = nil
      local guard = require("fastfn.console.guard")

      local out = ""
      ngx.say = function(s)
        out = out .. tostring(s)
      end
      ngx.req.get_headers = function()
        return {}
      end

      local function last_error()
        local decoded = cjson.decode(out) or {}
        return decoded.error
      end

      reset_shared_dict(cache)

      with_env({ FN_CONSOLE_API_ENABLED = "0" }, function()
        out = ""
        ngx.status = 0
        local ok = guard.enforce_api()
        assert_eq(ok, false, "api disabled must block")
        assert_eq(ngx.status, 404, "api disabled status")
        assert_eq(last_error(), "console api disabled", "api disabled error")
      end)

      with_env({ FN_CONSOLE_API_ENABLED = "1", FN_ADMIN_API_ENABLED = "0" }, function()
        out = ""
        ngx.status = 0
        local ok = guard.enforce_api()
        assert_eq(ok, false, "admin api disabled must block")
        assert_eq(ngx.status, 404, "admin api disabled status")
        assert_eq(last_error(), "admin api disabled", "admin api disabled error")
      end)

      with_env({ FN_CONSOLE_API_ENABLED = "1", FN_ADMIN_API_ENABLED = "1", FN_ADMIN_TOKEN = "secret" }, function()
        out = ""
        ngx.status = 0
        ngx.var.remote_addr = "8.8.8.8"
        local ok = guard.enforce_api()
        assert_eq(ok, false, "local-only must block non-local without token")
        assert_eq(ngx.status, 403, "local-only status")
        assert_eq(last_error(), "console api local-only", "local-only error")
      end)

      with_env({ FN_CONSOLE_API_ENABLED = "1", FN_ADMIN_API_ENABLED = "1", FN_ADMIN_TOKEN = "secret", FN_CONSOLE_LOCAL_ONLY = "0" }, function()
        out = ""
        ngx.status = 0
        ngx.var.remote_addr = "127.0.0.1"
        local ok = guard.enforce_api()
        assert_eq(ok, false, "login api enabled must require session or token")
        assert_eq(ngx.status, 401, "login required status")
        assert_eq(last_error(), "login required", "login required error")
      end)

      with_env({ FN_CONSOLE_API_ENABLED = "1", FN_ADMIN_API_ENABLED = "1", FN_ADMIN_TOKEN = "secret" }, function()
        out = ""
        ngx.status = 0
        ngx.var.remote_addr = "8.8.8.8"
        ngx.req.get_headers = function()
          return { ["x-fn-admin-token"] = "secret" }
        end
        local ok = guard.enforce_api()
        assert_eq(ok, true, "admin token bypasses local-only/login")
      end)

      -- Write enforcement: no admin token, write disabled (default false).
      with_env({ FN_ADMIN_TOKEN = "secret", FN_CONSOLE_WRITE_ENABLED = "0", FN_CONSOLE_LOCAL_ONLY = "0" }, function()
        out = ""
        ngx.status = 0
        ngx.req.get_headers = function()
          return {}
        end
        local ok = guard.enforce_write()
        assert_eq(ok, false, "write disabled must block without token")
        assert_eq(ngx.status, 403, "write disabled status")
        assert_eq(last_error(), "console write disabled", "write disabled error")
      end)

      -- Write enforcement: admin token bypasses write_enabled/local_only.
      with_env({ FN_ADMIN_TOKEN = "secret", FN_CONSOLE_WRITE_ENABLED = "0", FN_CONSOLE_LOCAL_ONLY = "1" }, function()
        out = ""
        ngx.status = 0
        ngx.var.remote_addr = "8.8.8.8"
        ngx.req.get_headers = function()
          return { ["x-fn-admin-token"] = "secret" }
        end
        local ok = guard.enforce_write()
        assert_eq(ok, true, "admin token should allow writes")
      end)

      local bad0, bad0_err = guard.update_state("not-an-object")
      assert_eq(bad0, nil, "update_state must reject non-table")
      assert_true(type(bad0_err) == "string" and bad0_err:find("payload must be", 1, true) ~= nil, "bad payload message")

      local bad1, bad1_err = guard.update_state({ ui_enabled = "yes" })
      assert_eq(bad1, nil, "update_state must reject non-boolean")
      assert_true(type(bad1_err) == "string" and bad1_err:find("ui_enabled", 1, true) ~= nil, "bad field message")

      with_env({
        FN_UI_ENABLED = "0",
        FN_CONSOLE_API_ENABLED = "1",
        FN_ADMIN_API_ENABLED = "1",
        FN_CONSOLE_WRITE_ENABLED = "0",
        FN_CONSOLE_LOCAL_ONLY = "1",
      }, function()
        local snap0 = guard.state_snapshot()
        assert_eq(snap0.ui_enabled, false, "env baseline ui disabled")

        local updated, u_err = guard.update_state({ ui_enabled = true, local_only = false })
        assert_true(type(updated) == "table", u_err or "update_state ok")
        assert_eq(updated.ui_enabled, true, "override ui enabled")
        assert_eq(updated.local_only, false, "override local_only false")

        local cleared, c_err = guard.clear_state()
        assert_true(type(cleared) == "table", c_err or "clear_state ok")
        assert_eq(cleared.ui_enabled, false, "clear_state restores env defaults")
      end)
    end)
  end)
end

local function test_console_guard_additional_paths()
  with_fake_ngx(function(cache, _conc, _set_now)
    local cjson = require("cjson.safe")
    local session_payload = nil

    with_module_stubs({
      ["fastfn.console.auth"] = {
        login_enabled = function()
          return true
        end,
        api_login_enabled = function()
          return true
        end,
        read_session = function()
          return session_payload
        end,
      },
    }, function()
      package.loaded["fastfn.console.guard"] = nil
      local guard = require("fastfn.console.guard")

      local out = ""
      ngx.say = function(s)
        out = out .. tostring(s)
      end
      ngx.req.get_headers = function()
        return {}
      end

      with_env({ FN_CONSOLE_API_ENABLED = "maybe" }, function()
        assert_eq(guard.api_enabled(), true, "invalid env bool should fallback to default")
      end)

      ngx.var.remote_addr = nil
      assert_eq(guard.request_is_local(), false, "missing remote addr should be non-local")
      ngx.var.remote_addr = "10.1.2.3"
      assert_eq(guard.request_is_local(), true, "10.x should be local")
      ngx.var.remote_addr = "172.20.1.2"
      assert_eq(guard.request_is_local(), true, "172.16-31 should be local")
      ngx.var.remote_addr = "fc00::1"
      assert_eq(guard.request_is_local(), true, "fc00::/7 should be local")
      ngx.var.remote_addr = "8.8.8.8"
      assert_eq(guard.request_is_local(), false, "public ip should be non-local")

      with_env({ FN_ADMIN_TOKEN = false }, function()
        assert_eq(guard.request_has_admin_token(), false, "missing admin token env should fail")
      end)

      cache:set("console:login_enabled", 1)
      cache:set("console:login_api_enabled", 0)
      assert_eq(guard.login_enabled(), true, "login enabled override from store")
      assert_eq(guard.login_api_enabled(), false, "login api override from store")
      cache:delete("console:login_enabled")
      cache:delete("console:login_api_enabled")

      session_payload = { user = "" }
      assert_eq(guard.current_session_user(), nil, "empty session user should return nil")
      session_payload = { user = "alice" }
      assert_eq(guard.current_session_user(), "alice", "valid session user")
      session_payload = nil

      with_env({ FN_UI_ENABLED = "0", FN_CONSOLE_LOCAL_ONLY = "0" }, function()
        out = ""
        ngx.status = 0
        local ok = guard.enforce_ui()
        assert_eq(ok, false, "ui disabled should block enforce_ui")
        assert_eq(ngx.status, 404, "ui disabled status")
        assert_true((cjson.decode(out) or {}).error == "console ui disabled", "ui disabled error body")
      end)

      with_env({ FN_UI_ENABLED = "1", FN_CONSOLE_LOCAL_ONLY = "1", FN_ADMIN_TOKEN = "secret" }, function()
        out = ""
        ngx.status = 0
        ngx.var.remote_addr = "8.8.8.8"
        ngx.req.get_headers = function()
          return {}
        end
        local ok = guard.enforce_ui()
        assert_eq(ok, false, "ui local-only should block non-local without token")
        assert_eq(ngx.status, 403, "ui local-only status")
        assert_true((cjson.decode(out) or {}).error == "console ui local-only", "ui local-only error body")
      end)

      with_env({ FN_UI_ENABLED = "1", FN_CONSOLE_LOCAL_ONLY = "1", FN_ADMIN_TOKEN = false }, function()
        ngx.var.remote_addr = "127.0.0.1"
        local ok = guard.enforce_ui()
        assert_eq(ok, true, "ui should allow local requests")
      end)

      with_env({ FN_ADMIN_TOKEN = "secret", FN_CONSOLE_WRITE_ENABLED = "1", FN_CONSOLE_LOCAL_ONLY = "1" }, function()
        out = ""
        ngx.status = 0
        ngx.var.remote_addr = "8.8.8.8"
        ngx.req.get_headers = function()
          return {}
        end
        local blocked = guard.enforce_write()
        assert_eq(blocked, false, "write local-only should block non-local without token")
        assert_eq(ngx.status, 403, "write local-only status")
        assert_true((cjson.decode(out) or {}).error == "console write local-only", "write local-only error body")

        ngx.var.remote_addr = "127.0.0.1"
        out = ""
        ngx.status = 0
        local allowed = guard.enforce_write()
        assert_eq(allowed, true, "write should allow local when enabled")
      end)

      with_env({ FN_CONSOLE_API_ENABLED = "1", FN_ADMIN_API_ENABLED = "1", FN_CONSOLE_LOCAL_ONLY = "0", FN_ADMIN_TOKEN = false }, function()
        ngx.var.remote_addr = "8.8.8.8"
        ngx.req.get_headers = function()
          return {}
        end
        local ok = guard.enforce_api({ skip_login = true })
        assert_eq(ok, true, "skip_login should bypass login enforcement")
      end)

      local saved_shared = ngx.shared
      ngx.shared = nil
      with_env({ FN_UI_ENABLED = "0" }, function()
        assert_eq(guard.ui_enabled(), false, "ui_enabled should fallback when store unavailable")
      end)
      local bad_update, bad_update_err = guard.update_state({ ui_enabled = true })
      assert_eq(bad_update, nil, "update_state should fail without store")
      assert_true(type(bad_update_err) == "string" and bad_update_err:find("state store unavailable", 1, true) ~= nil, "update_state store error")
      local bad_clear, bad_clear_err = guard.clear_state()
      assert_eq(bad_clear, nil, "clear_state should fail without store")
      assert_true(type(bad_clear_err) == "string" and bad_clear_err:find("state store unavailable", 1, true) ~= nil, "clear_state store error")
      ngx.shared = saved_shared
    end)
  end)
end

local function test_routes_discovery_and_host_routing()
  with_fake_ngx(function(cache, conc, set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-routes-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/python/hello/v2")
    mkdir_p(root .. "/node/hello")

    write_file(
      root .. "/python/hello/handler.py",
      "def handler(event):\n"
        .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
    )
    write_file(
      root .. "/python/hello/v2/handler.py",
      "def handler(event):\n"
        .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
    )
    write_file(
      root .. "/python/hello/fn.config.json",
      cjson.encode({
        max_concurrency = 4,
        worker_pool = {
          enabled = true,
          max_workers = 2,
          max_queue = 3,
          queue_timeout_ms = 100,
          overflow_status = 503,
        },
        keep_warm = {
          enabled = true,
          min_warm = 1,
          ping_seconds = 10,
          idle_ttl_seconds = 1,
        },
        invoke = {
          methods = { "GET" },
          routes = { "/secure", "/conflict" },
          allow_hosts = { "api.example.com" },
        },
      }) .. "\n"
    )

    write_file(
      root .. "/node/hello/handler.js",
      "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
    )
    write_file(
      root .. "/node/hello/fn.config.json",
      cjson.encode({
        invoke = {
          methods = { "GET" },
          routes = { "/conflict" },
        },
      }) .. "\n"
    )

    write_file(
      root .. "/get.users.[id].py",
      "def handler(event):\n"
        .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
    )
    write_file(
      root .. "/get.blog.[[...slug]].py",
      "def handler(event):\n"
        .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
    )
    write_file(
      root .. "/get.accounts.[id].py",
      "def handler(event):\n"
        .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
    )
    write_file(
      root .. "/get.accounts.[id].js",
      "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "node", "python", "rust", "go", "php" },
      defaults = {
        timeout_ms = 2500,
        max_concurrency = 20,
        max_body_bytes = 1048576,
      },
      runtimes = {
        node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
        python = { socket = "unix:/tmp/fastfn/fn-python.sock", timeout_ms = 2500 },
        rust = { socket = "unix:/tmp/fastfn/fn-rust.sock", timeout_ms = 2500 },
        go = { socket = "unix:/tmp/fastfn/fn-go.sock", timeout_ms = 2500 },
        php = { socket = "unix:/tmp/fastfn/fn-php.sock", timeout_ms = 2500 },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))

    local catalog = routes.discover_functions(true)
    assert_true(catalog.runtimes.python.functions.hello ~= nil, "python hello discovered")
    assert_true(catalog.runtimes.node.functions.hello ~= nil, "node hello discovered")
    assert_true(catalog.mapped_routes["/secure"] ~= nil, "secure route mapped")
    assert_true(catalog.mapped_routes["/users/:id"] ~= nil, "dynamic users route mapped")
    assert_true(catalog.mapped_routes["/blog/:slug*"] ~= nil, "catch-all route mapped")
    assert_true(catalog.mapped_routes["/blog"] ~= nil, "optional catch-all base route mapped")
    assert_true(catalog.mapped_routes["/conflict"] == nil, "conflict route removed")
    assert_true(catalog.mapped_routes["/accounts/:id"] == nil, "dynamic conflict route removed")
    assert_true(catalog.mapped_route_conflicts["/conflict"] == true, "conflict route tracked")
    assert_true(catalog.mapped_route_conflicts["/accounts/:id"] == true, "dynamic conflict route tracked")

    local conflict_rt, _, _, _, conflict_err = routes.resolve_mapped_target("/conflict", "GET", { host = "api.example.com" })
    assert_eq(conflict_rt, nil, "conflict route runtime blocked")
    assert_eq(conflict_err, "ambiguous function", "conflict route err")

    local rt_ok, fn_ok, ver_ok, _, err_ok = routes.resolve_mapped_target("/secure", "GET", { host = "api.example.com" })
    assert_eq(rt_ok, "python", "allowed host runtime")
    assert_eq(fn_ok, "hello", "allowed host fn")
    assert_eq(ver_ok, nil, "allowed host version")
    assert_eq(err_ok, nil, "allowed host err")

    local rt_bad, _, _, _, err_bad = routes.resolve_mapped_target("/secure", "GET", { host = "evil.example.com" })
    assert_eq(rt_bad, nil, "blocked host runtime")
    assert_eq(err_bad, "host not allowed", "blocked host err")

    local rt_dyn, fn_dyn, _, params_dyn = routes.resolve_mapped_target("/users/123", "GET", { host = "api.example.com" })
    assert_eq(rt_dyn, "python", "dynamic route runtime")
    assert_eq(fn_dyn, "get.users.[id].py", "dynamic route target")
    assert_true(type(params_dyn) == "table", "dynamic route params table")
    assert_eq(params_dyn.id, "123", "dynamic route id param")

    local rt_catch, _, _, params_catch = routes.resolve_mapped_target("/blog/a/b", "GET", { host = "api.example.com" })
    assert_eq(rt_catch, "python", "catch-all runtime")
    assert_true(type(params_catch) == "table", "catch-all params table")
    assert_eq(params_catch.slug, "a/b", "catch-all slug")

    local rt_base = routes.resolve_mapped_target("/blog", "GET", { host = "api.example.com" })
    assert_eq(rt_base, "python", "optional catch-all base route")

    local rt_dyn_conflict, _, _, _, err_dyn_conflict = routes.resolve_mapped_target("/accounts/42", "GET", { host = "api.example.com" })
    assert_eq(rt_dyn_conflict, nil, "dynamic conflict route runtime blocked")
    assert_eq(err_dyn_conflict, "ambiguous function", "dynamic conflict route err")

    local resolved_rt, resolved_ver = routes.resolve_named_target("hello", nil)
    assert_eq(resolved_rt, "node", "resolve named target uses runtime order")
    assert_eq(resolved_ver, nil, "resolve named target version default")

    local file_policy = routes.resolve_function_policy("python", "get.users.[id].py", nil)
    assert_true(type(file_policy) == "table", "file target policy fallback")
    assert_eq(file_policy.timeout_ms, 2500, "file target timeout default")

    local go_policy = routes.resolve_function_policy("go", "demo.go", nil)
    assert_true(type(go_policy) == "table", "go policy fallback")
    assert_true((go_policy.timeout_ms or 0) >= 180000, "go policy timeout floor")

    assert_true(routes.record_worker_pool_drop("python/hello@default", "overflow"), "worker pool overflow drop metric")
    assert_true(routes.record_worker_pool_drop("python/hello@default", "queue_timeout"), "worker pool queue timeout metric")

    set_now(2000)
    cache:set("warm:python/hello@default", 1900)
    local snapshot = routes.health_snapshot()
    assert_true((snapshot.routing or {}).mapped_routes >= 4, "snapshot includes mapped routes")
    assert_true(type((snapshot.functions or {}).states) == "table", "snapshot states present")
    assert_true((snapshot.functions.summary.pool_enabled or 0) >= 1, "pool-enabled summary")
    assert_true((snapshot.functions.summary.pool_queue_drops or 0) >= 2, "pool drop summary")

    rm_rf(root)
  end)
end

local function test_routes_skip_disabled_runtime_file_routes()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-routes-disabled-rt-" .. uniq

    rm_rf(root)
    mkdir_p(root)
    write_file(
      root .. "/get.health.py",
      "def handler(event):\n"
        .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
    )
    write_file(
      root .. "/get.health.rs",
      "pub fn handler(_event: String) -> String {\n"
        .. "    \"{}\".to_string()\n"
        .. "}\n"
    )
    write_file(
      root .. "/get.rust_only.rs",
      "pub fn handler(_event: String) -> String {\n"
        .. "    \"{}\".to_string()\n"
        .. "}\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "python", "node" },
      defaults = {
        timeout_ms = 2500,
        max_concurrency = 20,
        max_body_bytes = 1048576,
      },
      runtimes = {
        python = { socket = "unix:/tmp/fastfn/fn-python.sock", timeout_ms = 2500 },
        node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))
    local catalog = routes.discover_functions(true)
    local health_entries = (catalog.mapped_routes or {})["/health"]
    assert_true(type(health_entries) == "table" and #health_entries >= 1, "health route should be discovered for enabled runtime")
    for _, entry in ipairs(health_entries) do
      assert_true(entry.runtime ~= "rust", "rust entry must be filtered when runtime is disabled")
    end
    for _, entries in pairs(catalog.mapped_routes or {}) do
      for _, entry in ipairs(entries) do
        assert_true(entry.runtime ~= "rust", "no mapped routes should use disabled rust runtime")
      end
    end

    local runtime, fn_name = routes.resolve_mapped_target("/health", "GET", { host = "localhost" })
    assert_eq(runtime, "python", "health route should resolve to enabled python runtime")
    assert_eq(fn_name, "get.health.py", "health route should point to python file target")

    rm_rf(root)
  end)
end

local function test_routes_nested_project_root_scan_with_file_routes()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-routes-nested-root-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/nextstyle-clean/node")
    mkdir_p(root .. "/nextstyle-clean/users")

    -- File route in the nested project root.
    write_file(
      root .. "/nextstyle-clean/get.conflict-route.js",
      "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
    )

    -- Nested Next-style routes inside the same project.
    write_file(
      root .. "/nextstyle-clean/users/index.js",
      "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
    )
    write_file(
      root .. "/nextstyle-clean/users/[id].js",
      "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "node" },
      defaults = {
        timeout_ms = 2500,
        max_concurrency = 20,
        max_body_bytes = 1048576,
      },
      runtimes = {
        node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))

    local catalog = routes.discover_functions(true)
    assert_true(catalog.mapped_routes["/nextstyle-clean/users"] ~= nil, "nested project should include users route")
    assert_true(catalog.mapped_routes["/nextstyle-clean/users/:id"] ~= nil, "nested project should include users/:id route")

    rm_rf(root)
  end)
end

local function test_routes_force_url_policy_override()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-force-url-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/node/policyfn")

    -- File-based route: GET /conflict-route (node)
    write_file(
      root .. "/get.conflict-route.js",
      "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
    )

    -- Config/policy function that wants the same route.
    write_file(
      root .. "/node/policyfn/handler.js",
      "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
    )
    write_file(
      root .. "/node/policyfn/fn.config.json",
      cjson.encode({
        invoke = {
          methods = { "GET", "POST" },
          routes = { "/conflict-route" },
        },
      }) .. "\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "node" },
      defaults = {
        timeout_ms = 2500,
        max_concurrency = 20,
        max_body_bytes = 1048576,
      },
      runtimes = {
        node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))

    local catalog = routes.discover_functions(true)
    assert_true(catalog.mapped_routes["/conflict-route"] ~= nil, "conflict-route mapped")

    -- Without force-url, policy route must not override the already-mapped file route.
    local rt1, fn1 = routes.resolve_mapped_target("/conflict-route", "GET", { host = "localhost" })
    assert_eq(rt1, "node", "conflict-route runtime")
    assert_eq(fn1, "get.conflict-route.js", "file route wins without force-url")

    -- But non-overlapping methods can still be served by the policy entry.
    local rt1p, fn1p = routes.resolve_mapped_target("/conflict-route", "POST", { host = "localhost" })
    assert_eq(rt1p, "node", "conflict-route POST runtime")
    assert_eq(fn1p, "policyfn", "policy route serves POST without overriding GET")

    -- Now opt into override explicitly via force-url (invoke-scoped).
    write_file(
      root .. "/node/policyfn/fn.config.json",
      cjson.encode({
        invoke = {
          ["force-url"] = true,
          methods = { "GET", "POST" },
          routes = { "/conflict-route" },
        },
      }) .. "\n"
    )

    routes.discover_functions(true)

    local rt2, fn2 = routes.resolve_mapped_target("/conflict-route", "GET", { host = "localhost" })
    assert_eq(rt2, "node", "forced conflict-route runtime")
    assert_eq(fn2, "policyfn", "policy route overrides GET with force-url")

    rm_rf(root)
  end)
end

local function test_routes_force_url_ignored_for_version_scoped_configs()
  with_env({ FN_FORCE_URL = "" }, function()
    with_fake_ngx(function(cache, conc, _set_now)
      local cjson = require("cjson.safe")
      package.loaded["fastfn.core.routes"] = nil
      local routes = require("fastfn.core.routes")
      local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
      local root = "/tmp/fastfn-lua-force-url-version-" .. uniq

      rm_rf(root)
      mkdir_p(root .. "/node/demo")
      mkdir_p(root .. "/node/demo/test")

      -- File-based route: GET /conflict-route (node)
      write_file(
        root .. "/get.conflict-route.js",
        "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
      )

      -- Function root (default) exists, so the version can be discovered.
      write_file(
        root .. "/node/demo/handler.js",
        "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
      )

      -- Version-scoped config wants to take the same route with force-url. This must not override
      -- an already-mapped URL unless FN_FORCE_URL is enabled globally by the operator.
      write_file(
        root .. "/node/demo/test/handler.js",
        "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
      )
      write_file(
        root .. "/node/demo/test/fn.config.json",
        cjson.encode({
          invoke = {
            ["force-url"] = true,
            methods = { "GET" },
            routes = { "/conflict-route" },
          },
        }) .. "\n"
      )

      local cfg = {
        functions_root = root,
        socket_base_dir = "/tmp/fastfn",
        runtime_order = { "node" },
        defaults = {
          timeout_ms = 2500,
          max_concurrency = 20,
          max_body_bytes = 1048576,
        },
        runtimes = {
          node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
        },
      }

      reset_shared_dict(cache)
      reset_shared_dict(conc)
      cache:set("runtime:config", cjson.encode(cfg))

      local catalog = routes.discover_functions(true)
      assert_true(catalog.mapped_routes["/conflict-route"] ~= nil, "conflict-route mapped")

      local rt1, fn1 = routes.resolve_mapped_target("/conflict-route", "GET", { host = "localhost" })
      assert_eq(rt1, "node", "conflict-route runtime")
      assert_eq(fn1, "get.conflict-route.js", "version force-url must not override file route without global FN_FORCE_URL")

      rm_rf(root)
    end)
  end)
end

local function test_routes_force_url_breaks_policy_ties()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-force-url-tie-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/node/a")
    mkdir_p(root .. "/python/b")

    write_file(root .. "/node/a/handler.js", "exports.handler = async () => ({ status: 200, headers: {}, body: '{}' });\n")
    write_file(
      root .. "/node/a/fn.config.json",
      cjson.encode({
        invoke = {
          methods = { "GET" },
          routes = { "/tie" },
        },
      }) .. "\n"
    )

    write_file(
      root .. "/python/b/handler.py",
      "def handler(event):\n"
        .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
    )
    write_file(
      root .. "/python/b/fn.config.json",
      cjson.encode({
        invoke = {
          ["force-url"] = true,
          methods = { "GET" },
          routes = { "/tie" },
        },
      }) .. "\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "node", "python" },
      defaults = {
        timeout_ms = 2500,
        max_concurrency = 20,
        max_body_bytes = 1048576,
      },
      runtimes = {
        node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
        python = { socket = "unix:/tmp/fastfn/fn-python.sock", timeout_ms = 2500 },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))

    local catalog = routes.discover_functions(true)
    assert_true(catalog.mapped_routes["/tie"] ~= nil, "tie route mapped")
    assert_true(catalog.mapped_route_conflicts["/tie"] ~= true, "force-url should avoid tie conflict")

    local rt, fn_name = routes.resolve_mapped_target("/tie", "GET", { host = "localhost" })
    assert_eq(rt, "python", "forced policy wins tie")
    assert_eq(fn_name, "b", "forced policy function name")

    rm_rf(root)
  end)
end

local function test_routes_force_url_global_env_policy_override()
  with_env({ FN_FORCE_URL = "1" }, function()
    with_fake_ngx(function(cache, conc, _set_now)
      local cjson = require("cjson.safe")
      package.loaded["fastfn.core.routes"] = nil
      local routes = require("fastfn.core.routes")
      local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
      local root = "/tmp/fastfn-lua-force-url-global-" .. uniq

      rm_rf(root)
      mkdir_p(root .. "/node/policyfn")

      -- File-based route: GET /conflict-route (node)
      write_file(
        root .. "/get.conflict-route.js",
        "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
      )

      -- Config/policy function that wants the same route.
      write_file(
        root .. "/node/policyfn/handler.js",
        "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
      )
      write_file(
        root .. "/node/policyfn/fn.config.json",
        cjson.encode({
          invoke = {
            methods = { "GET" },
            routes = { "/conflict-route" },
          },
        }) .. "\n"
      )

      local cfg = {
        functions_root = root,
        socket_base_dir = "/tmp/fastfn",
        runtime_order = { "node" },
        defaults = {
          timeout_ms = 2500,
          max_concurrency = 20,
          max_body_bytes = 1048576,
        },
        runtimes = {
          node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
        },
      }

      reset_shared_dict(cache)
      reset_shared_dict(conc)
      cache:set("runtime:config", cjson.encode(cfg))

      local catalog = routes.discover_functions(true)
      assert_true(catalog.mapped_routes["/conflict-route"] ~= nil, "conflict-route mapped (global env)")

      local rt, fn_name = routes.resolve_mapped_target("/conflict-route", "GET", { host = "localhost" })
      assert_eq(rt, "node", "conflict-route runtime (global env)")
      assert_eq(fn_name, "policyfn", "policy route overrides GET with FN_FORCE_URL=1")

      rm_rf(root)
    end)
  end)
end

local function test_routes_force_url_global_env_keeps_policy_policy_conflict()
  with_env({ FN_FORCE_URL = "1" }, function()
    with_fake_ngx(function(cache, conc, _set_now)
      local cjson = require("cjson.safe")
      package.loaded["fastfn.core.routes"] = nil
      local routes = require("fastfn.core.routes")
      local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
      local root = "/tmp/fastfn-lua-force-url-global-tie-" .. uniq

      rm_rf(root)
      mkdir_p(root .. "/node/a")
      mkdir_p(root .. "/python/b")

      write_file(root .. "/node/a/handler.js", "exports.handler = async () => ({ status: 200, headers: {}, body: '{}' });\n")
      write_file(
        root .. "/node/a/fn.config.json",
        cjson.encode({
          invoke = {
            methods = { "GET" },
            routes = { "/tie" },
          },
        }) .. "\n"
      )

      write_file(
        root .. "/python/b/handler.py",
        "def handler(event):\n"
          .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
      )
      write_file(
        root .. "/python/b/fn.config.json",
        cjson.encode({
          invoke = {
            methods = { "GET" },
            routes = { "/tie" },
          },
        }) .. "\n"
      )

      local cfg = {
        functions_root = root,
        socket_base_dir = "/tmp/fastfn",
        runtime_order = { "node", "python" },
        defaults = {
          timeout_ms = 2500,
          max_concurrency = 20,
          max_body_bytes = 1048576,
        },
        runtimes = {
          node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
          python = { socket = "unix:/tmp/fastfn/fn-python.sock", timeout_ms = 2500 },
        },
      }

      reset_shared_dict(cache)
      reset_shared_dict(conc)
      cache:set("runtime:config", cjson.encode(cfg))

      local catalog = routes.discover_functions(true)
      assert_true(catalog.mapped_routes["/tie"] == nil, "tie route removed when both policies forced")
      assert_true(catalog.mapped_route_conflicts["/tie"] == true, "tie route conflict tracked when both policies forced")

      rm_rf(root)
    end)
  end)
end

local function test_routes_policy_routes_disjoint_allow_hosts()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-host-routing-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/node/a")
    mkdir_p(root .. "/python/b")

    write_file(root .. "/node/a/handler.js", "exports.handler = async () => ({ status: 200, headers: {}, body: '{}' });\n")
    write_file(
      root .. "/node/a/fn.config.json",
      cjson.encode({
        invoke = {
          methods = { "GET" },
          routes = { "/hosted" },
          allow_hosts = { "a.example.com" },
        },
      }) .. "\n"
    )

    write_file(
      root .. "/python/b/handler.py",
      "def handler(event):\n"
        .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
    )
    write_file(
      root .. "/python/b/fn.config.json",
      cjson.encode({
        invoke = {
          methods = { "GET" },
          routes = { "/hosted" },
          allow_hosts = { "b.example.com" },
        },
      }) .. "\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "node", "python" },
      defaults = {
        timeout_ms = 2500,
        max_concurrency = 20,
        max_body_bytes = 1048576,
      },
      runtimes = {
        node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
        python = { socket = "unix:/tmp/fastfn/fn-python.sock", timeout_ms = 2500 },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))

    local catalog = routes.discover_functions(true)
    assert_true(type(catalog.mapped_routes["/hosted"]) == "table", "/hosted mapped")
    assert_true(catalog.mapped_route_conflicts["/hosted"] ~= true, "/hosted should not be a conflict")

    local rt_a, fn_a, _, _, err_a = routes.resolve_mapped_target("/hosted", "GET", { host = "a.example.com" })
    assert_eq(rt_a, "node", "a.example.com resolves to node")
    assert_eq(fn_a, "a", "a.example.com resolves to function a")
    assert_eq(err_a, nil, "a.example.com no err")

    local rt_b, fn_b, _, _, err_b = routes.resolve_mapped_target("/hosted", "GET", { host = "b.example.com" })
    assert_eq(rt_b, "python", "b.example.com resolves to python")
    assert_eq(fn_b, "b", "b.example.com resolves to function b")
    assert_eq(err_b, nil, "b.example.com no err")

    local rt_c, _, _, _, err_c = routes.resolve_mapped_target("/hosted", "GET", { host = "c.example.com" })
    assert_eq(rt_c, nil, "c.example.com blocked")
    assert_eq(err_c, "host not allowed", "c.example.com host not allowed")

    local rt_wild, fn_wild, _, _, err_wild = routes.resolve_mapped_target("/hosted", "GET", { host = "api.a.example.com" })
    assert_eq(rt_wild, nil, "wildcard host should not match exact allow_hosts")
    assert_eq(fn_wild, nil, "wildcard host fn should be nil")
    assert_eq(err_wild, "host not allowed", "wildcard host blocked")

    local rt_none, fn_none, _, _, err_none = routes.resolve_mapped_target("/hosted", "DELETE", { host = "a.example.com" })
    assert_eq(rt_none, nil, "method mismatch should not resolve")
    assert_eq(fn_none, nil, "method mismatch fn should be nil")
    assert_eq(err_none, nil, "method mismatch without host hit should return nil err")

    rm_rf(root)
  end)
end

local function test_routes_dynamic_order_is_deterministic_and_specific()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-dynamic-order-" .. uniq

    rm_rf(root)
    mkdir_p(root)

    write_file(root .. "/get.users.[id].js", "exports.handler = async () => ({ status: 200, headers: {}, body: '{}' });\n")
    write_file(root .. "/get.users.[...id].js", "exports.handler = async () => ({ status: 200, headers: {}, body: '{}' });\n")

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "node" },
      defaults = {
        timeout_ms = 2500,
        max_concurrency = 20,
        max_body_bytes = 1048576,
      },
      runtimes = {
        node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))

    local catalog = routes.discover_functions(true)
    assert_true(type(catalog.mapped_routes["/users/:id"]) == "table", "dynamic /users/:id mapped")
    assert_true(type(catalog.mapped_routes["/users/:id*"]) == "table", "catch-all /users/:id* mapped")
    assert_true(type(catalog.dynamic_routes) == "table" and #catalog.dynamic_routes >= 2, "dynamic_routes computed")
    assert_eq(catalog.dynamic_routes[1], "/users/:id", "dynamic route order prefers specific over catch-all")

    local rt1, fn1, _, params1 = routes.resolve_mapped_target("/users/123", "GET", { host = "localhost" })
    assert_eq(rt1, "node", "dynamic /users/123 runtime")
    assert_eq(fn1, "get.users.[id].js", "dynamic /users/123 chooses specific handler")
    assert_true(type(params1) == "table" and params1.id == "123", "dynamic /users/123 param")

    local rt2, fn2, _, params2 = routes.resolve_mapped_target("/users/123/extra", "GET", { host = "localhost" })
    assert_eq(rt2, "node", "catch-all /users/123/extra runtime")
    assert_eq(fn2, "get.users.[...id].js", "catch-all chooses catch-all handler")
    assert_true(type(params2) == "table" and params2.id == "123/extra", "catch-all param")

    rm_rf(root)
  end)
end

local function test_console_data_crud_and_secrets()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-console-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/python")
    write_file(
      root .. "/direct.py",
      "def handler(event):\n"
        .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
    )
    write_file(root .. "/direct.js", "module.exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' })\n")
    write_file(root .. "/direct.php", "<?php\nfunction handler($event){return ['status'=>200,'headers'=>['Content-Type'=>'application/json'],'body'=>'{}'];}\n")
    write_file(root .. "/direct.lua", "function handler(event) return { status = 200, headers = { ['Content-Type'] = 'application/json' }, body = '{}' } end\n")
    write_file(root .. "/direct.rs", "pub fn handler(_event: &str) -> &'static str { \"{}\" }\n")
    write_file(root .. "/direct.go", "package main\nfunc Handler(_ any) any { return map[string]any{\"status\":200,\"headers\":map[string]string{\"Content-Type\":\"application/json\"},\"body\":\"{}\"} }\n")

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "python", "node", "php", "lua", "rust", "go" },
      defaults = {
        timeout_ms = 2500,
        max_concurrency = 20,
        max_body_bytes = 1048576,
      },
      runtimes = {
        python = { socket = "unix:/tmp/fastfn/fn-python.sock", timeout_ms = 2500 },
        node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
        php = { socket = "unix:/tmp/fastfn/fn-php.sock", timeout_ms = 2500 },
        lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true },
        rust = { socket = "unix:/tmp/fastfn/fn-rust.sock", timeout_ms = 2500 },
        go = { socket = "unix:/tmp/fastfn/fn-go.sock", timeout_ms = 2500 },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))
    routes.discover_functions(true)

    package.loaded["fastfn.console.data"] = nil
    local data = require("fastfn.console.data")

    local created, create_err = data.create_function("python", "unitcrud", nil, {
      summary = "Unit CRUD function",
      methods = { "GET", "POST", "INVALID" },
      query_example = { name = "Unit" },
      body_example = "{\"hello\":\"world\"}",
      route = "/unit-crud",
    })
    assert_true(created ~= nil, create_err or "create_function failed")
    assert_true(type(created.code) == "string", "create_function should return code")

    local detail, detail_err = data.function_detail("python", "unitcrud", nil, true)
    assert_true(detail ~= nil, detail_err or "function_detail failed")
    assert_true(type(detail.metadata) == "table", "detail metadata")
    assert_true(type(detail.metadata.endpoints) == "table", "detail endpoints metadata")
    assert_eq(detail.metadata.endpoints.preferred_public_route, "/unit-crud", "preferred route from config")

    local updated_cfg, cfg_err = data.set_function_config("python", "unitcrud", nil, {
      invoke = {
        methods = { "POST" },
        routes = { "/unit-crud", "/unit-crud/v2" },
        allow_hosts = { "api.example.com", "api.example.com" },
        handler = "handler",
      },
      response = {
        include_debug_headers = true,
      },
      schedule = {
        enabled = true,
        every_seconds = 60,
        cron = "*/5 * * * *",
        timezone = "UTC",
        method = "POST",
        query = { once = true },
        headers = { ["X-Test"] = "1" },
        body = { hello = "world" },
        context = { source = "lua_unit" },
        retry = {
          enabled = true,
          max_attempts = 3,
          base_delay_seconds = 1,
          max_delay_seconds = 8,
          jitter = 0.1,
        },
      },
      shared_deps = { "base_pack", "base_pack" },
      edge = {
        base_url = "https://api.example.com",
        allow_hosts = { "api.example.com" },
        allow_private = false,
        max_response_bytes = 4096,
      },
    })
    assert_true(updated_cfg ~= nil, cfg_err or "set_function_config failed")
    assert_true(type(updated_cfg.metadata) == "table", "updated config metadata")

    local bad_cfg, bad_err = data.set_function_config("python", "unitcrud", nil, {
      schedule = {
        method = "INVALID",
      },
    })
    assert_true(bad_cfg == nil, "invalid config should fail")
    assert_true(type(bad_err) == "string" and bad_err:find("schedule.method", 1, true) ~= nil, "invalid schedule error")

    local bad_cron, bad_cron_err = data.set_function_config("python", "unitcrud", nil, {
      schedule = {
        cron = "not a cron",
      },
    })
    assert_true(bad_cron == nil, "invalid cron should fail")
    assert_true(type(bad_cron_err) == "string" and bad_cron_err:find("schedule.cron", 1, true) ~= nil, "invalid cron error")

    local bad_tz, bad_tz_err = data.set_function_config("python", "unitcrud", nil, {
      schedule = {
        timezone = "America/New_York",
      },
    })
    assert_true(bad_tz == nil, "invalid timezone should fail")
    assert_true(type(bad_tz_err) == "string" and bad_tz_err:find("schedule.timezone", 1, true) ~= nil, "invalid timezone error")

    local bad_retry, bad_retry_err = data.set_function_config("python", "unitcrud", nil, {
      schedule = {
        retry = {},
      },
    })
    assert_true(bad_retry == nil, "empty retry object should fail")
    assert_true(type(bad_retry_err) == "string" and bad_retry_err:find("schedule.retry", 1, true) ~= nil, "invalid retry error")

    local env_detail, env_err = data.set_function_env("python", "unitcrud", nil, {
      API_TOKEN = { value = "token-1", is_secret = true },
      FLAG = true,
    })
    assert_true(env_detail ~= nil, env_err or "set_function_env failed")
    assert_true(type(env_detail.fn_env) == "table", "fn_env should be present")
    assert_eq(env_detail.fn_env.API_TOKEN.value, "<hidden>", "secret env is hidden")

    local env_kept, env_kept_err = data.set_function_env("python", "unitcrud", nil, {
      API_TOKEN = { value = "<hidden>", is_secret = true },
      FLAG = cjson.null,
    })
    assert_true(env_kept ~= nil, env_kept_err or "set_function_env keep_hidden failed")
    assert_true(env_kept.fn_env.FLAG == nil, "flag should be deleted")

    local code_detail, code_err = data.set_function_code(
      "python",
      "unitcrud",
      nil,
      {
        code = "def handler(event):\n"
          .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{\"ok\":true}'}\n",
      }
    )
    assert_true(code_detail ~= nil, code_err or "set_function_code failed")
    assert_true(type(code_detail.code) == "string", "updated code should be returned")

    local file_target, file_target_err = data.function_detail("python", "direct.py", nil, false)
    assert_true(file_target ~= nil, file_target_err or "file target detail failed")
    assert_eq(file_target.file_path, root .. "/direct.py", "file target path")

    local file_js, file_js_err = data.function_detail("node", "direct.js", nil, false)
    assert_true(file_js ~= nil, file_js_err or "file target js failed")
    assert_eq(file_js.file_path, root .. "/direct.js", "file target js path")

    local mismatch, mismatch_err = data.function_detail("python", "direct.js", nil, false)
    assert_true(mismatch == nil, "runtime mismatch should fail")
    assert_true(
      type(mismatch_err) == "string" and mismatch_err:find("runtime mismatch", 1, true) ~= nil,
      "runtime mismatch error"
    )

    local file_php, file_php_err = data.function_detail("php", "direct.php", nil, false)
    assert_true(file_php ~= nil, file_php_err or "file target php failed")
    assert_eq(file_php.file_path, root .. "/direct.php", "file target php path")

    local file_lua, file_lua_err = data.function_detail("lua", "direct.lua", nil, false)
    assert_true(file_lua ~= nil, file_lua_err or "file target lua failed")
    assert_eq(file_lua.file_path, root .. "/direct.lua", "file target lua path")

    local file_rust, file_rust_err = data.function_detail("rust", "direct.rs", nil, false)
    assert_true(file_rust ~= nil, file_rust_err or "file target rust failed")
    assert_eq(file_rust.file_path, root .. "/direct.rs", "file target rust path")

    local file_go, file_go_err = data.function_detail("go", "direct.go", nil, false)
    assert_true(file_go ~= nil, file_go_err or "file target go failed")
    assert_eq(file_go.file_path, root .. "/direct.go", "file target go path")

    local node_fn, node_fn_err = data.create_function("node", "unitnode", nil, {
      summary = "Unit Node",
      methods = { "GET" },
      route = "/unit-node",
    })
    assert_true(node_fn ~= nil, node_fn_err or "create node failed")
    write_file(
      node_fn.function_dir .. "/package.json",
      cjson.encode({ name = "unitnode", dependencies = { uuid = "1.0.0" }, devDependencies = { jest = "1.0.0" } }) .. "\n"
    )
    write_file(node_fn.function_dir .. "/package-lock.json", "{}\n")
    local node_detail, node_detail_err = data.function_detail("node", "unitnode", nil, false)
    assert_true(node_detail ~= nil, node_detail_err or "node detail failed")
    assert_true(node_detail.metadata.node.package_json_exists == true, "node package_json should exist")
    assert_eq(node_detail.metadata.node.dependency_count, 1, "node deps count")
    assert_eq(node_detail.metadata.node.dependencies[1], "uuid", "node dep name")
    assert_eq(node_detail.metadata.node.lock_file, "package-lock.json", "node lock file")

    local php_fn, php_fn_err = data.create_function("php", "unitphp", nil, { summary = "Unit PHP", methods = { "GET" }, route = "/unit-php" })
    assert_true(php_fn ~= nil, php_fn_err or "create php failed")
    write_file(
      php_fn.function_dir .. "/composer.json",
      cjson.encode({ require = { ["guzzlehttp/guzzle"] = "^7.0" }, ["require-dev"] = { ["phpunit/phpunit"] = "^10.0" } }) .. "\n"
    )
    write_file(php_fn.function_dir .. "/composer.lock", "{}\n")
    local php_detail, php_detail_err = data.function_detail("php", "unitphp", nil, false)
    assert_true(php_detail ~= nil, php_detail_err or "php detail failed")
    assert_true(php_detail.metadata.php.composer_json_exists == true, "php composer.json should exist")
    assert_eq(php_detail.metadata.php.dependency_count, 1, "php deps count")
    assert_eq(php_detail.metadata.php.dependencies[1], "guzzlehttp/guzzle", "php dep name")
    assert_true(php_detail.metadata.php.composer_lock_exists == true, "php composer.lock should exist")

    local lua_fn, lua_fn_err = data.create_function("lua", "unitlua", nil, { summary = "Unit Lua", methods = { "GET" }, route = "/unit-lua" })
    assert_true(lua_fn ~= nil, lua_fn_err or "create lua failed")
    local lua_detail, lua_detail_err = data.function_detail("lua", "unitlua", nil, false)
    assert_true(lua_detail ~= nil, lua_detail_err or "lua detail failed")
    assert_eq(lua_detail.metadata.lua.sandbox, "in-process", "lua sandbox metadata")

    local rust_fn, rust_fn_err = data.create_function("rust", "unitrust", nil, { summary = "Unit Rust", methods = { "GET" }, route = "/unit-rust" })
    assert_true(rust_fn ~= nil, rust_fn_err or "create rust failed")
    write_file(
      rust_fn.function_dir .. "/Cargo.toml",
      "[package]\nname = \"unitrust\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\nserde = \"1\"\nserde_json = \"1\"\n"
    )
    write_file(rust_fn.function_dir .. "/Cargo.lock", "\n")
    local rust_detail, rust_detail_err = data.function_detail("rust", "unitrust", nil, false)
    assert_true(rust_detail ~= nil, rust_detail_err or "rust detail failed")
    assert_true(rust_detail.metadata.rust.cargo_toml_exists == true, "rust Cargo.toml should exist")
    assert_eq(rust_detail.metadata.rust.dependency_count, 2, "rust deps count")

    local go_fn, go_fn_err = data.create_function("go", "unitgo", nil, { summary = "Unit Go", methods = { "GET" }, route = "/unit-go" })
    assert_true(go_fn ~= nil, go_fn_err or "create go failed")
    local go_detail, go_detail_err = data.function_detail("go", "unitgo", nil, false)
    assert_true(go_detail ~= nil, go_detail_err or "go detail failed")

    local secrets0 = data.list_secrets()
    assert_true(type(secrets0) == "table", "list_secrets should return array")
    assert_true(data.set_secret("API_KEY", "secret-value"), "set_secret should succeed")
    local secrets1 = data.list_secrets()
    assert_true(#secrets1 == 1, "secret should be added")
    assert_true(data.delete_secret("API_KEY"), "delete_secret should succeed")
    local secrets2 = data.list_secrets()
    assert_true(#secrets2 == 0, "secret should be removed")

    local metrics = data.get_dashboard_metrics()
    assert_true(type(metrics) == "table", "dashboard metrics response")
    assert_true(type(metrics.invocations_chart) == "table", "dashboard chart payload")

    local deleted, del_err = data.delete_function("python", "unitcrud", nil)
    assert_true(deleted ~= nil, del_err or "delete_function failed")
    assert_true(deleted.ok == true, "delete_function should return ok=true")

    rm_rf(root)
  end)
end

local function test_core_client_frame_protocol()
  with_fake_ngx(function(_cache, _conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.client"] = nil
    local client = require("fastfn.core.client")

    local function pack_frame(obj)
      local payload = cjson.encode(obj)
      local n = #payload
      local b1 = math.floor(n / 16777216) % 256
      local b2 = math.floor(n / 65536) % 256
      local b3 = math.floor(n / 256) % 256
      local b4 = n % 256
      return string.char(b1, b2, b3, b4) .. payload
    end

    local success_buf = pack_frame({
      status = 200,
      headers = { ["Content-Type"] = "application/json" },
      body = "{\"ok\":true}",
    })
    local success_pos = 1
    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function(_, data)
          return #tostring(data)
        end,
        receive = function(_, n)
          local out = success_buf:sub(success_pos, success_pos + n - 1)
          if out == nil or #out < n then
            return nil, "closed"
          end
          success_pos = success_pos + n
          return out
        end,
        close = function() end,
      }
    end
    local resp_ok, err_ok = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_true(type(resp_ok) == "table", "client success response should be table")
    assert_eq(err_ok, nil, "client success err should be nil")
    assert_eq(resp_ok.status, 200, "client success status")
    assert_eq(resp_ok.body, "{\"ok\":true}", "client success body")

    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return nil, "timeout"
        end,
        close = function() end,
      }
    end
    local resp_timeout, err_code_timeout, err_msg_timeout = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_timeout, nil, "client timeout should return nil response")
    assert_eq(err_code_timeout, "timeout", "client timeout error code")
    assert_true(
      type(err_msg_timeout) == "string" and err_msg_timeout:find("connect timeout", 1, true) ~= nil,
      "client timeout message"
    )

    local invalid_buf = pack_frame({
      status = 200,
      is_base64 = true,
      headers = {},
      body = "ignored",
    })
    local invalid_pos = 1
    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function(_, data)
          return #tostring(data)
        end,
        receive = function(_, n)
          local out = invalid_buf:sub(invalid_pos, invalid_pos + n - 1)
          if out == nil or #out < n then
            return nil, "closed"
          end
          invalid_pos = invalid_pos + n
          return out
        end,
        close = function() end,
      }
    end
    local resp_invalid, err_code_invalid, err_msg_invalid = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_invalid, nil, "client invalid response should fail")
    assert_eq(err_code_invalid, "invalid_response", "client invalid response code")
    assert_true(
      type(err_msg_invalid) == "string" and err_msg_invalid:find("body_base64", 1, true) ~= nil,
      "client invalid response message"
    )

    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function(_, data)
          return #tostring(data)
        end,
        receive = function(_, n)
          if n == 4 then
            return nil, "timeout"
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local resp_hdr_timeout, err_code_hdr_timeout, err_msg_hdr_timeout = client.call_unix(
      "unix:/tmp/fn.sock",
      { fn = "demo", event = {} },
      2500
    )
    assert_eq(resp_hdr_timeout, nil, "client header timeout response")
    assert_eq(err_code_hdr_timeout, "timeout", "client header timeout code")
    assert_true(
      type(err_msg_hdr_timeout) == "string" and err_msg_hdr_timeout:find("header timeout", 1, true) ~= nil,
      "client header timeout message"
    )

    local huge_header = string.char(0, 160, 0, 1) -- 10,485,761 bytes (>10MB hard limit)
    ngx.socket.tcp = function()
      local header_sent = false
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function(_, data)
          return #tostring(data)
        end,
        receive = function(_, n)
          if n == 4 and not header_sent then
            header_sent = true
            return huge_header
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local resp_huge, err_code_huge, err_msg_huge = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_huge, nil, "client huge frame should fail")
    assert_eq(err_code_huge, "invalid_response", "client huge frame error code")
    assert_true(type(err_msg_huge) == "string" and err_msg_huge:find("frame length", 1, true) ~= nil, "client huge frame error message")

    local list_buf = pack_frame({ "not-an-object" })
    local list_pos = 1
    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function(_, data)
          return #tostring(data)
        end,
        receive = function(_, n)
          local out = list_buf:sub(list_pos, list_pos + n - 1)
          if out == nil or #out < n then
            return nil, "closed"
          end
          list_pos = list_pos + n
          return out
        end,
        close = function() end,
      }
    end
    local resp_list, err_code_list, err_msg_list = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_list, nil, "client non-object JSON response should fail")
    assert_eq(err_code_list, "invalid_response", "client non-object JSON code")
    assert_true(type(err_msg_list) == "string" and err_msg_list ~= "", "client non-object JSON message")

    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return nil, "refused"
        end,
        close = function() end,
      }
    end
    local resp_conn_err, err_code_conn_err, err_msg_conn_err = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_conn_err, nil, "client connect error response should be nil")
    assert_eq(err_code_conn_err, "connect_error", "client connect error code")
    assert_true(type(err_msg_conn_err) == "string" and err_msg_conn_err:find("refused", 1, true) ~= nil, "client connect error message")

    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return nil, "timeout"
        end,
        close = function() end,
      }
    end
    local resp_send_timeout, err_code_send_timeout, err_msg_send_timeout = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_send_timeout, nil, "client send timeout response")
    assert_eq(err_code_send_timeout, "timeout", "client send timeout code")
    assert_true(type(err_msg_send_timeout) == "string" and err_msg_send_timeout:find("send timeout", 1, true) ~= nil, "client send timeout message")

    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return nil, "write_failed"
        end,
        close = function() end,
      }
    end
    local resp_send_err, err_code_send_err, err_msg_send_err = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_send_err, nil, "client send error response")
    assert_eq(err_code_send_err, "send_error", "client send error code")
    assert_true(type(err_msg_send_err) == "string" and err_msg_send_err:find("write_failed", 1, true) ~= nil, "client send error message")

    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == 4 then
            return nil, "eof"
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local resp_hdr_err, err_code_hdr_err, err_msg_hdr_err = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_hdr_err, nil, "client header read error response")
    assert_eq(err_code_hdr_err, "receive_error", "client header read error code")
    assert_true(type(err_msg_hdr_err) == "string" and err_msg_hdr_err:find("eof", 1, true) ~= nil, "client header read error message")

    ngx.socket.tcp = function()
      local sent_header = false
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == 4 and not sent_header then
            sent_header = true
            return string.char(0, 0, 0, 2)
          end
          return nil, "timeout"
        end,
        close = function() end,
      }
    end
    local resp_body_timeout, err_code_body_timeout, err_msg_body_timeout = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_body_timeout, nil, "client body timeout response")
    assert_eq(err_code_body_timeout, "timeout", "client body timeout code")
    assert_true(type(err_msg_body_timeout) == "string" and err_msg_body_timeout:find("body timeout", 1, true) ~= nil, "client body timeout message")

    ngx.socket.tcp = function()
      local sent_header = false
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == 4 and not sent_header then
            sent_header = true
            return string.char(0, 0, 0, 2)
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local resp_body_err, err_code_body_err, err_msg_body_err = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_body_err, nil, "client body receive error response")
    assert_eq(err_code_body_err, "receive_error", "client body receive error code")
    assert_true(type(err_msg_body_err) == "string" and err_msg_body_err:find("closed", 1, true) ~= nil, "client body receive error message")

    local scalar_buf = pack_frame(123)
    local scalar_pos = 1
    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          local out = scalar_buf:sub(scalar_pos, scalar_pos + n - 1)
          if out == nil or #out < n then
            return nil, "closed"
          end
          scalar_pos = scalar_pos + n
          return out
        end,
        close = function() end,
      }
    end
    local resp_scalar, err_code_scalar, err_msg_scalar = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_scalar, nil, "client scalar JSON response should fail")
    assert_eq(err_code_scalar, "invalid_response", "client scalar JSON error code")
    assert_true(type(err_msg_scalar) == "string" and err_msg_scalar:find("JSON object", 1, true) ~= nil, "client scalar JSON error message")

    local bad_headers_buf = pack_frame({ status = 200, headers = "bad", body = "ok" })
    local bad_headers_pos = 1
    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          local out = bad_headers_buf:sub(bad_headers_pos, bad_headers_pos + n - 1)
          if out == nil or #out < n then
            return nil, "closed"
          end
          bad_headers_pos = bad_headers_pos + n
          return out
        end,
        close = function() end,
      }
    end
    local resp_bad_headers, err_code_bad_headers, err_msg_bad_headers = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_bad_headers, nil, "client bad headers response should fail")
    assert_eq(err_code_bad_headers, "invalid_response", "client bad headers error code")
    assert_true(type(err_msg_bad_headers) == "string" and err_msg_bad_headers:find("headers must be", 1, true) ~= nil, "client bad headers message")

    local bad_body_buf = pack_frame({ status = 200, headers = {}, body = 123 })
    local bad_body_pos = 1
    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          local out = bad_body_buf:sub(bad_body_pos, bad_body_pos + n - 1)
          if out == nil or #out < n then
            return nil, "closed"
          end
          bad_body_pos = bad_body_pos + n
          return out
        end,
        close = function() end,
      }
    end
    local resp_bad_body, err_code_bad_body, err_msg_bad_body = client.call_unix("unix:/tmp/fn.sock", { fn = "demo", event = {} }, 2500)
    assert_eq(resp_bad_body, nil, "client bad body response should fail")
    assert_eq(err_code_bad_body, "invalid_response", "client bad body error code")
    assert_true(type(err_msg_bad_body) == "string" and err_msg_bad_body:find("body must be", 1, true) ~= nil, "client bad body message")

    local resp_bad_req, err_code_bad_req = client.call_unix("unix:/tmp/fn.sock", { bad = function() end }, 2500)
    assert_eq(resp_bad_req, nil, "client invalid request should fail")
    assert_eq(err_code_bad_req, "invalid_request", "client invalid request code")
  end)
end

local function test_core_http_client_request_paths()
  with_fake_ngx(function(_cache, _conc, _set_now)
    package.loaded["fastfn.core.http_client"] = nil
    local http_client = require("fastfn.core.http_client")

    ngx.re = {
      match = function(url)
        local scheme, authority, path = tostring(url or ""):match("^(https?)://([^/]+)(/.*)$")
        if scheme then
          return { scheme, authority, path }
        end
        local s2, a2 = tostring(url or ""):match("^(https?)://([^/]+)$")
        if s2 then
          return { s2, a2, nil }
        end
        return nil
      end,
    }

    local bad_resp, bad_err = http_client.request({ url = "not-a-url" })
    assert_eq(bad_resp, nil, "http client invalid url should fail")
    assert_eq(bad_err, "invalid_url", "http client invalid url code")

    local read_headers = get_upvalue(http_client.request, "read_headers")
    local read_chunked = get_upvalue(http_client.request, "read_chunked")
    local env_bool = get_upvalue(http_client.request, "env_bool")
    assert_true(type(read_headers) == "function", "http client read_headers helper")
    assert_true(type(read_chunked) == "function", "http client read_chunked helper")
    assert_true(type(env_bool) == "function", "http client env_bool helper")

    local rh_nil, rh_err = read_headers({
      receive = function()
        return nil, "hdr-down"
      end,
    })
    assert_eq(rh_nil, nil, "http client read_headers nil branch")
    assert_eq(rh_err, "hdr-down", "http client read_headers nil error")

    local saved_tonumber = tonumber
    tonumber = function(value, base)
      if base == 16 then
        return nil
      end
      return saved_tonumber(value, base)
    end
    local rc_nil, rc_err = read_chunked({
      receive = function(_, n)
        if n == "*l" then
          return "A"
        end
        return nil, "closed"
      end,
    }, nil)
    tonumber = saved_tonumber
    assert_eq(rc_nil, nil, "http client read_chunked invalid tonumber branch")
    assert_eq(rc_err, "invalid_chunk_size", "http client read_chunked invalid tonumber error")

    local rc_line_nil, rc_line_err = read_chunked({
      receive = function(_, n)
        if n == "*l" then
          return nil, "chunk-line-missing"
        end
        return nil, "closed"
      end,
    }, nil)
    assert_eq(rc_line_nil, nil, "http client read_chunked missing size line branch")
    assert_eq(rc_line_err, "chunk-line-missing", "http client read_chunked missing size line error")

    with_env({ FN_HTTP_VERIFY_TLS = false }, function()
      assert_eq(env_bool("FN_HTTP_VERIFY_TLS", true), true, "http client env_bool nil uses default")
    end)
    with_env({ FN_HTTP_VERIFY_TLS = "yes" }, function()
      assert_eq(env_bool("FN_HTTP_VERIFY_TLS", false), true, "http client env_bool true variants")
    end)
    with_env({ FN_HTTP_VERIFY_TLS = "maybe" }, function()
      assert_eq(env_bool("FN_HTTP_VERIFY_TLS", false), false, "http client env_bool invalid uses default")
    end)

    local lines = {
      "HTTP/1.1 200 OK\r",
      "Content-Length: 5\r",
      "X-Test: a\r",
      "X-Test: b\r",
      "",
    }
    local bytes = { "hello" }
    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          local v = table.remove(bytes, 1)
          if v == nil then
            return nil, "closed"
          end
          return v
        end,
        close = function() end,
      }
    end
    local resp_ok, err_ok = http_client.request({
      url = "http://example.com/hello",
      method = "POST",
      headers = { ["X-Req"] = "1" },
      body = "input",
      timeout_ms = 1200,
    })
    assert_eq(err_ok, nil, "http client success err should be nil")
    assert_eq(resp_ok.status, 200, "http client success status")
    assert_eq(resp_ok.body, "hello", "http client success body")
    assert_true(resp_ok.headers["x-test"]:find("a", 1, true) ~= nil, "http client merged duplicate headers")

    local chunk_lines = {
      "HTTP/1.1 200 OK\r",
      "Transfer-Encoding: chunked\r",
      "",
      "5\r",
      "0\r",
      "",
    }
    local chunk_bytes = { "hello", "\r\n" }
    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(chunk_lines, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          local v = table.remove(chunk_bytes, 1)
          if v == nil then
            return nil, "closed"
          end
          return v
        end,
        close = function() end,
      }
    end
    local resp_chunk, err_chunk = http_client.request({
      url = "http://example.com/chunk",
      max_body_bytes = 64,
    })
    assert_eq(err_chunk, nil, "http client chunked err should be nil")
    assert_eq(resp_chunk.body, "hello", "http client chunked body")

    local too_large_lines = {
      "HTTP/1.1 200 OK\r",
      "Content-Length: 10\r",
      "",
    }
    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(too_large_lines, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          return "xxxxxxxxxx"
        end,
        close = function() end,
      }
    end
    local resp_large, err_large = http_client.request({
      url = "http://example.com/large",
      max_body_bytes = 5,
    })
    assert_eq(resp_large, nil, "http client too large should fail")
    assert_eq(err_large, "response_too_large", "http client too large code")

    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        sslhandshake = function()
          return nil, "bad cert"
        end,
        close = function() end,
      }
    end
    local resp_tls, err_tls = http_client.request({
      url = "https://example.com/secure",
      timeout_ms = 1000,
      verify_tls = true,
    })
    assert_eq(resp_tls, nil, "http client tls should fail")
    assert_true(type(err_tls) == "string" and err_tls:find("tls_error:", 1, true) == 1, "http client tls error code")

    local invalid_headers_resp, invalid_headers_err = http_client.request({
      url = "http://example.com",
      headers = "bad",
    })
    assert_eq(invalid_headers_resp, nil, "http client invalid headers response")
    assert_eq(invalid_headers_err, "invalid_headers", "http client invalid headers code")

    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return nil, "refused"
        end,
        close = function() end,
      }
    end
    local connect_resp, connect_err = http_client.request({ url = "http://example.com/fail-connect" })
    assert_eq(connect_resp, nil, "http client connect error response")
    assert_true(type(connect_err) == "string" and connect_err:find("connect_error:", 1, true) == 1, "http client connect error code")

    ngx.socket.tcp = function()
      local lines2 = { "HTTP/1.1 200 OK\r", "Content-Length: 0\r", "" }
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function(_, data)
          if tostring(data):find("^GET ", 1, false) then
            return nil, "write_failed"
          end
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines2, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          return ""
        end,
        close = function() end,
      }
    end
    local send_resp, send_err = http_client.request({ url = "http://example.com/send-error" })
    assert_eq(send_resp, nil, "http client send error response")
    assert_true(type(send_err) == "string" and send_err:find("send_error:", 1, true) == 1, "http client send error code")

    ngx.socket.tcp = function()
      local lines_body_send = { "HTTP/1.1 200 OK\r", "Content-Length: 0\r", "" }
      local send_count = 0
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function(_, _data)
          send_count = send_count + 1
          if send_count == 1 then
            return true
          end
          return nil, "body_send_failed"
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines_body_send, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          return ""
        end,
        close = function() end,
      }
    end
    local body_send_resp, body_send_err = http_client.request({
      url = "http://example.com/body-send-error",
      method = "POST",
      body = "payload",
    })
    assert_eq(body_send_resp, nil, "http client body send error response")
    assert_true(type(body_send_err) == "string" and body_send_err:find("send_error:", 1, true) == 1, "http client body send error code")

    ngx.socket.tcp = function()
      local lines3 = { "NOT_HTTP\r" }
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines3, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local status_resp, status_err = http_client.request({ url = "http://example.com/bad-status" })
    assert_eq(status_resp, nil, "http client invalid status response")
    assert_eq(status_err, "invalid_status_line", "http client invalid status code")

    ngx.socket.tcp = function()
      local lines4 = { "HTTP/1.1 200 OK\r", "" }
      local chunks4 = { "abc", "def" }
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines4, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          local v = table.remove(chunks4, 1)
          if v == nil then
            return nil, "closed", ""
          end
          return v
        end,
        close = function() end,
      }
    end
    local close_resp, close_err = http_client.request({
      url = "http://example.com/close",
      max_body_bytes = 16,
    })
    assert_eq(close_err, nil, "http client read-to-close err")
    assert_eq(close_resp.body, "abcdef", "http client read-to-close body")

    local invalid_opts_resp, invalid_opts_err = http_client.request("bad")
    assert_eq(invalid_opts_resp, nil, "http client invalid options response")
    assert_eq(invalid_opts_err, "invalid_options", "http client invalid options code")

    local sent_chunks = {}
    ngx.socket.tcp = function()
      local lines5 = { "HTTP/1.1 200 OK\r", "Content-Length: 0\r", "" }
      return {
        settimeouts = function(_, ct, st, rt)
          assert_true(ct >= 50 and st >= 50 and rt >= 50, "http client timeout floor should clamp to >= 50ms")
        end,
        connect = function(_, host, port)
          assert_eq(host, "example.com", "http client host:port parse host")
          assert_eq(port, 8081, "http client host:port parse port")
          return true
        end,
        send = function(_, data)
          sent_chunks[#sent_chunks + 1] = tostring(data)
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines5, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          return ""
        end,
        close = function() end,
      }
    end
    local body_cast_resp, body_cast_err = http_client.request({
      url = "http://example.com:8081/cast",
      method = "POST",
      headers = { ["Content-Length"] = "3" },
      body = 123,
      timeout_ms = 1,
    })
    assert_eq(body_cast_err, nil, "http client body cast err")
    assert_eq(body_cast_resp.status, 200, "http client body cast status")
    assert_true(#sent_chunks >= 2, "http client should send request head and body")
    assert_true(sent_chunks[2] == "123", "http client should cast body to string")

    with_env({ FN_HTTP_VERIFY_TLS = "0" }, function()
      ngx.socket.tcp = function()
        local lines6 = { "HTTP/1.1 200 OK\r", "Content-Length: 0\r", "" }
        return {
          settimeouts = function() end,
          connect = function(_, host, port)
            assert_eq(host, "::1", "http client ipv6 host parse")
            assert_eq(port, 8443, "http client ipv6 port parse")
            return true
          end,
          sslhandshake = function(_, _, _, verify)
            assert_eq(verify, false, "http client env verify tls false")
            return true
          end,
          send = function()
            return true
          end,
          receive = function(_, n)
            if n == "*l" then
              local v = table.remove(lines6, 1)
              if v == nil then
                return nil, "closed"
              end
              return v
            end
            return ""
          end,
          close = function() end,
        }
      end
      local ipv6_tls_resp, ipv6_tls_err = http_client.request({
        url = "https://[::1]:8443/secure",
      })
      assert_eq(ipv6_tls_err, nil, "http client ipv6 tls err")
      assert_eq(ipv6_tls_resp.status, 200, "http client ipv6 tls status")
    end)

    ngx.socket.tcp = function()
      local lines7 = { "HTTP/1.1 200 OK\r", "Content-Length: 0\r", "" }
      return {
        settimeouts = function() end,
        connect = function(_, host, port)
          assert_eq(host, "::1", "http client ipv6 host without explicit port")
          assert_eq(port, nil, "http client ipv6 without explicit port keeps nil")
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines7, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          return ""
        end,
        close = function() end,
      }
    end
    local ipv6_plain_resp, ipv6_plain_err = http_client.request({ url = "http://[::1]/plain" })
    assert_eq(ipv6_plain_err, nil, "http client ipv6 plain err")
    assert_eq(ipv6_plain_resp.status, 200, "http client ipv6 plain status")

    ngx.socket.tcp = function()
      local lines8 = { "HTTP/1.1 200 OK\r", "Transfer-Encoding: chunked\r", "", "G\r" }
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines8, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local chunk_bad_resp, chunk_bad_err = http_client.request({ url = "http://example.com/chunk-bad" })
    assert_eq(chunk_bad_resp, nil, "http client invalid chunk response")
    assert_eq(chunk_bad_err, "invalid_chunk_size", "http client invalid chunk code")

    ngx.socket.tcp = function()
      local lines9 = { "HTTP/1.1 200 OK\r", "Transfer-Encoding: chunked\r", "", "A\r" }
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines9, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local chunk_limit_resp, chunk_limit_err = http_client.request({
      url = "http://example.com/chunk-limit",
      max_body_bytes = 5,
    })
    assert_eq(chunk_limit_resp, nil, "http client chunk limit response")
    assert_eq(chunk_limit_err, "response_too_large", "http client chunk limit code")

    ngx.socket.tcp = function()
      local lines10 = { "HTTP/1.1 200 OK\r", "Transfer-Encoding: chunked\r", "", "5\r" }
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines10, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          if n == 5 then
            return nil, "parterr"
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local chunk_part_resp, chunk_part_err = http_client.request({ url = "http://example.com/chunk-part" })
    assert_eq(chunk_part_resp, nil, "http client chunk part response")
    assert_eq(chunk_part_err, "parterr", "http client chunk part error")

    ngx.socket.tcp = function()
      local lines11 = { "HTTP/1.1 200 OK\r", "Transfer-Encoding: chunked\r", "", "5\r" }
      local read_chunk_done = false
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines11, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          if n == 5 and not read_chunk_done then
            read_chunk_done = true
            return "hello"
          end
          if n == 2 then
            return nil, "crlferr"
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local chunk_crlf_resp, chunk_crlf_err = http_client.request({ url = "http://example.com/chunk-crlf" })
    assert_eq(chunk_crlf_resp, nil, "http client chunk crlf response")
    assert_eq(chunk_crlf_err, "crlferr", "http client chunk crlf error")

    ngx.socket.tcp = function()
      local lines12 = { "HTTP/1.1 200 OK\r", "Transfer-Encoding: chunked\r", "", "0\r" }
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines12, 1)
            if v == nil then
              return nil, "trailerr"
            end
            return v
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local chunk_trailer_resp, chunk_trailer_err = http_client.request({ url = "http://example.com/chunk-trailer" })
    assert_eq(chunk_trailer_resp, nil, "http client chunk trailer response")
    assert_eq(chunk_trailer_err, "trailerr", "http client chunk trailer error")

    ngx.socket.tcp = function()
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            return nil, "slerr"
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local status_read_resp, status_read_err = http_client.request({ url = "http://example.com/status-read-error" })
    assert_eq(status_read_resp, nil, "http client status read error response")
    assert_true(type(status_read_err) == "string" and status_read_err:find("receive_error:slerr", 1, true) ~= nil, "http client status read error code")

    ngx.socket.tcp = function()
      local lines13 = { "HTTP/1.1 200 OK\r" }
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines13, 1)
            if v == nil then
              return nil, "hdrerr"
            end
            return v
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local headers_read_resp, headers_read_err = http_client.request({ url = "http://example.com/headers-read-error" })
    assert_eq(headers_read_resp, nil, "http client headers read error response")
    assert_true(type(headers_read_err) == "string" and headers_read_err:find("receive_error:hdrerr", 1, true) ~= nil, "http client headers read error code")

    ngx.socket.tcp = function()
      local lines14 = { "HTTP/1.1 200 OK\r", "Content-Length: 5\r", "" }
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines14, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          if n == 5 then
            return nil, "bodyerr"
          end
          return nil, "closed"
        end,
        close = function() end,
      }
    end
    local cl_body_resp, cl_body_err = http_client.request({ url = "http://example.com/cl-body-error" })
    assert_eq(cl_body_resp, nil, "http client content-length body error response")
    assert_true(type(cl_body_err) == "string" and cl_body_err:find("receive_error:bodyerr", 1, true) ~= nil, "http client content-length body error code")

    ngx.socket.tcp = function()
      local lines15 = { "HTTP/1.1 200 OK\r", "" }
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines15, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          return nil, "streamerr", ""
        end,
        close = function() end,
      }
    end
    local read_close_err_resp, read_close_err_code = http_client.request({ url = "http://example.com/read-close-error" })
    assert_eq(read_close_err_resp, nil, "http client read-to-close error response")
    assert_eq(read_close_err_code, "streamerr", "http client read-to-close error code")

    ngx.socket.tcp = function()
      local lines16 = { "HTTP/1.1 200 OK\r", "" }
      local chunks16 = { "abcdef" }
      return {
        settimeouts = function() end,
        connect = function()
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines16, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          local v = table.remove(chunks16, 1)
          if v == nil then
            return nil, "closed", ""
          end
          return v
        end,
        close = function() end,
      }
    end
    local read_close_large_resp, read_close_large_err = http_client.request({
      url = "http://example.com/read-close-large",
      max_body_bytes = 3,
    })
    assert_eq(read_close_large_resp, nil, "http client read-to-close too large response")
    assert_eq(read_close_large_err, "response_too_large", "http client read-to-close too large code")

    local original_match = ngx.re.match
    ngx.re.match = function(url, _, _)
      if tostring(url):find("badhost", 1, true) ~= nil then
        return { "http", "", "" }
      end
      if tostring(url):find("emptypath", 1, true) ~= nil then
        return { "http", "example.com", "" }
      end
      return original_match(url, [[^(https?)://([^/]+)(/.*)?$]], "jo")
    end

    local bad_host_resp, bad_host_err = http_client.request({ url = "http://badhost" })
    assert_eq(bad_host_resp, nil, "http client invalid host response")
    assert_eq(bad_host_err, "invalid_host", "http client invalid host code")

    ngx.socket.tcp = function()
      local lines17 = { "HTTP/1.1 200 OK\r", "Content-Length: 0\r", "" }
      return {
        settimeouts = function() end,
        connect = function(_, host, port)
          assert_eq(host, "example.com", "http client empty path host")
          assert_eq(port, 80, "http client empty path default port")
          return true
        end,
        send = function()
          return true
        end,
        receive = function(_, n)
          if n == "*l" then
            local v = table.remove(lines17, 1)
            if v == nil then
              return nil, "closed"
            end
            return v
          end
          return ""
        end,
        close = function() end,
      }
    end
    local empty_path_resp, empty_path_err = http_client.request({ url = "http://emptypath" })
    assert_eq(empty_path_err, nil, "http client empty path err")
    assert_eq(empty_path_resp.status, 200, "http client empty path status")
    ngx.re.match = original_match
  end)
end

local function test_jobs_module_queue_and_result()
  with_fake_ngx(function(cache, conc, set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-jobs-" .. uniq
    rm_rf(root)
    mkdir_p(root)

    local runtime_cfg = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true }
    local policy_methods = { "GET", "POST" }
    local policy_max_body = 4096
    local runtime_up = true
    local function resolve_numeric(a, b, c, d)
      local values = { a, b, c, d }
      for _, value in ipairs(values) do
        local n = tonumber(value)
        if n then
          return n
        end
      end
      return nil
    end

	    local routes_stub = {
	      get_config = function()
	        -- Ensure job specs/results are written under this test's temp dir rather than shared /tmp paths.
	        return { functions_root = root, socket_base_dir = root, runtimes = { lua = runtime_cfg } }
	      end,
	      resolve_named_target = function(fn_name, version)
	        if fn_name == "demo" then
	          return "lua", version
	        end
	        return nil, nil
	      end,
	      discover_functions = function()
	        return {
	          mapped_routes = {
	            ["/mapped/:id"] = {
              { runtime = "lua", fn_name = "demo", version = nil, methods = { "GET" } },
            },
          },
          runtimes = {},
        }
      end,
      resolve_function_policy = function(runtime, name, _version)
        if runtime ~= "lua" or name ~= "demo" then
          return nil, "unknown function"
        end
        return {
          methods = policy_methods,
          timeout_ms = 1200,
          max_concurrency = 2,
          max_body_bytes = policy_max_body,
          include_debug_headers = true,
        }
      end,
      get_runtime_config = function(runtime)
        if runtime == "lua" then
          return runtime_cfg
        end
        return nil
      end,
      runtime_is_up = function(_runtime)
        return runtime_up
      end,
      check_runtime_health = function(_runtime, _cfg)
        if runtime_up then
          return true, "ok"
        end
        return false, "down"
      end,
      set_runtime_health = function() end,
      runtime_is_in_process = function(_runtime, cfg)
        return cfg and cfg.in_process == true
      end,
      resolve_function_source_dir = function(runtime, name)
        if runtime == "lua" and name == "demo" then
          return "jobs/demo"
        end
        return nil
      end,
    }

    local inflight = {}
    local limits_stub = {
      try_acquire = function(_dict, key, max_concurrency)
        local next_value = (inflight[key] or 0) + 1
        if tonumber(max_concurrency) and tonumber(max_concurrency) > 0 and next_value > tonumber(max_concurrency) then
          return false, "busy"
        end
        inflight[key] = next_value
        return true
      end,
      release = function(_dict, key)
        local next_value = (inflight[key] or 1) - 1
        if next_value < 0 then
          next_value = 0
        end
        inflight[key] = next_value
      end,
    }

    local utils_stub = {
      resolve_numeric = resolve_numeric,
      map_runtime_error = function(code)
        if code == "timeout" then
          return 504, "runtime timeout"
        end
        if code == "connect_error" then
          return 503, "runtime down"
        end
        return 502, "runtime error"
      end,
    }

    local lua_calls = {}
    local lua_runtime_stub = {
      call = function(payload)
        lua_calls[#lua_calls + 1] = payload
        return {
          status = 200,
          headers = { ["Content-Type"] = "application/json" },
          body = cjson.encode({ ok = true }),
        }
      end,
    }

    local invoke_rules_stub = {
      normalize_route = function(route)
        if type(route) == "string" and route:sub(1, 1) == "/" then
          return route
        end
        return nil
      end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.limits"] = limits_stub,
      ["fastfn.core.gateway_utils"] = utils_stub,
      ["fastfn.core.lua_runtime"] = lua_runtime_stub,
      ["fastfn.core.client"] = { call_unix = function() return nil, "connect_error", "down" end },
      ["fastfn.core.invoke_rules"] = invoke_rules_stub,
    }, function()
      package.loaded["fastfn.core.jobs"] = nil
      local jobs = require("fastfn.core.jobs")

      local queue_tick = nil
      ngx.timer.every = function(_interval, fn)
        queue_tick = fn
        return true
      end

      with_env({
        FN_JOBS_ENABLED = "1",
        FN_JOBS_POLL_INTERVAL = "1",
        FN_JOBS_MAX_CONCURRENCY = "2",
        FN_JOBS_MAX_RESULT_BYTES = "4096",
      }, function()
        jobs.init()
        assert_true(type(queue_tick) == "function", "jobs init should register queue timer")

        local meta, status = jobs.enqueue({
          runtime = "lua",
          name = "demo",
          method = "POST",
          route = "/demo/:id",
          params = { id = "abc" },
          query = { q = "1" },
          headers = { ["x-id"] = "1" },
          body = { hello = "world" },
          context = { source = "unit" },
          max_attempts = 2,
        })
        assert_eq(status, 201, "jobs enqueue status")
        assert_true(type(meta.id) == "string" and meta.id ~= "", "jobs enqueue id")
        assert_eq(meta.route, "/demo/abc", "jobs resolved route")

        queue_tick(false)
        local done_meta = jobs.get(meta.id)
        assert_true(type(done_meta) == "table", "jobs get after run")
        assert_eq(done_meta.status, "done", "jobs run should finish done")
        local result = jobs.read_result(meta.id)
        assert_true(type(result) == "table", "jobs read_result")
        assert_eq(result.status, 200, "jobs result status")
        assert_true(type(result.body) == "string" and result.body:find("\"ok\":true", 1, true) ~= nil, "jobs result body")
        assert_true(#lua_calls >= 1, "jobs should invoke in-process lua runtime")
        assert_eq((((lua_calls[1] or {}).fn_source_dir)), "jobs/demo", "jobs should pass fn_source_dir to runtime payload")

        local mapped_meta, mapped_status = jobs.enqueue({
          runtime = "lua",
          name = "demo",
          method = "GET",
          params = { id = "mapped-id" },
        })
        assert_eq(mapped_status, 201, "jobs mapped route status")
        assert_eq(mapped_meta.route, "/mapped/mapped-id", "jobs mapped route interpolation")
        local canceled, cancel_status = jobs.cancel(mapped_meta.id)
        assert_eq(cancel_status, 200, "jobs cancel status")
        assert_eq(canceled.status, "canceled", "jobs cancel state")

        local missing_runtime_meta, missing_runtime_status, missing_runtime_err = jobs.enqueue({
          name = "demo",
          params = { id = "resolved" },
        })
        assert_eq(missing_runtime_err, nil, "jobs runtime optional error")
        assert_eq(missing_runtime_status, 201, "jobs runtime optional status")
        assert_eq(missing_runtime_meta.runtime, "lua", "jobs runtime optional resolved runtime")
        assert_eq(missing_runtime_meta.route, "/mapped/resolved", "jobs runtime optional resolved route")
        -- Prevent this queued job from interfering with later queue_tick() assertions.
        local canceled_missing, canceled_missing_status = jobs.cancel(missing_runtime_meta.id)
        assert_eq(canceled_missing_status, 200, "jobs runtime optional cancel status")
        assert_eq(canceled_missing.status, "canceled", "jobs runtime optional cancel state")
        -- Drain the canceled job from the in-memory queue so later queue assertions are deterministic.
        queue_tick(false)

        local missing_param, missing_param_status, missing_param_err = jobs.enqueue({
          runtime = "lua",
          name = "demo",
          method = "GET",
        })
        assert_eq(missing_param, nil, "jobs missing param response")
        assert_eq(missing_param_status, 400, "jobs missing param status")
        assert_true(
          type(missing_param_err) == "string" and missing_param_err:find("missing required path params", 1, true) ~= nil,
          "jobs missing param error"
        )

        local invalid_context, invalid_context_status = jobs.enqueue({
          runtime = "lua",
          name = "demo",
          method = "POST",
          route = "/demo/:id",
          params = { id = "x" },
          context = "bad",
        })
        assert_eq(invalid_context, nil, "jobs invalid context response")
        assert_eq(invalid_context_status, 400, "jobs invalid context status")

        policy_methods = { "GET" }
        local not_allowed, not_allowed_status, not_allowed_err, not_allowed_headers = jobs.enqueue({
          runtime = "lua",
          name = "demo",
          method = "POST",
          route = "/demo/:id",
          params = { id = "x" },
        })
        assert_eq(not_allowed, nil, "jobs method not allowed response")
        assert_eq(not_allowed_status, 405, "jobs method not allowed status")
        assert_eq(not_allowed_err, "method not allowed", "jobs method not allowed error")
        assert_true(type(not_allowed_headers) == "table" and not_allowed_headers.Allow == "GET", "jobs method not allowed allow header")
        policy_methods = { "GET", "POST" }

        policy_max_body = 3
        local too_large, too_large_status, too_large_err = jobs.enqueue({
          runtime = "lua",
          name = "demo",
          method = "POST",
          route = "/demo/:id",
          params = { id = "x" },
          body = "abcd",
        })
        assert_eq(too_large, nil, "jobs payload too large response")
        assert_eq(too_large_status, 413, "jobs payload too large status")
        assert_eq(too_large_err, "payload too large", "jobs payload too large error")
        policy_max_body = 4096

        local retry_meta, retry_status = jobs.enqueue({
          runtime = "lua",
          name = "demo",
          method = "POST",
          route = "/demo/:id",
          params = { id = "retry" },
          max_attempts = 2,
          retry_delay_ms = 1000,
        })
        assert_eq(retry_status, 201, "jobs retry enqueue status")
        runtime_up = false
        queue_tick(false)
        local retry_after_fail = jobs.get(retry_meta.id)
        assert_true(type(retry_after_fail) == "table", "jobs retry meta after first run")
        assert_eq(retry_after_fail.status, "queued", "jobs retry should requeue after first failure")
        local retry_fail_result = jobs.read_result(retry_meta.id)
        assert_true(type(retry_fail_result) == "table", "jobs retry first result")
        assert_eq(retry_fail_result.status, 503, "jobs retry first status should reflect runtime down")
        runtime_up = true
        set_now(1002)
        queue_tick(false)
        local retry_done = jobs.get(retry_meta.id)
        assert_eq(retry_done.status, "done", "jobs retry should finish once runtime is healthy")

        local list_items = jobs.list(10)
        assert_true(type(list_items) == "table" and #list_items >= 2, "jobs list should include recent jobs")
        assert_eq(jobs.read_result("missing"), nil, "jobs missing result should be nil")
      end)

      with_env({ FN_JOBS_ENABLED = "0" }, function()
        local disabled_resp, disabled_status, disabled_err = jobs.enqueue({
          runtime = "lua",
          name = "demo",
        })
        assert_eq(disabled_resp, nil, "jobs disabled response")
        assert_eq(disabled_status, 404, "jobs disabled status")
        assert_eq(disabled_err, "jobs disabled", "jobs disabled error")
      end)
    end)

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

local function test_scheduler_tick_and_snapshot()
  with_fake_ngx(function(cache, conc, set_now)
    local runtime_cfg = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true }
    local runtime_up = true
    local scheduler_methods = { "GET", "POST" }
    local scheduler_max_body = 4096
    local function fn_policy()
      return {
        methods = scheduler_methods,
        timeout_ms = 1200,
        max_concurrency = 2,
        max_body_bytes = scheduler_max_body,
        schedule = {
          enabled = true,
          every_seconds = 1,
          method = "POST",
          body = "{\"ok\":true}",
        },
        keep_warm = {
          enabled = true,
          min_warm = 1,
          ping_every_seconds = 1,
          idle_ttl_seconds = 1,
        },
      }
    end

	    local routes_stub = {
	      get_config = function()
	        return {
	          runtimes = { lua = runtime_cfg },
	        }
	      end,
	      resolve_named_target = function(fn_name, version)
	        if fn_name == "demo" then
	          return "lua", version
	        end
	        return nil, nil
	      end,
	      discover_functions = function()
	        return {
	          runtimes = {
	            lua = {
              functions = {
                demo = {
                  has_default = true,
                  versions = { "v2" },
                  policy = fn_policy(),
                  versions_policy = {
                    v2 = fn_policy(),
                  },
                },
              },
            },
          },
        }
      end,
      resolve_function_policy = function(runtime, name, _version)
        if runtime ~= "lua" or name ~= "demo" then
          return nil, "not found"
        end
        return fn_policy()
      end,
      get_runtime_config = function(runtime)
        if runtime == "lua" then
          return runtime_cfg
        end
        return nil
      end,
      runtime_is_up = function(_runtime)
        return runtime_up
      end,
      check_runtime_health = function(_runtime, _cfg)
        if runtime_up then
          return true, "ok"
        end
        return false, "down"
      end,
      set_runtime_health = function() end,
      runtime_is_in_process = function(_runtime, cfg)
        return cfg and cfg.in_process == true
      end,
      resolve_function_source_dir = function(runtime, name)
        if runtime == "lua" and name == "demo" then
          return "scheduler/demo"
        end
        return nil
      end,
    }

    local inflight = {}
    local limits_stub = {
      try_acquire = function(_dict, key, max_concurrency)
        local next_value = (inflight[key] or 0) + 1
        if tonumber(max_concurrency) and tonumber(max_concurrency) > 0 and next_value > tonumber(max_concurrency) then
          return false, "busy"
        end
        inflight[key] = next_value
        return true
      end,
      release = function(_dict, key)
        local next_value = (inflight[key] or 1) - 1
        if next_value < 0 then
          next_value = 0
        end
        inflight[key] = next_value
      end,
    }

    local lua_calls = {}
    local lua_runtime_stub = {
      call = function(payload)
        lua_calls[#lua_calls + 1] = payload
        return {
          status = 200,
          headers = { ["Content-Type"] = "application/json" },
          body = "{\"ok\":true}",
        }
      end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.limits"] = limits_stub,
      ["fastfn.core.lua_runtime"] = lua_runtime_stub,
      ["fastfn.core.client"] = { call_unix = function() return nil, "connect_error", "down" end },
      ["fastfn.core.gateway_utils"] = {
        map_runtime_error = function(code)
          if code == "connect_error" then
            return 503, "runtime down"
          end
          return 502, "runtime error"
        end,
      },
    }, function()
      package.loaded["fastfn.core.scheduler"] = nil
      local scheduler = require("fastfn.core.scheduler")

      local tick_fn = nil
      local tick_interval = nil
      ngx.timer.every = function(interval, fn)
        tick_interval = interval
        tick_fn = fn
        return true
      end

      with_env({ FN_SCHEDULER_ENABLED = "0" }, function()
        tick_fn = nil
        scheduler.init()
        assert_eq(tick_fn, nil, "scheduler should not start when disabled")
      end)

      with_env({
        FN_SCHEDULER_ENABLED = "1",
        FN_SCHEDULER_INTERVAL = "0",
      }, function()
        scheduler.init()
        assert_eq(tick_interval, 1, "scheduler interval floor")
        assert_true(type(tick_fn) == "function", "scheduler init should register timer")
      end)

      set_now(1000)
      tick_fn(false)
      set_now(1002)
      tick_fn(false)

      assert_true(#lua_calls >= 2, "scheduler should invoke lua runtime for schedule/keep_warm")
      assert_eq((((lua_calls[1] or {}).fn_source_dir)), "scheduler/demo", "scheduler should pass fn_source_dir to runtime payload")
      local snapshot = scheduler.snapshot()
      assert_true(type(snapshot) == "table", "scheduler snapshot table")
      assert_true(type(snapshot.schedules) == "table" and #snapshot.schedules >= 1, "scheduler snapshot schedules")
      assert_true(type(snapshot.keep_warm) == "table" and #snapshot.keep_warm >= 1, "scheduler snapshot keep_warm")

      local function has_last_status(snap, wanted)
        for _, row in ipairs((snap and snap.schedules) or {}) do
          local got = tonumber(((row or {}).state or {}).last_status)
          if got == wanted then
            return true
          end
        end
        return false
      end

      runtime_up = false
      set_now(1004)
      tick_fn(false)
      local snap_down = scheduler.snapshot()
      assert_true(has_last_status(snap_down, 503), "scheduler should record 503 when runtime is down")

      runtime_up = true
      scheduler_methods = { "GET" }
      set_now(1006)
      tick_fn(false)
      local snap_method = scheduler.snapshot()
      assert_true(has_last_status(snap_method, 405), "scheduler should record 405 when method is disallowed")

      scheduler_methods = { "GET", "POST" }
      scheduler_max_body = 1
      set_now(1008)
      tick_fn(false)
      local snap_body = scheduler.snapshot()
      assert_true(has_last_status(snap_body, 413), "scheduler should record 413 when body exceeds max size")

      reset_shared_dict(cache)
      reset_shared_dict(conc)
    end)
  end)
end

local function test_scheduler_cron_and_retry_backoff()
  with_fake_ngx(function(cache, conc, set_now)
    local runtime_cfg = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true }
    local runtime_up = true

	    local routes_stub = {
	      get_config = function()
	        return { runtimes = { lua = runtime_cfg } }
	      end,
	      resolve_named_target = function(fn_name, version)
	        if fn_name == "demo" then
	          return "lua", version
	        end
	        return nil, nil
	      end,
	      discover_functions = function()
	        return {
	          runtimes = {
	            lua = {
              functions = {
                demo = {
                  has_default = true,
                  versions = {},
                  policy = {
                    methods = { "GET" },
                    timeout_ms = 500,
                    schedule = {
                      enabled = true,
                      cron = "*/1 * * * * *",
                      timezone = "UTC",
                      method = "GET",
                      retry = {
                        enabled = true,
                        max_attempts = 3,
                        base_delay_seconds = 1,
                        max_delay_seconds = 1,
                        jitter = 0,
                      },
                    },
                  },
                },
              },
            },
          },
        }
      end,
      resolve_function_policy = function(runtime, name, _version)
        if runtime ~= "lua" or name ~= "demo" then
          return nil, "not found"
        end
        return {
          methods = { "GET" },
          timeout_ms = 500,
          max_concurrency = 1,
          schedule = {
            enabled = true,
            cron = "*/1 * * * * *",
            timezone = "UTC",
            method = "GET",
            retry = {
              enabled = true,
              max_attempts = 3,
              base_delay_seconds = 1,
              max_delay_seconds = 1,
              jitter = 0,
            },
          },
        }
      end,
      get_runtime_config = function(runtime)
        if runtime == "lua" then
          return runtime_cfg
        end
        return nil
      end,
      runtime_is_up = function(_runtime)
        return runtime_up
      end,
      check_runtime_health = function(_runtime, _cfg)
        if runtime_up then
          return true, "ok"
        end
        return false, "down"
      end,
      set_runtime_health = function() end,
      runtime_is_in_process = function(_runtime, cfg)
        return cfg and cfg.in_process == true
      end,
    }

    local inflight = {}
    local limits_stub = {
      try_acquire = function(_dict, key, max_concurrency)
        local next_value = (inflight[key] or 0) + 1
        if tonumber(max_concurrency) and tonumber(max_concurrency) > 0 and next_value > tonumber(max_concurrency) then
          return false, "busy"
        end
        inflight[key] = next_value
        return true
      end,
      release = function(_dict, key)
        local next_value = (inflight[key] or 1) - 1
        if next_value < 0 then
          next_value = 0
        end
        inflight[key] = next_value
      end,
    }

    local lua_calls = 0
    local lua_runtime_stub = {
      call = function(_payload)
        lua_calls = lua_calls + 1
        return {
          status = 200,
          headers = { ["Content-Type"] = "application/json" },
          body = "{\"ok\":true}",
        }
      end,
    }

    local timers = {}
    ngx.timer.at = function(delay, fn, ...)
      timers[#timers + 1] = {
        delay = tonumber(delay) or 0,
        fn = fn,
        args = { ... },
      }
      return true
    end

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.limits"] = limits_stub,
      ["fastfn.core.lua_runtime"] = lua_runtime_stub,
      ["fastfn.core.client"] = { call_unix = function() return nil, "connect_error", "down" end },
      ["fastfn.core.gateway_utils"] = {
        map_runtime_error = function(code)
          if code == "connect_error" then
            return 503, "runtime down"
          end
          return 502, "runtime error"
        end,
      },
    }, function()
      package.loaded["fastfn.core.scheduler"] = nil
      local scheduler = require("fastfn.core.scheduler")

      local tick_fn = nil
      ngx.timer.every = function(_interval, fn)
        tick_fn = fn
        return true
      end

      scheduler.init()
      assert_true(type(tick_fn) == "function", "scheduler init should register timer")

      -- Tick 1: seed next cron run (no dispatch yet).
      set_now(1000)
      tick_fn(false)
      assert_true(#timers == 0, "cron seeding should not dispatch immediately")

      -- Tick 2: due -> dispatch; runtime is down so first attempt schedules retry.
      runtime_up = false
      set_now(1001)
      tick_fn(false)
      assert_true(#timers >= 1, "schedule invocation should be queued via timer.at")

      local t1 = table.remove(timers, 1)
      assert_eq(math.floor(t1.delay), 0, "first attempt delay")
      t1.fn(false, unpack(t1.args))

      assert_true(#timers >= 1, "retry timer queued")
      local t2 = table.remove(timers, 1)
      assert_eq(math.floor(t2.delay), 1, "retry delay seconds")

      runtime_up = true
      set_now(1002)
      t2.fn(false, unpack(t2.args))
      assert_eq(lua_calls, 1, "lua runtime should be called once after recovery")

      local snapshot = scheduler.snapshot()
      assert_true(type(snapshot) == "table" and type(snapshot.schedules) == "table", "snapshot structure")

      local found_ok = false
      for _, row in ipairs(snapshot.schedules) do
        local status = tonumber(((row or {}).state or {}).last_status)
        if status == 200 then
          found_ok = true
        end
      end
      assert_true(found_ok, "cron schedule should record 200 after retry")

      reset_shared_dict(cache)
      reset_shared_dict(conc)
    end)
  end)
end

local function test_scheduler_cron_timezone_and_invalid_timezone()
  with_fake_ngx(function(cache, conc, set_now)
    local runtime_cfg = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true }

    local function policy_for(name)
      if name == "offset" then
        return {
          methods = { "GET" },
          timeout_ms = 500,
          max_concurrency = 1,
          schedule = {
            enabled = true,
            cron = "0 9 * * *",
            timezone = "-05:00",
            method = "GET",
          },
        }
      end
      if name == "badtz" then
        return {
          methods = { "GET" },
          timeout_ms = 500,
          max_concurrency = 1,
          schedule = {
            enabled = true,
            cron = "0 9 * * *",
            timezone = "Mars/Phobos",
            method = "GET",
          },
        }
      end
      return nil
    end

	    local routes_stub = {
	      get_config = function()
	        return { runtimes = { lua = runtime_cfg } }
	      end,
	      resolve_named_target = function(fn_name, version)
	        if fn_name == "offset" or fn_name == "badtz" then
	          return "lua", version
	        end
	        return nil, nil
	      end,
	      discover_functions = function()
	        return {
	          runtimes = {
	            lua = {
              functions = {
                offset = { has_default = true, versions = {}, policy = policy_for("offset") },
                badtz = { has_default = true, versions = {}, policy = policy_for("badtz") },
              },
            },
          },
        }
      end,
      resolve_function_policy = function(runtime, name, _version)
        if runtime ~= "lua" then
          return nil, "not found"
        end
        local out = policy_for(name)
        if not out then
          return nil, "not found"
        end
        return out
      end,
      get_runtime_config = function(runtime)
        if runtime == "lua" then
          return runtime_cfg
        end
        return nil
      end,
      runtime_is_up = function(_runtime)
        return true
      end,
      check_runtime_health = function(_runtime, _cfg)
        return true, "ok"
      end,
      set_runtime_health = function() end,
      runtime_is_in_process = function(_runtime, cfg)
        return cfg and cfg.in_process == true
      end,
    }

    local limits_stub = {
      try_acquire = function()
        return true
      end,
      release = function() end,
    }

    local lua_runtime_stub = {
      call = function(_payload)
        return {
          status = 200,
          headers = { ["Content-Type"] = "application/json" },
          body = "{\"ok\":true}",
        }
      end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.limits"] = limits_stub,
      ["fastfn.core.lua_runtime"] = lua_runtime_stub,
      ["fastfn.core.client"] = { call_unix = function() return nil, "connect_error", "down" end },
      ["fastfn.core.gateway_utils"] = {
        map_runtime_error = function(code)
          if code == "connect_error" then
            return 503, "runtime down"
          end
          return 502, "runtime error"
        end,
      },
    }, function()
      package.loaded["fastfn.core.scheduler"] = nil
      local scheduler = require("fastfn.core.scheduler")

      local tick_fn = nil
      ngx.timer.every = function(_interval, fn)
        tick_fn = fn
        return true
      end

      scheduler.init()
      assert_true(type(tick_fn) == "function", "scheduler init should register timer")

      set_now(0)
      tick_fn(false)

      local snap = scheduler.snapshot()
      local next_offset = nil
      local bad_err = nil

      for _, row in ipairs((snap and snap.schedules) or {}) do
        if row.name == "offset" then
          next_offset = tonumber(((row.state or {}).next))
        elseif row.name == "badtz" then
          bad_err = (row.state or {}).last_error
        end
      end

      -- Epoch 00:00 UTC, cron is 09:00 in -05:00 -> 14:00 UTC => 14 * 3600 = 50400.
      assert_eq(next_offset, 50400, "timezone offset should shift cron schedule next time")
      assert_true(type(bad_err) == "string" and bad_err:find("unsupported timezone", 1, true) ~= nil, "invalid timezone should surface in last_error")

      reset_shared_dict(cache)
      reset_shared_dict(conc)
    end)
  end)
end

local function test_scheduler_internal_cron_helpers()
  with_fake_ngx(function(cache, conc, _set_now)
    local routes_stub = {
      get_config = function()
        return { functions_root = "/tmp", runtimes = { lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true } } }
      end,
      runtime_is_up = function()
        return true
      end,
      check_runtime_health = function()
        return true, "ok"
      end,
      set_runtime_health = function() end,
      resolve_function_policy = function()
        return {}
      end,
      runtime_is_in_process = function()
        return true
      end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.limits"] = { try_acquire = function() return true end, release = function() end },
      ["fastfn.core.lua_runtime"] = { call = function() return { status = 200, headers = {}, body = "" } end },
      ["fastfn.core.client"] = { call_unix = function() return { status = 200, headers = {}, body = "" } end },
      ["fastfn.core.gateway_utils"] = { map_runtime_error = function() return 502, "runtime error" end },
    }, function()
      package.loaded["fastfn.core.scheduler"] = nil
      local scheduler = require("fastfn.core.scheduler")

      local tick_once = get_upvalue(scheduler.init, "tick_once")
      assert_true(type(tick_once) == "function", "tick_once helper should be available")

      local compute_next_cron_ts = get_upvalue(tick_once, "compute_next_cron_ts")
      local parse_cron = get_upvalue(compute_next_cron_ts, "parse_cron")
      local parse_timezone_offset = get_upvalue(compute_next_cron_ts, "parse_timezone_offset")
      local cron_field = get_upvalue(parse_cron, "cron_field")
      local cron_value = get_upvalue(cron_field, "cron_value")
      local schedule_retry_config = get_upvalue(tick_once, "schedule_retry_config")
      local dispatch_schedule_invocation = get_upvalue(tick_once, "dispatch_schedule_invocation")
      local retry_delay_seconds = get_upvalue(dispatch_schedule_invocation, "retry_delay_seconds")
      local status_retryable = get_upvalue(dispatch_schedule_invocation, "status_retryable")

      assert_true(type(parse_cron) == "function", "parse_cron helper should be available")
      assert_true(type(parse_timezone_offset) == "function", "parse_timezone_offset helper should be available")
      assert_true(type(cron_field) == "function", "cron_field helper should be available")
      assert_true(type(cron_value) == "function", "cron_value helper should be available")
      assert_true(type(schedule_retry_config) == "function", "schedule_retry_config helper should be available")
      assert_true(type(retry_delay_seconds) == "function", "retry_delay_seconds helper should be available")
      assert_true(type(status_retryable) == "function", "status_retryable helper should be available")

      local tz0 = parse_timezone_offset("UTC")
      assert_eq(tz0, 0, "UTC timezone should resolve to zero offset")
      local tz_local = parse_timezone_offset("local")
      assert_eq(tz_local, nil, "local timezone should resolve to nil offset")
      local tz_plus = parse_timezone_offset("+0530")
      assert_eq(tz_plus, 19800, "timezone +0530 should be parsed")
      local tz_minus = parse_timezone_offset("-05:30")
      assert_eq(tz_minus, -19800, "timezone -05:30 should be parsed")
      local tz_bad, tz_err = parse_timezone_offset("Mars/Phobos")
      assert_eq(tz_bad, nil, "unsupported timezone should fail")
      assert_true(type(tz_err) == "string" and tz_err:find("unsupported timezone", 1, true) ~= nil, "unsupported timezone error")

      local mon = { MON = 1 }
      local cv1 = cron_value("MON", mon, false)
      assert_eq(cv1, 1, "cron_value should parse named token")
      local cv2 = cron_value("7", nil, true)
      assert_eq(cv2, 0, "cron_value should normalize sunday=7 when allowed")
      local cv_bad, cv_err = cron_value("", nil, false)
      assert_eq(cv_bad, nil, "empty cron token should fail")
      assert_true(type(cv_err) == "string" and cv_err:find("empty token", 1, true) ~= nil, "empty token error")

      local all_hours = cron_field("*", 0, 23, nil, false)
      assert_true(type(all_hours) == "table" and all_hours.any == true, "wildcard cron field should be any=true")
      local stepped = cron_field("*/15", 0, 59, nil, false)
      assert_true(stepped.set[0] == true and stepped.set[15] == true and stepped.set[45] == true, "step field should include expected values")
      local named_range = cron_field("MON-FRI", 0, 6, { MON = 1, FRI = 5 }, true)
      assert_true(named_range.set[1] == true and named_range.set[5] == true, "named range should parse")
      local bad_step, bad_step_err = cron_field("1/0", 0, 59, nil, false)
      assert_eq(bad_step, nil, "invalid cron step should fail")
      assert_true(type(bad_step_err) == "string" and bad_step_err:find("invalid step", 1, true) ~= nil, "invalid step error")
      local bad_range, bad_range_err = cron_field("99", 0, 59, nil, false)
      assert_eq(bad_range, nil, "out of range cron value should fail")
      assert_true(type(bad_range_err) == "string" and bad_range_err:find("out of range", 1, true) ~= nil, "out of range error")

      local spec_hourly, spec_hourly_err = parse_cron("@hourly")
      assert_true(type(spec_hourly) == "table" and spec_hourly_err == nil, "hourly macro should parse")
      local spec_6, spec_6_err = parse_cron("0 */5 * * * *")
      assert_true(type(spec_6) == "table" and spec_6_err == nil, "6-field cron should parse")
      local spec_bad, spec_bad_err = parse_cron("bad cron expression")
      assert_eq(spec_bad, nil, "invalid cron expression should fail")
      assert_true(type(spec_bad_err) == "string" and spec_bad_err:find("5 or 6 fields", 1, true) ~= nil, "invalid cron field count error")
      local spec_bad_mins, spec_bad_mins_err = parse_cron("61 * * * *")
      assert_eq(spec_bad_mins, nil, "invalid minute range should fail")
      assert_true(type(spec_bad_mins_err) == "string" and spec_bad_mins_err:find("minutes", 1, true) ~= nil, "minute error should be surfaced")

      local next_ts, next_err = compute_next_cron_ts(1700000000, "*/5 * * * *", "UTC", false)
      assert_true(type(next_ts) == "number" and next_ts > 1700000000 and next_err == nil, "compute_next_cron_ts should return next timestamp")
      local inclusive_ts, inclusive_err = compute_next_cron_ts(1700000000, "*/5 * * * *", "UTC", true)
      assert_true(type(inclusive_ts) == "number" and inclusive_ts >= 1700000000 and inclusive_err == nil, "inclusive cron compute should succeed")
      local bad_tz_next, bad_tz_next_err = compute_next_cron_ts(1700000000, "*/5 * * * *", "Mars/Phobos", false)
      assert_eq(bad_tz_next, nil, "invalid timezone should fail cron compute")
      assert_true(type(bad_tz_next_err) == "string" and bad_tz_next_err:find("unsupported timezone", 1, true) ~= nil, "cron compute should surface timezone error")
      local prev_lookahead = get_upvalue(compute_next_cron_ts, "MAX_CRON_LOOKAHEAD_MINUTES")
      local patched_lookahead = set_upvalue(compute_next_cron_ts, "MAX_CRON_LOOKAHEAD_MINUTES", 32)
      assert_true(patched_lookahead, "MAX_CRON_LOOKAHEAD_MINUTES upvalue should be patchable")
      local impossible_next, impossible_next_err = compute_next_cron_ts(1700000000, "0 0 31 2 *", "UTC", false)
      set_upvalue(compute_next_cron_ts, "MAX_CRON_LOOKAHEAD_MINUTES", prev_lookahead)
      assert_eq(impossible_next, nil, "impossible cron should fail by lookahead")
      assert_true(type(impossible_next_err) == "string" and impossible_next_err:find("lookahead exceeded", 1, true) ~= nil, "cron lookahead exceeded error")

      local rc_disabled = schedule_retry_config(false)
      assert_eq(rc_disabled.enabled, false, "retry disabled should stay disabled")
      local rc_default = schedule_retry_config(true)
      assert_eq(rc_default.enabled, true, "retry true should enable defaults")
      assert_eq(rc_default.max_attempts, 3, "retry default max_attempts")
      local rc_clamped = schedule_retry_config({
        enabled = true,
        max_attempts = 99,
        base_delay_seconds = -1,
        max_delay_seconds = 99999,
        jitter = 2,
      })
      assert_eq(rc_clamped.max_attempts, 10, "max_attempts should clamp")
      assert_eq(rc_clamped.base_delay_seconds, 0, "base delay should clamp floor")
      assert_eq(rc_clamped.max_delay_seconds, 3600, "max delay should clamp ceiling")
      assert_eq(rc_clamped.jitter, 0.5, "jitter should clamp")

      local d1 = retry_delay_seconds({ base_delay_seconds = 1, max_delay_seconds = 2, jitter = 0 }, 10)
      assert_eq(d1, 2, "retry delay should respect max delay")
      local d2 = retry_delay_seconds({ base_delay_seconds = 0.5, max_delay_seconds = 10, jitter = 0.5 }, 1)
      assert_true(type(d2) == "number" and d2 >= 0, "retry delay with jitter should be non-negative")

      assert_eq(status_retryable(0), true, "status 0 should be retryable")
      assert_eq(status_retryable(429), true, "status 429 should be retryable")
      assert_eq(status_retryable(503), true, "status 503 should be retryable")
      assert_eq(status_retryable(500), true, "status >=500 should be retryable")
      assert_eq(status_retryable(404), false, "status 404 should not be retryable")

      reset_shared_dict(cache)
      reset_shared_dict(conc)
    end)
  end)
end

local function test_scheduler_persist_state_roundtrip()
  with_fake_ngx(function(cache, conc, _set_now)
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-scheduler-persist-" .. uniq
    local state_path = root .. "/scheduler-state.json"

    rm_rf(root)
    mkdir_p(root)

    local runtime_cfg = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true }
	    local routes_stub = {
	      get_config = function()
	        return { functions_root = root, runtimes = { lua = runtime_cfg } }
	      end,
	      resolve_named_target = function(fn_name, version)
	        if fn_name == "demo" then
	          return "lua", version
	        end
	        return nil, nil
	      end,
	      discover_functions = function()
	        return {
	          runtimes = {
	            lua = {
              functions = {
                demo = {
                  has_default = true,
                  versions = {},
                  policy = {
                    methods = { "GET" },
                    timeout_ms = 500,
                    schedule = { enabled = true, every_seconds = 60, method = "GET" },
                    keep_warm = { enabled = true, min_warm = 1, ping_every_seconds = 60, idle_ttl_seconds = 60 },
                  },
                },
              },
            },
          },
        }
      end,
      resolve_function_policy = function(runtime, name, _version)
        if runtime ~= "lua" or name ~= "demo" then
          return nil, "not found"
        end
        return {
          methods = { "GET" },
          timeout_ms = 500,
          max_concurrency = 1,
          schedule = { enabled = true, every_seconds = 60, method = "GET" },
          keep_warm = { enabled = true, min_warm = 1, ping_every_seconds = 60, idle_ttl_seconds = 60 },
        }
      end,
      get_runtime_config = function(runtime)
        if runtime == "lua" then
          return runtime_cfg
        end
        return nil
      end,
      runtime_is_up = function()
        return true
      end,
      check_runtime_health = function()
        return true, "ok"
      end,
      set_runtime_health = function() end,
      runtime_is_in_process = function(_runtime, cfg)
        return cfg and cfg.in_process == true
      end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.limits"] = { try_acquire = function() return true end, release = function() end },
      ["fastfn.core.lua_runtime"] = { call = function() return { status = 200, headers = {}, body = "{}" } end },
      ["fastfn.core.client"] = { call_unix = function() return nil, "connect_error", "down" end },
      ["fastfn.core.gateway_utils"] = { map_runtime_error = function() return 503, "runtime down" end },
    }, function()
      with_env({
        FN_SCHEDULER_STATE_PATH = state_path,
        FN_SCHEDULER_PERSIST_ENABLED = "1",
        FN_SCHEDULER_PERSIST_INTERVAL = "3600",
      }, function()
        package.loaded["fastfn.core.scheduler"] = nil
        local scheduler = require("fastfn.core.scheduler")

        local key = "lua/demo@default"
        cache:set("sched:" .. key .. ":next", 2000)
        cache:set("sched:" .. key .. ":retry_due", 1600)
        cache:set("sched:" .. key .. ":retry_attempt", 2)
        cache:set("sched:" .. key .. ":last", 1500)
        cache:set("sched:" .. key .. ":last_status", 503)
        cache:set("sched:" .. key .. ":last_error", "boom")
        cache:set("warm:" .. key, 1400)

        cache:set("sched:" .. key .. ":keep_warm_next", 2100)
        cache:set("sched:" .. key .. ":keep_warm_last", 1550)
        cache:set("sched:" .. key .. ":keep_warm_last_status", 200)
        cache:set("sched:" .. key .. ":keep_warm_last_error", "")

        local ok_persist, err_persist = scheduler.persist_now()
        assert_eq(ok_persist, true, "scheduler persist_now should succeed")
        assert_true(err_persist == nil or type(err_persist) == "string", "persist err type")

        reset_shared_dict(cache)
        reset_shared_dict(conc)

        package.loaded["fastfn.core.scheduler"] = nil
        local scheduler2 = require("fastfn.core.scheduler")
        scheduler2.init()
        local snap = scheduler2.snapshot()

        local found = nil
        for _, row in ipairs(snap.schedules or {}) do
          if row.key == key then
            found = row
          end
        end
        assert_true(found ~= nil, "restored schedule row should be present")
        assert_eq(tonumber(found.state.next), 2000, "restored next")
        assert_eq(tonumber(found.state.retry_due), 1600, "restored retry_due")
        assert_eq(tonumber(found.state.retry_attempt), 2, "restored retry_attempt")
        assert_eq(tonumber(found.state.last_status), 503, "restored last_status")
        assert_true(type(found.state.last_error) == "string" and found.state.last_error:find("boom", 1, true) ~= nil, "restored last_error")

        local kw = nil
        for _, row in ipairs(snap.keep_warm or {}) do
          if row.key == key then
            kw = row
          end
        end
        assert_true(kw ~= nil, "restored keep_warm row should be present")
        assert_eq(tonumber(kw.state.warm_at), 1400, "restored warm_at")
        assert_eq(tonumber(kw.state.next), 2100, "restored keep_warm next")
        assert_eq(tonumber(kw.state.last_status), 200, "restored keep_warm status")

        rm_rf(root)
      end)
    end)
  end)
end

local function test_watchdog_mock_linux_backend()
  with_fake_ngx(function(_cache, _conc, _set_now)
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-watchdog-mock-" .. uniq
    rm_rf(root)
    mkdir_p(root .. "/a/sub")

    local fake_errno = 0
    local next_wd = 10
    local fake_ffi = {
      cdef = function()
        return true
      end,
      errno = function()
        return fake_errno
      end,
      C = {
        inotify_init1 = function(_flags)
          return 3
        end,
        inotify_add_watch = function(_fd, _path, _mask)
          next_wd = next_wd + 1
          return next_wd
        end,
        inotify_rm_watch = function()
          return 0
        end,
        read = function(_fd, _buf, _count)
          fake_errno = 11 -- EAGAIN
          return 0
        end,
        close = function()
          return 0
        end,
      },
      new = function(_ctype, _size)
        return {}
      end,
      sizeof = function(_ctype)
        return 16
      end,
      cast = function(_ctype, value)
        return value
      end,
      string = function(_ptr, len)
        return string.rep("\0", tonumber(len) or 0)
      end,
    }
    local fake_bit = {
      bor = function(...)
        local out = 0
        for i = 1, select("#", ...) do
          out = out + (tonumber((select(i, ...))) or 0)
        end
        return out
      end,
      band = function(a, b)
        local na = tonumber(a) or 0
        local nb = tonumber(b) or 0
        if na == nb then
          return na
        end
        return 0
      end,
    }

    local original_jit = rawget(_G, "jit")
    local ok_watchdog, watchdog_err = pcall(function()
      with_module_stubs({
        ["ffi"] = fake_ffi,
        ["bit"] = fake_bit,
      }, function()
        rawset(_G, "jit", { os = "Linux" })
        package.loaded["fastfn.core.watchdog"] = nil
        local watchdog = require("fastfn.core.watchdog")

        ngx.timer.at = function(_delay, fn, ...)
          if type(fn) == "function" then
            fn(false, ...)
          end
          return true
        end
        ngx.timer.every = function(_interval, fn)
          if type(fn) == "function" then
            fn(false)
          end
          return true
        end

        local changed = 0
        local ok, info = watchdog.start({
          root = root,
          on_change = function()
            changed = changed + 1
          end,
          poll_interval_s = 0.01,
          debounce_ms = 1,
        })
        assert_eq(ok, true, "watchdog mock start should succeed")
        assert_true(type(info) == "table", "watchdog mock info should be table")
        assert_eq(info.backend, "inotify_ffi", "watchdog backend")
        assert_true((tonumber(info.watches) or 0) >= 1, "watchdog watches count")
        assert_eq(info.poll_interval_s, 0.05, "watchdog poll interval floor")
        assert_eq(info.debounce_ms, 25, "watchdog debounce floor")
        assert_eq(changed, 0, "watchdog mock should not trigger callback without events")
      end)
    end)
    rawset(_G, "jit", original_jit)
    rm_rf(root)
    if not ok_watchdog then
      error(watchdog_err)
    end
  end)
end

local function test_watchdog_guardrails()
  local watchdog = require("fastfn.core.watchdog")

  local ok_root, err_root = watchdog.start({})
  assert_eq(ok_root, false, "watchdog root required")
  assert_true(type(err_root) == "string" and err_root:find("root is required", 1, true) ~= nil, "watchdog root message")

  local ok_cb, err_cb = watchdog.start({ root = "/tmp" })
  assert_eq(ok_cb, false, "watchdog callback required")
  assert_true(type(err_cb) == "string" and err_cb:find("on_change callback is required", 1, true) ~= nil, "watchdog callback message")
end

local function test_watchdog_internal_error_paths()
  with_fake_ngx(function(_cache, _conc, _set_now)
    local fake_errno = 0
    local close_calls = 0
    local add_calls = 0
    local next_wd = 20

    local fake_ffi = {
      cdef = function()
        return true
      end,
      errno = function()
        return fake_errno
      end,
      C = {
        inotify_init1 = function(_flags)
          return 7
        end,
        inotify_add_watch = function(_fd, _path, _mask)
          add_calls = add_calls + 1
          next_wd = next_wd + 1
          return next_wd
        end,
        read = function(_fd, _buf, _count)
          fake_errno = 11
          return 0
        end,
        close = function()
          close_calls = close_calls + 1
          return 0
        end,
      },
      new = function()
        return {}
      end,
      sizeof = function()
        return 16
      end,
      cast = function(_ctype, value)
        return value
      end,
      string = function(_ptr, len)
        return string.rep("\0", tonumber(len) or 0)
      end,
    }

    local fake_bit = {
      bor = function(...)
        local out = 0
        for i = 1, select("#", ...) do
          local part = select(i, ...)
          out = out + (tonumber(part) or 0)
        end
        return out
      end,
      band = function(a, b)
        local na = tonumber(a) or 0
        local nb = tonumber(b) or 0
        if na == nb then
          return na
        end
        return 0
      end,
    }

    local original_jit = rawget(_G, "jit")
    local original_timer_every = ngx.timer.every
    local original_timer_at = ngx.timer.at
    local ok_case, case_err = pcall(function()
      with_module_stubs({
        ["ffi"] = fake_ffi,
        ["bit"] = fake_bit,
      }, function()
        rawset(_G, "jit", { os = "Linux" })
        package.loaded["fastfn.core.watchdog"] = nil
        local watchdog = require("fastfn.core.watchdog")

        local has_ignored_segment = get_upvalue(watchdog.start, "has_ignored_segment")
        local list_dirs_recursive = get_upvalue(watchdog.start, "list_dirs_recursive")
        assert_true(type(has_ignored_segment) == "function", "watchdog has_ignored_segment helper should exist")
        assert_true(type(list_dirs_recursive) == "function", "watchdog list_dirs_recursive helper should exist")
        assert_eq(has_ignored_segment("/tmp/a/.git/file.txt"), true, "ignored segment should be detected")
        assert_eq(has_ignored_segment("/tmp/a/src/file.lua"), false, "non-ignored path should pass")
        local missing_dirs = list_dirs_recursive("/tmp/fastfn-watchdog-does-not-exist-" .. tostring(math.random(1000, 9999)))
        assert_true(type(missing_dirs) == "table", "list_dirs_recursive should return a table for missing paths")

        local patched = {}
        local function patch(name, value)
          local ok, previous = set_upvalue(watchdog.start, name, value)
          assert_true(ok, "failed to patch watchdog upvalue " .. tostring(name))
          patched[#patched + 1] = { name = name, previous = previous }
        end
        local function restore_patches()
          for i = #patched, 1, -1 do
            local row = patched[i]
            set_upvalue(watchdog.start, row.name, row.previous)
          end
        end

        ngx.timer.at = function(_delay, fn, ...)
          if type(fn) == "function" then
            fn(false, ...)
          end
          return true
        end

        patch("linux_luajit_ready", function()
          return false
        end)
        local ok_linux, err_linux = watchdog.start({ root = "/tmp", on_change = function() end })
        assert_eq(ok_linux, false, "watchdog should reject non-linux jit")
        assert_true(type(err_linux) == "string" and err_linux:find("Linux LuaJIT", 1, true) ~= nil, "linux guard error")

        patch("linux_luajit_ready", function()
          return true
        end)
        patch("ffi_ok", false)
        local ok_ffi, err_ffi = watchdog.start({ root = "/tmp", on_change = function() end })
        assert_eq(ok_ffi, false, "watchdog should reject missing ffi")
        assert_true(type(err_ffi) == "string" and err_ffi:find("requires ffi", 1, true) ~= nil, "ffi guard error")

        patch("ffi_ok", true)
        patch("bit_ok", false)
        local ok_bit, err_bit = watchdog.start({ root = "/tmp", on_change = function() end })
        assert_eq(ok_bit, false, "watchdog should reject missing bit")
        assert_true(type(err_bit) == "string" and err_bit:find("bit library", 1, true) ~= nil, "bit guard error")

        patch("bit_ok", true)
        patch("ensure_ffi_cdef", function()
          return false, "boom-cdef"
        end)
        local ok_cdef, err_cdef = watchdog.start({ root = "/tmp", on_change = function() end })
        assert_eq(ok_cdef, false, "watchdog should reject failed ffi cdef")
        assert_true(type(err_cdef) == "string" and err_cdef:find("ffi init failed", 1, true) ~= nil, "ffi cdef error")

        patch("ensure_ffi_cdef", function()
          return true
        end)
        patch("list_dirs_recursive", function()
          return { "/tmp/demo", "/tmp/demo", "", "/tmp/demo/.git", "/tmp/demo/sub" }
        end)

        local ffi_fail_init = {
          cdef = fake_ffi.cdef,
          errno = function()
            return 77
          end,
          C = {
            inotify_init1 = function()
              return -1
            end,
            inotify_add_watch = fake_ffi.C.inotify_add_watch,
            read = fake_ffi.C.read,
            close = fake_ffi.C.close,
          },
          new = fake_ffi.new,
          sizeof = fake_ffi.sizeof,
          cast = fake_ffi.cast,
          string = fake_ffi.string,
        }
        patch("ffi", ffi_fail_init)
        local ok_init, err_init = watchdog.start({ root = "/tmp/demo", on_change = function() end })
        assert_eq(ok_init, false, "watchdog should fail when inotify_init1 fails")
        assert_true(type(err_init) == "string" and err_init:find("inotify_init1 failed", 1, true) ~= nil, "inotify init error")

        local ffi_add_fail = {
          cdef = fake_ffi.cdef,
          errno = function()
            return 13
          end,
          C = {
            inotify_init1 = function()
              return 8
            end,
            inotify_add_watch = function()
              return -1
            end,
            read = fake_ffi.C.read,
            close = fake_ffi.C.close,
          },
          new = fake_ffi.new,
          sizeof = fake_ffi.sizeof,
          cast = fake_ffi.cast,
          string = fake_ffi.string,
        }
        patch("ffi", ffi_add_fail)
        local ok_add, err_add = watchdog.start({ root = "/tmp/demo", on_change = function() end })
        assert_eq(ok_add, false, "watchdog should fail when add_watch fails")
        assert_true(type(err_add) == "string" and err_add:find("inotify_add_watch failed", 1, true) ~= nil, "add watch error")

        patch("ffi", fake_ffi)
        ngx.timer.every = function(_interval, _fn)
          return false, "timer-boom"
        end
        local ok_timer, err_timer = watchdog.start({ root = "/tmp/demo", on_change = function() end })
        assert_eq(ok_timer, false, "watchdog should fail when poll timer fails")
        assert_true(type(err_timer) == "string" and err_timer:find("watchdog timer failed", 1, true) ~= nil, "watchdog timer error")

        restore_patches()
      end)
    end)
    rawset(_G, "jit", original_jit)
    ngx.timer.every = original_timer_every
    ngx.timer.at = original_timer_at
    if not ok_case then
      error(case_err)
    end

    assert_true(close_calls >= 2, "watchdog close should run on setup failures")
    assert_true(add_calls >= 1, "watchdog add_watch should run in patched scenarios")
  end)
end

local function test_watchdog_event_reload_paths()
  with_fake_ngx(function(_cache, _conc, set_now)
    local real_bit = require("bit")
    local original_jit = rawget(_G, "jit")
    local original_timer_every = ngx.timer.every
    local original_timer_at = ngx.timer.at
    local original_io_popen = io.popen
    local original_ngx_log = ngx.log

    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-watchdog-events-" .. uniq
    rm_rf(root)
    mkdir_p(root)

    local read_calls_in_poll = 0
    local emit_event = false
    local force_read_error = false
    local fake_errno = 11
    local callbacks = {}
    local on_change_calls = 0
    local log_calls = 0
    local added_paths = {}

    local current_event = {
      mask = 0x40000000 + 0x00000100, -- IN_ISDIR | IN_CREATE
      wd = 11,
      len = 7,
      name = "subdir",
    }

    local fake_ffi = {
      cdef = function()
        return true
      end,
      errno = function()
        return fake_errno
      end,
      C = {
        inotify_init1 = function()
          return 3
        end,
        inotify_add_watch = function(_fd, path, _mask)
          added_paths[#added_paths + 1] = tostring(path)
          return 10 + #added_paths
        end,
        read = function(_fd, _buf, _count)
          if force_read_error then
            read_calls_in_poll = read_calls_in_poll + 1
            fake_errno = 99
            return -1
          end
          if emit_event and read_calls_in_poll == 0 then
            read_calls_in_poll = read_calls_in_poll + 1
            fake_errno = 0
            return 16 + current_event.len
          end
          read_calls_in_poll = read_calls_in_poll + 1
          fake_errno = 11
          return 0
        end,
        close = function()
          return 0
        end,
      },
      new = function()
        return {}
      end,
      sizeof = function()
        return 16
      end,
      cast = function(ctype, value)
        if tostring(ctype):find("uint8_t%*") then
          return 0
        end
        if tostring(ctype):find("struct inotify_event%*") then
          return current_event
        end
        return value
      end,
      string = function(ptr, _len)
        if type(ptr) == "string" then
          return ptr .. "\0"
        end
        return ""
      end,
    }

    local ok_case, case_err = pcall(function()
      with_module_stubs({
        ["ffi"] = fake_ffi,
        ["bit"] = {
          bor = real_bit.bor,
          band = real_bit.band,
        },
      }, function()
        rawset(_G, "jit", { os = "Linux" })
        package.loaded["fastfn.core.watchdog"] = nil
        local watchdog = require("fastfn.core.watchdog")

        local list_dirs_recursive = get_upvalue(watchdog.start, "list_dirs_recursive")
        local ensure_ffi_cdef = get_upvalue(watchdog.start, "ensure_ffi_cdef")
        local linux_luajit_ready = get_upvalue(watchdog.start, "linux_luajit_ready")
        assert_true(type(list_dirs_recursive) == "function", "watchdog list_dirs_recursive helper")
        assert_true(type(ensure_ffi_cdef) == "function", "watchdog ensure_ffi_cdef helper")
        assert_true(type(linux_luajit_ready) == "function", "watchdog linux_luajit_ready helper")

        local saved_jit = rawget(_G, "jit")
        rawset(_G, "jit", nil)
        assert_eq(linux_luajit_ready(), false, "watchdog linux helper rejects missing jit")
        rawset(_G, "jit", saved_jit)

        local ok_loaded, old_loaded = set_upvalue(ensure_ffi_cdef, "cdef_loaded", true)
        assert_true(ok_loaded, "patch cdef_loaded upvalue")
        assert_eq(ensure_ffi_cdef(), true, "ensure_ffi_cdef short-circuit branch")
        set_upvalue(ensure_ffi_cdef, "cdef_loaded", old_loaded)

        local ffi_for_cdef = get_upvalue(ensure_ffi_cdef, "ffi")
        local ffi_boom = {
          cdef = function()
            error("boom-cdef")
          end,
        }
        local ok_patch_ffi = set_upvalue(ensure_ffi_cdef, "ffi", ffi_boom)
        assert_true(ok_patch_ffi, "patch ensure_ffi_cdef ffi upvalue")
        local cdef_ok, cdef_err = ensure_ffi_cdef()
        assert_eq(cdef_ok, false, "ensure_ffi_cdef should fail on non-redefinition error")
        assert_true(type(cdef_err) == "string" and cdef_err:find("boom-cdef", 1, true) ~= nil, "ensure_ffi_cdef error text")
        set_upvalue(ensure_ffi_cdef, "ffi", ffi_for_cdef)
        set_upvalue(ensure_ffi_cdef, "cdef_loaded", false)

	        local fs = require("fastfn.core.fs")
	        local prev_list_dirs_recursive = fs.list_dirs_recursive
	        fs.list_dirs_recursive = function()
	          return {}
	        end
	        local no_dirs = list_dirs_recursive(root)
	        assert_true(type(no_dirs) == "table" and #no_dirs == 0, "list_dirs_recursive handles fs fallback")
	        fs.list_dirs_recursive = prev_list_dirs_recursive

        local poll_cb = nil
        ngx.timer.every = function(_interval, fn)
          poll_cb = fn
          return true
        end
        ngx.timer.at = function(_delay, fn, ...)
          callbacks[#callbacks + 1] = { fn = fn, args = { ... } }
          return true
        end
        ngx.log = function(_level, ...)
          log_calls = log_calls + 1
        end

        local ok, info = watchdog.start({
          root = root,
          on_change = function()
            on_change_calls = on_change_calls + 1
            if on_change_calls > 1 then
              error("forced callback error")
            end
          end,
          poll_interval_s = 0.05,
          debounce_ms = 30,
        })
        assert_eq(ok, true, "watchdog event start should succeed")
        assert_true(type(info) == "table" and info.backend == "inotify_ffi", "watchdog event info")
        assert_true(type(poll_cb) == "function", "watchdog poll callback")

        -- Poll #1: emit event; pending_since should be set.
        set_now(1000.00)
        read_calls_in_poll = 0
        emit_event = true
        force_read_error = false
        current_event = { mask = 0x40000000 + 0x00000100, wd = 11, len = 7, name = "subdir" }
        poll_cb(false)

        -- Poll #2: no event; debounce not elapsed yet.
        set_now(1000.02)
        read_calls_in_poll = 0
        emit_event = false
        poll_cb(false)

        -- Poll #3: no event; debounce elapsed; schedule reload.
        set_now(1000.10)
        read_calls_in_poll = 0
        emit_event = false
        poll_cb(false)
        assert_true(#callbacks >= 1, "watchdog reload callback queued")

        -- Keep callback queued and trigger another debounce window to hit reload_scheduled short-circuit.
        set_now(1000.15)
        read_calls_in_poll = 0
        emit_event = true
        current_event = { mask = 0x00000002, wd = 11, len = 8, name = "guard.txt" }
        poll_cb(false)
        set_now(1000.25)
        read_calls_in_poll = 0
        emit_event = false
        poll_cb(false)

        -- Execute first reload callback successfully.
        local cb_first = table.remove(callbacks, 1)
        cb_first.fn(false, unpack(cb_first.args))

        -- Queue second callback and force callback error path.
        set_now(1000.20)
        read_calls_in_poll = 0
        emit_event = true
        current_event = { mask = 0x00000002, wd = 11, len = 9, name = "file.txt" } -- IN_MODIFY
        poll_cb(false)
        set_now(1000.30)
        read_calls_in_poll = 0
        emit_event = false
        poll_cb(false)
        assert_true(#callbacks >= 1, "second watchdog reload callback queued")
        local cb_second = table.remove(callbacks, 1)
        cb_second.fn(false, unpack(cb_second.args))

        -- Queue third callback and run with premature=true branch.
        set_now(1000.40)
        read_calls_in_poll = 0
        emit_event = true
        current_event = { mask = 0x00000002, wd = 11, len = 10, name = "file3.txt" }
        poll_cb(false)
        set_now(1000.50)
        read_calls_in_poll = 0
        emit_event = false
        poll_cb(false)
        assert_true(#callbacks >= 1, "third watchdog reload callback queued")
        local cb_third = table.remove(callbacks, 1)
        cb_third.fn(true, unpack(cb_third.args))

        -- Emit IN_IGNORED event to exercise watch removal branch.
        set_now(1000.60)
        read_calls_in_poll = 0
        emit_event = true
        current_event = { mask = 0x00008000, wd = 12, len = 0, name = "" } -- IN_IGNORED
        poll_cb(false)
        set_now(1000.70)
        read_calls_in_poll = 0
        emit_event = false
        poll_cb(false)

        while #callbacks > 0 do
          local cb = table.remove(callbacks, 1)
          cb.fn(false, unpack(cb.args))
        end
        assert_true(on_change_calls >= 1, "watchdog on_change called")

        -- Poll callback early-return branch.
        poll_cb(true)

        -- Force read error path (changed == nil).
        force_read_error = true
        set_now(1000.80)
        read_calls_in_poll = 0
        emit_event = false
        poll_cb(false)
        force_read_error = false

        -- Force timer.at failure path.
        ngx.timer.at = function()
          return false, "at-boom"
        end
        set_now(1001.00)
        read_calls_in_poll = 0
        emit_event = true
        current_event = { mask = 0x00000002, wd = 11, len = 10, name = "file2.txt" }
        poll_cb(false)
        set_now(1001.20)
        read_calls_in_poll = 0
        emit_event = false
        poll_cb(false)
        assert_true(log_calls >= 1, "watchdog logs callback/timer errors")
      end)
    end)

    io.popen = original_io_popen
    rawset(_G, "jit", original_jit)
    ngx.timer.every = original_timer_every
    ngx.timer.at = original_timer_at
    ngx.log = original_ngx_log
    rm_rf(root)

    if not ok_case then
      error(case_err)
    end
    assert_true(on_change_calls >= 1, "watchdog callback count")
    assert_true(#added_paths >= 1, "watchdog added paths")
  end)
end

local function test_lua_runtime_in_process()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    package.loaded["fastfn.core.lua_runtime"] = nil
    local lua_runtime = require("fastfn.core.lua_runtime")

    local uniq = tostring(math.floor(os.time())) .. "-" .. tostring(math.random(1000, 9999))
    local root = "/tmp/fastfn-lua-runtime-" .. uniq
    mkdir_p(root .. "/lua/hello")
    mkdir_p(root .. "/lua/raw")
    mkdir_p(root .. "/lua/envos")
    write_file(
      root .. "/lua/hello/handler.lua",
      "local cjson = require('cjson.safe')\n"
        .. "function handler(event)\n"
        .. "  local q = event.query or {}\n"
        .. "  return { status = 200, headers = { ['Content-Type'] = 'application/json' }, body = cjson.encode({ runtime = 'lua', name = q.name or 'World' }) }\n"
        .. "end\n"
    )
    write_file(
      root .. "/lua/raw/handler.lua",
      "function handler(_event)\n"
        .. "  return { ok = true, answer = 42 }\n"
        .. "end\n"
    )
    write_file(
      root .. "/lua/envos/handler.lua",
      "local cjson = require('cjson.safe')\n"
        .. "function handler(event)\n"
        .. "  local env = event.env or {}\n"
        .. "  return { status = 200, headers = { ['Content-Type'] = 'application/json' }, body = cjson.encode({ event_m = env.m, os_m = os.getenv('m') }) }\n"
        .. "end\n"
    )
    write_file(
      root .. "/lua/envos/fn.env.json",
      "{ \"m\": \"test\" }\n"
    )
    write_file(
      root .. "/lua/get.health.lua",
      "function handler(_event)\n"
        .. "  return { status = 200, body = 'ok' }\n"
        .. "end\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "lua" },
      defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1024 * 1024 },
      runtimes = {
        lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))
    routes.discover_functions(true)
    routes.healthcheck_once(cfg)

    local status = routes.runtime_status("lua")
    assert_true(type(status) == "table" and status.up == true, "lua runtime must be healthy in-process")

    local resp1 = lua_runtime.call({ fn = "hello", version = nil, event = { query = { name = "Unit" } } })
    assert_true(type(resp1) == "table", "lua runtime response table expected")
    assert_eq(resp1.status, 200, "lua handler status")
    assert_true(type(resp1.body) == "string" and resp1.body:find('"runtime":"lua"', 1, true) ~= nil, "lua handler body")

    local resp2 = lua_runtime.call({ fn = "raw", version = nil, event = {} })
    assert_eq(resp2.status, 200, "lua raw status")
    assert_true(resp2.headers["Content-Type"] == "application/json", "lua raw json content type")
    assert_true(type(resp2.body) == "string" and resp2.body:find('"ok":true', 1, true) ~= nil, "lua raw body")

    local resp3 = lua_runtime.call({ fn = "get.health.lua", version = nil, event = {} })
    assert_eq(resp3.status, 200, "lua file-target status")
    assert_eq(resp3.body, "ok", "lua file-target body")

    local resp4 = lua_runtime.call({ fn = "envos", version = nil, event = {} })
    assert_eq(resp4.status, 200, "lua env status")
    local env_body = cjson.decode(resp4.body)
    assert_eq(env_body.event_m, "test", "lua event env injection")
    assert_eq(env_body.os_m, "test", "lua os.getenv injection")

    rm_rf(root)
  end)
end

local function test_lua_runtime_print_capture()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    package.loaded["fastfn.core.lua_runtime"] = nil
    local lua_runtime = require("fastfn.core.lua_runtime")

    local uniq = tostring(math.floor(os.time())) .. "-" .. tostring(math.random(1000, 9999))
    local root = "/tmp/fastfn-lua-print-" .. uniq
    mkdir_p(root .. "/lua/printfn")
    mkdir_p(root .. "/lua/silent")
    write_file(
      root .. "/lua/printfn/handler.lua",
      "function handler(event)\n"
        .. "  print('hello from lua')\n"
        .. "  print('line two', 42)\n"
        .. "  return { status = 200, headers = {}, body = 'ok' }\n"
        .. "end\n"
    )
    write_file(
      root .. "/lua/silent/handler.lua",
      "function handler(event)\n"
        .. "  return { status = 200, headers = {}, body = 'silent' }\n"
        .. "end\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "lua" },
      defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1024 * 1024 },
      runtimes = {
        lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))
    routes.discover_functions(true)

    -- Test handler that prints
    local resp1 = lua_runtime.call({ fn = "printfn", version = nil, event = {} })
    assert_eq(resp1.status, 200, "lua print handler status")
    assert_eq(resp1.body, "ok", "lua print handler body")
    assert_true(type(resp1.stdout) == "string", "lua print handler should have stdout")
    assert_true(resp1.stdout:find("hello from lua") ~= nil, "lua stdout should contain first print")
    assert_true(resp1.stdout:find("line two") ~= nil, "lua stdout should contain second print")

    -- Test silent handler (no print)
    local resp2 = lua_runtime.call({ fn = "silent", version = nil, event = {} })
    assert_eq(resp2.status, 200, "lua silent handler status")
    assert_eq(resp2.body, "silent", "lua silent handler body")
    assert_true(resp2.stdout == nil, "lua silent handler should NOT have stdout")

    rm_rf(root)
  end)
end

local function test_lua_runtime_session_passthrough()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    package.loaded["fastfn.core.lua_runtime"] = nil
    local lua_runtime = require("fastfn.core.lua_runtime")

    local uniq = tostring(math.floor(os.time())) .. "-" .. tostring(math.random(1000, 9999))
    local root = "/tmp/fastfn-lua-session-" .. uniq
    mkdir_p(root .. "/lua/sesstest")
    write_file(
      root .. "/lua/sesstest/handler.lua",
      "local cjson = require('cjson.safe')\n"
        .. "function handler(event)\n"
        .. "  local session = event.session or {}\n"
        .. "  return {\n"
        .. "    status = 200,\n"
        .. "    headers = { ['Content-Type'] = 'application/json' },\n"
        .. "    body = cjson.encode({ sid = session.id, cookies = session.cookies or {} })\n"
        .. "  }\n"
        .. "end\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "lua" },
      defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1024 * 1024 },
      runtimes = {
        lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))
    routes.discover_functions(true)

    local resp = lua_runtime.call({
      fn = "sesstest",
      version = nil,
      event = {
        session = {
          id = "abc123",
          raw = "session_id=abc123; theme=dark",
          cookies = { session_id = "abc123", theme = "dark" },
        },
      },
    })
    assert_eq(resp.status, 200, "lua session handler status")
    local body = cjson.decode(resp.body)
    assert_eq(body.sid, "abc123", "lua session id")
    assert_eq(body.cookies.theme, "dark", "lua session cookie")

    rm_rf(root)
  end)
end

local function test_lua_runtime_os_time_date()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    package.loaded["fastfn.core.lua_runtime"] = nil
    local lua_runtime = require("fastfn.core.lua_runtime")

    local uniq = tostring(math.floor(os.time())) .. "-" .. tostring(math.random(1000, 9999))
    local root = "/tmp/fastfn-lua-ostime-" .. uniq
    mkdir_p(root .. "/lua/timefn")
    write_file(
      root .. "/lua/timefn/handler.lua",
      "local cjson = require('cjson.safe')\n"
        .. "function handler(event)\n"
        .. "  local t = os.time()\n"
        .. "  local d = os.date('!%Y-%m-%dT%H:%M:%SZ')\n"
        .. "  local c = os.clock()\n"
        .. "  local diff = os.difftime(t, t - 10)\n"
        .. "  return {\n"
        .. "    status = 200,\n"
        .. "    headers = { ['Content-Type'] = 'application/json' },\n"
        .. "    body = cjson.encode({ time = t, date = d, clock_type = type(c), diff = diff })\n"
        .. "  }\n"
        .. "end\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "lua" },
      defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1024 * 1024 },
      runtimes = {
        lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))
    routes.discover_functions(true)

    local resp = lua_runtime.call({ fn = "timefn", version = nil, event = {} })
    assert_eq(resp.status, 200, "lua os.time/date handler status")
    local body = cjson.decode(resp.body)
    assert_true(type(body.time) == "number" and body.time > 0, "os.time() returns positive number")
    assert_true(type(body.date) == "string" and body.date:match("^%d%d%d%d%-%d%d%-%d%d"), "os.date() returns ISO string")
    assert_eq(body.clock_type, "number", "os.clock() returns number")
    assert_eq(body.diff, 10, "os.difftime() returns correct diff")

    rm_rf(root)
  end)
end

local function test_lua_runtime_params_injection()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    package.loaded["fastfn.core.lua_runtime"] = nil
    local lua_runtime = require("fastfn.core.lua_runtime")

    local uniq = tostring(math.floor(os.time())) .. "-" .. tostring(math.random(1000, 9999))
    local root = "/tmp/fastfn-lua-params-" .. uniq
    mkdir_p(root .. "/lua/paramfn")
    write_file(
      root .. "/lua/paramfn/handler.lua",
      "local cjson = require('cjson.safe')\n"
        .. "function handler(event, params)\n"
        .. "  return {\n"
        .. "    status = 200,\n"
        .. "    headers = { ['Content-Type'] = 'application/json' },\n"
        .. "    body = cjson.encode({\n"
        .. "      got_id = params.id or 'none',\n"
        .. "      got_slug = params.slug or 'none',\n"
        .. "      params_type = type(params)\n"
        .. "    })\n"
        .. "  }\n"
        .. "end\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "lua" },
      defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1024 * 1024 },
      runtimes = {
        lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true },
      },
    }

    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))
    routes.discover_functions(true)

    -- Test with params in event
    local resp = lua_runtime.call({
      fn = "paramfn",
      version = nil,
      event = {
        params = { id = "42", slug = "hello-world" },
      },
    })
    assert_eq(resp.status, 200, "lua params handler status")
    local body = cjson.decode(resp.body)
    assert_eq(body.got_id, "42", "lua params id injected")
    assert_eq(body.got_slug, "hello-world", "lua params slug injected")
    assert_eq(body.params_type, "table", "lua params is table")

    -- Test without params — should get empty table
    local resp2 = lua_runtime.call({
      fn = "paramfn",
      version = nil,
      event = {},
    })
    assert_eq(resp2.status, 200, "lua no-params handler status")
    local body2 = cjson.decode(resp2.body)
    assert_eq(body2.got_id, "none", "lua no-params id fallback")
    assert_eq(body2.params_type, "table", "lua no-params still gets table")

    rm_rf(root)
  end)
end

local function test_lua_runtime_internal_error_paths()
  with_fake_ngx(function(_cache, _conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor(os.time())) .. "-" .. tostring(math.random(1000, 9999))
    local root = "/tmp/fastfn-lua-runtime-edge-" .. uniq
    rm_rf(root)
    mkdir_p(root)

    local current_entry = nil
    local routes_stub = {
      resolve_function_entrypoint = function(_runtime, _name, _version)
        if current_entry then
          return current_entry
        end
        return nil, "entrypoint missing"
      end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
    }, function()
      package.loaded["fastfn.core.lua_runtime"] = nil
      local lua_runtime = require("fastfn.core.lua_runtime")

      local load_handler = get_upvalue(lua_runtime.call, "load_handler")
      local build_sandbox_env = get_upvalue(load_handler, "build_sandbox_env")
      local runtime_getenv = get_upvalue(build_sandbox_env, "runtime_getenv")
      local error_response = get_upvalue(lua_runtime.call, "error_response")
      local json_body = get_upvalue(error_response, "json_body")
      local normalize_response = get_upvalue(lua_runtime.call, "normalize_response")
      local read_function_env = get_upvalue(lua_runtime.call, "read_function_env")
      local normalize_function_env = get_upvalue(read_function_env, "normalize_function_env")
      local merge_event_env = get_upvalue(lua_runtime.call, "merge_event_env")
      assert_true(type(runtime_getenv) == "function", "lua runtime_getenv helper")
      assert_true(type(json_body) == "function", "lua json_body helper")
      assert_true(type(normalize_response) == "function", "lua normalize_response helper")
      assert_true(type(read_function_env) == "function", "lua read_function_env helper")
      assert_true(type(normalize_function_env) == "function", "lua normalize_function_env helper")
      assert_true(type(merge_event_env) == "function", "lua merge_event_env helper")

      local ok_native, prev_native = set_upvalue(runtime_getenv, "_native_getenv", function(name)
        return "native:" .. tostring(name)
      end)
      assert_true(ok_native, "lua runtime_getenv _native_getenv patch")
      local ok_scope, prev_scope = set_upvalue(runtime_getenv, "_current_event_env", { FROM_SCOPE = "scoped" })
      assert_true(ok_scope, "lua runtime_getenv _current_event_env patch")
      assert_eq(runtime_getenv("FROM_SCOPE"), "scoped", "lua runtime_getenv scoped value")
      assert_eq(runtime_getenv("MISSING_SCOPE"), "native:MISSING_SCOPE", "lua runtime_getenv fallback for missing key")
      assert_eq(runtime_getenv(nil), "native:nil", "lua runtime_getenv non-string fallback")
      set_upvalue(runtime_getenv, "_current_event_env", prev_scope)
      set_upvalue(runtime_getenv, "_native_getenv", prev_native)

      local ok_cjson, prev_cjson = set_upvalue(json_body, "cjson", {
        encode = function()
          return nil
        end,
        decode = cjson.decode,
      })
      assert_true(ok_cjson, "lua json_body cjson patch")
      assert_eq(json_body({ ok = true }), "{\"error\":\"json encode failed\"}", "lua json_body encode failure fallback")
      set_upvalue(json_body, "cjson", prev_cjson)

      local norm_env = normalize_function_env({
        TOKEN = { value = "abc" },
        ENABLED = true,
        COUNT = 3,
        SKIP = { nested = true },
        [""] = "bad",
      })
      local norm_env_nil = normalize_function_env(nil)
      assert_true(type(norm_env_nil) == "table" and next(norm_env_nil) == nil, "lua normalize_function_env non-table")
      assert_eq(norm_env.TOKEN, "abc", "lua normalize_function_env table scalar value")
      assert_eq(norm_env.ENABLED, "true", "lua normalize_function_env bool value")
      assert_eq(norm_env.COUNT, "3", "lua normalize_function_env numeric value")
      assert_eq(norm_env.SKIP, nil, "lua normalize_function_env non-scalar table skipped")
      assert_eq(norm_env[""], nil, "lua normalize_function_env empty key skipped")

      local rf0 = read_function_env(nil)
      assert_true(type(rf0) == "table" and next(rf0) == nil, "lua read_function_env invalid entrypoint")

      mkdir_p(root .. "/lua/envtest")
      write_file(root .. "/lua/envtest/handler.lua", "function handler(event) return { status = 200, body = 'ok' } end\n")
      write_file(root .. "/lua/envtest/fn.env.json", "")
      local rf1 = read_function_env(root .. "/lua/envtest/handler.lua")
      assert_true(type(rf1) == "table" and next(rf1) == nil, "lua read_function_env empty file")

      write_file(root .. "/lua/envtest/fn.env.json", "{\"TOKEN\":{\"value\":\"abc\"},\"N\":1}\n")
      local rf2 = read_function_env(root .. "/lua/envtest/handler.lua")
      assert_eq(rf2.TOKEN, "abc", "lua read_function_env nested scalar")
      assert_eq(rf2.N, "1", "lua read_function_env numeric scalar")

      local merged_event, merged_env = merge_event_env({ env = { A = 1, [""] = "bad" } }, { B = "2", A = "3" })
      assert_true(type(merged_event) == "table" and type(merged_event.env) == "table", "lua merge_event_env output event")
      assert_eq(merged_env.A, "3", "lua merge_event_env fn env overrides event env")
      assert_eq(merged_env.B, "2", "lua merge_event_env fn env value")
      assert_eq(merged_env[""], nil, "lua merge_event_env ignores empty key")

      local sandbox = build_sandbox_env({})
      local req_ok, req_err = pcall(sandbox.require, "os")
      assert_eq(req_ok, false, "lua sandbox blocks non-whitelisted require")
      assert_true(type(req_err) == "string" and req_err:find("module not allowed", 1, true) ~= nil, "lua sandbox require error message")

      local module_root = root .. "/lua/moduletest"
      mkdir_p(module_root .. "/pkg")
      write_file(module_root .. "/pkg/init.lua", "return { value = 'from-init' }\n")
      write_file(module_root .. "/syntax_bad.lua", "local =\n")
      write_file(module_root .. "/runtime_bad.lua", "error('module-boom')\n")
      write_file(module_root .. "/nil_return.lua", "return nil\n")

      local sandbox_modules = build_sandbox_env({}, module_root, {})
      local load_local_module = get_upvalue(sandbox_modules.require, "load_local_module")
      assert_true(type(load_local_module) == "function", "lua load_local_module helper")
      local resolve_local_module_path = get_upvalue(load_local_module, "resolve_local_module_path")
      assert_true(type(resolve_local_module_path) == "function", "lua resolve_local_module_path helper")
      local normalize_module_name = get_upvalue(resolve_local_module_path, "normalize_module_name")
      assert_true(type(normalize_module_name) == "function", "lua normalize_module_name helper")

      assert_eq(normalize_module_name(nil), nil, "lua normalize_module_name non-string")
      assert_eq(normalize_module_name("   "), nil, "lua normalize_module_name empty")
      assert_eq(normalize_module_name("/abs"), nil, "lua normalize_module_name absolute path")
      assert_eq(normalize_module_name("bad\\\\name"), nil, "lua normalize_module_name backslash path")
      assert_eq(normalize_module_name("bad//name"), nil, "lua normalize_module_name double slash")
      assert_eq(normalize_module_name("bad$mod"), nil, "lua normalize_module_name invalid segment")
      assert_eq(normalize_module_name(" pkg.init "), "pkg/init", "lua normalize_module_name trims and normalizes")

      assert_eq(resolve_local_module_path(module_root, nil), nil, "lua resolve_local_module_path invalid name")
      assert_eq(resolve_local_module_path(module_root, "pkg"), module_root .. "/pkg/init.lua", "lua resolve_local_module_path init module")

      local cached_mod = { cached = true }
      local cached_val = load_local_module("cached_mod", module_root, {}, { cached_mod = cached_mod })
      assert_eq(cached_val, cached_mod, "lua load_local_module cached branch")

      local mod_cache_err, mod_cache_msg = load_local_module("pkg", module_root, {}, nil)
      assert_eq(mod_cache_err, nil, "lua load_local_module cache type guard")
      assert_true(type(mod_cache_msg) == "string" and mod_cache_msg:find("module cache unavailable", 1, true) ~= nil, "lua load_local_module cache type message")

      local syntax_mod, syntax_err = load_local_module("syntax_bad", module_root, {}, {})
      assert_eq(syntax_mod, nil, "lua load_local_module syntax failure")
      assert_true(type(syntax_err) == "string" and syntax_err:find("failed to load lua module", 1, true) ~= nil, "lua load_local_module syntax failure message")

      local runtime_cache = {}
      local runtime_mod, runtime_err = load_local_module("runtime_bad", module_root, {}, runtime_cache)
      assert_eq(runtime_mod, nil, "lua load_local_module runtime error")
      assert_true(type(runtime_err) == "string" and runtime_err:find("lua module error", 1, true) ~= nil, "lua load_local_module runtime error message")
      assert_eq(runtime_cache.runtime_bad, nil, "lua load_local_module clears cache on runtime error")

      local nil_mod, nil_err = load_local_module("nil_return", module_root, {}, {})
      assert_eq(nil_err, nil, "lua load_local_module nil return no error")
      assert_eq(nil_mod, true, "lua load_local_module nil return cached as true")

      local h0, e0 = load_handler(root .. "/missing.lua", {})
      assert_eq(h0, nil, "lua load_handler missing file")
      assert_true(type(e0) == "string" and e0:find("failed to load lua entrypoint", 1, true) ~= nil, "lua load_handler missing file message")

      write_file(root .. "/boom.lua", "error('boot-fail')\n")
      local h1, e1 = load_handler(root .. "/boom.lua", {})
      assert_eq(h1, nil, "lua load_handler boot error")
      assert_true(type(e1) == "string" and e1:find("lua entrypoint error", 1, true) ~= nil, "lua load_handler boot error message")

      write_file(root .. "/ret_fn.lua", "return function(event) return { status = 201, body = 'fn-ok' } end\n")
      local h2, e2 = load_handler(root .. "/ret_fn.lua", {})
      assert_true(type(h2) == "function", e2 or "lua load_handler return function")
      assert_eq((h2({}) or {}).status, 201, "lua load_handler return function branch")

      write_file(root .. "/ret_table_main.lua", "return { main = function(event) return { status = 202, body = 'main-ok' } end }\n")
      local h3, e3 = load_handler(root .. "/ret_table_main.lua", {})
      assert_true(type(h3) == "function", e3 or "lua load_handler return table.main")
      assert_eq((h3({}) or {}).status, 202, "lua load_handler table.main branch")

      write_file(root .. "/ret_table_handler.lua", "return { handler = function(event) return { status = 204, body = 'handler-ok' } end }\n")
      local h3b, e3b = load_handler(root .. "/ret_table_handler.lua", {})
      assert_true(type(h3b) == "function", e3b or "lua load_handler return table.handler")
      assert_eq((h3b({}) or {}).status, 204, "lua load_handler table.handler branch")

      write_file(root .. "/env_main.lua", "function main(event) return { status = 203, body = 'env-main-ok' } end\n")
      local h4, e4 = load_handler(root .. "/env_main.lua", {})
      assert_true(type(h4) == "function", e4 or "lua load_handler env.main fallback")
      assert_eq((h4({}) or {}).status, 203, "lua load_handler env.main branch")

      write_file(root .. "/no_handler.lua", "return { noop = true }\n")
      local h5, e5 = load_handler(root .. "/no_handler.lua", {})
      assert_eq(h5, nil, "lua load_handler no handler")
      assert_true(type(e5) == "string" and e5:find("must define handler", 1, true) ~= nil, "lua load_handler no handler message")

      local nr_proxy = normalize_response({ status = 204, headers = {}, proxy = { upstream = "http://x" } })
      assert_true(type(nr_proxy.proxy) == "table", "lua normalize_response proxy branch")
      local nr_b64 = normalize_response({ status = 200, headers = {}, is_base64 = true, body_base64 = 123 })
      assert_eq(nr_b64.is_base64, true, "lua normalize_response base64 flag")
      assert_eq(nr_b64.body_base64, "", "lua normalize_response base64 body fallback")
      local nr_tbl = normalize_response({ status = 200, headers = {}, body = { ok = true } })
      assert_eq(nr_tbl.headers["Content-Type"], "application/json", "lua normalize_response table body content type")
      local nr_nil = normalize_response({ status = 200, headers = {}, body = nil })
      assert_eq(nr_nil.body, "", "lua normalize_response nil body")
      local nr_num = normalize_response({ status = 200, headers = {}, body = 123 })
      assert_eq(nr_num.body, "123", "lua normalize_response non-string body cast")

      local invalid_req = lua_runtime.call("bad-request")
      assert_eq(invalid_req.status, 500, "lua runtime invalid request status")
      assert_true((cjson.decode(invalid_req.body) or {}).error:find("invalid lua request payload", 1, true) ~= nil, "lua runtime invalid request message")

      local missing_fn = lua_runtime.call({ event = {} })
      assert_eq(missing_fn.status, 500, "lua runtime missing fn status")
      assert_true((cjson.decode(missing_fn.body) or {}).error:find("missing function name", 1, true) ~= nil, "lua runtime missing fn message")

      current_entry = nil
      local missing_entry = lua_runtime.call({ fn = "demo", event = {} })
      assert_eq(missing_entry.status, 500, "lua runtime missing entrypoint status")
      assert_true((cjson.decode(missing_entry.body) or {}).error:find("entrypoint", 1, true) ~= nil, "lua runtime missing entrypoint message")

      current_entry = root .. "/no_handler.lua"
      local no_handler_resp = lua_runtime.call({ fn = "demo", event = {} })
      assert_eq(no_handler_resp.status, 500, "lua runtime no handler status")
      assert_true((cjson.decode(no_handler_resp.body) or {}).error:find("must define handler", 1, true) ~= nil, "lua runtime no handler message")

      write_file(root .. "/panic.lua", "function handler(event) error('boom-run') end\n")
      current_entry = root .. "/panic.lua"
      local panic_resp = lua_runtime.call({ fn = "demo", event = {} })
      assert_eq(panic_resp.status, 500, "lua runtime panic status")
      assert_true((cjson.decode(panic_resp.body) or {}).error:find("lua handler error", 1, true) ~= nil, "lua runtime panic message")
    end)

    rm_rf(root)
  end)
end

local function test_routes_file_exists_regression()
  -- Regression: file_exists used io.popen("[ -f ... ]") which silently fails
  -- on Docker Desktop VirtioFS mounts inside OpenResty worker processes.
  -- The fix uses io.open + read(0) to detect files vs directories.
  with_fake_ngx(function(cache, _conc, _set_now)
    local cjson = require("cjson.safe")
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    local uniq = tostring(math.floor(os.time() * 1000000))
    local root = "/tmp/fastfn-lua-fileexists-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/lua/admin/session-demo")
    mkdir_p(root .. "/python/user/hello")

    write_file(
      root .. "/lua/admin/session-demo/handler.lua",
      "return function(event) return {status=200,body='ok'} end\n"
    )
    write_file(
      root .. "/python/user/hello/handler.py",
      "def handler(event):\n    return {'status':200,'body':'ok'}\n"
    )

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "lua", "python" },
      defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1048576 },
      runtimes = {
        lua = { in_process = true, timeout_ms = 2500 },
        python = { socket = "unix:/tmp/fastfn/fn-python.sock", timeout_ms = 2500 },
      },
    }
    reset_shared_dict(cache)
    cache:set("runtime:config", cjson.encode(cfg))

    -- resolve_function_entrypoint should find the actual file, not the directory
    local lua_entry, lua_err = routes.resolve_function_entrypoint("lua", "admin/session-demo", nil)
    assert_true(lua_entry ~= nil, "lua entrypoint resolved: " .. tostring(lua_err))
    assert_true(lua_entry:match("handler%.lua$") ~= nil, "lua entrypoint is handler.lua, got: " .. tostring(lua_entry))

    local py_entry, py_err = routes.resolve_function_entrypoint("python", "user/hello", nil)
    assert_true(py_entry ~= nil, "python entrypoint resolved: " .. tostring(py_err))
    assert_true(py_entry:match("handler%.py$") ~= nil, "python entrypoint is handler.py, got: " .. tostring(py_entry))

    -- Accessing the internal file_exists via upvalue chain to verify directly
    local resolve_fn = routes.resolve_function_entrypoint
    local file_exists = get_upvalue(resolve_fn, "file_exists")
    if type(file_exists) == "function" then
      -- file_exists must return true for a real file
      assert_true(file_exists(root .. "/lua/admin/session-demo/handler.lua"), "file_exists: regular file")
      -- file_exists must return false for a directory (the core regression)
      assert_true(not file_exists(root .. "/lua/admin/session-demo"), "file_exists: directory must be false")
      -- file_exists must return false for non-existent path
      assert_true(not file_exists(root .. "/lua/admin/session-demo/nonexistent.lua"), "file_exists: missing file")
      -- file_exists must return false for empty file (edge case: should still be true)
      write_file(root .. "/lua/admin/session-demo/empty.lua", "")
      assert_true(file_exists(root .. "/lua/admin/session-demo/empty.lua"), "file_exists: empty file is still a file")
    end

    rm_rf(root)
  end)
end

local function test_routes_internal_helpers_and_edge_cases()
  with_fake_ngx(function(_cache, _conc, _set_now)
    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")

    local resolve_mapped_target = routes.resolve_mapped_target
    local resolve_request_host_values = get_upvalue(resolve_mapped_target, "resolve_request_host_values")
    local host_allowlist_matches = get_upvalue(resolve_mapped_target, "host_allowlist_matches")
    local sort_dynamic_routes = get_upvalue(resolve_mapped_target, "sort_dynamic_routes")
    local extract_dynamic_route_params = get_upvalue(resolve_mapped_target, "extract_dynamic_route_params")

    local split_host_port = get_upvalue(resolve_request_host_values, "split_host_port")
    local normalize_host_token = get_upvalue(split_host_port, "normalize_host_token")
    local host_matches_pattern = get_upvalue(host_allowlist_matches, "host_matches_pattern")

    local discover_functions = routes.discover_functions
    local normalize_allow_hosts = get_upvalue(discover_functions, "normalize_allow_hosts")
    local host_constraints_overlap = get_upvalue(discover_functions, "host_constraints_overlap")
    local normalize_policy = get_upvalue(discover_functions, "normalize_policy")
    local normalize_edge = get_upvalue(normalize_policy, "normalize_edge")
    local normalize_keep_warm = get_upvalue(normalize_policy, "normalize_keep_warm")
    local normalize_worker_pool = get_upvalue(normalize_policy, "normalize_worker_pool")
    local detect_file_based_routes_in_dir = get_upvalue(discover_functions, "detect_file_based_routes_in_dir")
    local parse_method_and_tokens = get_upvalue(detect_file_based_routes_in_dir, "parse_method_and_tokens")
    local split_file_tokens = get_upvalue(parse_method_and_tokens, "split_file_tokens")
    local normalize_route_token = get_upvalue(detect_file_based_routes_in_dir, "normalize_route_token")
    local split_rel_segments = get_upvalue(detect_file_based_routes_in_dir, "split_rel_segments")
    local dynamic_route_sort_key = get_upvalue(sort_dynamic_routes, "dynamic_route_sort_key")
    local compile_dynamic_route_pattern = get_upvalue(extract_dynamic_route_params, "compile_dynamic_route_pattern")

    assert_true(type(normalize_host_token) == "function", "normalize_host_token helper")
    assert_true(type(split_host_port) == "function", "split_host_port helper")
    assert_true(type(host_matches_pattern) == "function", "host_matches_pattern helper")
    assert_true(type(normalize_allow_hosts) == "function", "normalize_allow_hosts helper")
    assert_true(type(host_constraints_overlap) == "function", "host_constraints_overlap helper")
    assert_true(type(normalize_policy) == "function", "normalize_policy helper")
    assert_true(type(normalize_edge) == "function", "normalize_edge helper")
    assert_true(type(normalize_keep_warm) == "function", "normalize_keep_warm helper")
    assert_true(type(normalize_worker_pool) == "function", "normalize_worker_pool helper")
    assert_true(type(parse_method_and_tokens) == "function", "parse_method_and_tokens helper")
    assert_true(type(split_file_tokens) == "function", "split_file_tokens helper")
    assert_true(type(normalize_route_token) == "function", "normalize_route_token helper")
    assert_true(type(split_rel_segments) == "function", "split_rel_segments helper")
    assert_true(type(dynamic_route_sort_key) == "function", "dynamic_route_sort_key helper")
    assert_true(type(compile_dynamic_route_pattern) == "function", "compile_dynamic_route_pattern helper")

    assert_eq(normalize_host_token("  ExAmple.com  "), "example.com", "normalize host token trims/lowercases")
    assert_eq(normalize_host_token(""), nil, "normalize host token empty")

    local ipv6_host, ipv6_authority = split_host_port("[2001:db8::1]:443")
    assert_eq(ipv6_host, "2001:db8::1", "split_host_port ipv6 host")
    assert_eq(ipv6_authority, "[2001:db8::1]:443", "split_host_port ipv6 authority")
    local host1, authority1 = split_host_port("api.example.com:8443")
    assert_eq(host1, "api.example.com", "split_host_port hostname")
    assert_eq(authority1, "api.example.com:8443", "split_host_port host:port")

    assert_eq(host_matches_pattern("api.example.com", "api.example.com"), true, "exact host match")
    assert_eq(host_matches_pattern("x.api.example.com", "*.example.com"), true, "wildcard host match")
    assert_eq(host_matches_pattern("example.com", "*.example.com"), false, "wildcard should not match apex")
    assert_eq(host_matches_pattern("", "*.example.com"), false, "empty host never matches")

    assert_eq(host_allowlist_matches(nil, "", ""), true, "nil allowlist means allow all")
    assert_eq(host_allowlist_matches({}, "", ""), true, "empty allowlist means allow all")
    assert_eq(host_allowlist_matches({ "api.example.com" }, "", ""), false, "missing request host should deny")
    assert_eq(host_allowlist_matches({ "api.example.com:8443" }, "api.example.com", "api.example.com:8443"), true, "host+port allowlist")
    assert_eq(host_allowlist_matches({ "*.example.com" }, "example.com", "example.com"), false, "wildcard excludes apex")

    local fwd_host, fwd_authority = resolve_request_host_values("edge.example.com:80", "api.example.com:443, proxy.example.com")
    assert_eq(fwd_host, "api.example.com", "forwarded host preferred")
    assert_eq(fwd_authority, "api.example.com:443", "forwarded authority preferred")
    local req_host, req_authority = resolve_request_host_values("edge.example.com:80", nil)
    assert_eq(req_host, "edge.example.com", "fallback host header")
    assert_eq(req_authority, "edge.example.com:80", "fallback authority")

    local allow_hosts = normalize_allow_hosts(" api.example.com,*.example.com,bad/host,api.example.com , ")
    assert_true(type(allow_hosts) == "table" and #allow_hosts == 2, "normalize_allow_hosts dedupe and sanitize")
    assert_eq(allow_hosts[1], "api.example.com", "normalize_allow_hosts first entry")
    assert_eq(allow_hosts[2], "*.example.com", "normalize_allow_hosts wildcard entry")
    assert_eq(normalize_allow_hosts({ "bad host", "/" }), nil, "normalize_allow_hosts rejects invalid list")

    assert_eq(host_constraints_overlap({}, { "a.example.com" }), true, "empty host set overlaps all")
    assert_eq(host_constraints_overlap({ "a.example.com" }, { "b.example.com" }), false, "distinct hosts do not overlap")
    assert_eq(host_constraints_overlap({ "*.example.com" }, { "a.example.com" }), true, "wildcard overlap is conservative")
    assert_eq(host_constraints_overlap({ "a.example.com" }, { "a.example.com" }), true, "exact host overlap")

    assert_eq(normalize_edge({}), nil, "empty edge config is nil")
    local edge_cfg = normalize_edge({
      base_url = " https://api.example.com ",
      allow_hosts = { "api.example.com", "api.example.com", "", "bad host" },
      allow_private = true,
      max_response_bytes = "4096",
    })
    assert_true(type(edge_cfg) == "table", "edge config normalized")
    assert_eq(edge_cfg.base_url, "https://api.example.com", "edge base_url trimmed")
    assert_true(type(edge_cfg.allow_hosts) == "table" and #edge_cfg.allow_hosts == 2, "edge allow_hosts deduped")
    assert_eq(edge_cfg.allow_private, true, "edge allow_private normalized")
    assert_eq(edge_cfg.max_response_bytes, 4096, "edge max_response_bytes normalized")

    local keep_warm_disabled = normalize_keep_warm({ enabled = false, min_warm = 0, ping_every_seconds = 0, idle_ttl_seconds = 0 })
    assert_true(type(keep_warm_disabled) == "table", "disabled keep_warm still normalizes explicit min_warm")
    assert_eq(keep_warm_disabled.enabled, false, "keep_warm disabled flag")
    assert_eq(keep_warm_disabled.min_warm, 0, "keep_warm disabled min_warm")
    local keep_warm = normalize_keep_warm({ enabled = true, min_warm = -5, ping_every_seconds = -1, idle_ttl_seconds = 5 })
    assert_true(type(keep_warm) == "table", "keep_warm normalized")
    assert_eq(keep_warm.enabled, true, "keep_warm enabled")
    assert_eq(keep_warm.min_warm, 1, "keep_warm default min_warm")
    assert_eq(keep_warm.ping_every_seconds, 45, "keep_warm default ping")
    assert_eq(keep_warm.idle_ttl_seconds, 5, "keep_warm provided idle ttl")

    assert_eq(normalize_worker_pool({ enabled = false }, nil), nil, "fully disabled worker pool without overrides")
    local pool_cfg = normalize_worker_pool({
      enabled = true,
      min_warm = 10,
      max_workers = 2,
      max_queue = -1,
      idle_ttl_seconds = 0,
      queue_timeout_ms = -1,
      queue_poll_ms = 0,
      overflow_status = 418,
    }, 5)
    assert_true(type(pool_cfg) == "table", "worker pool normalized")
    assert_eq(pool_cfg.max_workers, 2, "worker pool max_workers")
    assert_eq(pool_cfg.min_warm, 2, "worker pool min_warm clamped to max_workers")
    assert_eq(pool_cfg.max_queue, 0, "worker pool max_queue defaulted")
    assert_eq(pool_cfg.queue_timeout_ms, 0, "worker pool queue_timeout defaulted")
    assert_eq(pool_cfg.queue_poll_ms, 20, "worker pool queue_poll defaulted")
    assert_eq(pool_cfg.overflow_status, 429, "worker pool overflow_status default fallback")

    local toks = split_file_tokens("get.users.[id].[...slug]")
    assert_true(type(toks) == "table" and #toks == 4, "split_file_tokens should preserve bracket groups")
    local m1, parts1, explicit1, ambiguous1 = parse_method_and_tokens("post.users.[id]")
    assert_eq(m1, "POST", "parse_method_and_tokens method")
    assert_eq(explicit1, true, "parse_method_and_tokens explicit flag")
    assert_eq(ambiguous1, false, "parse_method_and_tokens non-ambiguous flag")
    assert_true(type(parts1) == "table" and parts1[1] == "users", "parse_method_and_tokens parts")
    local m2, parts2, explicit2, ambiguous2 = parse_method_and_tokens("users.index")
    assert_eq(m2, "GET", "parse_method_and_tokens default method")
    assert_eq(explicit2, false, "parse_method_and_tokens default explicit flag")
    assert_eq(ambiguous2, false, "parse_method_and_tokens default ambiguous flag")
    assert_true(type(parts2) == "table" and #parts2 == 2, "parse_method_and_tokens default parts")
    local m3, parts3, explicit3, ambiguous3 = parse_method_and_tokens("get.post.items")
    assert_eq(m3, "GET", "parse_method_and_tokens ambiguous method")
    assert_eq(explicit3, true, "parse_method_and_tokens ambiguous explicit flag")
    assert_eq(ambiguous3, true, "parse_method_and_tokens ambiguous flag")
    assert_true(type(parts3) == "table" and parts3[1] == "post", "parse_method_and_tokens ambiguous parts")

    assert_eq(normalize_route_token("[id]"), ":id", "normalize dynamic segment")
    assert_eq(normalize_route_token("[[...slug]]"), ":slug*", "normalize optional catch-all")
    assert_eq(normalize_route_token("edge_header_inject"), "edge-header-inject", "normalize underscores to hyphen")
    assert_eq(normalize_route_token("index"), nil, "normalize index should be ignored")

    local rel_tokens = split_rel_segments("api/[id]/index/[...slug]")
    assert_true(type(rel_tokens) == "table" and #rel_tokens == 3, "split_rel_segments output size")
    assert_eq(rel_tokens[1], "api", "split_rel_segments static")
    assert_eq(rel_tokens[2], ":id", "split_rel_segments dynamic")
    assert_eq(rel_tokens[3], ":slug*", "split_rel_segments catch-all")

    local s1, t1, c1, d1 = dynamic_route_sort_key("/users/:id")
    local s2, t2, c2, d2 = dynamic_route_sort_key("/users/:id*")
    assert_true(s1 == s2 and t1 == t2 and c1 < c2 and d1 > d2, "dynamic_route_sort_key specificity tuple")

    local dyn_sorted = sort_dynamic_routes({
      ["/users/:id*"] = true,
      ["/users/:id"] = true,
      ["/users/*"] = true,
    })
    assert_true(type(dyn_sorted) == "table" and dyn_sorted[1] == "/users/:id", "sort_dynamic_routes prefers specific route")

    local pattern, names = compile_dynamic_route_pattern("/files/*")
    assert_eq(pattern, "^/files/(.+)$", "compile_dynamic_route_pattern wildcard pattern")
    assert_true(type(names) == "table" and names[1] == "wildcard", "compile_dynamic_route_pattern wildcard name")
    local dyn_params = extract_dynamic_route_params("/files/*", "/files/a/b/c")
    assert_true(type(dyn_params) == "table", "extract_dynamic_route_params table")
    assert_eq(dyn_params.wildcard, "a/b/c", "extract_dynamic_route_params wildcard value")
  end)
end

local function test_console_data_validation_edges_and_helpers()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-console-edge-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/python/existing")
    mkdir_p(root .. "/node")

    write_file(
      root .. "/python/existing/handler.py",
      "def handler(event):\n"
        .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
    )
    write_file(
      root .. "/node/get.helper-demo.js",
      "// @summary helper demo\n"
        .. "// @methods GET,POST\n"
        .. "// @query {\"name\":\"FastFN\"}\n"
        .. "// @body {\"ok\":true}\n"
        .. "// @content_type application/json\n"
        .. "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
    )
    write_file(root .. "/direct.py", "def handler(event):\n    return {'status':200,'headers':{},'body':'{}'}\n")
    write_file(root .. "/node/package.json", cjson.encode({ dependencies = { axios = "1.0.0" } }) .. "\n")
    write_file(root .. "/rust.toml", "[dependencies]\nserde = \"1\"\n")

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "python", "node", "php", "lua", "rust", "go" },
      defaults = {
        timeout_ms = 2500,
        max_concurrency = 20,
        max_body_bytes = 1048576,
      },
      runtimes = {
        python = { socket = "unix:/tmp/fastfn/fn-python.sock", timeout_ms = 2500 },
        node = { socket = "unix:/tmp/fastfn/fn-node.sock", timeout_ms = 2500 },
        php = { socket = "unix:/tmp/fastfn/fn-php.sock", timeout_ms = 2500 },
        lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true },
        rust = { socket = "unix:/tmp/fastfn/fn-rust.sock", timeout_ms = 2500 },
        go = { socket = "unix:/tmp/fastfn/fn-go.sock", timeout_ms = 2500 },
      },
    }

    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))
    routes.discover_functions(true)

    package.loaded["fastfn.console.data"] = nil
    local data = require("fastfn.console.data")

    local normalize_config_payload = get_upvalue(data.set_function_config, "normalize_config_payload")
    local normalize_env_payload = get_upvalue(data.set_function_env, "normalize_env_payload")
    local parse_handler_hints = get_upvalue(data.function_detail, "parse_handler_hints")
    local parse_requirements_file = get_upvalue(data.function_detail, "parse_requirements_file")
    local parse_cargo_dependency_names = get_upvalue(data.function_detail, "parse_cargo_dependency_names")
    local resolve_function_paths = get_upvalue(data.function_detail, "resolve_function_paths")
    local build_fn_dir = get_upvalue(resolve_function_paths, "build_fn_dir")
    local detect_runtime_from_file_path = get_upvalue(resolve_function_paths, "detect_runtime_from_file_path")
    local file_target_name_allowed = get_upvalue(resolve_function_paths, "file_target_name_allowed")
    local read_json_file_helper = get_upvalue(data.function_detail, "read_json_file")
    local copy_table = get_upvalue(data.function_detail, "copy_table")
    local normalize_env_file = get_upvalue(data.function_detail, "normalize_env_file")
    local scalar_value = get_upvalue(data.function_detail, "scalar_value")
    local extract_inline_requirements = get_upvalue(data.function_detail, "extract_inline_requirements")
    local normalize_invoke_config = get_upvalue(data.function_detail, "normalize_invoke_config")
    local default_handler_template = get_upvalue(data.create_function, "default_handler_template")
    local default_handler_filename = get_upvalue(data.create_function, "default_handler_filename")
    local env_enabled = get_upvalue(data.function_detail, "env_enabled")
    local table_is_empty = get_upvalue(data.function_detail, "table_is_empty")
    local merge_invoke = get_upvalue(data.function_detail, "merge_invoke")
    local build_query_string = get_upvalue(merge_invoke, "build_query_string")
    local merge_unique_routes = get_upvalue(merge_invoke, "merge_unique_routes")
    if type(merge_unique_routes) ~= "function" then
      merge_unique_routes = get_upvalue(data.function_detail, "merge_unique_routes")
    end

    assert_true(type(normalize_config_payload) == "function", "normalize_config_payload helper")
    assert_true(type(normalize_env_payload) == "function", "normalize_env_payload helper")
    assert_true(type(parse_handler_hints) == "function", "parse_handler_hints helper")
    assert_true(type(parse_requirements_file) == "function", "parse_requirements_file helper")
    assert_true(type(parse_cargo_dependency_names) == "function", "parse_cargo_dependency_names helper")
    assert_true(type(resolve_function_paths) == "function", "resolve_function_paths helper")
    assert_true(type(build_fn_dir) == "function", "build_fn_dir helper")
    assert_true(type(detect_runtime_from_file_path) == "function", "detect_runtime_from_file_path helper")
    assert_true(type(file_target_name_allowed) == "function", "file_target_name_allowed helper")
    assert_true(type(read_json_file_helper) == "function", "read_json_file helper")
    assert_true(type(merge_invoke) == "function", "merge_invoke helper")
    assert_true(type(build_query_string) == "function", "build_query_string helper")
    assert_true(type(merge_unique_routes) == "function", "merge_unique_routes helper")

    assert_eq(build_fn_dir(root, "python", "demo", nil), root .. "/python/demo", "build_fn_dir default")
    assert_eq(build_fn_dir(root, "python", "demo", "v1"), root .. "/python/demo/v1", "build_fn_dir version")
    assert_eq(detect_runtime_from_file_path("noext"), nil, "detect_runtime_from_file_path no ext")
    assert_eq(detect_runtime_from_file_path("demo.xyz"), nil, "detect_runtime_from_file_path unknown ext")
    assert_eq(file_target_name_allowed(""), false, "file_target_name_allowed empty")
    assert_eq(file_target_name_allowed("/etc/passwd"), false, "file_target_name_allowed absolute")
    assert_eq(file_target_name_allowed("../evil.py"), false, "file_target_name_allowed parent dir")
    if type(copy_table) == "function" then
      assert_eq(copy_table("bad")[1], nil, "copy_table non-table")
    end
    if type(table_is_empty) == "function" then
      assert_eq(table_is_empty("bad"), true, "table_is_empty non-table")
      assert_eq(table_is_empty({}), true, "table_is_empty empty")
      assert_eq(table_is_empty({ a = 1 }), false, "table_is_empty non-empty")
    end
    if type(scalar_value) == "function" then
      local scalar_tbl = { a = 1 }
      assert_eq(scalar_value(scalar_tbl), tostring(scalar_tbl), "scalar_value table tostring")
    end
    if type(normalize_env_file) == "function" then
      local env_norm = normalize_env_file({
        TOKEN = "abc",
        COUNT = 2,
        BOOL = true,
        DROP = cjson.null,
        WRAPPED = { value = "x", is_secret = true },
      })
      assert_true(type(env_norm) == "table" and env_norm.TOKEN ~= nil and env_norm.WRAPPED ~= nil, "normalize_env_file mixed values")
    end
    local req_inline_path = root .. "/node/inline-req.js"
    write_file(req_inline_path, "#@requirements axios, lodash\n#@requirements chalk\n")
    if type(extract_inline_requirements) == "function" then
      local inline_reqs = extract_inline_requirements(req_inline_path)
      assert_true(type(inline_reqs) == "table" and #inline_reqs >= 2, "extract_inline_requirements parsed")
    end
    if type(default_handler_template) == "function" then
      assert_true(type(default_handler_template("python")) == "string" and #default_handler_template("python") > 0, "default_handler_template python")
      assert_true(type(default_handler_template("node")) == "string" and #default_handler_template("node") > 0, "default_handler_template node")
      assert_true(type(default_handler_template("php")) == "string" and #default_handler_template("php") > 0, "default_handler_template php")
      assert_true(type(default_handler_template("lua")) == "string" and #default_handler_template("lua") > 0, "default_handler_template lua")
      assert_true(type(default_handler_template("rust")) == "string" and #default_handler_template("rust") > 0, "default_handler_template rust")
      assert_true(type(default_handler_template("go")) == "string" and #default_handler_template("go") > 0, "default_handler_template go")
      assert_eq(default_handler_template("unknown"), "", "default_handler_template fallback")
    end
    if type(default_handler_filename) == "function" then
      assert_eq(default_handler_filename("unknown"), nil, "default_handler_filename unknown")
      assert_eq(default_handler_filename("python"), "handler.py", "default_handler_filename python")
    end
    if type(normalize_invoke_config) == "function" then
      local invoke_norm = normalize_invoke_config({
        methods = { "get" },
        body = { ok = true },
        content_type = "application/json",
        default_method = "post",
        allow_hosts = { "api.example.com" },
        route = "/invoke-demo",
      })
      assert_true(type(invoke_norm) == "table", "normalize_invoke_config table")
      assert_true(type(invoke_norm.body_example) == "string" and #invoke_norm.body_example > 0, "normalize_invoke_config body encoded")
      assert_eq(invoke_norm.content_type, "application/json", "normalize_invoke_config content_type")
      assert_eq(invoke_norm.default_method, "POST", "normalize_invoke_config default_method upper")
    end
    if type(env_enabled) == "function" then
      with_env({ FN_TEST_ENV_ENABLED = "" }, function()
        assert_eq(env_enabled("FN_TEST_ENV_ENABLED", true), true, "env_enabled default")
      end)
      with_env({ FN_TEST_ENV_ENABLED = "off" }, function()
        assert_eq(env_enabled("FN_TEST_ENV_ENABLED", true), false, "env_enabled false")
      end)
      with_env({ FN_TEST_ENV_ENABLED = "invalid" }, function()
        assert_eq(env_enabled("FN_TEST_ENV_ENABLED", false), false, "env_enabled invalid falls back")
      end)
    end
    write_file(root .. "/json-invalid.txt", "\"x\"")
    assert_eq(read_json_file_helper(root .. "/json-invalid.txt"), nil, "read_json_file scalar")

    local bad_cfg0, bad_cfg0_err = normalize_config_payload("bad")
    assert_eq(bad_cfg0, nil, "normalize_config_payload non-table")
    assert_true(type(bad_cfg0_err) == "string" and bad_cfg0_err:find("payload must be", 1, true) ~= nil, "normalize_config_payload error")

    local bad_cfg1, bad_cfg1_err = normalize_config_payload({
      timeout_ms = -1,
      invoke = { allow_hosts = 1 },
    })
    assert_eq(bad_cfg1, nil, "normalize_config_payload invalid timeout")
    assert_true(type(bad_cfg1_err) == "string" and bad_cfg1_err:find("timeout_ms", 1, true) ~= nil, "normalize_config_payload timeout error")

    local bad_cfg2, bad_cfg2_err = normalize_config_payload({
      schedule = {
        cron = "@invalid",
      },
    })
    assert_eq(bad_cfg2, nil, "normalize_config_payload invalid cron macro")
    assert_true(type(bad_cfg2_err) == "string" and bad_cfg2_err:find("supported @macro", 1, true) ~= nil, "normalize_config_payload cron macro error")

    local bad_cfg3, bad_cfg3_err = normalize_config_payload({
      schedule = {
        retry = {
          base_delay_seconds = 2,
          max_delay_seconds = 1,
        },
      },
    })
    assert_eq(bad_cfg3, nil, "normalize_config_payload retry max<base")
    assert_true(type(bad_cfg3_err) == "string" and bad_cfg3_err:find("max_delay_seconds", 1, true) ~= nil, "normalize_config_payload retry ordering error")

    local good_cfg, good_cfg_err = normalize_config_payload({
      group = "edge-group",
      response = { include_debug_headers = true },
      invoke = {
        methods = { "GET", "post", "INVALID" },
        route = "/edge-demo",
        routes = { "/edge-demo", "/edge-demo/v2" },
        handler = "handler",
        allow_hosts = { "api.example.com", "api.example.com" },
      },
      schedule = {
        enabled = true,
        every_seconds = 5,
        timezone = "+02:00",
        method = "GET",
      },
      shared_deps = "base_pack,base_pack,tools_pack",
      edge = {
        base_url = "https://api.example.com",
        allow_hosts = { "api.example.com" },
        allow_private = false,
        max_response_bytes = 1024,
      },
    })
    assert_true(type(good_cfg) == "table", good_cfg_err or "normalize_config_payload success")
    assert_true(type(good_cfg.invoke) == "table" and type(good_cfg.invoke.routes) == "table", "normalized invoke routes")
    assert_true(type(good_cfg.shared_deps) == "table" and #good_cfg.shared_deps == 2, "normalized shared_deps")

    local function expect_cfg_error(payload, needle, label)
      local out, err = normalize_config_payload(payload)
      assert_eq(out, nil, label .. " should fail")
      assert_true(type(err) == "string" and err:find(needle, 1, true) ~= nil, label .. " error")
    end

    expect_cfg_error({ group = 1 }, "group must be a string", "group invalid type")
    expect_cfg_error({ group = string.rep("x", 81) }, "group must be <= 80 chars", "group too long")
    local group_null, group_null_err = normalize_config_payload({ group = cjson.null })
    assert_true(type(group_null) == "table", group_null_err or "group null payload")
    assert_eq(group_null.group, cjson.null, "group null output")

    expect_cfg_error({ max_concurrency = -1 }, "max_concurrency must be >= 0", "max_concurrency invalid")
    expect_cfg_error({ max_body_bytes = 0 }, "max_body_bytes must be > 0", "max_body_bytes invalid")
    local cfg_limits, cfg_limits_err = normalize_config_payload({
      max_concurrency = 3.7,
      max_body_bytes = 2048,
      include_debug_headers = true,
    })
    assert_true(type(cfg_limits) == "table", cfg_limits_err or "limits payload")
    assert_eq(cfg_limits.max_concurrency, 3, "max_concurrency floor")
    assert_eq(cfg_limits.max_body_bytes, 2048, "max_body_bytes output")
    assert_eq(cfg_limits.include_debug_headers, true, "include_debug_headers output")

    local methods_empty_cfg, methods_empty_err = normalize_config_payload({ methods = {} })
    assert_true(type(methods_empty_cfg) == "table", methods_empty_err or "methods empty payload")
    assert_true(type(methods_empty_cfg.invoke) == "table", "methods empty invoke table")
    assert_true(type(methods_empty_cfg.invoke.methods) == "table", "methods empty methods table")
    assert_eq(methods_empty_cfg.invoke.methods[1], "GET", "methods empty defaults to GET")
    expect_cfg_error({ invoke = { handler = 1 } }, "invoke.handler must be a string or null", "invoke.handler type")
    expect_cfg_error({ invoke = { handler = "1bad" } }, "invoke.handler must match", "invoke.handler pattern")
    local cfg_handler_null, cfg_handler_null_err = normalize_config_payload({ invoke = { handler = cjson.null } })
    assert_true(type(cfg_handler_null) == "table", cfg_handler_null_err or "invoke.handler null")
    assert_eq(cfg_handler_null.invoke.handler, cjson.null, "invoke.handler null output")
    expect_cfg_error({ invoke = { allow_hosts = 1 } }, "invoke.allow_hosts", "invoke.allow_hosts type")
    expect_cfg_error({ invoke = { allow_hosts = { string.rep("a", 201) } } }, "length must be <= 200", "invoke.allow_hosts length")
    expect_cfg_error({ invoke = { allow_hosts = { "bad host" } } }, "may not include spaces", "invoke.allow_hosts spaces")
    expect_cfg_error({ invoke = { allow_hosts = { "bad/host" } } }, "may not include spaces", "invoke.allow_hosts slash")
    expect_cfg_error({ invoke = { allow_hosts = { "bad^host" } } }, "invalid host characters", "invoke.allow_hosts charset")
    local cfg_hosts_null, cfg_hosts_null_err = normalize_config_payload({ invoke = { allow_hosts = cjson.null } })
    assert_true(type(cfg_hosts_null) == "table", cfg_hosts_null_err or "invoke.allow_hosts null")
    assert_eq(cfg_hosts_null.invoke.allow_hosts, cjson.null, "invoke.allow_hosts null output")

    expect_cfg_error({ response = "bad" }, "response must be an object", "response type")

    local cfg_sched_null, cfg_sched_null_err = normalize_config_payload({ schedule = cjson.null })
    assert_true(type(cfg_sched_null) == "table", cfg_sched_null_err or "schedule null")
    assert_eq(cfg_sched_null.schedule, cjson.null, "schedule null output")
    expect_cfg_error({ schedule = true }, "schedule must be an object", "schedule type")
    expect_cfg_error({ schedule = { every_seconds = 0 } }, "schedule.every_seconds must be > 0", "schedule every invalid")
    local sched_cron_null, sched_cron_null_err = normalize_config_payload({ schedule = { cron = cjson.null } })
    assert_true(type(sched_cron_null) == "table", sched_cron_null_err or "schedule cron null")
    expect_cfg_error({ schedule = { cron = 1 } }, "schedule.cron must be a string or null", "schedule cron type")
    expect_cfg_error({ schedule = { cron = "   " } }, "schedule.cron must be a non-empty string", "schedule cron empty")
    local sched_tz_null, sched_tz_null_err = normalize_config_payload({ schedule = { timezone = cjson.null } })
    assert_true(type(sched_tz_null) == "table", sched_tz_null_err or "schedule timezone null")
    expect_cfg_error({ schedule = { timezone = 1 } }, "schedule.timezone must be a string or null", "schedule timezone type")
    expect_cfg_error({ schedule = { timezone = "   " } }, "schedule.timezone must be non-empty", "schedule timezone empty")

    local sched_retry_null, sched_retry_null_err = normalize_config_payload({ schedule = { retry = cjson.null } })
    assert_true(type(sched_retry_null) == "table", sched_retry_null_err or "schedule retry null")
    local sched_retry_bool, sched_retry_bool_err = normalize_config_payload({ schedule = { retry = true } })
    assert_true(type(sched_retry_bool) == "table", sched_retry_bool_err or "schedule retry bool")
    assert_eq(sched_retry_bool.schedule.retry, true, "schedule retry bool output")
    expect_cfg_error({ schedule = { retry = "bad" } }, "schedule.retry must be a boolean, object, or null", "schedule retry type")
    expect_cfg_error({ schedule = { retry = { max_attempts = 0 } } }, "schedule.retry.max_attempts must be >= 1", "schedule retry max_attempts")
    expect_cfg_error({ schedule = { retry = { base_delay_seconds = -1 } } }, "schedule.retry.base_delay_seconds must be >= 0", "schedule retry base delay")
    expect_cfg_error({ schedule = { retry = { max_delay_seconds = -1 } } }, "schedule.retry.max_delay_seconds must be >= 0", "schedule retry max delay")
    expect_cfg_error({ schedule = { retry = { jitter = -1 } } }, "schedule.retry.jitter must be >= 0", "schedule retry jitter")

    expect_cfg_error({ schedule = { query = "bad" } }, "schedule.query must be an object", "schedule query type")
    expect_cfg_error({ schedule = { headers = "bad" } }, "schedule.headers must be an object", "schedule headers type")
    expect_cfg_error({ schedule = { context = "bad" } }, "schedule.context must be an object", "schedule context type")

    local schedule_body_string, schedule_body_string_err = normalize_config_payload({ schedule = { body = "x" } })
    assert_true(type(schedule_body_string) == "table", schedule_body_string_err or "schedule body string")
    assert_eq(schedule_body_string.schedule.body, "x", "schedule body string output")
    local schedule_body_non_string, schedule_body_non_string_err = normalize_config_payload({ schedule = { body = 123 } })
    assert_true(type(schedule_body_non_string) == "table", schedule_body_non_string_err or "schedule body number")
    assert_eq(schedule_body_non_string.schedule.body, "123", "schedule body number output")

    local deps_null, deps_null_err = normalize_config_payload({ shared_deps = cjson.null })
    assert_true(type(deps_null) == "table", deps_null_err or "shared_deps null")
    assert_eq(deps_null.shared_deps, cjson.null, "shared_deps null output")
    expect_cfg_error({ shared_deps = 1 }, "shared_deps must be an array of strings", "shared_deps type")
    expect_cfg_error({ shared_deps = { "ok", "bad deps" } }, "shared_deps entries must match", "shared_deps invalid item")
    expect_cfg_error({ sharedDeps = "ok,bad deps" }, "shared_deps entries must match", "sharedDeps invalid token")
    expect_cfg_error({ deps = "ok,bad deps" }, "shared_deps entries must match", "deps invalid token")

    local edge_null, edge_null_err = normalize_config_payload({ edge = cjson.null })
    assert_true(type(edge_null) == "table", edge_null_err or "edge null")
    assert_eq(edge_null.edge, cjson.null, "edge null output")
    expect_cfg_error({ edge = true }, "edge must be an object", "edge type")
    local edge_base_null, edge_base_null_err = normalize_config_payload({ edge = { base_url = cjson.null } })
    assert_true(type(edge_base_null) == "table", edge_base_null_err or "edge base_url null")
    expect_cfg_error({ edge = { base_url = "   " } }, "edge.base_url must be a non-empty string", "edge base_url empty")
    local edge_hosts_null, edge_hosts_null_err = normalize_config_payload({ edge = { allow_hosts = cjson.null } })
    assert_true(type(edge_hosts_null) == "table", edge_hosts_null_err or "edge allow_hosts null")
    expect_cfg_error({ edge = { allow_hosts = "bad" } }, "edge.allow_hosts must be an array", "edge allow_hosts type")
    local edge_max_null, edge_max_null_err = normalize_config_payload({ edge = { max_response_bytes = cjson.null } })
    assert_true(type(edge_max_null) == "table", edge_max_null_err or "edge max_response_bytes null")
    expect_cfg_error({ edge = { max_response_bytes = 0 } }, "edge.max_response_bytes must be > 0", "edge max_response_bytes invalid")

    -- Top-level routes (sent by dashboard) are accepted and mapped to invoke.routes
    local top_routes_cfg, top_routes_err = normalize_config_payload({
      timeout_ms = 5000,
      methods = { "GET", "POST" },
      routes = { "/alice/demo", "/alice/demo/{id}" },
    })
    assert_true(type(top_routes_cfg) == "table", top_routes_err or "normalize_config_payload top-level routes")
    assert_true(type(top_routes_cfg.invoke) == "table", "top-level routes: invoke created")
    assert_true(type(top_routes_cfg.invoke.routes) == "table", "top-level routes: invoke.routes created")
    assert_eq(#top_routes_cfg.invoke.routes, 2, "top-level routes: count")
    assert_eq(top_routes_cfg.invoke.routes[1], "/alice/demo", "top-level routes: first")
    assert_eq(top_routes_cfg.invoke.routes[2], "/alice/demo/{id}", "top-level routes: second")
    assert_true(type(top_routes_cfg.invoke.methods) == "table", "top-level routes: methods also mapped")

    -- invoke.routes takes precedence over top-level routes when both provided
    local override_cfg, override_err = normalize_config_payload({
      routes = { "/alice/old-route" },
      invoke = { routes = { "/alice/new-route", "/alice/new-route/{slug}" } },
    })
    assert_true(type(override_cfg) == "table", override_err or "normalize_config_payload invoke override")
    assert_eq(#override_cfg.invoke.routes, 2, "invoke.routes takes precedence: count")
    assert_eq(override_cfg.invoke.routes[1], "/alice/new-route", "invoke.routes takes precedence: first")

    local bad_env0, bad_env0_err = normalize_env_payload("bad")
    assert_eq(bad_env0, nil, "normalize_env_payload non-table")
    assert_true(type(bad_env0_err) == "string" and bad_env0_err:find("payload must be", 1, true) ~= nil, "normalize_env_payload error")

    local bad_env1, bad_env1_err = normalize_env_payload({
      API_TOKEN = { value = {} },
    })
    assert_eq(bad_env1, nil, "normalize_env_payload invalid object value")
    assert_true(type(bad_env1_err) == "string" and bad_env1_err:find("env value must be", 1, true) ~= nil, "normalize_env_payload invalid value error")

    local good_env, good_env_err = normalize_env_payload({
      API_TOKEN = { value = "secret-1", is_secret = true },
      DEBUG = true,
      DELETE_ME = cjson.null,
    })
    assert_true(type(good_env) == "table", good_env_err or "normalize_env_payload success")
    assert_true(type(good_env.updates) == "table", "normalize_env_payload updates table")

    local hints = parse_handler_hints(root .. "/node/get.helper-demo.js")
    assert_eq(hints.summary, "helper demo", "parse_handler_hints summary")
    assert_true(type(hints.methods) == "table" and #hints.methods >= 2, "parse_handler_hints methods")
    assert_true(type(hints.query_example) == "table" and hints.query_example.name == "FastFN", "parse_handler_hints query")
    local hints_missing = parse_handler_hints(root .. "/node/missing.js")
    assert_true(type(hints_missing) == "table", "parse_handler_hints missing file")

    local reqs = parse_requirements_file("requests==2.0.0\n# comment\nfastapi>=0.1\n")
    assert_true(type(reqs) == "table" and #reqs == 2, "parse_requirements_file count")
    assert_eq(reqs[1], "fastapi", "parse_requirements_file sorted first")
    local cargo_deps = parse_cargo_dependency_names("[dependencies]\nserde = \"1\"\nserde_json = \"1\"\n\n[dev-dependencies]\ninsta = \"1\"\n")
    assert_true(type(cargo_deps) == "table" and #cargo_deps == 2, "parse_cargo_dependency_names count")
    local qs = build_query_string({ b = 2, a = "x", no = { bad = true } })
    assert_eq(qs, "a=x&b=2", "build_query_string sorted and scalar-only")
    assert_eq(build_query_string("bad"), "", "build_query_string non-table")
    local merged = merge_unique_routes({ "/a", "/b" }, { "/b", "/c" })
    assert_true(type(merged) == "table" and #merged == 3, "merge_unique_routes dedupe")

    local bad_create0, bad_create0_err = data.create_function("python", "bad:name", nil, {})
    assert_eq(bad_create0, nil, "create_function invalid name")
    assert_true(type(bad_create0_err) == "string" and bad_create0_err:find("invalid function", 1, true) ~= nil, "create_function invalid name error")

    local ns_create, ns_create_err = data.create_function("python", "edge_ns/hello", nil, {
      summary = "Edge Namespace Create",
      methods = { "GET" },
      route = "/edge-ns-hello",
    })
    assert_true(ns_create ~= nil, ns_create_err or "create_function namespaced name")

    local bad_create1, bad_create1_err = data.create_function("python", "edge_create_invalid_filename", nil, { filename = "../evil.py" })
    assert_eq(bad_create1, nil, "create_function invalid filename")
    assert_true(type(bad_create1_err) == "string" and bad_create1_err:find("invalid filename", 1, true) ~= nil, "create_function invalid filename error")

    local bad_create2, bad_create2_err = data.create_function("python", "edge_create_reserved_route", nil, { route = "/_fn/private" })
    assert_eq(bad_create2, nil, "create_function reserved route blocked")
    assert_true(type(bad_create2_err) == "string" and bad_create2_err:find("invoke.routes", 1, true) ~= nil, "create_function reserved route error")

    local created, created_err = data.create_function("python", "edge_create_ok", nil, {
      summary = "Edge Create",
      methods = { "GET", "POST" },
      route = "/edge-create-ok",
    })
    assert_true(created ~= nil, created_err or "create_function edge_create_ok")

    local bad_set_cfg0, bad_set_cfg0_err = data.set_function_config("python", "edge_create_ok", nil, {
      response = "bad",
    })
    assert_eq(bad_set_cfg0, nil, "set_function_config invalid response type")
    assert_true(type(bad_set_cfg0_err) == "string" and bad_set_cfg0_err:find("response must be an object", 1, true) ~= nil, "set_function_config invalid response error")

    local bad_set_env0, bad_set_env0_err = data.set_function_env("python", "edge_create_ok", nil, "bad")
    assert_eq(bad_set_env0, nil, "set_function_env invalid payload")
    assert_true(type(bad_set_env0_err) == "string" and bad_set_env0_err:find("payload must be", 1, true) ~= nil, "set_function_env invalid payload error")

    local bad_set_code0, bad_set_code0_err = data.set_function_code("python", "edge_create_ok", nil, {
      code = string.rep("x", 2 * 1024 * 1024 + 1),
    })
    assert_eq(bad_set_code0, nil, "set_function_code too large")
    assert_true(type(bad_set_code0_err) == "string" and bad_set_code0_err:find("maximum size", 1, true) ~= nil, "set_function_code too large error")

    local file_target_detail, file_target_err = data.function_detail("python", "direct.py", nil, false)
    assert_true(file_target_detail ~= nil, file_target_err or "file target detail direct.py")
    local mismatch_detail, mismatch_err = data.function_detail("node", "direct.py", nil, false)
    assert_eq(mismatch_detail, nil, "file target runtime mismatch")
    assert_true(type(mismatch_err) == "string" and mismatch_err:find("runtime mismatch", 1, true) ~= nil, "file target runtime mismatch error")

    local bad_detail0, bad_detail0_err = data.function_detail(123, "edge_create_ok", nil, false)
    assert_eq(bad_detail0, nil, "function_detail invalid runtime type")
    assert_true(type(bad_detail0_err) == "string" and bad_detail0_err:find("invalid runtime", 1, true) ~= nil, "function_detail invalid runtime err")
    local bad_detail1, bad_detail1_err = data.function_detail("python", "bad name", nil, false)
    assert_eq(bad_detail1, nil, "function_detail invalid function")
    assert_true(type(bad_detail1_err) == "string" and bad_detail1_err:find("invalid function", 1, true) ~= nil, "function_detail invalid function err")
    local bad_detail2, bad_detail2_err = data.function_detail("python", "edge_create_ok", {}, false)
    assert_eq(bad_detail2, nil, "function_detail invalid version")
    assert_true(type(bad_detail2_err) == "string" and bad_detail2_err:find("invalid version", 1, true) ~= nil, "function_detail invalid version err")

    local bad_set_cfg_runtime, bad_set_cfg_runtime_err = data.set_function_config(123, "edge_create_ok", nil, {})
    assert_eq(bad_set_cfg_runtime, nil, "set_function_config invalid runtime type")
    assert_true(type(bad_set_cfg_runtime_err) == "string" and bad_set_cfg_runtime_err:find("invalid runtime", 1, true) ~= nil, "set_function_config invalid runtime err")
    local bad_set_cfg_name, bad_set_cfg_name_err = data.set_function_config("python", "bad name", nil, {})
    assert_eq(bad_set_cfg_name, nil, "set_function_config invalid function")
    assert_true(type(bad_set_cfg_name_err) == "string" and bad_set_cfg_name_err:find("invalid function", 1, true) ~= nil, "set_function_config invalid function err")
    local bad_set_cfg_version, bad_set_cfg_version_err = data.set_function_config("python", "edge_create_ok", {}, {})
    assert_eq(bad_set_cfg_version, nil, "set_function_config invalid version")
    assert_true(type(bad_set_cfg_version_err) == "string" and bad_set_cfg_version_err:find("invalid version", 1, true) ~= nil, "set_function_config invalid version err")
    local bad_set_cfg_missing, bad_set_cfg_missing_err = data.set_function_config("python", "missing_fn", nil, {})
    assert_eq(bad_set_cfg_missing, nil, "set_function_config missing function")
    assert_true(type(bad_set_cfg_missing_err) == "string" and #bad_set_cfg_missing_err > 0, "set_function_config missing function err")

    local bad_set_env_runtime, bad_set_env_runtime_err = data.set_function_env(123, "edge_create_ok", nil, {})
    assert_eq(bad_set_env_runtime, nil, "set_function_env invalid runtime type")
    assert_true(type(bad_set_env_runtime_err) == "string" and bad_set_env_runtime_err:find("invalid runtime", 1, true) ~= nil, "set_function_env invalid runtime err")
    local bad_set_env_name, bad_set_env_name_err = data.set_function_env("python", "bad name", nil, {})
    assert_eq(bad_set_env_name, nil, "set_function_env invalid function")
    assert_true(type(bad_set_env_name_err) == "string" and bad_set_env_name_err:find("invalid function", 1, true) ~= nil, "set_function_env invalid function err")
    local bad_set_env_version, bad_set_env_version_err = data.set_function_env("python", "edge_create_ok", {}, {})
    assert_eq(bad_set_env_version, nil, "set_function_env invalid version")
    assert_true(type(bad_set_env_version_err) == "string" and bad_set_env_version_err:find("invalid version", 1, true) ~= nil, "set_function_env invalid version err")
    local bad_set_env_missing, bad_set_env_missing_err = data.set_function_env("python", "missing_fn", nil, {})
    assert_eq(bad_set_env_missing, nil, "set_function_env missing function")
    assert_true(type(bad_set_env_missing_err) == "string" and #bad_set_env_missing_err > 0, "set_function_env missing function err")

    local bad_set_code_runtime, bad_set_code_runtime_err = data.set_function_code(123, "edge_create_ok", nil, { code = "x" })
    assert_eq(bad_set_code_runtime, nil, "set_function_code invalid runtime type")
    assert_true(type(bad_set_code_runtime_err) == "string" and bad_set_code_runtime_err:find("invalid runtime", 1, true) ~= nil, "set_function_code invalid runtime err")
    local bad_set_code_name, bad_set_code_name_err = data.set_function_code("python", "bad name", nil, { code = "x" })
    assert_eq(bad_set_code_name, nil, "set_function_code invalid function")
    assert_true(type(bad_set_code_name_err) == "string" and bad_set_code_name_err:find("invalid function", 1, true) ~= nil, "set_function_code invalid function err")
    local bad_set_code_version, bad_set_code_version_err = data.set_function_code("python", "edge_create_ok", {}, { code = "x" })
    assert_eq(bad_set_code_version, nil, "set_function_code invalid version")
    assert_true(type(bad_set_code_version_err) == "string" and bad_set_code_version_err:find("invalid version", 1, true) ~= nil, "set_function_code invalid version err")
    local bad_set_code_payload0, bad_set_code_payload0_err = data.set_function_code("python", "edge_create_ok", nil, "bad")
    assert_eq(bad_set_code_payload0, nil, "set_function_code invalid payload type")
    assert_true(type(bad_set_code_payload0_err) == "string" and bad_set_code_payload0_err:find("payload must be an object", 1, true) ~= nil, "set_function_code invalid payload err")
    local bad_set_code_payload1, bad_set_code_payload1_err = data.set_function_code("python", "edge_create_ok", nil, { code = 1 })
    assert_eq(bad_set_code_payload1, nil, "set_function_code invalid code type")
    assert_true(type(bad_set_code_payload1_err) == "string" and bad_set_code_payload1_err:find("code must be a string", 1, true) ~= nil, "set_function_code invalid code err")
    local bad_set_code_missing, bad_set_code_missing_err = data.set_function_code("python", "missing_fn", nil, { code = "x" })
    assert_eq(bad_set_code_missing, nil, "set_function_code missing function")
    assert_true(type(bad_set_code_missing_err) == "string" and #bad_set_code_missing_err > 0, "set_function_code missing function err")

    local bad_create_runtime, bad_create_runtime_err = data.create_function("unknownrt", "x", nil, {})
    assert_eq(bad_create_runtime, nil, "create_function unknown runtime")
    assert_true(type(bad_create_runtime_err) == "string" and bad_create_runtime_err:find("unknown runtime", 1, true) ~= nil, "create_function unknown runtime err")
    local bad_create_version, bad_create_version_err = data.create_function("python", "x", {}, {})
    assert_eq(bad_create_version, nil, "create_function invalid version type")
    assert_true(type(bad_create_version_err) == "string" and bad_create_version_err:find("invalid version", 1, true) ~= nil, "create_function invalid version err")
    local bad_create_code_size, bad_create_code_size_err = data.create_function("python", "edge_create_big_code", nil, {
      code = string.rep("x", 2 * 1024 * 1024 + 1),
    })
    assert_eq(bad_create_code_size, nil, "create_function code exceeds max")
    assert_true(type(bad_create_code_size_err) == "string" and bad_create_code_size_err:find("maximum size", 1, true) ~= nil, "create_function code exceeds max err")

    local bad_delete_runtime, bad_delete_runtime_err = data.delete_function(123, "edge_create_ok", nil)
    assert_eq(bad_delete_runtime, nil, "delete_function invalid runtime type")
    assert_true(type(bad_delete_runtime_err) == "string" and bad_delete_runtime_err:find("invalid runtime", 1, true) ~= nil, "delete_function invalid runtime err")
    local bad_delete_name, bad_delete_name_err = data.delete_function("python", "bad name", nil)
    assert_eq(bad_delete_name, nil, "delete_function invalid function")
    assert_true(type(bad_delete_name_err) == "string" and bad_delete_name_err:find("invalid function", 1, true) ~= nil, "delete_function invalid function err")
    local bad_delete_version, bad_delete_version_err = data.delete_function("python", "edge_create_ok", {})
    assert_eq(bad_delete_version, nil, "delete_function invalid version")
    assert_true(type(bad_delete_version_err) == "string" and bad_delete_version_err:find("invalid version", 1, true) ~= nil, "delete_function invalid version err")
    local bad_delete_missing, bad_delete_missing_err = data.delete_function("python", "missing_fn", nil)
    assert_eq(bad_delete_missing, nil, "delete_function missing function")
    assert_true(type(bad_delete_missing_err) == "string" and bad_delete_missing_err:find("function not found", 1, true) ~= nil, "delete_function missing function err")

    rm_rf(root)
  end)
end

local function test_console_data_file_operations()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-console-files-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/python")

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "python" },
      defaults = {
        timeout_ms = 2500,
        max_concurrency = 20,
        max_body_bytes = 1048576,
      },
      runtimes = {
        python = { socket = "unix:/tmp/fastfn/fn-python.sock", timeout_ms = 2500 },
      },
    }

    package.loaded["fastfn.core.routes"] = nil
    local routes = require("fastfn.core.routes")
    reset_shared_dict(cache)
    reset_shared_dict(conc)
    cache:set("runtime:config", cjson.encode(cfg))
    routes.discover_functions(true)

    package.loaded["fastfn.console.data"] = nil
    local data = require("fastfn.console.data")

    local created, create_err = data.create_function("python", "files_demo", nil, {
      summary = "File operations demo",
      methods = { "GET" },
      route = "/files-demo",
    })
    assert_true(created ~= nil, create_err or "create_function files_demo")

    local files_before, files_before_err = data.function_files("python", "files_demo", nil)
    assert_true(files_before ~= nil, files_before_err or "function_files before")
    assert_true(type(files_before.files) == "table", "function_files before returns table")

    local write_ok, write_err = data.write_function_file("python", "files_demo", "docs/readme.txt", "hello", nil)
    assert_true(write_ok ~= nil, write_err or "write_function_file")
    assert_eq(write_ok.ok, true, "write_function_file ok")

    local read_ok, read_err = data.read_function_file("python", "files_demo", "docs/readme.txt", nil)
    assert_true(read_ok ~= nil, read_err or "read_function_file")
    assert_eq(read_ok.content, "hello", "read_function_file content")

    local files_after, files_after_err = data.function_files("python", "files_demo", nil)
    assert_true(files_after ~= nil, files_after_err or "function_files after")
    assert_true(type(files_after.files) == "table" and #files_after.files >= 2, "function_files after includes files")

    local bad_write0, bad_write0_err = data.write_function_file("python", "files_demo", "../evil.txt", "x", nil)
    assert_eq(bad_write0, nil, "write invalid path rejected")
    assert_true(type(bad_write0_err) == "string" and bad_write0_err:find("invalid path", 1, true) ~= nil, "write invalid path error")

    local bad_write1, bad_write1_err = data.write_function_file("python", "files_demo", "fn.config.json", "{}", nil)
    assert_eq(bad_write1, nil, "write managed config rejected")
    assert_true(type(bad_write1_err) == "string" and bad_write1_err:find("use config/env API", 1, true) ~= nil, "write managed config error")

    local bad_read, bad_read_err = data.read_function_file("python", "files_demo", "docs/missing.txt", nil)
    assert_eq(bad_read, nil, "read missing file rejected")
    assert_true(type(bad_read_err) == "string" and bad_read_err:find("not found", 1, true) ~= nil, "read missing file error")

    local del_fail0, del_fail0_err = data.delete_function_file("python", "files_demo", "fn.env.json", nil)
    assert_eq(del_fail0, nil, "delete managed config rejected")
    assert_true(type(del_fail0_err) == "string" and del_fail0_err:find("cannot delete", 1, true) ~= nil, "delete managed config error")

    local del_fail1, del_fail1_err = data.delete_function_file("python", "files_demo", "handler.py", nil)
    assert_eq(del_fail1, nil, "delete main handler rejected")
    assert_true(type(del_fail1_err) == "string" and del_fail1_err:find("main handler", 1, true) ~= nil, "delete main handler error")

    local del_ok, del_ok_err = data.delete_function_file("python", "files_demo", "docs/readme.txt", nil)
    assert_true(del_ok ~= nil, del_ok_err or "delete function file")
    assert_eq(del_ok.ok, true, "delete function file ok")

    rm_rf(root)
  end)
end

local function test_console_data_catalog_edge_cases()
  with_fake_ngx(function(cache, conc, set_now)
    local cjson = require("cjson.safe")
    local root = "/tmp/fastfn-lua-console-catalog-" .. tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    rm_rf(root)
    mkdir_p(root)

    local routes_stub = {
      get_config = function()
        return {
          functions_root = root,
          defaults = { timeout_ms = 2500 },
          runtime_order = { "lua" },
          runtimes = {
            lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true },
          },
        }
      end,
      discover_functions = function()
        return {
          runtimes = {
            lua = {
              functions = {
                alpha = {
                  has_default = true,
                  versions = { "v1" },
                  policy = "bad-policy",
                  versions_policy = "bad-versions-policy",
                },
                beta = {
                  has_default = false,
                  versions = {},
                  policy = { methods = "bad-methods", routes = "bad-routes" },
                  versions_policy = {},
                },
              },
            },
          },
          mapped_routes = {
            ["/alpha"] = { runtime = "lua", fn_name = "alpha", version = nil, methods = { "GET", "POST", "GET" } },
            ["/alpha/:id"] = {
              { runtime = "lua", fn_name = "alpha", version = nil, methods = { "GET" } },
              { runtime = "lua", fn_name = "alpha", version = nil, methods = { "POST" } },
            },
            ["/beta"] = {
              { runtime = "lua", fn_name = "beta", version = nil, methods = { "GET" } },
              "skip-invalid",
            },
          },
          mapped_route_conflicts = {
            ["/dup"] = { { route = "/dup", reason = "demo" } },
          },
        }
      end,
      runtime_status = function()
        return { up = true, reason = "ok" }
      end,
      resolve_function_policy = function(runtime, name, version)
        if runtime ~= "lua" then
          return nil, "runtime not found"
        end
        if name == "alpha" and (version == nil or version == "" or version == cjson.null) then
          return { keep_warm = { enabled = true, idle_ttl_seconds = 50 } }
        end
        if name == "alpha" and version == "v1" then
          return { keep_warm = { enabled = true, idle_ttl_seconds = 200 } }
        end
        if name == "beta" then
          return {}
        end
        return nil, "function not found"
      end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
    }, function()
      package.loaded["fastfn.console.data"] = nil
      local data = require("fastfn.console.data")

      reset_shared_dict(cache)
      reset_shared_dict(conc)
      set_now(1000)
      cache:set("warm:lua/alpha@default", 900)
      cache:set("warm:lua/alpha@v1", 980)
      cache:set("sched:lua/alpha@default:keep_warm_next", 1100)
      cache:set("sched:lua/alpha@default:keep_warm_last", 990)
      cache:set("sched:lua/alpha@default:keep_warm_last_status", 200)
      cache:set("sched:lua/alpha@default:keep_warm_last_error", "")

      local catalog = data.catalog()
      assert_true(type(catalog) == "table", "catalog payload table")
      assert_true(type(catalog.runtimes) == "table", "catalog runtimes table")
      assert_true(type(catalog.runtimes.lua) == "table", "catalog lua runtime")
      assert_true(type(catalog.mapped_routes) == "table", "catalog mapped_routes")
      assert_true(type(catalog.mapped_route_conflicts) == "table", "catalog mapped_route_conflicts")

      local function by_name(name)
        for _, row in ipairs((catalog.runtimes.lua or {}).functions or {}) do
          if row.name == name then
            return row
          end
        end
        return nil
      end

      local alpha = by_name("alpha")
      local beta = by_name("beta")
      assert_true(type(alpha) == "table", "catalog alpha entry")
      assert_true(type(beta) == "table", "catalog beta entry")
      assert_eq(alpha.has_default, true, "alpha has_default")
      assert_true(type(alpha.policy) == "table", "alpha policy table")
      assert_true(type(alpha.policy.methods) == "table", "alpha policy methods table")
      assert_true(type(alpha.policy.routes) == "table", "alpha policy routes table")
      assert_true(type(alpha.default_state) == "table", "alpha default_state")
      assert_eq(alpha.default_state.state, "stale", "alpha default state stale")
      assert_true(type(alpha.versions_state) == "table", "alpha versions_state table")
      assert_true(type(alpha.versions_state.v1) == "table", "alpha v1 state")
      assert_eq(alpha.versions_state.v1.state, "warm", "alpha v1 warm state")

      assert_eq(beta.has_default, true, "beta becomes default through mapped route")
      assert_true(type(beta.policy.methods) == "table", "beta methods normalized")
      assert_true(type(beta.policy.routes) == "table", "beta routes normalized")
      assert_true(type(beta.default_state) == "table", "beta default_state")
      assert_eq(beta.default_state.state, "cold", "beta default state cold")
    end)

    rm_rf(root)
  end)
end

local function with_console_data_fixture(run)
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-console-extra-" .. uniq
    rm_rf(root)
    mkdir_p(root .. "/python/demo")
    mkdir_p(root .. "/node/demo")
    mkdir_p(root .. "/node/demo/v1")
    write_file(root .. "/python/demo/handler.py", "def handler(event):\n    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n")
    write_file(root .. "/python/demo/fn.config.json", "{\n  \"invoke\": {\"methods\": [\"GET\"]}\n}\n")
    write_file(root .. "/python/demo/fn.env.json", "{}\n")
    write_file(root .. "/node/demo/handler.js", "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n")
    write_file(root .. "/node/demo/fn.config.json", "{\n  \"invoke\": {\"methods\": [\"GET\"]}\n}\n")
    write_file(root .. "/node/demo/npm-shrinkwrap.json", "{}\n")
    write_file(root .. "/node/demo/v1/handler.js", "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n")
    write_file(root .. "/node/demo/v1/fn.config.json", "{\n  \"invoke\": {\"methods\": [\"GET\"]}\n}\n")

    local routes_stub = {
      get_config = function()
        return {
          functions_root = root,
          defaults = { timeout_ms = 2500 },
          runtime_order = { "python", "node", "custom" },
          runtimes = {
            python = { socket = "unix:/tmp/fn-python.sock", timeout_ms = 2500 },
            node = { socket = "unix:/tmp/fn-node.sock", timeout_ms = 2500 },
            custom = { socket = "unix:/tmp/fn-custom.sock", timeout_ms = 2500 },
          },
        }
      end,
      discover_functions = function()
        return {
          runtimes = {
            python = {
              functions = {
                demo = {
                  has_default = true,
                  versions = {},
                  policy = { methods = { "GET", "POST" }, routes = { "/demo" } },
                  versions_policy = {},
                },
              },
            },
            node = {
              functions = {
                demo = {
                  has_default = true,
                  versions = { "v1" },
                  policy = { methods = { "GET" }, routes = { "/node-demo" } },
                  versions_policy = { v1 = { methods = { "GET" }, routes = { "/node-demo@v1" } } },
                },
              },
            },
          },
          mapped_routes = {
            ["/mapped-single"] = { runtime = "python", fn_name = "demo", version = nil, methods = { "GET" } },
          },
          mapped_route_conflicts = {},
        }
      end,
      resolve_function_policy = function(runtime, _name, _version)
        if runtime == "python" or runtime == "node" then
          return { methods = { "GET" }, timeout_ms = 2500, max_concurrency = 10, max_body_bytes = 1024 * 1024 }
        end
        return nil, "function not found"
      end,
      runtime_status = function()
        return { up = true, reason = "ok" }
      end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
    }, function()
      package.loaded["fastfn.console.data"] = nil
      local data = require("fastfn.console.data")
      reset_shared_dict(cache)
      reset_shared_dict(conc)
      run({
        data = data,
        cjson = cjson,
        root = root,
        routes_stub = routes_stub,
      })
    end)

    rm_rf(root)
  end)
end

local function test_console_data_additional_internal_paths()
  with_console_data_fixture(function(ctx)
    local data = ctx.data
    local cjson = ctx.cjson
    local root = ctx.root
    local resolve_function_paths = get_upvalue(data.function_detail, "resolve_function_paths")
    local normalize_config_payload = get_upvalue(data.set_function_config, "normalize_config_payload")
    local normalize_env_payload = get_upvalue(data.set_function_env, "normalize_env_payload")
    local default_handler_template = get_upvalue(data.create_function, "default_handler_template")
    local read_file_helper = get_upvalue(data.function_detail, "read_file")
    local write_file_helper = get_upvalue(data.set_function_code, "write_file")
    local normalize_routes_from_invoke = get_upvalue(normalize_config_payload, "normalize_routes_from_invoke")
    local normalize_allow_hosts_payload = get_upvalue(normalize_config_payload, "normalize_allow_hosts_payload")
    local validate_invoke_routes_payload = get_upvalue(normalize_config_payload, "validate_invoke_routes_payload")

    assert_true(type(default_handler_template("python")) == "string", "python template")
    assert_true(type(default_handler_template("node")) == "string", "node template")
    assert_true(type(default_handler_template("php")) == "string", "php template")
    assert_true(type(default_handler_template("lua")) == "string", "lua template")
    assert_true(type(default_handler_template("rust")) == "string", "rust template")
    assert_true(type(default_handler_template("go")) == "string", "go template")

    write_file(root .. "/empty.txt", "")
    local empty = read_file_helper(root .. "/empty.txt", nil)
    assert_eq(empty, "", "read_file all")
    write_file(root .. "/big.txt", "abcdef")
    local trunc, was_trunc = read_file_helper(root .. "/big.txt", 3)
    assert_eq(trunc, "abc", "read_file truncate")
    assert_eq(was_trunc, true, "read_file truncate flag")

    os.execute(string.format("ln -sf %q %q", root .. "/big.txt", root .. "/big-link.txt"))
    local symlink_write_ok = write_file_helper(root .. "/big-link.txt", "x")
    assert_eq(symlink_write_ok, nil, "write_file symlink")

    assert_eq(normalize_routes_from_invoke("bad"), nil, "normalize routes non-table")
    local cleared = normalize_routes_from_invoke({ route = cjson.null, routes = {} })
    assert_true(cleared == cjson.null, "normalize routes clear")
    assert_eq(validate_invoke_routes_payload("bad"), nil, "validate routes non-table")
    local bad_routes_ok, bad_routes_err = validate_invoke_routes_payload({ routes = 123 })
    assert_eq(bad_routes_ok, nil, "validate routes invalid type")
    assert_true(type(bad_routes_err) == "string", "validate routes invalid type err")
    local hosts = normalize_allow_hosts_payload("api.example.com, cdn.example.com")
    assert_true(type(hosts) == "table" and #hosts == 2, "normalize allow_hosts string")
    local bad_hosts = normalize_allow_hosts_payload({ "ok.example.com", 123 })
    assert_eq(bad_hosts, nil, "normalize allow_hosts invalid entry")

    local group_cfg = normalize_config_payload({ group = "  " })
    assert_true(type(group_cfg) == "table" and group_cfg.group == cjson.null, "blank group clears")
    local retry_cfg = normalize_config_payload({
      schedule = { retry = { max_attempts = 99, base_delay_seconds = 9999, max_delay_seconds = 9999, jitter = 9 } },
    })
    assert_eq(retry_cfg.schedule.retry.max_attempts, 10, "retry max attempts clamp")
    assert_eq(retry_cfg.schedule.retry.base_delay_seconds, 3600, "retry base delay clamp")
    assert_eq(retry_cfg.schedule.retry.max_delay_seconds, 3600, "retry max delay clamp")
    assert_eq(retry_cfg.schedule.retry.jitter, 0.5, "retry jitter clamp")

    local env_bad_key_err = select(2, normalize_env_payload({ [1] = "x" }))
    assert_true(type(env_bad_key_err) == "string", "env bad key err")
    local env_missing_value_err = select(2, normalize_env_payload({ TOKEN = { is_secret = true } }))
    assert_true(type(env_missing_value_err) == "string", "env missing value err")
    local env_invalid_scalar_err = select(2, normalize_env_payload({ TOKEN = function() end }))
    assert_true(type(env_invalid_scalar_err) == "string", "env invalid scalar err")

    local cfg = ctx.routes_stub.get_config()
    local missing_target, missing_err = resolve_function_paths(cfg, "python", "missing.py", nil)
    assert_eq(missing_target, nil, "resolve missing file target")
    assert_true(type(missing_err) == "string", "resolve missing file target err")
  end)
end

local function test_console_data_additional_mutation_paths()
  with_console_data_fixture(function(ctx)
    local data = ctx.data
    local cjson = ctx.cjson
    local ok_cfg = data.set_function_config("python", "demo", nil, { invoke = { routes = cjson.null } })
    assert_true(ok_cfg ~= nil, "set_function_config routes clear")

    local prev_resolve_cfg = get_upvalue(data.set_function_config, "resolve_function_paths")
    set_upvalue(data.set_function_config, "resolve_function_paths", function()
      return nil, "resolve boom"
    end)
    local bad_cfg = data.set_function_config("python", "demo", nil, {})
    assert_eq(bad_cfg, nil, "set_function_config resolve fail")
    set_upvalue(data.set_function_config, "resolve_function_paths", prev_resolve_cfg)

    local prev_resolve_env = get_upvalue(data.set_function_env, "resolve_function_paths")
    set_upvalue(data.set_function_env, "resolve_function_paths", function()
      return nil, "resolve env boom"
    end)
    local bad_env = data.set_function_env("python", "demo", nil, {})
    assert_eq(bad_env, nil, "set_function_env resolve fail")
    set_upvalue(data.set_function_env, "resolve_function_paths", prev_resolve_env)

    local prev_resolve_code = get_upvalue(data.set_function_code, "resolve_function_paths")
    set_upvalue(data.set_function_code, "resolve_function_paths", function()
      return nil, "resolve code boom"
    end)
    local bad_code = data.set_function_code("python", "demo", nil, { code = "x" })
    assert_eq(bad_code, nil, "set_function_code resolve fail")
    set_upvalue(data.set_function_code, "resolve_function_paths", prev_resolve_code)

    local created = data.create_function("python", "withopts", nil, {
      filename = "handler.py",
      routes = { "/withopts", "/withopts/v2" },
    })
    assert_true(created ~= nil, "create_function with filename/routes")

    local create_invalid_runtime = data.create_function(123, "x", nil, {})
    assert_eq(create_invalid_runtime, nil, "create_function invalid runtime")

    local prev_path_under_create = get_upvalue(data.create_function, "path_is_under")
    set_upvalue(data.create_function, "path_is_under", function()
      return false
    end)
    local create_bad_path = data.create_function("python", "badpath", nil, {})
    assert_eq(create_bad_path, nil, "create_function invalid path")
    set_upvalue(data.create_function, "path_is_under", prev_path_under_create)

    local create_existing = data.create_function("python", "demo", nil, {})
    assert_eq(create_existing, nil, "create_function existing function")

    assert_true(data.set_secret("API_KEY", "a"), "set_secret initial")
    assert_true(data.set_secret("API_KEY", "b"), "set_secret update existing")
    assert_true(data.set_secret("TOKEN", "c"), "set_secret second key")
    assert_true(data.delete_secret("API_KEY"), "delete_secret existing")

    local prev_rm_path = get_upvalue(data.delete_function, "rm_path")
    set_upvalue(data.delete_function, "rm_path", function()
      return false
    end)
    local delete_ver = data.delete_function("node", "demo", "v1")
    assert_eq(delete_ver, nil, "delete_function version rm failure")
    set_upvalue(data.delete_function, "rm_path", prev_rm_path)
  end)
end

local function test_console_data_additional_file_paths()
  with_console_data_fixture(function(ctx)
    local data = ctx.data
    local root = ctx.root
    local classify_file = get_upvalue(data.function_files, "classify_file")

    assert_eq(classify_file("fn.env.json", "python"), "env", "classify_file env")
    assert_eq(classify_file("requirements.txt", "python"), "deps", "classify_file deps")
    assert_eq(classify_file("package-lock.json", "node"), "lock", "classify_file lock")

    assert_eq(select(1, data.function_files(123, "demo", nil)), nil, "function_files invalid runtime")
    assert_eq(select(1, data.function_files("python", "bad name", nil)), nil, "function_files invalid function")
    assert_eq(select(1, data.function_files("python", "demo", {})), nil, "function_files invalid version")

    local py_dir = root .. "/python/demo"
    mkdir_p(py_dir .. "/v2")
    write_file(py_dir .. "/v2/handler.py", "def handler(event):\n    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n")
    local files, files_err = data.function_files("python", "demo", nil)
    assert_true(files ~= nil, files_err or "function_files ok")
    assert_true(type(files.versions) == "table" and #files.versions >= 1, "function_files versions includes v2")

    local read_no_path, read_no_path_err = data.read_function_file("python", "demo", nil, nil)
    assert_eq(read_no_path, nil, "read_function_file path required")
    assert_true(type(read_no_path_err) == "string", "read_function_file path required err")
    local write_bad_chars = data.write_function_file("python", "demo", "docs/*bad.txt", "x", nil)
    assert_eq(write_bad_chars, nil, "write_function_file invalid chars")
    local write_no_content = data.write_function_file("python", "demo", "docs/nocontent.txt", nil, nil)
    assert_eq(write_no_content, nil, "write_function_file missing content")
    local write_too_large = data.write_function_file("python", "demo", "docs/huge.txt", string.rep("x", 1048576 + 1), nil)
    assert_eq(write_too_large, nil, "write_function_file too large")
    local delete_bad_fn = data.delete_function_file("python", "bad name", "docs/a.txt", nil)
    assert_eq(delete_bad_fn, nil, "delete_function_file invalid function")

    write_file(py_dir .. "/real.txt", "ok")
    os.execute(string.format("ln -sf %q %q", py_dir .. "/real.txt", py_dir .. "/link.txt"))
    local read_symlink = data.read_function_file("python", "demo", "link.txt", nil)
    assert_eq(read_symlink, nil, "read_function_file symlink")
    local delete_symlink = data.delete_function_file("python", "demo", "link.txt", nil)
    assert_eq(delete_symlink, nil, "delete_function_file symlink")
    local delete_missing = data.delete_function_file("python", "demo", "missing.txt", nil)
    assert_eq(delete_missing, nil, "delete_function_file missing")
  end)
end

local function test_console_data_additional_helper_and_resolve_paths()
  with_console_data_fixture(function(ctx)
    local data = ctx.data
    local cjson = ctx.cjson
    local root = ctx.root

    local resolve_function_paths = get_upvalue(data.function_detail, "resolve_function_paths")
    local default_handler_template = get_upvalue(data.create_function, "default_handler_template")
    local read_file_helper = get_upvalue(data.function_detail, "read_file")
    local write_file_helper = get_upvalue(data.set_function_code, "write_file")
    local read_json_file = get_upvalue(data.function_detail, "read_json_file")
    local copy_table = get_upvalue(data.set_function_config, "copy_table")
    local extract_inline_requirements = get_upvalue(data.function_detail, "extract_inline_requirements")
    local parse_dependency_keys_from_json = get_upvalue(data.function_detail, "parse_dependency_keys_from_json")
    local normalize_invoke_config = get_upvalue(data.function_detail, "normalize_invoke_config")
    local normalize_config_payload = get_upvalue(data.set_function_config, "normalize_config_payload")
    local normalize_allow_hosts_payload = get_upvalue(normalize_config_payload, "normalize_allow_hosts_payload")
    local validate_invoke_routes_payload = get_upvalue(normalize_config_payload, "validate_invoke_routes_payload")
    local normalize_env_payload = get_upvalue(data.set_function_env, "normalize_env_payload")
    local function_name_allowed = get_upvalue(data.function_detail, "function_name_allowed")
    local is_file_target_name = get_upvalue(resolve_function_paths, "is_file_target_name")
    local file_target_name_allowed = get_upvalue(resolve_function_paths, "file_target_name_allowed")
    local path_is_under = get_upvalue(resolve_function_paths, "path_is_under")
    local dir_exists = get_upvalue(data.delete_function, "dir_exists")
    local list_dirs = get_upvalue(data.function_files, "list_dirs")
	    local version_children_count = get_upvalue(data.delete_function, "version_children_count")
	    local file_size = get_upvalue(data.function_files, "file_size")
	    local list_files_recursive = get_upvalue(data.function_files, "list_files_recursive")
	    local is_symlink = get_upvalue(write_file_helper, "is_symlink")
	    local data_fs = get_upvalue(is_symlink, "fs")
	    local build_env_view = get_upvalue(data.function_detail, "build_env_view")
	    local scalar_value = get_upvalue(build_env_view, "scalar_value")

    assert_eq(is_file_target_name(123), false, "is_file_target_name non-string")
    assert_eq(file_target_name_allowed("demo//handler.py"), false, "file_target_name_allowed //")
    assert_eq(file_target_name_allowed(123), false, "file_target_name_allowed non-string")
    assert_eq(function_name_allowed(123), false, "function_name_allowed non-string")
    assert_eq(path_is_under(nil, root), false, "path_is_under invalid type")
    assert_eq(path_is_under("", root), false, "path_is_under empty root")

	    local prev_is_symlink = data_fs.is_symlink
	    local prev_is_dir = data_fs.is_dir
	    local prev_list_dirs = data_fs.list_dirs
	    local prev_stat = data_fs.stat
	    local prev_list_files_recursive = data_fs.list_files_recursive
	    data_fs.is_symlink = function() return false end
	    data_fs.is_dir = function() return false end
	    data_fs.list_dirs = function() return {} end
	    data_fs.stat = function() return nil end
	    data_fs.list_files_recursive = function() return {} end
	    assert_eq(is_symlink(root), false, "is_symlink fs fail")
	    assert_eq(dir_exists(root), false, "dir_exists fs fail")
	    assert_eq(#list_dirs(root), 0, "list_dirs fs fail")
	    assert_eq(version_children_count(root), 0, "version_children_count fs fail")
	    assert_eq(file_size(root .. "/missing.txt"), 0, "file_size fs fail")
	    assert_eq(#list_files_recursive(root, 2), 0, "list_files_recursive fs fail")
	    data_fs.is_symlink = prev_is_symlink
	    data_fs.is_dir = prev_is_dir
	    data_fs.list_dirs = prev_list_dirs
	    data_fs.stat = prev_stat
	    data_fs.list_files_recursive = prev_list_files_recursive

    mkdir_p(root .. "/python/demo/vx")
    assert_true(version_children_count(root .. "/python/demo") >= 1, "version_children_count increments")

    assert_true(type(default_handler_template("python")) == "string", "python template branch")
    assert_true(type(default_handler_template("node")) == "string", "node template branch")
    assert_true(type(default_handler_template("php")) == "string", "php template branch")
    assert_true(type(default_handler_template("lua")) == "string", "lua template branch")
    assert_true(type(default_handler_template("rust")) == "string", "rust template branch")
    assert_true(type(default_handler_template("go")) == "string", "go template branch")

    local prev_open = io.open
    io.open = function()
      return { read = function() return nil end, close = function() end }
    end
    local nil_data = read_file_helper(root .. "/nil-read.txt", nil)
    assert_eq(nil_data, "", "read_file nil read")
    io.open = prev_open

    local write_dir = write_file_helper(root, "x")
    assert_eq(write_dir, nil, "write_file io.open err")
    write_file(root .. "/plain.txt", "ok")
    os.execute(string.format("ln -sf %q %q", root .. "/plain.txt", root .. "/plain-link.txt"))
    assert_eq(read_json_file(root .. "/plain-link.txt"), nil, "read_json_file symlink")
    assert_eq(type(copy_table("bad")), "table", "copy_table non-table")
    assert_eq(type(scalar_value({ a = 1 })), "string", "scalar_value fallback")
    assert_eq(#extract_inline_requirements(root .. "/missing-inline.py"), 0, "extract_inline_requirements missing")

    write_file(root .. "/nodeps.json", cjson.encode({ name = "x" }) .. "\n")
    local deps, has_obj = parse_dependency_keys_from_json(root .. "/nodeps.json", "dependencies")
    assert_eq(has_obj, true, "parse_dependency_keys_from_json object")
    assert_eq(#deps, 0, "parse_dependency_keys_from_json empty deps")

    local bad_routes_cfg, bad_routes_err = normalize_config_payload({ routes = "/_fn/private" })
    assert_eq(bad_routes_cfg, nil, "normalize_config_payload invalid routes")
    assert_true(type(bad_routes_err) == "string", "normalize_config_payload invalid routes err")
    local bad_routes_item_ok = validate_invoke_routes_payload({ routes = { "not-a-route" } })
    assert_eq(bad_routes_item_ok, nil, "validate_invoke_routes_payload invalid item branch")
    assert_eq(normalize_allow_hosts_payload(nil), nil, "normalize_allow_hosts_payload nil")
    local handler_clear_cfg = normalize_config_payload({ invoke = { handler = "  " } })
    assert_true(type(handler_clear_cfg) == "table" and handler_clear_cfg.invoke.handler == cjson.null, "normalize_config_payload blank handler")
    local prev_parse_methods = get_upvalue(normalize_config_payload, "parse_methods")
    set_upvalue(normalize_config_payload, "parse_methods", function()
      return {}
    end)
    assert_eq(select(1, normalize_config_payload({ methods = { "GET" } })), nil, "normalize_config_payload methods empty branch")
    set_upvalue(normalize_config_payload, "parse_methods", prev_parse_methods)
    local env_delete = normalize_env_payload({ SECRET = { value = cjson.null, is_secret = true } })
    assert_true(type(env_delete) == "table" and env_delete.updates.SECRET.delete == true, "normalize_env_payload delete branch")
    local invoke_empty = normalize_invoke_config("bad")
    assert_true(type(invoke_empty) == "table" and next(invoke_empty) == nil, "normalize_invoke_config non-table")

    local cfg = ctx.routes_stub.get_config()
    local prev_detect = get_upvalue(resolve_function_paths, "detect_app_file")
    local prev_handler_allowed = get_upvalue(resolve_function_paths, "handler_name_allowed")
    set_upvalue(resolve_function_paths, "detect_app_file", function() return root .. "/python/demo/handler.py" end)
    set_upvalue(resolve_function_paths, "handler_name_allowed", function() return false end)
    assert_eq(select(1, resolve_function_paths(cfg, "python", "demo", nil)), nil, "resolve invalid code path")
    set_upvalue(resolve_function_paths, "detect_app_file", prev_detect)
    set_upvalue(resolve_function_paths, "handler_name_allowed", prev_handler_allowed)

    assert_eq(select(1, resolve_function_paths(cfg, "python", "files/demo.py", "v1")), nil, "resolve file target version")
    assert_eq(select(1, resolve_function_paths(cfg, "python", "../evil.py", nil)), nil, "resolve invalid function name")
    local prev_path_under_resolve = get_upvalue(resolve_function_paths, "path_is_under")
    set_upvalue(resolve_function_paths, "path_is_under", function()
      return false
    end)
    assert_eq(select(1, resolve_function_paths(cfg, "python", "demo.py", nil)), nil, "resolve invalid file target path")
    set_upvalue(resolve_function_paths, "path_is_under", prev_path_under_resolve)
    os.execute(string.format("ln -sf %q %q", root .. "/python/demo/handler.py", root .. "/link.py"))
    assert_eq(select(1, resolve_function_paths(cfg, "python", "link.py", nil)), nil, "resolve symlink file target")
    assert_eq(select(1, resolve_function_paths(cfg, "python", "missing.py", nil)), nil, "resolve missing file")

    local node_detail, node_detail_err = data.function_detail("node", "demo", nil, false)
    assert_true(node_detail ~= nil, node_detail_err or "node detail for shrinkwrap")
    assert_eq(node_detail.metadata.node.lock_file, "npm-shrinkwrap.json", "node lock file shrinkwrap")
    local v1_detail, v1_detail_err = data.function_detail("node", "demo", "v1", false)
    assert_true(v1_detail ~= nil, v1_detail_err or "node version detail")
    assert_true(type(v1_detail.metadata.endpoints.public_route) == "string" and v1_detail.metadata.endpoints.public_route:find("@v1", 1, true) ~= nil, "version route fallback")
    local prev_path_under_detail = get_upvalue(data.function_detail, "path_is_under")
    set_upvalue(data.function_detail, "path_is_under", function()
      return false
    end)
    assert_eq(select(1, data.function_detail("python", "demo", nil, false)), nil, "function_detail invalid config path branch")
    set_upvalue(data.function_detail, "path_is_under", prev_path_under_detail)

    local cat = data.catalog()
    assert_true(type(cat) == "table", "catalog coverage for methods/routes seen")
  end)
end

local function test_console_data_additional_mutation_failure_paths()
  with_console_data_fixture(function(ctx)
    local data = ctx.data
    local cjson = ctx.cjson
    local root = ctx.root

    local prev_resolve_detail = get_upvalue(data.function_detail, "resolve_function_paths")
    set_upvalue(data.function_detail, "resolve_function_paths", function()
      return {
        fn_dir = root .. "/python/demo",
        app_path = root .. "/python/demo/handler.py",
        conf_path = "/tmp/outside-fn.config.json",
        env_path = root .. "/python/demo/fn.env.json",
      }
    end)
    assert_eq(select(1, data.function_detail("python", "demo", nil, false)), nil, "function_detail invalid config path")
    set_upvalue(data.function_detail, "resolve_function_paths", prev_resolve_detail)

    local prev_path_cfg = get_upvalue(data.set_function_config, "path_is_under")
    set_upvalue(data.set_function_config, "path_is_under", function() return false end)
    assert_eq(select(1, data.set_function_config("python", "demo", nil, {})), nil, "set_function_config invalid path")
    set_upvalue(data.set_function_config, "path_is_under", prev_path_cfg)

    local prev_resolve_cfg_path = get_upvalue(data.set_function_config, "resolve_function_paths")
    set_upvalue(data.set_function_config, "resolve_function_paths", function()
      return {
        fn_dir = root .. "/python/demo",
        app_path = root .. "/python/demo/handler.py",
        conf_path = "/tmp/outside-fn.config.json",
        env_path = root .. "/python/demo/fn.env.json",
      }
    end)
    assert_eq(select(1, data.set_function_config("python", "demo", nil, {})), nil, "set_function_config invalid config path branch")
    set_upvalue(data.set_function_config, "resolve_function_paths", prev_resolve_cfg_path)

	    local prev_read_cfg = get_upvalue(data.set_function_config, "read_json_file")
	    local prev_ensure_exists = get_upvalue(data.set_function_config, "ensure_function_exists")
	    local prev_detail_cfg = data.function_detail
	    set_upvalue(data.set_function_config, "read_json_file", function() return "bad" end)
	    set_upvalue(data.set_function_config, "ensure_function_exists", function() return {} end)
	    data.function_detail = function() return { name = "demo" } end
	    assert_true(data.set_function_config("python", "demo", nil, {}) ~= nil, "set_function_config non-table base")
	    set_upvalue(data.set_function_config, "read_json_file", prev_read_cfg)
	    set_upvalue(data.set_function_config, "ensure_function_exists", prev_ensure_exists)
	    data.function_detail = prev_detail_cfg

    assert_true(data.set_function_config("python", "demo", nil, { invoke = { route = cjson.null, routes = {} } }) ~= nil, "set_function_config routes null")

    local prev_cjson_cfg = get_upvalue(data.set_function_config, "cjson")
    set_upvalue(data.set_function_config, "cjson", { encode = function() return nil end, decode = prev_cjson_cfg.decode, null = prev_cjson_cfg.null })
    assert_eq(select(1, data.set_function_config("python", "demo", nil, {})), nil, "set_function_config encode fail")
    set_upvalue(data.set_function_config, "cjson", prev_cjson_cfg)

    local prev_write_cfg = get_upvalue(data.set_function_config, "write_file")
    set_upvalue(data.set_function_config, "write_file", function() return nil, "boom" end)
    assert_eq(select(1, data.set_function_config("python", "demo", nil, {})), nil, "set_function_config write fail")
    set_upvalue(data.set_function_config, "write_file", prev_write_cfg)

    local prev_detail = data.function_detail
    data.function_detail = function() return nil, "detail boom" end
    assert_eq(select(1, data.set_function_config("python", "demo", nil, {})), nil, "set_function_config detail fail")
    data.function_detail = prev_detail

    local prev_path_env = get_upvalue(data.set_function_env, "path_is_under")
    set_upvalue(data.set_function_env, "path_is_under", function() return false end)
    assert_eq(select(1, data.set_function_env("python", "demo", nil, {})), nil, "set_function_env invalid path")
    set_upvalue(data.set_function_env, "path_is_under", prev_path_env)

    local prev_resolve_env_path = get_upvalue(data.set_function_env, "resolve_function_paths")
    set_upvalue(data.set_function_env, "resolve_function_paths", function()
      return {
        fn_dir = root .. "/python/demo",
        app_path = root .. "/python/demo/handler.py",
        conf_path = root .. "/python/demo/fn.config.json",
        env_path = "/tmp/outside-fn.env.json",
      }
    end)
    assert_eq(select(1, data.set_function_env("python", "demo", nil, {})), nil, "set_function_env invalid env path branch")
    set_upvalue(data.set_function_env, "resolve_function_paths", prev_resolve_env_path)

	    local prev_norm_env = get_upvalue(data.set_function_env, "normalize_env_payload")
	    local prev_ensure_env_exists = get_upvalue(data.set_function_env, "ensure_function_exists")
	    local prev_read_env_file = get_upvalue(data.set_function_env, "read_json_file")
	    local prev_write_env_file = get_upvalue(data.set_function_env, "write_file")
	    local prev_detail_env = data.function_detail
	    set_upvalue(data.set_function_env, "normalize_env_payload", function() return { updates = { GHOST = {} } } end)
	    set_upvalue(data.set_function_env, "ensure_function_exists", function() return {} end)
	    set_upvalue(data.set_function_env, "read_json_file", function() return {} end)
	    set_upvalue(data.set_function_env, "write_file", function() return true end)
	    data.function_detail = function() return { name = "demo" } end
	    assert_true(data.set_function_env("python", "demo", nil, {}) ~= nil, "set_function_env base delete branch")
	    set_upvalue(data.set_function_env, "normalize_env_payload", prev_norm_env)
	    set_upvalue(data.set_function_env, "ensure_function_exists", prev_ensure_env_exists)
	    set_upvalue(data.set_function_env, "read_json_file", prev_read_env_file)
	    set_upvalue(data.set_function_env, "write_file", prev_write_env_file)
	    data.function_detail = prev_detail_env

    local prev_cjson_env = get_upvalue(data.set_function_env, "cjson")
    set_upvalue(data.set_function_env, "cjson", { encode = function() return nil end, decode = prev_cjson_env.decode, null = prev_cjson_env.null })
    assert_eq(select(1, data.set_function_env("python", "demo", nil, {})), nil, "set_function_env encode fail")
    set_upvalue(data.set_function_env, "cjson", prev_cjson_env)

    local prev_write_env = get_upvalue(data.set_function_env, "write_file")
    set_upvalue(data.set_function_env, "write_file", function() return nil, "boom" end)
    assert_eq(select(1, data.set_function_env("python", "demo", nil, {})), nil, "set_function_env write fail")
    set_upvalue(data.set_function_env, "write_file", prev_write_env)

    data.function_detail = function() return nil, "detail env boom" end
    assert_eq(select(1, data.set_function_env("python", "demo", nil, {})), nil, "set_function_env detail fail")
    data.function_detail = prev_detail

    local prev_write_code = get_upvalue(data.set_function_code, "write_file")
    set_upvalue(data.set_function_code, "write_file", function() return nil, "boom" end)
    assert_eq(select(1, data.set_function_code("python", "demo", nil, { code = "x" })), nil, "set_function_code write fail")
    set_upvalue(data.set_function_code, "write_file", prev_write_code)

    data.function_detail = function() return nil, "detail code boom" end
    assert_eq(select(1, data.set_function_code("python", "demo", nil, { code = "x" })), nil, "set_function_code detail fail")
    data.function_detail = prev_detail

    local prev_symlink_create = get_upvalue(data.create_function, "is_symlink")
    set_upvalue(data.create_function, "is_symlink", function() return true end)
    assert_eq(select(1, data.create_function("python", "symcreate", nil, {})), nil, "create_function symlink path")
    set_upvalue(data.create_function, "is_symlink", prev_symlink_create)

    local prev_ensure_dir = get_upvalue(data.create_function, "ensure_dir")
    set_upvalue(data.create_function, "ensure_dir", function() return false end)
    assert_eq(select(1, data.create_function("python", "mkdirfail", nil, {})), nil, "create_function ensure_dir fail")
    set_upvalue(data.create_function, "ensure_dir", prev_ensure_dir)

    assert_eq(select(1, data.create_function("custom", "nocode", nil, {})), nil, "create_function unsupported runtime")

    local prev_write_create = get_upvalue(data.create_function, "write_file")
    set_upvalue(data.create_function, "write_file", function() return nil, "boom" end)
    assert_eq(select(1, data.create_function("python", "writefail", nil, {})), nil, "create_function code write fail")
    set_upvalue(data.create_function, "write_file", prev_write_create)

    local prev_path_create = get_upvalue(data.create_function, "path_is_under")
    local calls = 0
    set_upvalue(data.create_function, "path_is_under", function()
      calls = calls + 1
      return calls == 1
    end)
    assert_eq(select(1, data.create_function("python", "badcfgpath", nil, {})), nil, "create_function invalid config path")
    set_upvalue(data.create_function, "path_is_under", prev_path_create)

    local prev_cjson_create = get_upvalue(data.create_function, "cjson")
    set_upvalue(data.create_function, "cjson", { encode = function() return nil end, decode = prev_cjson_create.decode, null = prev_cjson_create.null })
    assert_eq(select(1, data.create_function("python", "encodefail", nil, {})), nil, "create_function encode fail")
    set_upvalue(data.create_function, "cjson", prev_cjson_create)

    local prev_write_cfg = get_upvalue(data.create_function, "write_file")
    local wc = 0
    set_upvalue(data.create_function, "write_file", function(path, content)
      wc = wc + 1
      if wc == 1 then
        return prev_write_cfg(path, content)
      end
      return nil, "cfg boom"
    end)
    assert_eq(select(1, data.create_function("python", "cfgwritefail", nil, {})), nil, "create_function config write fail")
    set_upvalue(data.create_function, "write_file", prev_write_cfg)

    data.function_detail = function() return nil, "detail create boom" end
    assert_eq(select(1, data.create_function("python", "detailfail", nil, {})), nil, "create_function detail fail")
    data.function_detail = prev_detail

    local prev_path_delete = get_upvalue(data.delete_function, "path_is_under")
    set_upvalue(data.delete_function, "path_is_under", function() return false end)
    assert_eq(select(1, data.delete_function("python", "demo", nil)), nil, "delete_function invalid path")
    set_upvalue(data.delete_function, "path_is_under", prev_path_delete)

    local prev_symlink_delete = get_upvalue(data.delete_function, "is_symlink")
    set_upvalue(data.delete_function, "is_symlink", function() return true end)
    assert_eq(select(1, data.delete_function("python", "demo", nil)), nil, "delete_function symlink")
    set_upvalue(data.delete_function, "is_symlink", prev_symlink_delete)

    local prev_file_size = get_upvalue(data.function_files, "file_size")
    set_upvalue(data.function_files, "file_size", function() return 0 end)
    assert_true(data.function_files("python", "demo", nil) ~= nil, "function_files with stubbed size")
    set_upvalue(data.function_files, "file_size", prev_file_size)

    local prev_resolve_files = get_upvalue(data.function_files, "resolve_function_paths")
    set_upvalue(data.function_files, "resolve_function_paths", function() return nil, "missing" end)
    assert_eq(select(1, data.function_files("python", "missing_fn", nil)), nil, "function_files target err")
    set_upvalue(data.function_files, "resolve_function_paths", prev_resolve_files)

    local prev_resolve_files_path = get_upvalue(data.function_files, "resolve_function_paths")
    set_upvalue(data.function_files, "resolve_function_paths", function()
      return {
        fn_dir = "/tmp/outside-demo",
        app_path = root .. "/python/demo/handler.py",
        conf_path = root .. "/python/demo/fn.config.json",
        env_path = root .. "/python/demo/fn.env.json",
      }
    end)
    assert_eq(select(1, data.function_files("python", "demo", nil)), nil, "function_files invalid function path")
    set_upvalue(data.function_files, "resolve_function_paths", prev_resolve_files_path)

    assert_eq(select(1, data.read_function_file("python", "bad name", "x.txt", nil)), nil, "read_function_file invalid function")
    local prev_path_read = get_upvalue(data.read_function_file, "path_is_under")
    local ok_patch_read = set_upvalue(data.read_function_file, "path_is_under", function() return false end)
    assert_true(ok_patch_read, "patch read_function_file path_is_under")
    assert_eq(select(1, data.read_function_file("python", "demo", "x.txt", nil)), nil, "read_function_file outside")
    set_upvalue(data.read_function_file, "path_is_under", prev_path_read)

    assert_eq(select(1, data.write_function_file("python", "bad name", "x.txt", "x", nil)), nil, "write_function_file invalid function")
    local prev_path_write = get_upvalue(data.write_function_file, "path_is_under")
    local ok_patch_write = set_upvalue(data.write_function_file, "path_is_under", function() return false end)
    assert_true(ok_patch_write, "patch write_function_file path_is_under")
    assert_eq(select(1, data.write_function_file("python", "demo", "x.txt", "x", nil)), nil, "write_function_file outside")
    set_upvalue(data.write_function_file, "path_is_under", prev_path_write)

    write_file(ctx.root .. "/python/demo/real.txt", "ok")
    os.execute(string.format("ln -sf %q %q", ctx.root .. "/python/demo/real.txt", ctx.root .. "/python/demo/link.txt"))
    assert_eq(select(1, data.write_function_file("python", "demo", "link.txt", "x", nil)), nil, "write_function_file symlink")

    local prev_path_delete_file = get_upvalue(data.delete_function_file, "path_is_under")
    local ok_patch_delete = set_upvalue(data.delete_function_file, "path_is_under", function() return false end)
    assert_true(ok_patch_delete, "patch delete_function_file path_is_under")
    assert_eq(select(1, data.delete_function_file("python", "demo", "x.txt", nil)), nil, "delete_function_file outside")
    set_upvalue(data.delete_function_file, "path_is_under", prev_path_delete_file)
  end)
end

local function test_console_data_ensure_dir_fallback_paths()
  with_console_data_fixture(function(ctx)
    local data = ctx.data
    local ensure_dir = get_upvalue(data.create_function, "ensure_dir")
    assert_true(type(ensure_dir) == "function", "console ensure_dir helper available")
    local ok_patch_fs, prev_fs = set_upvalue(ensure_dir, "fs", {
      is_dir = function()
        return false
      end,
      mkdir_p = function(path)
        return path == ctx.root .. "/python/demo", "mkdir failed"
      end,
    })
    assert_true(ok_patch_fs, "patch ensure_dir fs")
    assert_eq(ensure_dir(ctx.root .. "/python/demo"), true, "ensure_dir mkdir_p success")

    set_upvalue(ensure_dir, "fs", {
      is_dir = function()
        return false
      end,
      mkdir_p = function()
        return false, "mkdir failed"
      end,
    })
    assert_eq(ensure_dir(ctx.root .. "/python/demo"), false, "ensure_dir mkdir_p failure")

    set_upvalue(ensure_dir, "fs", prev_fs)
  end)
end

local function test_jobs_internal_helpers_and_edge_cases()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-jobs-helpers-" .. uniq
    rm_rf(root)
    mkdir_p(root)

    local routes_stub = {
      get_config = function()
        return { functions_root = root, socket_base_dir = root, runtimes = { lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true } } }
      end,
      resolve_named_target = function(name, version)
        if name == "demo" then
          return "lua", version
        end
        return nil, nil
      end,
      discover_functions = function()
        return {
          mapped_routes = {
            ["/demo/:id"] = {
              { runtime = "lua", fn_name = "demo", version = nil, methods = { "GET", "POST" } },
            },
            ["/demo/:tail*"] = {
              { runtime = "lua", fn_name = "demo", version = nil, methods = { "GET" } },
            },
          },
          runtimes = {},
        }
      end,
      resolve_function_policy = function(runtime, name)
        if runtime ~= "lua" or name ~= "demo" then
          return nil, "unknown function"
        end
        return {
          methods = { "GET", "POST" },
          timeout_ms = 1000,
          max_concurrency = 2,
          max_body_bytes = 4096,
        }
      end,
      get_runtime_config = function()
        return { socket = "inprocess:lua", timeout_ms = 2500, in_process = true }
      end,
      runtime_is_up = function()
        return true
      end,
      check_runtime_health = function()
        return true, "ok"
      end,
      set_runtime_health = function() end,
      runtime_is_in_process = function()
        return true
      end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.limits"] = { try_acquire = function() return true end, release = function() end },
      ["fastfn.core.gateway_utils"] = { map_runtime_error = function() return 502, "runtime error" end, resolve_numeric = function(a, b) return tonumber(a) or tonumber(b) end },
      ["fastfn.core.lua_runtime"] = { call = function() return { status = 200, headers = {}, body = cjson.encode({ ok = true }) } end },
      ["fastfn.core.client"] = { call_unix = function() return nil, "connect_error", "down" end },
      ["fastfn.core.invoke_rules"] = { normalize_route = function(route) if type(route) == "string" and route:sub(1, 1) == "/" then return route end return nil end },
    }, function()
      package.loaded["fastfn.core.jobs"] = nil
      local jobs = require("fastfn.core.jobs")

      local parse_params_object = get_upvalue(jobs.enqueue, "parse_params_object")
      local interpolate_route_params = get_upvalue(jobs.enqueue, "interpolate_route_params")
      local encode_path_segment = get_upvalue(interpolate_route_params, "encode_path_segment")
      local encode_catch_all = get_upvalue(interpolate_route_params, "encode_catch_all")
      local method_allowed = get_upvalue(jobs.enqueue, "method_allowed")
      local allow_header_value = get_upvalue(jobs.enqueue, "allow_header_value")

      assert_true(type(parse_params_object) == "function", "parse_params_object helper")
      assert_true(type(interpolate_route_params) == "function", "interpolate_route_params helper")
      assert_true(type(encode_path_segment) == "function", "encode_path_segment helper")
      assert_true(type(encode_catch_all) == "function", "encode_catch_all helper")
      assert_true(type(method_allowed) == "function", "method_allowed helper")
      assert_true(type(allow_header_value) == "function", "allow_header_value helper")

      local parsed_ok, parsed_ok_err = parse_params_object({ id = 123, active = true, n = cjson.null })
      assert_true(type(parsed_ok) == "table", parsed_ok_err or "parse_params_object success")
      assert_eq(parsed_ok.id, "123", "parse_params_object numeric cast")
      assert_eq(parsed_ok.active, "true", "parse_params_object boolean cast")
      local parsed_bad0, parsed_bad0_err = parse_params_object({ "list" })
      assert_eq(parsed_bad0, nil, "parse_params_object array should fail")
      assert_true(type(parsed_bad0_err) == "string" and parsed_bad0_err:find("JSON object", 1, true) ~= nil, "parse_params_object array error")

      assert_eq(encode_path_segment("a b"), "a b", "encode_path_segment uses ngx.escape_uri")
      assert_eq(encode_catch_all("a/b/c"), "a/b/c", "encode_catch_all keeps separators")

      local rendered0, missing0 = interpolate_route_params("/demo/:id", { id = "x y" })
      assert_eq(rendered0, "/demo/x y", "interpolate_route_params simple")
      assert_eq(missing0, nil, "interpolate_route_params no missing")
      local rendered1, missing1 = interpolate_route_params("/demo/:tail*", { tail = "a/b/c" })
      assert_eq(rendered1, "/demo/a/b/c", "interpolate_route_params catch-all")
      assert_eq(missing1, nil, "interpolate_route_params catch-all missing nil")
      local rendered2, missing2 = interpolate_route_params("/demo/:id/:tail*", { id = "x" })
      assert_eq(rendered2, nil, "interpolate_route_params missing should fail")
      assert_true(type(missing2) == "table" and missing2[1] == "tail", "interpolate_route_params missing names")

      assert_eq(method_allowed("GET", nil), true, "method_allowed default GET")
      assert_eq(method_allowed("POST", nil), false, "method_allowed default denies POST")
      assert_eq(method_allowed("POST", { "GET", "POST" }), true, "method_allowed explicit")
      assert_eq(allow_header_value(nil), "GET", "allow_header_value default")
      assert_eq(allow_header_value({ "GET", "POST" }), "GET, POST", "allow_header_value list")

      local enqueue_ok, enqueue_status = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "GET",
        route = "/demo/:id",
        params = { id = "ok" },
      })
      assert_eq(enqueue_status, 201, "jobs enqueue status")
      assert_true(type(enqueue_ok) == "table" and type(enqueue_ok.id) == "string", "jobs enqueue response")

      local ensure_name = get_upvalue(jobs.enqueue, "ensure_name")
      local ensure_version = get_upvalue(jobs.enqueue, "ensure_version")
      local ensure_runtime = get_upvalue(jobs.enqueue, "ensure_runtime")
      local normalize_method = get_upvalue(jobs.enqueue, "normalize_method")
      local normalize_body = get_upvalue(jobs.enqueue, "normalize_body")
      local resolve_mapped_route = get_upvalue(jobs.enqueue, "resolve_mapped_route")
      local jobs_dir = get_upvalue(jobs.init, "jobs_dir")
      local jobs_enabled = get_upvalue(jobs.init, "jobs_enabled")
      local jobs_poll_interval = get_upvalue(jobs.init, "jobs_poll_interval")
      local env_bool = get_upvalue(jobs_enabled, "env_bool")
      local env_num = get_upvalue(jobs_poll_interval, "env_num")
      local process_queue = get_upvalue(jobs.init, "process_queue")
      local jobs_max_concurrency = get_upvalue(process_queue, "jobs_max_concurrency")
      local run_job = get_upvalue(process_queue, "run_job")
      local write_result = get_upvalue(run_job, "write_result")
      local jobs_max_result_bytes = get_upvalue(write_result, "jobs_max_result_bytes")
      local invoke_one = get_upvalue(run_job, "invoke_one")
      local set_meta = get_upvalue(run_job, "set_meta")
      local get_meta = get_upvalue(run_job, "get_meta")
      local job_cancel_key = get_upvalue(run_job, "job_cancel_key")
      local active_key = get_upvalue(run_job, "active_key")
      local read_spec = get_upvalue(run_job, "read_spec")

      assert_true(type(ensure_name) == "function", "ensure_name helper")
      assert_true(type(ensure_version) == "function", "ensure_version helper")
      assert_true(type(ensure_runtime) == "function", "ensure_runtime helper")
      assert_true(type(normalize_method) == "function", "normalize_method helper")
      assert_true(type(normalize_body) == "function", "normalize_body helper")
      assert_true(type(resolve_mapped_route) == "function", "resolve_mapped_route helper")
      assert_true(type(jobs_dir) == "function", "jobs_dir helper")
      assert_true(type(jobs_enabled) == "function", "jobs_enabled helper")
      assert_true(type(jobs_poll_interval) == "function", "jobs_poll_interval helper")
      assert_true(type(jobs_max_concurrency) == "function", "jobs_max_concurrency helper")
      assert_true(type(jobs_max_result_bytes) == "function", "jobs_max_result_bytes helper")
      assert_true(type(env_bool) == "function", "env_bool helper")
      assert_true(type(env_num) == "function", "env_num helper")
      assert_true(type(process_queue) == "function", "process_queue helper")
      assert_true(type(run_job) == "function", "run_job helper")
      assert_true(type(invoke_one) == "function", "invoke_one helper")
      assert_true(type(set_meta) == "function", "set_meta helper")
      assert_true(type(get_meta) == "function", "get_meta helper")
      assert_true(type(job_cancel_key) == "function", "job_cancel_key helper")
      assert_true(type(active_key) == "function", "active_key helper")
      assert_true(type(read_spec) == "function", "read_spec helper")

      local write_spec_helper = get_upvalue(jobs.enqueue, "write_spec")
	      local ensure_dir = get_upvalue(write_spec_helper, "ensure_dir")
	      local write_file_atomic = get_upvalue(write_spec_helper, "write_file_atomic")
	      local jobs_fs = get_upvalue(ensure_dir, "fs")
	      local write_file_fs = get_upvalue(write_file_atomic, "fs")
	      local read_file = get_upvalue(jobs.read_result, "read_file")
      local mapping_method_allowed = get_upvalue(resolve_mapped_route, "mapping_method_allowed")
      local mark_recent = get_upvalue(jobs.enqueue, "mark_recent")
      local encode_catch_all_local = get_upvalue(interpolate_route_params, "encode_catch_all")
      assert_true(type(write_spec_helper) == "function", "write_spec helper")
      assert_true(type(ensure_dir) == "function", "ensure_dir helper")
      assert_true(type(write_file_atomic) == "function", "write_file_atomic helper")
      assert_true(type(read_file) == "function", "read_file helper")
      assert_true(type(mapping_method_allowed) == "function", "mapping_method_allowed helper")
      assert_true(type(mark_recent) == "function", "mark_recent helper")
      assert_true(type(encode_catch_all_local) == "function", "encode_catch_all helper alias")

      with_env({ FN_JOBS_POLL_INTERVAL = "-1" }, function()
        assert_eq(jobs_poll_interval(), 1, "jobs_poll_interval <=0 fallback")
      end)

      local ensure_dir_ok0, ensure_dir_err0 = ensure_dir(nil)
      assert_eq(ensure_dir_ok0, false, "ensure_dir invalid path")
      assert_true(type(ensure_dir_err0) == "string" and ensure_dir_err0:find("invalid dir", 1, true) ~= nil, "ensure_dir invalid path err")
	      local original_jobs_mkdir_p = jobs_fs.mkdir_p
	      jobs_fs.mkdir_p = function()
	        return false, "mkdir failed"
	      end
	      local ensure_dir_ok1, ensure_dir_err1 = ensure_dir("/tmp/fastfn-jobs-mkdir-fail-" .. uniq)
	      jobs_fs.mkdir_p = original_jobs_mkdir_p
	      assert_eq(ensure_dir_ok1, false, "ensure_dir mkdir failure")
	      assert_true(type(ensure_dir_err1) == "string" and ensure_dir_err1:find("mkdir failed", 1, true) ~= nil, "ensure_dir mkdir failure err")

      local original_io_open = io.open
      io.open = function()
        return nil, "open-fail"
      end
      local wf_ok0, wf_err0 = write_file_atomic(root .. "/x.tmp", "abc")
      io.open = original_io_open
      assert_eq(wf_ok0, nil, "write_file_atomic open failure")
      assert_true(type(wf_err0) == "string" and wf_err0:find("open-fail", 1, true) ~= nil, "write_file_atomic open error")

	      local original_write_file_rename_atomic = write_file_fs.rename_atomic
	      local original_write_file_remove_tree = write_file_fs.remove_tree
	      io.open = function()
	        return {
	          write = function() end,
          close = function() end,
        }
      end
	      write_file_fs.rename_atomic = function()
	        return nil, "rename-fail"
	      end
	      write_file_fs.remove_tree = function()
	        return true
	      end
	      local wf_ok1, wf_err1 = write_file_atomic(root .. "/x.tmp2", "abc")
	      io.open = original_io_open
	      write_file_fs.rename_atomic = original_write_file_rename_atomic
	      write_file_fs.remove_tree = original_write_file_remove_tree
	      assert_eq(wf_ok1, nil, "write_file_atomic rename failure")
	      assert_true(type(wf_err1) == "string" and wf_err1:find("rename-fail", 1, true) ~= nil, "write_file_atomic rename error")

      write_file(root .. "/read-helper.txt", "abcdef")
      local read_all, read_all_trunc = read_file(root .. "/read-helper.txt", nil)
      assert_eq(read_all, "abcdef", "read_file *a branch")
      assert_eq(read_all_trunc, false, "read_file *a trunc flag")
      local read_cut, read_cut_trunc = read_file(root .. "/read-helper.txt", 3)
      assert_eq(read_cut, "abc", "read_file max bytes")
      assert_eq(read_cut_trunc, true, "read_file truncation flag")
      io.open = function()
        return {
          read = function()
            return nil
          end,
          close = function() end,
        }
      end
      local read_nil = read_file(root .. "/read-helper.txt", nil)
      io.open = original_io_open
      assert_eq(read_nil, nil, "read_file nil data branch")

      assert_eq(mapping_method_allowed(nil, "GET"), true, "mapping_method_allowed default true")
      assert_eq(encode_catch_all_local(""), "", "encode_catch_all empty")
      assert_true(type(encode_catch_all_local("//")) == "string", "encode_catch_all escaped raw path")

      local prev_routes_mapped = get_upvalue(resolve_mapped_route, "routes")
      set_upvalue(resolve_mapped_route, "routes", {
        discover_functions = function()
          return {
            mapped_routes = {
              ["/compat"] = { runtime = "lua", fn_name = "demo", version = nil, methods = { "GET" } },
            },
          }
        end,
      })
      local mapped_compat = resolve_mapped_route("lua", "demo", nil, "GET")
      assert_eq(mapped_compat, "/compat", "resolve_mapped_route compat entry shape")
      set_upvalue(resolve_mapped_route, "routes", prev_routes_mapped)

      cache:set("job:meta-invalid:meta", "\"bad\"")
      assert_eq(get_meta("meta-invalid"), nil, "get_meta invalid JSON object branch")

      for i = 1, 260 do
        mark_recent("old-" .. tostring(i))
      end

      local prev_ensure_dir_ws = get_upvalue(write_spec_helper, "ensure_dir")
      set_upvalue(write_spec_helper, "ensure_dir", function()
        return nil, "ensure-dir-fail"
      end)
      local ws_ok, ws_err = write_spec_helper("helper-write-spec", { ok = true })
      assert_eq(ws_ok, nil, "write_spec ensure_dir failure")
      assert_true(type(ws_err) == "string" and ws_err:find("ensure-dir-fail", 1, true) ~= nil, "write_spec ensure_dir failure err")
      set_upvalue(write_spec_helper, "ensure_dir", prev_ensure_dir_ws)

      write_file(root .. "/jobs/read-spec-invalid.spec.json", "\"bad\"")
      assert_eq(read_spec("read-spec-invalid"), nil, "read_spec invalid object branch")

      local prev_ensure_dir_wr = get_upvalue(write_result, "ensure_dir")
      set_upvalue(write_result, "ensure_dir", function()
        return nil, "ensure-dir-fail-result"
      end)
      local wr_fail_ok, wr_fail_err = write_result("wr-fail", { status = 200, headers = {}, body = "ok" })
      assert_eq(wr_fail_ok, nil, "write_result ensure_dir failure")
      assert_true(type(wr_fail_err) == "string" and wr_fail_err:find("ensure-dir-fail-result", 1, true) ~= nil, "write_result ensure_dir failure err")
      set_upvalue(write_result, "ensure_dir", prev_ensure_dir_wr)

      with_env({ FN_JOBS_MAX_RESULT_BYTES = "120" }, function()
        local wr_ok = write_result("wr-trunc", { status = 200, headers = {}, body = string.rep("x", 1000) })
        assert_true(wr_ok == true or wr_ok == 0, "write_result truncation write ok")
      end)
      local wr_trunc = jobs.read_result("wr-trunc")
      assert_true(wr_trunc == nil or wr_trunc.truncated == true, "write_result truncation branch")
      write_file(root .. "/jobs/result-not-object.result.json", "\"bad\"")
      assert_eq(jobs.read_result("result-not-object"), nil, "read_result decoded non-object branch")

      local bad_name0, bad_name0_err = ensure_name(nil)
      assert_eq(bad_name0, nil, "ensure_name nil")
      assert_true(type(bad_name0_err) == "string" and bad_name0_err:find("required", 1, true) ~= nil, "ensure_name nil err")
      local bad_name1, bad_name1_err = ensure_name("/bad")
      assert_eq(bad_name1, nil, "ensure_name invalid path")
      assert_true(type(bad_name1_err) == "string" and bad_name1_err:find("invalid", 1, true) ~= nil, "ensure_name invalid err")
      local bad_name2, bad_name2_err = ensure_name("bad name")
      assert_eq(bad_name2, nil, "ensure_name invalid chars")
      assert_true(type(bad_name2_err) == "string" and bad_name2_err:find("invalid", 1, true) ~= nil, "ensure_name invalid chars err")

      local bad_ver0, bad_ver0_err = ensure_version({})
      assert_eq(bad_ver0, nil, "ensure_version invalid type")
      assert_true(type(bad_ver0_err) == "string" and bad_ver0_err:find("invalid version", 1, true) ~= nil, "ensure_version invalid err")
      assert_eq(ensure_version("v1"), "v1", "ensure_version valid")

      local bad_rt0, bad_rt0_err = ensure_runtime("bad runtime")
      assert_eq(bad_rt0, nil, "ensure_runtime invalid")
      assert_true(type(bad_rt0_err) == "string" and bad_rt0_err:find("invalid runtime", 1, true) ~= nil, "ensure_runtime invalid err")
      assert_eq(ensure_runtime("python"), "python", "ensure_runtime valid")

      local bad_method, bad_method_err = normalize_method("TRACE")
      assert_eq(bad_method, nil, "normalize_method invalid")
      assert_true(type(bad_method_err) == "string" and bad_method_err:find("unsupported", 1, true) ~= nil, "normalize_method invalid err")

      local bad_body, bad_body_err = normalize_body(function() end)
      assert_eq(bad_body, nil, "normalize_body non-encodable")
      assert_true(type(bad_body_err) == "string" and bad_body_err:find("JSON-encodable", 1, true) ~= nil, "normalize_body non-encodable err")

      local mapped0 = resolve_mapped_route("lua", "demo", nil, "GET")
      assert_true(type(mapped0) == "string" and mapped0:find("/demo/", 1, true) ~= nil, "resolve_mapped_route match")
      local mapped1 = resolve_mapped_route("lua", "demo", nil, "DELETE")
      assert_eq(mapped1, nil, "resolve_mapped_route no candidate")

      with_env({ FN_JOBS_DIR = "/tmp/jobs-custom" }, function()
        assert_eq(jobs_dir(), "/tmp/jobs-custom", "jobs_dir env override")
      end)
      local prev_routes = get_upvalue(jobs_dir, "routes")
      set_upvalue(jobs_dir, "routes", { get_config = function() return {} end })
      with_env({ FN_JOBS_DIR = false }, function()
        assert_eq(jobs_dir(), "/tmp/fastfn/jobs", "jobs_dir default fallback")
      end)
      set_upvalue(jobs_dir, "routes", prev_routes)

      with_env({ FN_JOBS_ENABLED = "off", FN_JOBS_POLL_INTERVAL = "x", FN_JOBS_MAX_CONCURRENCY = "0", FN_JOBS_MAX_RESULT_BYTES = "-1" }, function()
        assert_eq(env_bool("FN_JOBS_ENABLED", true), false, "env_bool false branch")
        assert_eq(env_num("FN_JOBS_POLL_INTERVAL", 7), 7, "env_num fallback")
        assert_eq(jobs_poll_interval(), 1, "jobs_poll_interval default floor")
        assert_eq(jobs_max_concurrency(), 2, "jobs_max_concurrency default fallback")
        assert_eq(jobs_max_result_bytes(), 262144, "jobs_max_result_bytes default fallback")
      end)
      with_env({ FN_JOBS_ENABLED = "weird" }, function()
        assert_eq(env_bool("FN_JOBS_ENABLED", true), true, "env_bool default branch")
      end)

	      local init_worker_id = ngx.worker.id
	      ngx.worker.id = function()
	        return 1
	      end
	      jobs.init()
	      ngx.worker.id = init_worker_id
	      with_env({ FN_JOBS_ENABLED = "0" }, function()
	        jobs.init()
	      end)
	      io.open = original_io_open
	      jobs_fs.mkdir_p = original_jobs_mkdir_p
	      write_file_fs.rename_atomic = original_write_file_rename_atomic
	      write_file_fs.remove_tree = original_write_file_remove_tree

	      local bad_enqueue0, bad_enqueue0_status = jobs.enqueue("bad")
      assert_eq(bad_enqueue0, nil, "enqueue non-table")
      assert_eq(bad_enqueue0_status, 400, "enqueue non-table status")
      local bad_enqueue1, bad_enqueue1_status = jobs.enqueue({ runtime = "lua" })
      assert_eq(bad_enqueue1, nil, "enqueue missing name")
      assert_eq(bad_enqueue1_status, 400, "enqueue missing name status")
      local bad_enqueue2, bad_enqueue2_status = jobs.enqueue({ runtime = "lua", name = "demo", version = {} })
      assert_eq(bad_enqueue2, nil, "enqueue invalid version")
      assert_eq(bad_enqueue2_status, 400, "enqueue invalid version status")
      local bad_enqueue3, bad_enqueue3_status = jobs.enqueue({ name = "missing", method = "GET" })
      assert_eq(bad_enqueue3, nil, "enqueue unresolved runtime")
      assert_eq(bad_enqueue3_status, 404, "enqueue unresolved runtime status")
      local bad_enqueue4, bad_enqueue4_status = jobs.enqueue({ runtime = "bad runtime", name = "demo", method = "GET" })
      assert_eq(bad_enqueue4, nil, "enqueue invalid runtime")
      assert_eq(bad_enqueue4_status, 400, "enqueue invalid runtime status")
      local bad_enqueue5, bad_enqueue5_status = jobs.enqueue({ runtime = "lua", name = "demo", method = "TRACE" })
      assert_eq(bad_enqueue5, nil, "enqueue invalid method")
      assert_eq(bad_enqueue5_status, 400, "enqueue invalid method status")
      local bad_enqueue6, bad_enqueue6_status = jobs.enqueue({ runtime = "lua", name = "missing", method = "GET" })
      assert_eq(bad_enqueue6, nil, "enqueue unknown policy target")
      assert_eq(bad_enqueue6_status, 404, "enqueue unknown policy target status")
      local bad_enqueue7, bad_enqueue7_status = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "GET",
        route = {},
      })
      assert_eq(bad_enqueue7, nil, "enqueue invalid route type")
      assert_eq(bad_enqueue7_status, 400, "enqueue invalid route type status")
      local bad_enqueue8, bad_enqueue8_status = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "GET",
        route = "/demo/:id",
        params = { [""] = "x" },
      })
      assert_eq(bad_enqueue8, nil, "enqueue invalid params object")
      assert_eq(bad_enqueue8_status, 400, "enqueue invalid params status")
      local bad_enqueue9, bad_enqueue9_status = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "GET",
        route = "no-slash",
        params = { id = "x" },
      })
      assert_eq(bad_enqueue9, nil, "enqueue invalid route format")
      assert_eq(bad_enqueue9_status, 400, "enqueue invalid route format status")
      local bad_enqueue10, bad_enqueue10_status = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "DELETE",
      })
      assert_eq(bad_enqueue10, nil, "enqueue no mapped route for method")
      assert_eq(bad_enqueue10_status, 405, "enqueue no mapped route status via policy check")
      local bad_enqueue11, bad_enqueue11_status = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "POST",
        route = "/demo/:id",
        params = { id = "x" },
        body = function() end,
      })
      assert_eq(bad_enqueue11, nil, "enqueue invalid body")
      assert_eq(bad_enqueue11_status, 400, "enqueue invalid body status")

      local caps_meta, caps_status = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "GET",
        route = cjson.null,
        params = { id = "caps" },
        max_attempts = 0,
        retry_delay_ms = -5,
      })
      assert_eq(caps_status, 201, "enqueue caps status")
      assert_eq(caps_meta.max_attempts, 1, "enqueue max_attempts floor")
      assert_eq(caps_meta.retry_delay_ms, 1000, "enqueue retry_delay floor")

      local prev_resolve_mapped = get_upvalue(jobs.enqueue, "resolve_mapped_route")
      set_upvalue(jobs.enqueue, "resolve_mapped_route", function()
        return nil
      end)
      local no_route_meta, no_route_status = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "GET",
      })
      assert_eq(no_route_meta, nil, "enqueue missing mapped route")
      assert_eq(no_route_status, 404, "enqueue missing mapped route status")
      set_upvalue(jobs.enqueue, "resolve_mapped_route", prev_resolve_mapped)

	      local write_spec_fn = get_upvalue(jobs.enqueue, "write_spec")
	      assert_true(type(write_spec_fn) == "function", "enqueue write_spec helper available")
	      local prev_write_file_atomic = get_upvalue(write_spec_fn, "write_file_atomic")
	      set_upvalue(write_spec_fn, "write_file_atomic", function()
	        return nil, "write-spec-fail"
	      end)
	      local write_spec_meta, write_spec_status = jobs.enqueue({
	        runtime = "lua",
	        name = "demo",
        method = "GET",
        route = "/demo/:id",
        params = { id = "write-spec-fail" },
      })
	      assert_true(type(write_spec_meta) == "table", "enqueue write_spec failure meta")
	      assert_eq(write_spec_status, 500, "enqueue write_spec failure status")
	      assert_eq(write_spec_meta.status, "failed", "enqueue write_spec failure meta status")
	      set_upvalue(write_spec_fn, "write_file_atomic", prev_write_file_atomic)

      -- Direct invoke_one branches.
      local prev_routes_unknown_rt = get_upvalue(invoke_one, "routes")
      set_upvalue(invoke_one, "routes", {
        get_runtime_config = function()
          return nil
        end,
      })
      local _, st_unknown_rt = invoke_one({
        runtime = "node",
        name = "demo",
        method = "GET",
      })
      assert_eq(st_unknown_rt, 404, "invoke_one unknown runtime")
      set_upvalue(invoke_one, "routes", prev_routes_unknown_rt)

      local _, st_unknown_fn = invoke_one({
        runtime = "lua",
        name = "missing",
        method = "GET",
      })
      assert_eq(st_unknown_fn, 404, "invoke_one unknown function")

      local _, st_not_allowed = invoke_one({
        runtime = "lua",
        name = "demo",
        method = "DELETE",
      })
      assert_eq(st_not_allowed, 405, "invoke_one method not allowed")

      local _, st_too_large = invoke_one({
        runtime = "lua",
        name = "demo",
        method = "POST",
        body = string.rep("x", 5000),
      })
      assert_eq(st_too_large, 413, "invoke_one payload too large")

      local limits_prev = get_upvalue(invoke_one, "limits")
      set_upvalue(invoke_one, "limits", {
        try_acquire = function() return false, "busy" end,
        release = function() end,
      })
      local _, st_busy = invoke_one({
        runtime = "lua",
        name = "demo",
        method = "GET",
      })
      assert_eq(st_busy, 429, "invoke_one busy branch")
      set_upvalue(invoke_one, "limits", {
        try_acquire = function() return false, "gate_fail" end,
        release = function() end,
      })
      local _, st_gate_fail = invoke_one({
        runtime = "lua",
        name = "demo",
        method = "GET",
      })
      assert_eq(st_gate_fail, 500, "invoke_one gate failure branch")
      set_upvalue(invoke_one, "limits", limits_prev)

      local routes_prev_invoke = get_upvalue(invoke_one, "routes")
      set_upvalue(invoke_one, "routes", {
        get_runtime_config = function() return { socket = "unix:/tmp/fn.sock", timeout_ms = 2500, in_process = false } end,
        resolve_function_policy = routes_stub.resolve_function_policy,
        runtime_is_up = function() return true end,
        check_runtime_health = function() return true, "ok" end,
        set_runtime_health = function() end,
        runtime_is_in_process = function() return false end,
      })
      local _, st_runtime_down = invoke_one({
        runtime = "lua",
        name = "demo",
        method = "GET",
      })
      assert_eq(st_runtime_down, 502, "invoke_one unix client down branch")
      set_upvalue(invoke_one, "routes", routes_prev_invoke)

      -- run_job / process_queue branches.
      run_job(true, enqueue_ok.id)
      run_job(false, "missing-job-id")

      local canceled_meta = {
        id = "job-canceled",
        status = "queued",
        max_attempts = 1,
        retry_delay_ms = 0,
      }
      set_meta(canceled_meta.id, canceled_meta)
      cache:set(job_cancel_key(canceled_meta.id), 1)
      run_job(false, canceled_meta.id)
      local canceled_after = get_meta(canceled_meta.id)
      assert_eq(canceled_after.status, "canceled", "run_job canceled branch")

      local prev_invoke = get_upvalue(run_job, "invoke_one")
      local base64_id = "job-base64"
      set_meta(base64_id, { id = base64_id, status = "queued", max_attempts = 1, retry_delay_ms = 0 })
      set_upvalue(run_job, "invoke_one", function()
        return { status = 200, headers = { ["Content-Type"] = "application/octet-stream" }, is_base64 = true, body_base64 = "YWJj" }, 200, nil, nil, 1
      end)
      run_job(false, base64_id)
      local base64_result = jobs.read_result(base64_id)
      assert_true(type(base64_result) == "table" and base64_result.is_base64 == true, "run_job base64 response branch")

      local allow_id = "job-allow"
      set_meta(allow_id, { id = allow_id, status = "queued", max_attempts = 1, retry_delay_ms = 0 })
      set_upvalue(run_job, "invoke_one", function()
        return nil, 405, "method not allowed", { Allow = "GET" }, 1
      end)
      run_job(false, allow_id)
      local allow_result = jobs.read_result(allow_id)
      assert_true(type(allow_result.headers) == "table" and allow_result.headers.Allow == "GET", "run_job allow header branch")

      local crash_id = "job-crash"
      set_meta(crash_id, { id = crash_id, status = "queued", max_attempts = 1, retry_delay_ms = 0 })
      set_upvalue(run_job, "invoke_one", function()
        error("boom-run-job")
      end)
      run_job(false, crash_id)
      local crash_meta = get_meta(crash_id)
      assert_eq(crash_meta.status, "failed", "run_job xpcall error branch")
      set_upvalue(run_job, "invoke_one", prev_invoke)

      process_queue(true)
      with_env({ FN_JOBS_ENABLED = "0" }, function()
        process_queue(false)
      end)
      local original_worker_id = ngx.worker.id
      ngx.worker.id = function()
        return 1
      end
      process_queue(false)
      ngx.worker.id = original_worker_id
      cache:set(active_key(), 99)
      process_queue(false)
      cache:delete(active_key())

      local queue_fail_meta, _ = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "GET",
        route = "/demo/:id",
        params = { id = "queue-fail" },
      })
      local original_timer_at = ngx.timer.at
      ngx.timer.at = function()
        return false
      end
      local prev_dequeue_id = get_upvalue(process_queue, "dequeue_id")
      local consumed = false
      set_upvalue(process_queue, "dequeue_id", function()
        if consumed then
          return nil
        end
        consumed = true
        return queue_fail_meta.id
      end)
      with_env({ FN_JOBS_MAX_CONCURRENCY = "1" }, function()
        process_queue(false)
      end)
      set_upvalue(process_queue, "dequeue_id", prev_dequeue_id)
      ngx.timer.at = original_timer_at
      local queue_fail_after = jobs.get(queue_fail_meta.id)
      assert_eq(queue_fail_after.status, "failed", "process_queue timer failure branch")

      local list_low = jobs.list(0)
      assert_true(type(list_low) == "table", "jobs list lower bound")
      local list_high = jobs.list(999)
      assert_true(type(list_high) == "table", "jobs list upper bound")

      local cancel_missing, cancel_missing_status = jobs.cancel("missing")
      assert_eq(cancel_missing, nil, "jobs cancel missing")
      assert_eq(cancel_missing_status, 404, "jobs cancel missing status")
      local cancel_not_queued, cancel_not_queued_status = jobs.cancel(crash_id)
      assert_eq(cancel_not_queued, nil, "jobs cancel non-queued")
      assert_eq(cancel_not_queued_status, 409, "jobs cancel non-queued status")

      local spec = read_spec(enqueue_ok.id)
      assert_true(type(spec) == "table", "read_spec helper should decode spec")
      write_file(root .. "/jobs/invalid.result.json", "{bad json")
      assert_eq(jobs.read_result("invalid"), nil, "jobs read_result invalid json")
    end)

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

local function test_routes_runtime_config_and_init_edge_paths()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-routes-edge-" .. uniq
    local functions_root = root .. "/srv/fn/functions"

    rm_rf(root)
    mkdir_p(functions_root)
    mkdir_p(functions_root .. "/node/hasdefault")
    mkdir_p(functions_root .. "/node/versioned/v1")
    mkdir_p(functions_root .. "/python/hello")
    mkdir_p(functions_root .. "/php/basic")
    mkdir_p(functions_root .. "/lua/echo")
    mkdir_p(functions_root .. "/rust/exp")
    mkdir_p(functions_root .. "/go/exp")
    mkdir_p(functions_root .. "/node/aa_force_on")
    mkdir_p(functions_root .. "/node/ab_force_off")
    mkdir_p(functions_root .. "/node/ba_force_off")
    mkdir_p(functions_root .. "/node/bb_force_on")
    mkdir_p(functions_root .. "/node/runtime_manifest")
    mkdir_p(functions_root .. "/beta")

    write_file(functions_root .. "/node/hasdefault/handler.js", "exports.handler = async () => ({ status: 200, body: 'ok' });\n")
    write_file(functions_root .. "/node/versioned/v1/handler.js", "exports.handler = async () => ({ status: 200, body: 'v1' });\n")
    write_file(functions_root .. "/python/hello/handler.py", "def handler(event):\n    return {'status':200,'headers':{},'body':'ok'}\n")
    write_file(functions_root .. "/php/basic/handler.php", "<?php echo 'ok';\n")
    write_file(functions_root .. "/lua/echo/handler.lua", "return function(_event) return {status=200, body='ok'} end\n")
    write_file(functions_root .. "/rust/exp/handler.rs", "fn main() {}\n")
    write_file(functions_root .. "/go/exp/main.go", "package main\nfunc main() {}\n")
    write_file(functions_root .. "/node/aa_force_on/handler.js", "exports.handler = async () => ({ status: 200, body: 'force-on' });\n")
    write_file(functions_root .. "/node/ab_force_off/handler.js", "exports.handler = async () => ({ status: 200, body: 'force-off' });\n")
    write_file(functions_root .. "/node/ba_force_off/handler.js", "exports.handler = async () => ({ status: 200, body: 'replace-old' });\n")
    write_file(functions_root .. "/node/bb_force_on/handler.js", "exports.handler = async () => ({ status: 200, body: 'replace-new' });\n")
    write_file(functions_root .. "/beta/fn.config.json", cjson.encode({
      name = "beta",
    }) .. "\n")
    write_file(functions_root .. "/beta/handler.js", "exports.handler = async () => ({ status: 200, body: 'beta-root' });\n")
    write_file(functions_root .. "/beta/get.stats.js", "exports.handler = async () => ({ status: 200, body: 'beta-stats' });\n")
    write_file(functions_root .. "/manifest-wins.py", "def handler(event):\n    return {'status':200,'headers':{},'body':'wins'}\n")
    write_file(functions_root .. "/node/runtime_manifest/fn.routes.json", cjson.encode({
      routes = {
        ["/runtime-manifest"] = "node/runtime_manifest/handler.js",
      },
    }) .. "\n")
    write_file(functions_root .. "/node/runtime_manifest/handler.js", "exports.handler = async () => ({ status: 200, body: 'runtime-manifest' });\n")
    write_file(functions_root .. "/node/aa_force_on/fn.config.json", cjson.encode({
      invoke = { route = "/force-keep", methods = { "GET" }, force_url = true },
    }) .. "\n")
    write_file(functions_root .. "/node/ab_force_off/fn.config.json", cjson.encode({
      invoke = { route = "/force-keep", methods = { "GET" } },
    }) .. "\n")
    write_file(functions_root .. "/node/ba_force_off/fn.config.json", cjson.encode({
      invoke = { route = "/force-replace", methods = { "GET" } },
    }) .. "\n")
    write_file(functions_root .. "/node/bb_force_on/fn.config.json", cjson.encode({
      invoke = { route = "/force-replace", methods = { "GET" }, force_url = true },
    }) .. "\n")

    write_file(functions_root .. "/fn.config.json", cjson.encode({
      zero_config = { ignore_dirs = { "tmp", "node_modules" } },
      zero_config_ignore_dirs = { "vendor", "tmp" },
    }) .. "\n")
    write_file(functions_root .. "/fn.routes.json", cjson.encode({
      routes = {
        ["GET /from-manifest"] = "node/hasdefault/handler.js",
        ["/from-manifest-default"] = "python/hello/handler.py",
        ["/manifest-wins"] = "node/hasdefault/handler.js",
      },
    }) .. "\n")

    with_module_stubs({
      ["fastfn.core.watchdog"] = {
        start = function(_opts)
          return false, "disabled in unit"
        end,
      },
    }, function()
      package.loaded["fastfn.core.routes"] = nil
      local routes = require("fastfn.core.routes")
      reset_shared_dict(cache)
      reset_shared_dict(conc)

      local resolve_mapped_target = routes.resolve_mapped_target
      local resolve_request_host_values = get_upvalue(resolve_mapped_target, "resolve_request_host_values")
      local split_host_port = get_upvalue(resolve_request_host_values, "split_host_port")
      local extract_dynamic_route_params = get_upvalue(resolve_mapped_target, "extract_dynamic_route_params")
      local compile_dynamic_route_pattern = get_upvalue(extract_dynamic_route_params, "compile_dynamic_route_pattern")
      local load_runtime_config = get_upvalue(routes.get_config, "load_runtime_config")
      local split_csv = get_upvalue(load_runtime_config, "split_csv")
      local load_zero_config_ignore_dirs = get_upvalue(load_runtime_config, "load_zero_config_ignore_dirs")
      local append_zero_config_ignore_dirs = get_upvalue(load_zero_config_ignore_dirs, "append_zero_config_ignore_dirs")
      local normalize_zero_config_dir = get_upvalue(append_zero_config_ignore_dirs, "normalize_zero_config_dir")
      local detect_functions_root = get_upvalue(load_runtime_config, "detect_functions_root")
      local detect_socket_base_dir = get_upvalue(load_runtime_config, "detect_socket_base_dir")
      local discover_functions = routes.discover_functions
      local normalize_allow_hosts = get_upvalue(discover_functions, "normalize_allow_hosts")
      local host_constraints_overlap = get_upvalue(discover_functions, "host_constraints_overlap")
      local detect_manifest_routes_in_dir = get_upvalue(discover_functions, "detect_manifest_routes_in_dir")
      local detect_file_based_routes_in_dir = get_upvalue(discover_functions, "detect_file_based_routes_in_dir")
      local normalize_policy = get_upvalue(discover_functions, "normalize_policy")
      local normalize_edge = get_upvalue(normalize_policy, "normalize_edge")
      local normalize_keep_warm = get_upvalue(normalize_policy, "normalize_keep_warm")
      local normalize_worker_pool = get_upvalue(normalize_policy, "normalize_worker_pool")
      local maybe_add_directory_home_alias = get_upvalue(detect_file_based_routes_in_dir, "maybe_add_directory_home_alias")
      local normalize_home_alias_target_route = get_upvalue(maybe_add_directory_home_alias, "normalize_home_alias_target_route")
      local parse_method_and_tokens = get_upvalue(detect_file_based_routes_in_dir, "parse_method_and_tokens")
      local split_file_tokens = get_upvalue(parse_method_and_tokens, "split_file_tokens")
      local should_ignore_file_base = get_upvalue(detect_file_based_routes_in_dir, "should_ignore_file_base")
      local resolve_inherited_allow_hosts = get_upvalue(detect_file_based_routes_in_dir, "resolve_inherited_allow_hosts")
      local is_explicit_fn_config = get_upvalue(resolve_inherited_allow_hosts, "is_explicit_fn_config")
      local normalize_route_token = get_upvalue(detect_file_based_routes_in_dir, "normalize_route_token")
      local sort_dynamic_routes = get_upvalue(resolve_mapped_target, "sort_dynamic_routes")
      local resolve_entry = routes.resolve_function_entrypoint
      local resolve_runtime_file_target = get_upvalue(resolve_entry, "resolve_runtime_file_target")
      local runtime_entrypoint_candidates = get_upvalue(resolve_entry, "runtime_entrypoint_candidates")
      local resolve_runtime_function_dir = get_upvalue(resolve_entry, "resolve_runtime_function_dir")
      local detect_runtime_from_file = get_upvalue(detect_file_based_routes_in_dir, "detect_runtime_from_file")
      local has_valid_config_entrypoint = get_upvalue(discover_functions, "has_valid_config_entrypoint")
      local file_exists = get_upvalue(resolve_entry, "file_exists")
      local list_files = get_upvalue(detect_file_based_routes_in_dir, "list_files")
      local is_safe_relative_path = get_upvalue(resolve_entry, "is_safe_relative_path")
      local worker_pool_snapshot = get_upvalue(routes.health_snapshot, "worker_pool_snapshot")
      local read_nonneg_counter = get_upvalue(worker_pool_snapshot, "read_nonneg_counter")
      local warm_state_for_key = get_upvalue(routes.health_snapshot, "warm_state_for_key")
      local hot_reload_enabled = get_upvalue(routes.init, "hot_reload_enabled")
      local hot_reload_watchdog_enabled = get_upvalue(routes.init, "hot_reload_watchdog_enabled")
      local dir_exists = get_upvalue(detect_functions_root, "dir_exists")
      local list_dirs = get_upvalue(load_runtime_config, "list_dirs")
      local has_single_entry_file = get_upvalue(discover_functions, "has_single_entry_file")

      assert_true(type(split_csv) == "function", "split_csv helper")
      assert_true(type(split_host_port) == "function", "split_host_port helper")
      assert_true(type(extract_dynamic_route_params) == "function", "extract_dynamic_route_params helper")
      assert_true(type(compile_dynamic_route_pattern) == "function", "compile_dynamic_route_pattern helper")
      assert_true(type(normalize_zero_config_dir) == "function", "normalize_zero_config_dir helper")
      assert_true(type(append_zero_config_ignore_dirs) == "function", "append_zero_config_ignore_dirs helper")
      assert_true(type(load_zero_config_ignore_dirs) == "function", "load_zero_config_ignore_dirs helper")
      assert_true(type(detect_functions_root) == "function", "detect_functions_root helper")
      assert_true(type(detect_socket_base_dir) == "function", "detect_socket_base_dir helper")
      assert_true(type(normalize_allow_hosts) == "function", "normalize_allow_hosts helper")
      assert_true(type(host_constraints_overlap) == "function", "host_constraints_overlap helper")
      assert_true(type(detect_manifest_routes_in_dir) == "function", "detect_manifest_routes_in_dir helper")
      assert_true(type(detect_file_based_routes_in_dir) == "function", "detect_file_based_routes_in_dir helper")
      assert_true(type(normalize_edge) == "function", "normalize_edge helper")
      assert_true(type(normalize_keep_warm) == "function", "normalize_keep_warm helper")
      assert_true(type(normalize_worker_pool) == "function", "normalize_worker_pool helper")
      assert_true(type(runtime_entrypoint_candidates) == "function", "runtime_entrypoint_candidates helper")
      assert_true(type(resolve_runtime_function_dir) == "function", "resolve_runtime_function_dir helper")
      assert_true(type(maybe_add_directory_home_alias) == "function", "maybe_add_directory_home_alias helper")
      assert_true(type(normalize_home_alias_target_route) == "function", "normalize_home_alias_target_route helper")
      assert_true(type(parse_method_and_tokens) == "function", "parse_method_and_tokens helper")
      assert_true(type(split_file_tokens) == "function", "split_file_tokens helper")
      assert_true(type(should_ignore_file_base) == "function", "should_ignore_file_base helper")
      assert_true(type(resolve_inherited_allow_hosts) == "function", "resolve_inherited_allow_hosts helper")
      assert_true(type(is_explicit_fn_config) == "function", "is_explicit_fn_config helper")
      assert_true(type(normalize_route_token) == "function", "normalize_route_token helper")
      assert_true(type(sort_dynamic_routes) == "function", "sort_dynamic_routes helper")
      assert_true(type(resolve_runtime_file_target) == "function", "resolve_runtime_file_target helper")
      assert_true(type(detect_runtime_from_file) == "function", "detect_runtime_from_file helper")
      assert_true(type(has_valid_config_entrypoint) == "function", "has_valid_config_entrypoint helper")
      assert_true(type(file_exists) == "function", "file_exists helper")
      assert_true(type(list_files) == "function", "list_files helper")
      assert_true(type(dir_exists) == "function", "dir_exists helper")
      assert_true(type(list_dirs) == "function", "list_dirs helper")
      assert_true(type(has_single_entry_file) == "function", "has_single_entry_file helper")
      assert_true(type(read_nonneg_counter) == "function", "read_nonneg_counter helper")
      assert_true(type(warm_state_for_key) == "function", "warm_state_for_key helper")

      local csv = split_csv(" a, ,b,, c ")
      assert_true(type(csv) == "table" and #csv == 3, "split_csv trims and keeps non-empty")
      local empty_host, empty_auth = split_host_port(nil)
      assert_eq(empty_host, "", "split_host_port empty host")
      assert_eq(empty_auth, "", "split_host_port empty authority")
      assert_eq(normalize_zero_config_dir("  Temp  "), "temp", "normalize_zero_config_dir lower")
      assert_eq(normalize_zero_config_dir(""), nil, "normalize_zero_config_dir empty")
      assert_eq(normalize_zero_config_dir("../x"), nil, "normalize_zero_config_dir invalid slash")
      assert_eq(normalize_zero_config_dir("."), nil, "normalize_zero_config_dir dot")
      assert_true(type(normalize_allow_hosts(string.rep("a", 240))) == "nil", "normalize_allow_hosts rejects long host")
      assert_eq(normalize_allow_hosts({ "bad/host" }), nil, "normalize_allow_hosts invalid chars")
      assert_eq(normalize_allow_hosts({ "bad@host" }), nil, "normalize_allow_hosts rejects symbol host")
      assert_eq(host_constraints_overlap({ "a.example.com" }, { "*.example.com" }), true, "host_constraints_overlap wildcard rhs")
      assert_eq(host_constraints_overlap({ "a.example.com" }, { "b.example.com" }), false, "host_constraints_overlap no overlap")
      assert_eq(normalize_edge({ base_url = "   " }), nil, "normalize_edge empty base_url")
      assert_eq(normalize_keep_warm({ enabled = false, min_warm = -1 }), nil, "normalize_keep_warm disabled/invalid")
      local pool_min_warm_nil = normalize_worker_pool({ enabled = true, min_warm = -1 }, 2)
      assert_true(type(pool_min_warm_nil) == "table" and pool_min_warm_nil.min_warm == 0, "normalize_worker_pool negative min_warm reset")
      local keep_warm_floor = normalize_keep_warm({ enabled = true, min_warm = -5, ping_every_seconds = 1, idle_ttl_seconds = 1 })
      assert_true(type(keep_warm_floor) == "table" and keep_warm_floor.min_warm == 1, "normalize_keep_warm min_warm floor")
      local bad_host_value = resolve_request_host_values("bad host", nil)
      assert_eq(bad_host_value, "bad host", "resolve_request_host_values preserves raw host token")

      local ignore_dirs, seen = {}, {}
      append_zero_config_ignore_dirs(ignore_dirs, seen, "tmp,node_modules, vendor ")
      append_zero_config_ignore_dirs(ignore_dirs, seen, { "vendor", "build" })
      assert_true(#ignore_dirs >= 4, "append_zero_config_ignore_dirs dedupe")

      with_env({ FN_ZERO_CONFIG_IGNORE_DIRS = "cache,tmp" }, function()
        local loaded = load_zero_config_ignore_dirs(functions_root)
        assert_true(type(loaded) == "table" and #loaded >= 4, "load_zero_config_ignore_dirs merged")
      end)

      local prev_read_json = get_upvalue(load_zero_config_ignore_dirs, "read_json_file")
      set_upvalue(load_zero_config_ignore_dirs, "read_json_file", function()
        return { discovery = { ignore_dirs = { "disc" } }, zero_config_ignore_dirs = { "zc" } }
      end)
      local loaded_from_discovery = load_zero_config_ignore_dirs(functions_root)
      assert_true(type(loaded_from_discovery) == "table" and #loaded_from_discovery >= 2, "load_zero_config_ignore_dirs discovery fallback")
      set_upvalue(load_zero_config_ignore_dirs, "read_json_file", function()
        return { routing = { ignore_dirs = { "route" } } }
      end)
      local loaded_from_routing = load_zero_config_ignore_dirs(functions_root)
      assert_true(type(loaded_from_routing) == "table" and #loaded_from_routing >= 1, "load_zero_config_ignore_dirs routing fallback")
      set_upvalue(load_zero_config_ignore_dirs, "read_json_file", prev_read_json)

      assert_true(type(runtime_entrypoint_candidates("rust")) == "table", "runtime_entrypoint_candidates rust")
      assert_true(type(runtime_entrypoint_candidates("go")) == "table", "runtime_entrypoint_candidates go")
      assert_true(type(runtime_entrypoint_candidates("php")) == "table", "runtime_entrypoint_candidates php")
      assert_true(type(runtime_entrypoint_candidates("unknown")) == "table", "runtime_entrypoint_candidates unknown")
      assert_eq(is_safe_relative_path(nil), false, "is_safe_relative_path nil")
      assert_eq(is_safe_relative_path("ok/path.js"), true, "is_safe_relative_path valid")
      assert_eq(is_safe_relative_path("/abs/path"), false, "is_safe_relative_path absolute")
      assert_eq(is_safe_relative_path("bad//path"), false, "is_safe_relative_path double slash")
      assert_eq(is_safe_relative_path("bad\\path"), false, "is_safe_relative_path backslash")
      assert_eq(is_safe_relative_path("../escape"), false, "is_safe_relative_path invalid")
      assert_eq(resolve_runtime_file_target(functions_root, "node", "../bad.js"), nil, "resolve_runtime_file_target unsafe path")
      assert_eq(resolve_runtime_file_target(functions_root, "node", "missing.js"), nil, "resolve_runtime_file_target missing file")
      assert_eq(resolve_runtime_function_dir(functions_root, "node", "../bad", nil), nil, "resolve_runtime_function_dir unsafe fn name")
      assert_eq(resolve_runtime_function_dir(functions_root, "node", "versioned", "bad/version"), nil, "resolve_runtime_function_dir invalid version")
      assert_true(resolve_runtime_function_dir(functions_root, "node", "versioned", "v1") ~= nil, "resolve_runtime_function_dir valid")
      assert_eq(detect_runtime_from_file("noext"), nil, "detect_runtime_from_file no extension")
      assert_eq(detect_runtime_from_file("x.php"), "php", "detect_runtime_from_file php")

      mkdir_p(functions_root .. "/node/config-entry")
      write_file(functions_root .. "/node/config-entry/fn.config.json", cjson.encode({ entrypoint = "custom.js" }) .. "\n")
      write_file(functions_root .. "/node/config-entry/custom.js", "exports.handler = async () => ({ status: 200, body: 'custom' });\n")
      assert_eq(has_valid_config_entrypoint(functions_root .. "/node/config-entry"), true, "has_valid_config_entrypoint true")
      write_file(functions_root .. "/node/config-entry/fn.config.json", cjson.encode({ entrypoint = "../evil.js" }) .. "\n")
      assert_eq(has_valid_config_entrypoint(functions_root .. "/node/config-entry"), false, "has_valid_config_entrypoint false")

      -- Create put. and delete. prefixed files to exercise file-based route detection
      mkdir_p(functions_root .. "/node/methods-test")
      write_file(functions_root .. "/node/methods-test/put.items.[id].js", "exports.handler = async () => ({ status: 200, body: 'put' });\n")
      write_file(functions_root .. "/node/methods-test/delete.items.[id].js", "exports.handler = async () => ({ status: 200, body: 'delete' });\n")
      write_file(functions_root .. "/node/methods-test/get.post.items.js", "exports.handler = async () => ({ status: 200, body: 'ambiguous' });\n")
      local method_routes = detect_file_based_routes_in_dir(
        functions_root .. "/node/methods-test", "node/methods-test"
      )
      assert_true(type(method_routes) == "table", "detect_file_based_routes_in_dir put/delete files")
      local found_put = false
      local found_delete = false
      local found_ambiguous = false
      for _, entry in ipairs(method_routes) do
        if type(entry.target) == "string" and entry.target:find("get.post.items.js", 1, true) ~= nil then
          found_ambiguous = true
        end
        if type(entry.methods) == "table" then
          for _, m in ipairs(entry.methods) do
            if m == "PUT" then found_put = true end
            if m == "DELETE" then found_delete = true end
          end
        end
      end
      assert_true(found_put, "detect_file_based_routes_in_dir found PUT route")
      assert_true(found_delete, "detect_file_based_routes_in_dir found DELETE route")
      assert_eq(found_ambiguous, false, "detect_file_based_routes_in_dir skips ambiguous multi-method filename")
      assert_explicit_root_project_helpers(
        functions_root,
        detect_file_based_routes_in_dir,
        resolve_runtime_file_target,
        resolve_runtime_function_dir,
        cjson
      )
      assert_routes_internal_helper_coverage(
        root,
        functions_root,
        routes,
        discover_functions,
        resolve_entry,
        resolve_runtime_file_target,
        resolve_runtime_function_dir,
        cache,
        cjson
      )

      assert_eq(should_ignore_file_base("_private"), true, "should_ignore_file_base underscore")
      assert_eq(should_ignore_file_base("demo.spec"), true, "should_ignore_file_base spec")
      assert_eq(should_ignore_file_base("demo"), false, "should_ignore_file_base normal")
      assert_parse_method_tokens(parse_method_and_tokens, "patch.users.[id]", "PATCH", true, false, "users", "parse_method_and_tokens patch")
      assert_parse_method_tokens(parse_method_and_tokens, "put.items.[id]", "PUT", true, false, "items", "parse_method_and_tokens put")
      assert_parse_method_tokens(parse_method_and_tokens, "delete.items.[id]", "DELETE", true, false, "items", "parse_method_and_tokens delete")
      assert_parse_method_tokens(parse_method_and_tokens, "get.post.items", "GET", true, true, "post", "parse_method_and_tokens ambiguous")
      local split_one = split_file_tokens("")
      assert_true(type(split_one) == "table" and #split_one == 1, "split_file_tokens fallback base")
      assert_eq(is_explicit_fn_config({ runtime = "node" }), true, "is_explicit_fn_config runtime")
      assert_eq(is_explicit_fn_config({ name = "demo" }), true, "is_explicit_fn_config name")
      assert_eq(is_explicit_fn_config({ entrypoint = "app.js" }), true, "is_explicit_fn_config entrypoint")
      assert_eq(is_explicit_fn_config({ invoke = { routes = { "/x" } } }), true, "is_explicit_fn_config invoke routes")
      assert_eq(normalize_route_token(""), nil, "normalize_route_token empty")
      assert_eq(normalize_route_token("!!!"), nil, "normalize_route_token punctuation")
      assert_eq(routes.canonical_route_segment_for_name("___"), nil, "canonical route invalid-only tokens")
      assert_eq(normalize_home_alias_target_route("api/v1", ""), nil, "normalize_home_alias_target_route empty")
      assert_eq(normalize_home_alias_target_route("api/v1", "/health"), "/health", "normalize_home_alias_target_route absolute")
      local sorted_ties = sort_dynamic_routes({
        ["/a/*/*"] = true,
        ["/a/:id/*"] = true,
      })
      assert_true(type(sorted_ties) == "table" and #sorted_ties == 2, "sort_dynamic_routes tie paths")
      assert_compiled_dynamic_route_pattern(compile_dynamic_route_pattern, "/", "^/$", 0, "compile_dynamic_route_pattern root")
      local wild_pattern, wild_names = assert_compiled_dynamic_route_pattern(compile_dynamic_route_pattern, "/a/*/*", nil, 2, "compile_dynamic_route_pattern wildcard")
      assert_true(wild_pattern:find("%(%.%+%)", 1) ~= nil, "compile_dynamic_route_pattern wildcard regex")
      assert_true(wild_names[1] ~= wild_names[2], "compile_dynamic_route_pattern wildcard unique names")
      assert_compiled_dynamic_route_pattern(compile_dynamic_route_pattern, "/a/*/*/*", nil, 3, "compile_dynamic_route_pattern third wildcard")
      local params_unescaped = extract_dynamic_route_params("/a/:id", "/a/one%20two")
      assert_true(type(params_unescaped) == "table" and params_unescaped.id == "one%20two", "extract_dynamic_route_params assign param")
      local prev_unescape = ngx.unescape_uri
      ngx.unescape_uri = nil
      local params_raw = extract_dynamic_route_params("/a/:id", "/a/raw%20value")
      assert_true(type(params_raw) == "table" and params_raw.id == "raw%20value", "extract_dynamic_route_params no-unescape path")
      ngx.unescape_uri = prev_unescape

      local prev_sort_key = get_upvalue(sort_dynamic_routes, "dynamic_route_sort_key")
      set_upvalue(sort_dynamic_routes, "dynamic_route_sort_key", function(route)
        if route == "/k/:a" then
          return 1, 3, 0, 2
        end
        return 1, 2, 0, 1
      end)
      local sorted_total = sort_dynamic_routes({
        ["/k/:a"] = true,
        ["/k/:b"] = true,
      })
      assert_true(type(sorted_total) == "table" and #sorted_total == 2, "sort_dynamic_routes total tie-break path")
      set_upvalue(sort_dynamic_routes, "dynamic_route_sort_key", function(route)
        if route == "/k/:a" then
          return 1, 2, 0, 2
        end
        return 1, 2, 0, 1
      end)
      local sorted_dynamic = sort_dynamic_routes({
        ["/k/:a"] = true,
        ["/k/:b"] = true,
      })
      assert_true(type(sorted_dynamic) == "table" and #sorted_dynamic == 2, "sort_dynamic_routes dynamic tie-break path")
      -- Test sort_dynamic_routes where `as` (static segments) differ → exercises `return as > bs` branch
      set_upvalue(sort_dynamic_routes, "dynamic_route_sort_key", function(route)
        if route == "/k/:a" then
          return 3, 2, 0, 1
        end
        return 1, 2, 0, 1
      end)
      local sorted_static = sort_dynamic_routes({
        ["/k/:a"] = true,
        ["/k/:b"] = true,
      })
      assert_true(type(sorted_static) == "table" and #sorted_static == 2, "sort_dynamic_routes static segment tie-break path")
      -- /k/:a has more static segments (3) so should sort first (as > bs → true → a before b)
      assert_eq(sorted_static[1], "/k/:a", "sort_dynamic_routes static segment order")

      -- Test sort_dynamic_routes where `ac` (catch-all) differ → exercises `return ac < bc` branch
      set_upvalue(sort_dynamic_routes, "dynamic_route_sort_key", function(route)
        if route == "/k/:a" then
          return 1, 2, 0, 1
        end
        return 1, 2, 1, 1
      end)
      local sorted_catchall = sort_dynamic_routes({
        ["/k/:a"] = true,
        ["/k/:b"] = true,
      })
      assert_true(type(sorted_catchall) == "table" and #sorted_catchall == 2, "sort_dynamic_routes catch-all tie-break path")
      -- /k/:a has fewer catch-all segments (0) so should sort first (ac < bc → true)
      assert_eq(sorted_catchall[1], "/k/:a", "sort_dynamic_routes catch-all order")

      set_upvalue(sort_dynamic_routes, "dynamic_route_sort_key", prev_sort_key)

      write_file(functions_root .. "/node/fn.config.json", cjson.encode({ invoke = { allow_hosts = { "api.example.com" } } }) .. "\n")
      local inherited_hosts = resolve_inherited_allow_hosts(functions_root .. "/node/hasdefault", "node/hasdefault")
      assert_true(type(inherited_hosts) == "table" and inherited_hosts[1] == "api.example.com", "resolve_inherited_allow_hosts parent config")
      local alias_root_discovered = {
        { route = "/demo/ok", runtime = "node", target = "ok.js", methods = { "GET" } },
      }
      maybe_add_directory_home_alias({ home = { ["function"] = "demo/ok" } }, "", alias_root_discovered)
      assert_true(#alias_root_discovered == 1, "maybe_add_directory_home_alias ignores root folder route")

	      assert_eq(dir_exists(nil), false, "dir_exists nil path")
	      local list_dirs_result = list_dirs(functions_root)
	      local list_files_result = list_files(functions_root)
	      assert_true(type(list_dirs_result) == "table" and #list_dirs_result > 0, "list_dirs fs result")
	      assert_true(type(list_files_result) == "table", "list_files fs result")
	      assert_eq(dir_exists(functions_root), true, "dir_exists fs result")
	      assert_eq(has_single_entry_file(functions_root), false, "has_single_entry_file no entrypoint")

      cache:set("runtime:config", cjson.encode({
        functions_root = functions_root,
        socket_base_dir = "/tmp/fastfn",
        runtime_order = { "node", "python", "php", "lua" },
        defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1024 * 1024 },
        zero_config = { ignore_dirs = {} },
        runtimes = {
          node = { socket = "unix:/tmp/fn-node.sock", timeout_ms = 2500 },
          python = { socket = "unix:/tmp/fn-python.sock", timeout_ms = 2500 },
          php = { socket = "unix:/tmp/fn-php.sock", timeout_ms = 2500 },
          lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true },
        },
      }))

      local prev_dir_exists_detect = get_upvalue(detect_functions_root, "dir_exists")
      set_upvalue(detect_functions_root, "dir_exists", function(path)
        return path == "/workspace/srv/fn/functions"
      end)
      with_env({ FN_FUNCTIONS_ROOT = false, PWD = "/workspace" }, function()
        assert_eq(detect_functions_root(), "/workspace/srv/fn/functions", "detect_functions_root PWD candidate")
      end)
      set_upvalue(detect_functions_root, "dir_exists", function(_path)
        return false
      end)
      with_env({ FN_FUNCTIONS_ROOT = false, PWD = false }, function()
        assert_eq(detect_functions_root(), "/srv/fn/functions", "detect_functions_root default fallback")
      end)
      set_upvalue(detect_functions_root, "dir_exists", prev_dir_exists_detect)

      local prev_dir_exists_socket = get_upvalue(detect_socket_base_dir, "dir_exists")
      set_upvalue(detect_socket_base_dir, "dir_exists", function(path)
        return path == "/sockets"
      end)
      with_env({ FN_SOCKET_BASE_DIR = false }, function()
        assert_eq(detect_socket_base_dir(), "/sockets", "detect_socket_base_dir sockets dir")
      end)
      set_upvalue(detect_socket_base_dir, "dir_exists", function(_path)
        return false
      end)
      with_env({ FN_SOCKET_BASE_DIR = false }, function()
        assert_eq(detect_socket_base_dir(), "/tmp/fastfn", "detect_socket_base_dir fallback")
      end)
      set_upvalue(detect_socket_base_dir, "dir_exists", prev_dir_exists_socket)

      local prev_list_dirs_cfg = get_upvalue(load_runtime_config, "list_dirs")
      set_upvalue(load_runtime_config, "list_dirs", function()
        return {}
      end)
      with_env({
        FN_FUNCTIONS_ROOT = functions_root,
        FN_RUNTIMES = "",
      }, function()
        cache:delete("runtime:config")
        local cfg_default = load_runtime_config(true)
        assert_true(type(cfg_default.runtime_order) == "table" and #cfg_default.runtime_order >= 4, "load_runtime_config default runtime order")
      end)
      set_upvalue(load_runtime_config, "list_dirs", prev_list_dirs_cfg)
      set_upvalue(load_runtime_config, "list_dirs", function()
        return {
          functions_root .. "/node",
          functions_root .. "/rust",
          functions_root .. "/bad name",
        }
      end)
      with_env({
        FN_FUNCTIONS_ROOT = functions_root,
        FN_RUNTIMES = "",
      }, function()
        cache:delete("runtime:config")
        local cfg_known = load_runtime_config(true)
        assert_true(type(cfg_known.runtimes.node) == "table", "load_runtime_config includes known runtime dir")
        assert_true(cfg_known.runtimes.rust == nil, "load_runtime_config skips experimental runtime dirs")
      end)
      set_upvalue(load_runtime_config, "list_dirs", prev_list_dirs_cfg)
      with_env({
        FN_FUNCTIONS_ROOT = functions_root,
        FN_RUNTIMES = "",
      }, function()
        cache:delete("runtime:config")
        local cfg_scanned = load_runtime_config(true)
        assert_true(type(cfg_scanned.runtime_order) == "table" and #cfg_scanned.runtime_order >= 1, "load_runtime_config scans runtime dirs")
      end)
      set_upvalue(load_runtime_config, "list_dirs", function()
        return { functions_root .. "/node" }
      end)
      with_env({
        FN_FUNCTIONS_ROOT = functions_root,
        FN_RUNTIMES = false,
      }, function()
        cache:delete("runtime:config")
        local cfg_scanned_node = load_runtime_config(true)
        assert_true(type(cfg_scanned_node.runtimes.node) == "table", "load_runtime_config scans known runtime on empty env var")
      end)
      set_upvalue(load_runtime_config, "list_dirs", prev_list_dirs_cfg)
      local empty_root = root .. "/empty-root"
      mkdir_p(empty_root)
      with_env({
        FN_FUNCTIONS_ROOT = empty_root,
        FN_RUNTIMES = "",
      }, function()
        cache:delete("runtime:config")
        local cfg_fallback = load_runtime_config(true)
        assert_true(type(cfg_fallback.runtime_order) == "table" and #cfg_fallback.runtime_order >= 4, "load_runtime_config fallback runtimes")
      end)

      cache:set("runtime:config", cjson.encode({
        functions_root = functions_root,
        socket_base_dir = "/tmp/fastfn",
        runtime_order = { "node", "python", "php", "lua" },
        defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1024 * 1024 },
        zero_config = { ignore_dirs = {} },
        runtimes = {
          node = { socket = "unix:/tmp/fn-node.sock", timeout_ms = 2500 },
          python = { socket = "unix:/tmp/fn-python.sock", timeout_ms = 2500 },
          php = { socket = "unix:/tmp/fn-php.sock", timeout_ms = 2500 },
          lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true },
        },
      }))

      local direct_entry, direct_err = routes.resolve_function_entrypoint("node", "hasdefault", nil)
      assert_true(direct_entry ~= nil, direct_err or "resolve_function_entrypoint default")
      assert_explicit_root_beta_entrypoints(routes)
      local missing_fn_name, missing_fn_name_err = routes.resolve_function_entrypoint("node", "", nil)
      assert_eq(missing_fn_name, nil, "resolve_function_entrypoint function name required")
      assert_true(type(missing_fn_name_err) == "string" and missing_fn_name_err:find("function name required", 1, true) ~= nil, "resolve_function_entrypoint missing fn name err")
      local ver_entry, ver_err = routes.resolve_function_entrypoint("node", "versioned", "v1")
      assert_true(ver_entry ~= nil, ver_err or "resolve_function_entrypoint version")
      local missing_entry, missing_err = routes.resolve_function_entrypoint("node", "missing", nil)
      assert_eq(missing_entry, nil, "resolve_function_entrypoint missing")
      assert_true(type(missing_err) == "string" and #missing_err > 0, "resolve_function_entrypoint missing error")

      local bad_runtime_entry, bad_runtime_err = routes.resolve_function_entrypoint("", "x", nil)
      assert_eq(bad_runtime_entry, nil, "resolve_function_entrypoint runtime required")
      assert_true(type(bad_runtime_err) == "string" and bad_runtime_err:find("runtime required", 1, true) ~= nil, "runtime required message")
      local prev_load_cfg_entry = get_upvalue(routes.resolve_function_entrypoint, "load_runtime_config")
      set_upvalue(routes.resolve_function_entrypoint, "load_runtime_config", function()
        return { functions_root = "" }
      end)
      local no_root_entry, no_root_entry_err = routes.resolve_function_entrypoint("node", "hasdefault", nil)
      assert_eq(no_root_entry, nil, "resolve_function_entrypoint missing functions root")
      assert_true(type(no_root_entry_err) == "string" and no_root_entry_err:find("functions root not configured", 1, true) ~= nil, "resolve_function_entrypoint missing root err")
      set_upvalue(routes.resolve_function_entrypoint, "load_runtime_config", prev_load_cfg_entry)

      write_file(functions_root .. "/node/config-entry/fn.config.json", cjson.encode({ entrypoint = "custom.js" }) .. "\n")
      local configured_entry, configured_entry_err = routes.resolve_function_entrypoint("node", "config-entry", nil)
      assert_true(configured_entry ~= nil, configured_entry_err or "resolve_function_entrypoint configured entrypoint")
      write_file(functions_root .. "/node/config-entry/fn.config.json", cjson.encode({ entrypoint = "../evil.js" }) .. "\n")
      local invalid_cfg_entry, invalid_cfg_entry_err = routes.resolve_function_entrypoint("node", "config-entry", nil)
      assert_eq(invalid_cfg_entry, nil, "resolve_function_entrypoint invalid configured entrypoint path")
      assert_true(type(invalid_cfg_entry_err) == "string" and invalid_cfg_entry_err:find("invalid entrypoint path", 1, true) ~= nil, "resolve_function_entrypoint invalid entrypoint path err")

      mkdir_p(functions_root .. "/node/fallback-file")
      write_file(functions_root .. "/node/fallback-file/custom.js", "exports.handler = async () => ({ status: 200, body: 'x' });\n")
      local fallback_entry, fallback_entry_err = routes.resolve_function_entrypoint("node", "fallback-file", nil)
      assert_eq(fallback_entry, nil, "resolve_function_entrypoint should not fall back to arbitrary runtime file")
      assert_true(type(fallback_entry_err) == "string" and fallback_entry_err:find("entrypoint not found", 1, true) ~= nil, "resolve_function_entrypoint fallback-file err")

      mkdir_p(functions_root .. "/node/empty-dir")
      local empty_entry, empty_entry_err = routes.resolve_function_entrypoint("node", "empty-dir", nil)
      assert_eq(empty_entry, nil, "resolve_function_entrypoint not found")
      assert_true(type(empty_entry_err) == "string" and empty_entry_err:find("entrypoint not found", 1, true) ~= nil, "resolve_function_entrypoint not found err")

      local alias_discovered = {
        { route = "/api/v1/users/:id", runtime = "node", target = "users.js", methods = { "GET" } },
      }
      maybe_add_directory_home_alias({ home = { ["function"] = "users/[id]" } }, "api/v1", alias_discovered)
      assert_true(type(alias_discovered) == "table" and #alias_discovered >= 2, "maybe_add_directory_home_alias adds alias")
      maybe_add_directory_home_alias({ home = { ["function"] = "https://example.com" } }, "api/v1", alias_discovered)
      assert_true(type(alias_discovered) == "table", "maybe_add_directory_home_alias ignores external target")
      local alias_existing = {
        { route = "/api/v1", runtime = "node", target = "index.js", methods = { "GET" } },
        { route = "/api/v1/users/:id", runtime = "node", target = "users.js", methods = { "GET" } },
      }
      maybe_add_directory_home_alias({ home = { ["function"] = "users/[id]" } }, "api/v1", alias_existing)
      assert_true(#alias_existing == 2, "maybe_add_directory_home_alias skips when alias exists")

      local manifest_routes, has_manifest = detect_manifest_routes_in_dir(functions_root, ".")
      assert_eq(has_manifest, true, "detect_manifest_routes_in_dir has manifest")
      assert_true(type(manifest_routes) == "table" and #manifest_routes >= 2, "detect_manifest_routes_in_dir routes")
      mkdir_p(functions_root .. "/manifest-sub")
      write_file(functions_root .. "/manifest-sub/fn.routes.json", cjson.encode({
        routes = { ["/sub"] = "hello.py" },
      }) .. "\n")
      local sub_manifest_routes, sub_has_manifest = detect_manifest_routes_in_dir(functions_root .. "/manifest-sub", "manifest-sub")
      assert_eq(sub_has_manifest, true, "detect_manifest_routes_in_dir rel target prefix")
      assert_true(type(sub_manifest_routes) == "table" and sub_manifest_routes[1] and sub_manifest_routes[1].target:find("manifest%-sub/", 1) ~= nil, "detect_manifest_routes_in_dir rel target applied")
      local no_manifest_routes, no_manifest = detect_manifest_routes_in_dir(functions_root .. "/node/hasdefault", "node/hasdefault")
      assert_eq(no_manifest, false, "detect_manifest_routes_in_dir no manifest")
      assert_true(type(no_manifest_routes) == "table", "detect_manifest_routes_in_dir empty list")
      write_file(functions_root .. "/manifest-sub/fn.routes.json", cjson.encode({ routes = cjson.null }) .. "\n")
      local bad_manifest_routes, bad_manifest = detect_manifest_routes_in_dir(functions_root .. "/manifest-sub", "manifest-sub")
      assert_eq(bad_manifest, false, "detect_manifest_routes_in_dir invalid manifest shape")
      assert_true(type(bad_manifest_routes) == "table", "detect_manifest_routes_in_dir invalid manifest empty")
      write_file(functions_root .. "/manifest-sub/fn.routes.json", "")
      local empty_manifest_routes, empty_manifest = detect_manifest_routes_in_dir(functions_root .. "/manifest-sub", "manifest-sub")
      assert_eq(empty_manifest, false, "detect_manifest_routes_in_dir empty file")
      assert_true(type(empty_manifest_routes) == "table", "detect_manifest_routes_in_dir empty file routes")
      write_file(functions_root .. "/manifest-sub/fn.routes.json", "\"oops\"")
      local scalar_manifest_routes, scalar_manifest = detect_manifest_routes_in_dir(functions_root .. "/manifest-sub", "manifest-sub")
      assert_eq(scalar_manifest, false, "detect_manifest_routes_in_dir scalar json")
      assert_true(type(scalar_manifest_routes) == "table", "detect_manifest_routes_in_dir scalar routes")

      local p = normalize_policy({
        group = "edge",
        timeout_ms = 1234,
        max_concurrency = 2,
        max_body_bytes = 4096,
        include_debug_headers = true,
        invoke = {
          methods = { "GET" },
          routes = { "/x" },
          allow_hosts = { "api.example.com" },
          force_url = true,
        },
        keep_warm = { enabled = true, min_warm = -5, ping_every_seconds = 0, idle_ttl_seconds = 0 },
        worker_pool = {
          enabled = true,
          max_workers = -1,
          max_queue = -1,
          queue_timeout_ms = -1,
          queue_poll_ms = 0,
          overflow_status = 418,
        },
        schedule = {
          enabled = true,
          every_seconds = "3",
          method = "INVALID",
          retry = { max_attempts = 999, base_delay_seconds = -1, max_delay_seconds = 9999, jitter = 99 },
          body = 123,
        },
        edge = { base_url = 42, allow_hosts = { "a", "a" }, max_response_bytes = "100" },
      })
      assert_eq(p.group, "edge", "normalize_policy group")
      assert_true(type(p.schedule) == "table", "normalize_policy schedule")
      local p_force = normalize_policy({ forceUrl = true })
      assert_eq(p_force.force_url, true, "normalize_policy forceUrl alias")
      local p_sched_invalid = normalize_policy({
        schedule = {
          enabled = true,
          every_seconds = "bad",
          cron = " ",
          timezone = "Mars/Phobos",
          method = "bad",
          retry = true,
        },
      })
      assert_true(type(p_sched_invalid.schedule) == "table", "normalize_policy schedule invalid values normalized")
      local p_sched_retry_false = normalize_policy({
        schedule = {
          enabled = true,
          retry = false,
        },
      })
      assert_true(type(p_sched_retry_false.schedule) == "table", "normalize_policy schedule retry false")
      local p_sched_retry_obj = normalize_policy({
        schedule = {
          enabled = true,
          retry = {
            max_attempts = 0,
            base_delay_seconds = 9999,
            max_delay_seconds = -1,
            jitter = -1,
          },
        },
      })
      assert_true(type(p_sched_retry_obj.schedule) == "table", "normalize_policy schedule retry object clamps")
      local p_sched_non_string = normalize_policy({
        schedule = {
          enabled = true,
          cron = 123,
          timezone = 123,
        },
      })
      assert_true(type(p_sched_non_string.schedule) == "table" and p_sched_non_string.schedule.cron == nil, "normalize_policy non-string cron ignored")
      local p_sched_blank_tz = normalize_policy({
        schedule = {
          enabled = true,
          cron = "*/5 * * * *",
          timezone = "   ",
        },
      })
      assert_true(type(p_sched_blank_tz.schedule) == "table" and p_sched_blank_tz.schedule.timezone == nil, "normalize_policy blank timezone ignored")

      with_env({
        FN_FUNCTIONS_ROOT = functions_root,
        FN_RUNTIMES = false,
        FN_DEFAULT_TIMEOUT_MS = "1500",
        FN_DEFAULT_MAX_CONCURRENCY = "3",
        FN_DEFAULT_MAX_BODY_BYTES = "2048",
        FN_RUNTIME_SOCKETS = cjson.encode({ node = "unix:/tmp/custom-node.sock" }),
      }, function()
        reset_shared_dict(cache)
        local cfg = routes.get_config()
        assert_true(type(cfg) == "table", "routes.get_config")
        assert_true(type(cfg.runtimes) == "table" and cfg.runtimes.node ~= nil, "routes.get_config runtimes")
        assert_eq(((cfg.runtimes.node or {}).socket), "unix:/tmp/custom-node.sock", "runtime socket map")
        assert_eq((((cfg.runtimes.node or {}).sockets or {})[1]), "unix:/tmp/custom-node.sock", "runtime sockets list single")
        assert_true(cfg.runtimes.lua and cfg.runtimes.lua.in_process == true, "lua in-process runtime")
      end)

      with_env({
        FN_FUNCTIONS_ROOT = functions_root,
        FN_RUNTIMES = "node,python,lua",
        FN_RUNTIME_SOCKETS = cjson.encode({
          node = { "unix:/tmp/node-1.sock", "unix:/tmp/node-2.sock", "unix:/tmp/node-3.sock" },
          python = "unix:/tmp/python.sock",
        }),
      }, function()
        reset_shared_dict(cache)
        local cfg = routes.get_config()
        assert_eq(((cfg.runtimes.node or {}).routing), "round_robin", "runtime routing set for multi-socket")
        assert_eq(#(((cfg.runtimes.node or {}).sockets or {})), 3, "runtime sockets list count")
        assert_eq((((cfg.runtimes.node or {}).sockets or {})[2]), "unix:/tmp/node-2.sock", "runtime sockets list second")
        assert_eq(((cfg.runtimes.python or {}).routing), "single", "single socket routing")
      end)

      with_env({
        FN_FUNCTIONS_ROOT = functions_root,
        FN_RUNTIMES = "node,lua,python",
      }, function()
        reset_shared_dict(cache)
        local catalog = routes.discover_functions(true)
        assert_true(type(catalog) == "table", "discover_functions full")
        assert_explicit_root_beta_catalog(routes, catalog)
        local rt1, fn1 = routes.resolve_mapped_target("/from-manifest", "GET", { host = "localhost" })
        assert_eq(rt1, "node", "manifest route runtime")
        assert_eq(fn1, "node/hasdefault/handler.js", "manifest route target")
        local reload_out = routes.reload()
        assert_true(type(reload_out) == "table" and type(reload_out.config) == "table", "routes.reload response")
      end)

      cache:delete("rt:node:up")
      assert_eq(routes.runtime_is_up("node"), nil, "runtime_is_up nil when unset")
      routes.set_runtime_health("node", true, "ok")
      assert_eq(routes.runtime_is_up("node"), true, "runtime_is_up true after set")

      local sock_missing_ok, sock_missing_err = routes.check_runtime_socket(nil, 10)
      assert_eq(sock_missing_ok, false, "check_runtime_socket missing uri")
      assert_true(type(sock_missing_err) == "string" and sock_missing_err:find("missing runtime socket", 1, true) ~= nil, "check_runtime_socket missing error")

      local prev_tcp = ngx.socket.tcp
      ngx.socket.tcp = function()
        return {
          settimeouts = function() end,
          connect = function()
            return true
          end,
          close = function() end,
        }
      end
      local sock_ok = routes.check_runtime_socket("unix:/tmp/ok.sock", 100)
      assert_eq(sock_ok, true, "check_runtime_socket connect ok")
      ngx.socket.tcp = function()
        return {
          settimeouts = function() end,
          connect = function()
            return nil, "refused"
          end,
          close = function() end,
        }
      end
      local sock_fail_ok, sock_fail_err = routes.check_runtime_socket("unix:/tmp/fail.sock", 100)
      assert_eq(sock_fail_ok, false, "check_runtime_socket connect fail")
      assert_true(type(sock_fail_err) == "string" and sock_fail_err:find("refused", 1, true) ~= nil, "check_runtime_socket fail error")
      ngx.socket.tcp = prev_tcp

      local health_missing_ok, health_missing_err = routes.check_runtime_health("missingrt", nil)
      assert_eq(health_missing_ok, false, "check_runtime_health missing cfg")
      assert_true(type(health_missing_err) == "string" and health_missing_err:find("runtime config missing", 1, true) ~= nil, "check_runtime_health missing cfg err")
      local health_inproc_ok = routes.check_runtime_health("lua", { in_process = true })
      assert_eq(health_inproc_ok, true, "check_runtime_health lua in-process")
      routes.set_runtime_socket_health("node", 1, "unix:/tmp/node-1.sock", true, "ok")
      routes.set_runtime_socket_health("node", 2, "unix:/tmp/node-2.sock", true, "ok")
      routes.set_runtime_socket_health("node", 3, "unix:/tmp/node-3.sock", false, "down")
      local picked1_uri, picked1_idx, picked1_routing = routes.pick_runtime_socket("node", {
        socket = "unix:/tmp/node-1.sock",
        sockets = { "unix:/tmp/node-1.sock", "unix:/tmp/node-2.sock", "unix:/tmp/node-3.sock" },
        timeout_ms = 2500,
        routing = "round_robin",
      })
      local picked2_uri, picked2_idx = routes.pick_runtime_socket("node", {
        socket = "unix:/tmp/node-1.sock",
        sockets = { "unix:/tmp/node-1.sock", "unix:/tmp/node-2.sock", "unix:/tmp/node-3.sock" },
        timeout_ms = 2500,
        routing = "round_robin",
      })
      assert_eq(picked1_routing, "round_robin", "pick_runtime_socket routing")
      assert_true((picked1_idx == 1 and picked1_uri == "unix:/tmp/node-1.sock") or (picked1_idx == 2 and picked1_uri == "unix:/tmp/node-2.sock"), "pick_runtime_socket first healthy socket")
      assert_true((picked2_idx == 1 and picked2_uri == "unix:/tmp/node-1.sock") or (picked2_idx == 2 and picked2_uri == "unix:/tmp/node-2.sock"), "pick_runtime_socket second healthy socket")
      assert_true(picked1_idx ~= picked2_idx, "pick_runtime_socket rotates between healthy sockets")
      local picked_ex_uri, picked_ex_idx = routes.pick_runtime_socket("node", {
        socket = "unix:/tmp/node-1.sock",
        sockets = { "unix:/tmp/node-1.sock", "unix:/tmp/node-2.sock", "unix:/tmp/node-3.sock" },
        timeout_ms = 2500,
        routing = "round_robin",
      }, { [picked1_idx] = true, [picked2_idx] = true })
      assert_eq(picked_ex_uri, nil, "pick_runtime_socket no candidates when all healthy sockets excluded")
      assert_eq(picked_ex_idx, nil, "pick_runtime_socket nil index when excluded")

      local host_from_ngx, auth_from_ngx = resolve_request_host_values(nil, nil)
      assert_eq(host_from_ngx, "localhost", "resolve_request_host_values uses ngx.var.host")
      assert_eq(auth_from_ngx, "localhost", "resolve_request_host_values authority from ngx.var.host")
      local prev_var = ngx.var
      ngx.var = nil
      local host_empty, auth_empty = resolve_request_host_values(nil, nil)
      assert_eq(host_empty, "", "resolve_request_host_values empty host without ngx.var")
      assert_eq(auth_empty, "", "resolve_request_host_values empty authority without ngx.var")
      ngx.var = prev_var

      local warm_state, warm_at = warm_state_for_key("node/hasdefault@default", nil)
      assert_eq(warm_state, "cold", "warm_state_for_key cold")
      assert_eq(warm_at, nil, "warm_state_for_key cold timestamp")
      cache:set("warm:node/hasdefault@default", ngx.now())
      local warm_state2 = warm_state_for_key("node/hasdefault@default", nil)
      assert_eq(warm_state2, "warm", "warm_state_for_key warm")

      local read_zero = read_nonneg_counter(nil, "k")
      assert_eq(read_zero, 0, "read_nonneg_counter nil dict")
      local snapshot_pool = worker_pool_snapshot("node/hasdefault@default", {
        worker_pool = {
          enabled = true,
          min_warm = 1,
          max_workers = 2,
          max_queue = 3,
          idle_ttl_seconds = 60,
          queue_timeout_ms = 10,
          queue_poll_ms = 5,
          overflow_status = 418,
        },
      })
      assert_true(type(snapshot_pool) == "table", "worker_pool_snapshot table")
      assert_eq(snapshot_pool.overflow_status, 429, "worker_pool_snapshot overflow fallback")

      assert_eq(routes.record_worker_pool_drop(nil, "overflow"), false, "record_worker_pool_drop invalid key")
      assert_eq(routes.record_worker_pool_drop("node/hasdefault@default", "invalid"), false, "record_worker_pool_drop invalid reason")
      local prev_conc = get_upvalue(routes.record_worker_pool_drop, "CONC")
      set_upvalue(routes.record_worker_pool_drop, "CONC", nil)
      assert_eq(routes.record_worker_pool_drop("node/hasdefault@default", "overflow"), false, "record_worker_pool_drop missing dict")
      set_upvalue(routes.record_worker_pool_drop, "CONC", prev_conc)
      assert_eq(routes.record_worker_pool_drop("node/hasdefault@default", "overflow"), true, "record_worker_pool_drop overflow")
      assert_eq(routes.record_worker_pool_drop("node/hasdefault@default", "queue_timeout"), true, "record_worker_pool_drop timeout")

      local health = routes.health_snapshot()
      assert_true(type(health) == "table", "health_snapshot returns table")
      assert_true(tonumber(((health.functions or {}).summary or {}).warm or 0) >= 1, "health snapshot warm summary")
      assert_true(type((((health.runtimes or {}).node or {}).sockets)) == "table", "health snapshot runtime sockets")
      assert_true((((health.runtimes or {}).node or {}).routing) ~= nil, "health snapshot runtime routing")
      assert_true(type(routes.health_json()) == "string", "health_json string")

      cache:set("catalog:raw", cjson.encode({
        functions_root = functions_root,
        runtimes = { node = { functions = { demo = { has_default = true, versions = {}, policy = { methods = { "GET" } } } } } },
        mapped_routes = {
          ["/users/:id"] = {
            { runtime = "node", fn_name = "demo", methods = { "GET" }, allow_hosts = { "api.example.com" } },
          },
        },
        dynamic_routes = { "/users/:id" },
      }))
      local _, _, _, _, host_err = routes.resolve_mapped_target("/users/1", "GET", { host = "evil.example.com" })
      assert_eq(host_err, "host not allowed", "resolve_mapped_target host mismatch")
      local bad_route_rt = routes.resolve_mapped_target("users/1", "GET", { host = "localhost" })
      assert_eq(bad_route_rt, nil, "resolve_mapped_target invalid route path")

      cache:set("catalog:raw", cjson.encode({
        functions_root = functions_root,
        runtimes = { node = { functions = { demo = { has_default = true, versions = { "v1" }, policy = {} } } } },
        mapped_routes = {
          ["/methods-any"] = {
            { runtime = "node", fn_name = "demo", methods = nil },
          },
        },
        dynamic_routes = {},
      }))
      local rt_any, fn_any = routes.resolve_mapped_target("/methods-any", "DELETE", { host = "localhost" })
      assert_eq(rt_any, "node", "resolve_mapped_target nil methods means any")
      assert_eq(fn_any, "demo", "resolve_mapped_target nil methods target")
      local missing_named = routes.resolve_named_target("missing-fn", "v1")
      assert_eq(missing_named, nil, "resolve_named_target missing function by version")

      local pol_unknown_rt, pol_unknown_rt_err = routes.resolve_function_policy("unknown", "demo", nil)
      assert_eq(pol_unknown_rt, nil, "resolve_function_policy unknown runtime")
      assert_true(type(pol_unknown_rt_err) == "string" and pol_unknown_rt_err:find("unknown runtime", 1, true) ~= nil, "resolve_function_policy unknown runtime err")

      write_file(functions_root .. "/manifest-sub/fn.config.json", cjson.encode({
        invoke = {
          methods = { "POST" },
          allow_hosts = { "files.example.com" },
        },
      }) .. "\n")
      cache:set("catalog:raw", cjson.encode({
        functions_root = functions_root,
        runtimes = { node = { functions = {} } },
        mapped_routes = {},
        dynamic_routes = {},
      }))
      cache:set("runtime:config", cjson.encode({
        functions_root = functions_root,
        socket_base_dir = "/tmp/fastfn",
        runtime_order = { "node" },
        defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1024 * 1024 },
        runtimes = { node = { socket = "unix:/tmp/node.sock", timeout_ms = 2500 } },
      }))
      local file_policy, file_policy_err = routes.resolve_function_policy("node", "manifest-sub/hello.py", nil)
      assert_true(type(file_policy) == "table", file_policy_err or "resolve_function_policy file path fallback")

      cache:set("catalog:raw", cjson.encode({
        functions_root = functions_root,
        runtimes = {
          node = {
            functions = {
              demo = { has_default = false, versions = { "v1" }, policy = {}, versions_policy = { v1 = {} } },
            },
          },
        },
        mapped_routes = {},
        dynamic_routes = {},
      }))
      cache:set("runtime:config", cjson.encode({
        functions_root = functions_root,
        socket_base_dir = "/tmp/fastfn",
        runtime_order = { "node" },
        defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1024 * 1024 },
        runtimes = { node = { socket = "unix:/tmp/node.sock", timeout_ms = 2500 } },
      }))
      local pol_default_missing, pol_default_missing_err = routes.resolve_function_policy("node", "demo", nil)
      assert_eq(pol_default_missing, nil, "resolve_function_policy default missing")
      assert_true(type(pol_default_missing_err) == "string" and pol_default_missing_err:find("default version not available", 1, true) ~= nil, "resolve_function_policy default missing err")
      local pol_ver_missing, pol_ver_missing_err = routes.resolve_function_policy("node", "demo", "v2")
      assert_eq(pol_ver_missing, nil, "resolve_function_policy version missing")
      assert_true(type(pol_ver_missing_err) == "string" and pol_ver_missing_err:find("unknown version", 1, true) ~= nil, "resolve_function_policy unknown version err")

      local rt_named_v, ver_named_v = routes.resolve_named_target("demo", "v1")
      assert_eq(rt_named_v, "node", "resolve_named_target versioned runtime")
      assert_eq(ver_named_v, "v1", "resolve_named_target versioned version")
      local rt_named_none = routes.resolve_named_target("demo", "v9")
      assert_eq(rt_named_none, nil, "resolve_named_target missing version")
      local rt_named_default_none = routes.resolve_named_target("demo", nil)
      assert_eq(rt_named_default_none, nil, "resolve_named_target no default available")
      local force_keep_rt, force_keep_fn = routes.resolve_mapped_target("/force-keep", "GET", { host = "localhost" })
      assert_true(force_keep_rt == nil or force_keep_rt == "node", "force_url keep route resolution")
      assert_true(force_keep_fn == nil or force_keep_fn == "aa_force_on", "force_url keep target resolution")
      local force_replace_rt, force_replace_fn = routes.resolve_mapped_target("/force-replace", "GET", { host = "localhost" })
      assert_true(force_replace_rt == nil or force_replace_rt == "node", "force_url replace route resolution")
      assert_true(force_replace_fn == nil or force_replace_fn == "bb_force_on", "force_url replace target resolution")
      local manifest_wins_rt, manifest_wins_fn = routes.resolve_mapped_target("/manifest-wins", "GET", { host = "localhost" })
      assert_true(manifest_wins_rt == nil or manifest_wins_rt == "node", "manifest/file route resolution")
      assert_true(manifest_wins_fn == nil or manifest_wins_fn == "node/hasdefault/handler.js", "manifest/file route target resolution")

      assert_eq(routes.canonical_route_segment_for_name(""), nil, "canonical route empty")
      assert_eq(routes.canonical_route_segment_for_name("Api_V1/Users"), "api-v1/users", "canonical route namespaced")

      local deep_root = root .. "/deep-routes-root"
      mkdir_p(deep_root .. "/node/d1/d2/d3/d4/d5/d6/d7/d8")
      mkdir_p(deep_root .. "/misc/x1/x2/x3/x4/x5/x6/x7/x8")
      with_env({
        FN_FUNCTIONS_ROOT = deep_root,
        FN_RUNTIMES = "node",
      }, function()
        cache:delete("runtime:config")
        cache:delete("catalog:raw")
        local deep_catalog = routes.discover_functions(true)
        assert_true(type(deep_catalog) == "table", "discover_functions deep recursion guard")
      end)
      local prev_basename = get_upvalue(discover_functions, "basename")
      set_upvalue(discover_functions, "basename", function()
        return ""
      end)
      with_env({
        FN_FUNCTIONS_ROOT = deep_root,
        FN_RUNTIMES = "node",
      }, function()
        cache:delete("runtime:config")
        cache:delete("catalog:raw")
        local blank_name_catalog = routes.discover_functions(true)
        assert_true(type(blank_name_catalog) == "table", "discover_functions blank basename guard")
      end)
      set_upvalue(discover_functions, "basename", prev_basename)

      local runtime_manifest_root = root .. "/runtime-manifest-root"
      mkdir_p(runtime_manifest_root .. "/node/manifest_only")
      mkdir_p(runtime_manifest_root .. "/other")
      write_file(runtime_manifest_root .. "/node/manifest_only/fn.routes.json", cjson.encode({
        routes = {
          ["/from-runtime-manifest"] = "node/hasdefault/handler.js",
        },
      }) .. "\n")
      with_env({
        FN_FUNCTIONS_ROOT = runtime_manifest_root,
        FN_RUNTIMES = "node",
      }, function()
        cache:delete("runtime:config")
        cache:delete("catalog:raw")
        local manifest_catalog = routes.discover_functions(true)
        assert_true(type(manifest_catalog) == "table", "discover_functions runtime manifest branch")
      end)

      local prev_detect_manifest = get_upvalue(discover_functions, "detect_manifest_routes_in_dir")
      set_upvalue(discover_functions, "detect_manifest_routes_in_dir", function(_abs, rel)
        if rel == "." then
          return {
            { route = nil, runtime = "node", target = "node/hasdefault/handler.js", methods = { "GET" } },
          }, true
        end
        return {}, false
      end)
      with_env({
        FN_FUNCTIONS_ROOT = functions_root,
        FN_RUNTIMES = "node",
      }, function()
        cache:delete("runtime:config")
        cache:delete("catalog:raw")
        local invalid_route_catalog = routes.discover_functions(true)
        assert_true(type(invalid_route_catalog) == "table", "discover_functions skips invalid manifest route")
      end)
      set_upvalue(discover_functions, "detect_manifest_routes_in_dir", prev_detect_manifest)

      local hybrid_root = root .. "/hybrid-runtime-root"
      mkdir_p(hybrid_root .. "/node/whatsapp/admin")
      mkdir_p(hybrid_root .. "/node/whatsapp/api")
      mkdir_p(hybrid_root .. "/node/whatsapp/a/b/c/d/e/f/g/h")
      mkdir_p(hybrid_root .. "/node/multi-endpoints")
      mkdir_p(hybrid_root .. "/node/users")
      write_file(hybrid_root .. "/node/whatsapp/handler.js", "exports.handler = async () => ({ status: 200, body: 'app' });\n")
      write_file(hybrid_root .. "/node/whatsapp/core.js", "exports.handler = async () => ({ status: 200, body: 'core' });\n")
      write_file(hybrid_root .. "/node/whatsapp/admin/index.js", "exports.handler = async () => ({ status: 200, body: 'admin' });\n")
      write_file(hybrid_root .. "/node/whatsapp/api/get.health.js", "exports.handler = async () => ({ status: 200, body: 'health' });\n")
      write_file(hybrid_root .. "/node/whatsapp/a/b/c/d/e/f/g/h/get.health.js", "exports.handler = async () => ({ status: 200, body: 'too-deep' });\n")
      write_file(hybrid_root .. "/node/multi-endpoints/get.alpha.js", "exports.handler = async () => ({ status: 200, body: 'alpha' });\n")
      write_file(hybrid_root .. "/node/users/index.js", "exports.handler = async () => ({ status: 200, body: 'users' });\n")
      with_env({
        FN_FUNCTIONS_ROOT = hybrid_root,
        FN_RUNTIMES = "node",
      }, function()
        cache:delete("runtime:config")
        cache:delete("catalog:raw")
        local hybrid_catalog = routes.discover_functions(true)
        assert_true(type(hybrid_catalog) == "table", "discover_functions hybrid runtime root catalog")
        assert_true(type((((hybrid_catalog.runtimes or {}).node or {}).functions or {}).whatsapp) == "table", "hybrid runtime root base function")
        assert_true(type((((hybrid_catalog.runtimes or {}).node or {}).functions or {}).users) == "table", "runtime root index.js becomes base function")

        local admin_rt, admin_fn = routes.resolve_mapped_target("/whatsapp/admin", "GET", { host = "localhost" })
        assert_eq(admin_rt, "node", "mixed runtime subroute runtime")
        assert_eq(admin_fn, "whatsapp/admin/index.js", "mixed runtime subroute target")

        local api_rt, api_fn = routes.resolve_mapped_target("/whatsapp/api/health", "GET", { host = "localhost" })
        assert_eq(api_rt, "node", "mixed runtime explicit method route runtime")
        assert_eq(api_fn, "whatsapp/api/get.health.js", "mixed runtime explicit method route target")

        local multi_rt, multi_fn = routes.resolve_mapped_target("/node/multi-endpoints/alpha", "GET", { host = "localhost" })
        assert_eq(multi_rt, "node", "runtime root pure file route runtime")
        assert_eq(multi_fn, "node/multi-endpoints/get.alpha.js", "runtime root pure file route target")

        local leaked_core_rt = routes.resolve_mapped_target("/node/whatsapp/core", "GET", { host = "localhost" })
        assert_eq(leaked_core_rt, nil, "runtime helper should not leak with /node prefix")
        local leaked_node_rt = routes.resolve_mapped_target("/node/users", "GET", { host = "localhost" })
        assert_eq(leaked_node_rt, nil, "runtime single-entry index should not keep /node prefix")
        local deep_rt, deep_fn = routes.resolve_mapped_target("/whatsapp/a/b/c/d/e/f/g/h/health", "GET", { host = "localhost" })
        assert_eq(deep_rt, "node", "mixed runtime deep path should still resolve via base wildcard runtime")
        assert_eq(deep_fn, "whatsapp", "mixed runtime deep path should not leak helper target")
      end)

      with_env({ FN_HOT_RELOAD = "", FN_HOT_RELOAD_WATCHDOG = "" }, function()
        assert_eq(hot_reload_enabled(), true, "hot_reload_enabled default true")
        assert_eq(hot_reload_watchdog_enabled(), true, "hot_reload_watchdog_enabled default true")
      end)
      with_env({ FN_HOT_RELOAD = "0", FN_HOT_RELOAD_WATCHDOG = "0" }, function()
        assert_eq(hot_reload_enabled(), false, "hot_reload_enabled false")
        assert_eq(hot_reload_watchdog_enabled(), false, "hot_reload_watchdog_enabled false")
      end)
    end)

    -- Init branches with watchdog enabled and disabled.
    with_module_stubs({
      ["fastfn.core.watchdog"] = {
        start = function(opts)
          opts.on_change()
          cache:add("catalog:scan:running", ngx.now(), 2)
          opts.on_change()
          cache:delete("catalog:scan:running")
          local routes_mod = package.loaded["fastfn.core.routes"]
          local prev_discover = routes_mod and routes_mod.discover_functions or nil
          if routes_mod then
            routes_mod.discover_functions = function()
              error("watchdog forced failure")
            end
          end
          opts.on_change()
          if routes_mod and prev_discover then
            routes_mod.discover_functions = prev_discover
          end
          return true, { backend = "mock-watchdog" }
        end,
      },
    }, function()
      package.loaded["fastfn.core.routes"] = nil
      local routes = require("fastfn.core.routes")
      reset_shared_dict(cache)
      reset_shared_dict(conc)
      cache:set("runtime:config", cjson.encode({
        functions_root = functions_root,
        socket_base_dir = "/tmp/fastfn",
        runtime_order = { "lua" },
        defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1024 * 1024 },
        zero_config = { ignore_dirs = {} },
        runtimes = { lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true } },
      }))
      cache:set("catalog:raw", cjson.encode({
        functions_root = functions_root,
        runtimes = { lua = { functions = {} } },
        mapped_routes = {},
        dynamic_routes = {},
      }))

      local prev_worker_id = ngx.worker.id
      ngx.worker.id = function()
        return 1
      end
      routes.init()
      ngx.worker.id = prev_worker_id

      local prev_at = ngx.timer.at
      local prev_every = ngx.timer.every
      ngx.timer.at = function(_delay, _fn, ...)
        return false, "health at fail"
      end
      ngx.timer.every = function(_interval, _fn)
        return false, "health every fail"
      end
      with_env({
        FN_HOT_RELOAD = "0",
        FN_HOT_RELOAD_WATCHDOG = "0",
      }, function()
        routes.init()
      end)

      local every_calls = 0
      ngx.timer.at = function(_delay, fn, ...)
        if type(fn) == "function" then
          fn(true, ...)
          fn(false, ...)
        end
        return true
      end
      ngx.timer.every = function(_interval, fn)
        every_calls = every_calls + 1
        if type(fn) == "function" then
          fn(true)
          fn(false)
        end
        return true
      end
      with_env({
        FN_HOT_RELOAD = "1",
        FN_HOT_RELOAD_WATCHDOG = "1",
        FN_HEALTH_INTERVAL = "0",
      }, function()
        routes.init()
      end)
      assert_true(every_calls >= 1, "routes.init scheduled timers")
      assert_true(cache:get("catalog:watchdog:last_scan_at") ~= nil, "routes.init watchdog stores last scan timestamp")
      ngx.timer.at = prev_at
      ngx.timer.every = prev_every
    end)

    with_module_stubs({
      ["fastfn.core.watchdog"] = {
        start = function(_opts)
          return false, "watchdog unavailable"
        end,
      },
    }, function()
      package.loaded["fastfn.core.routes"] = nil
      local routes = require("fastfn.core.routes")
      reset_shared_dict(cache)
      reset_shared_dict(conc)
      cache:set("runtime:config", cjson.encode({
        functions_root = functions_root,
        socket_base_dir = "/tmp/fastfn",
        runtime_order = { "lua" },
        defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1024 * 1024 },
        zero_config = { ignore_dirs = {} },
        runtimes = { lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true } },
      }))
      cache:set("catalog:raw", cjson.encode({
        functions_root = functions_root,
        runtimes = { lua = { functions = {} } },
        mapped_routes = {},
        dynamic_routes = {},
      }))

      local prev_every = ngx.timer.every
      local every_count = 0
      ngx.timer.every = function(_interval, fn)
        every_count = every_count + 1
        if every_count == 1 then
          if type(fn) == "function" then
            fn(true)
            fn(false)
          end
          return true
        end
        if type(fn) == "function" then
          fn(true)
          cache:set("catalog:scan:running", ngx.now())
          fn(false)
          cache:delete("catalog:scan:running")
          local prev_discover = routes.discover_functions
          routes.discover_functions = function()
            error("hot reload boom")
          end
          fn(false)
          routes.discover_functions = prev_discover
        end
        return true
      end
      with_env({
        FN_HOT_RELOAD = "1",
        FN_HOT_RELOAD_WATCHDOG = "1",
        FN_HOT_RELOAD_INTERVAL = "0",
      }, function()
        routes.init()
      end)
      every_count = 0
      ngx.timer.every = function(_interval, _fn)
        every_count = every_count + 1
        if every_count == 1 then
          return true
        end
        return false, "hot-reload timer failed"
      end
      with_env({
        FN_HOT_RELOAD = "1",
        FN_HOT_RELOAD_WATCHDOG = "1",
        FN_HOT_RELOAD_INTERVAL = "0",
      }, function()
        routes.init()
      end)
      ngx.timer.every = prev_every
    end)

    rm_rf(root)
  end)
end

local function test_scheduler_additional_edge_paths_for_coverage()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-scheduler-edge-" .. uniq
    local state_path = root .. "/scheduler-state.json"

    rm_rf(root)
    mkdir_p(root)

    local routes_stub = {
      get_config = function()
        return {
          functions_root = root,
          runtimes = {
            lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true },
            node = { socket = "unix:/tmp/fn-node.sock", timeout_ms = 2500 },
          },
        }
      end,
      discover_functions = function()
        return {
          runtimes = {
            lua = {
              functions = {
                demo = {
                  has_default = true,
                  versions = { "v1" },
                  policy = {
                    methods = { "POST" },
                    timeout_ms = 500,
                    max_concurrency = 1,
                    max_body_bytes = 8,
                    schedule = { enabled = true, every_seconds = 1, method = "POST", retry = true },
                    keep_warm = { enabled = true, min_warm = 1, ping_every_seconds = 1, idle_ttl_seconds = 1 },
                  },
                  versions_policy = {
                    v1 = {
                      methods = { "POST" },
                      timeout_ms = 500,
                      max_concurrency = 1,
                      max_body_bytes = 8,
                      schedule = { enabled = true, cron = "*/1 * * * * *", method = "POST", retry = true },
                      keep_warm = { enabled = true, min_warm = 1, ping_every_seconds = 1, idle_ttl_seconds = 1 },
                    },
                  },
                },
              },
            },
          },
        }
      end,
      resolve_named_target = function(name, version)
        if name == "demo" then
          return "lua", version
        end
        return nil, nil
      end,
      resolve_function_policy = function(runtime, name, _version)
        if runtime ~= "lua" or name ~= "demo" then
          return nil, "not found"
        end
        return {
          methods = { "POST" },
          timeout_ms = 500,
          max_concurrency = 1,
          max_body_bytes = 8,
          schedule = { enabled = true, every_seconds = 1, method = "POST", retry = true },
          keep_warm = { enabled = true, min_warm = 1, ping_every_seconds = 1, idle_ttl_seconds = 1 },
        }
      end,
      get_runtime_config = function(runtime)
        if runtime == "lua" then
          return { socket = "inprocess:lua", timeout_ms = 2500, in_process = true }
        end
        if runtime == "node" then
          return { socket = "unix:/tmp/fn-node.sock", timeout_ms = 2500, in_process = false }
        end
        return nil
      end,
      runtime_is_up = function(runtime)
        if runtime == "lua" then
          return true
        end
        return false
      end,
      check_runtime_health = function(runtime, _cfg)
        if runtime == "lua" then
          return true, "ok"
        end
        return false, "down"
      end,
      set_runtime_health = function() end,
      runtime_is_in_process = function(runtime, cfg)
        if runtime == "lua" then
          return true
        end
        return cfg and cfg.in_process == true
      end,
    }

    local limits_stub = {
      try_acquire = function(_dict, _key, max_concurrency)
        if tonumber(max_concurrency) and tonumber(max_concurrency) < 0 then
          return false, "busy"
        end
        return true
      end,
      release = function() end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.limits"] = limits_stub,
      ["fastfn.core.lua_runtime"] = {
        call = function(payload)
          local event = (payload or {}).event or {}
          if event and event.path and tostring(event.path):find("explode", 1, true) then
            error("explode")
          end
          return { status = 500, headers = {}, body = string.rep("x", 900) }
        end,
      },
      ["fastfn.core.client"] = {
        call_unix = function(_socket, _payload, _timeout)
          return nil, "connect_error", "runtime down"
        end,
      },
      ["fastfn.core.gateway_utils"] = {
        map_runtime_error = function(code)
          if code == "connect_error" then
            return 503, "runtime down"
          end
          return 502, "runtime error"
        end,
      },
    }, function()
      package.loaded["fastfn.core.scheduler"] = nil
      local scheduler = require("fastfn.core.scheduler")

      local tick_once = get_upvalue(scheduler.init, "tick_once")
      local dispatch_schedule_invocation = get_upvalue(tick_once, "dispatch_schedule_invocation")
      local run_scheduled_invocation = get_upvalue(dispatch_schedule_invocation, "run_scheduled_invocation")
      local dispatch_keep_warm_invocation = get_upvalue(tick_once, "dispatch_keep_warm_invocation")
      local scheduler_worker_pool_context = get_upvalue(run_scheduled_invocation, "scheduler_worker_pool_context")
      local should_block_runtime = get_upvalue(run_scheduled_invocation, "should_block_runtime")
      local pick_policy_method = get_upvalue(dispatch_keep_warm_invocation, "pick_policy_method")
      local scheduler_persist_enabled = get_upvalue(scheduler.persist_now, "scheduler_persist_enabled")
      local env_flag = get_upvalue(scheduler_persist_enabled, "env_flag")
      local scheduler_persist_interval_seconds = get_upvalue(scheduler.init, "scheduler_persist_interval_seconds")
      local scheduler_state_path = get_upvalue(scheduler.persist_now, "scheduler_state_path")
      local truncate_error = get_upvalue(scheduler.persist_now, "truncate_error")
      local restore_persisted_state = get_upvalue(scheduler.init, "restore_persisted_state")
	      local write_file_atomic = get_upvalue(scheduler.persist_now, "write_file_atomic")
	      local scheduler_fs = get_upvalue(write_file_atomic, "fs")
	      local dirname = get_upvalue(write_file_atomic, "dirname")
	      local ensure_dir = get_upvalue(write_file_atomic, "ensure_dir")
      local compute_next_ts = get_upvalue(dispatch_schedule_invocation, "compute_next_ts")
      local compute_next_cron_ts = get_upvalue(dispatch_schedule_invocation, "compute_next_cron_ts")
      local parse_cron = get_upvalue(compute_next_cron_ts, "parse_cron")
      local cron_field = get_upvalue(parse_cron, "cron_field")
      local cron_value = get_upvalue(cron_field, "cron_value")
      local parse_timezone_offset = get_upvalue(compute_next_cron_ts, "parse_timezone_offset")
      local cron_date_fields = get_upvalue(compute_next_cron_ts, "cron_date_fields")
      local cron_day_matches = get_upvalue(compute_next_cron_ts, "cron_day_matches")
      local effective_schedule = get_upvalue(tick_once, "effective_schedule")
      local effective_keep_warm = get_upvalue(tick_once, "effective_keep_warm")
      local schedule_retry_config = get_upvalue(dispatch_schedule_invocation, "schedule_retry_config")
      local retry_delay_seconds = get_upvalue(dispatch_schedule_invocation, "retry_delay_seconds")
      local try_acquire_schedule_lock = get_upvalue(dispatch_schedule_invocation, "try_acquire_schedule_lock")

      assert_true(type(run_scheduled_invocation) == "function", "run_scheduled_invocation helper")
      assert_true(type(dispatch_schedule_invocation) == "function", "dispatch_schedule_invocation helper")
      assert_true(type(dispatch_keep_warm_invocation) == "function", "dispatch_keep_warm_invocation helper")
      assert_true(type(scheduler_worker_pool_context) == "function", "scheduler_worker_pool_context helper")
      assert_true(type(should_block_runtime) == "function", "should_block_runtime helper")
      assert_true(type(pick_policy_method) == "function", "pick_policy_method helper")
      assert_true(type(env_flag) == "function", "env_flag helper")
      assert_true(type(scheduler_persist_interval_seconds) == "function", "scheduler_persist_interval_seconds helper")
      assert_true(type(scheduler_state_path) == "function", "scheduler_state_path helper")
      assert_true(type(truncate_error) == "function", "truncate_error helper")
      assert_true(type(restore_persisted_state) == "function", "restore_persisted_state helper")
      assert_true(type(dirname) == "function", "dirname helper")
      assert_true(type(ensure_dir) == "function", "ensure_dir helper")
      assert_true(type(compute_next_ts) == "function", "compute_next_ts helper")
      assert_true(type(compute_next_cron_ts) == "function", "compute_next_cron_ts helper")
      assert_true(type(parse_cron) == "function", "parse_cron helper")
      assert_true(type(cron_field) == "function", "cron_field helper")
      assert_true(type(cron_value) == "function", "cron_value helper")
      assert_true(type(parse_timezone_offset) == "function", "parse_timezone_offset helper")
      assert_true(type(cron_date_fields) == "function", "cron_date_fields helper")
      assert_true(type(cron_day_matches) == "function", "cron_day_matches helper")
      assert_true(type(effective_schedule) == "function", "effective_schedule helper")
      assert_true(type(effective_keep_warm) == "function", "effective_keep_warm helper")
      assert_true(type(schedule_retry_config) == "function", "schedule_retry_config helper")
      assert_true(type(retry_delay_seconds) == "function", "retry_delay_seconds helper")
      assert_true(type(try_acquire_schedule_lock) == "function", "try_acquire_schedule_lock helper")

      assert_eq(dirname("a/b/c.txt"), "a/b", "dirname nested")
      assert_eq(dirname("single"), ".", "dirname root fallback")
      assert_eq(env_flag("MISSING_FLAG", true), true, "env_flag default true")
      with_env({ TEST_FLAG_EDGE = "off" }, function()
        assert_eq(env_flag("TEST_FLAG_EDGE", true), false, "env_flag false value")
      end)
      with_env({ TEST_FLAG_EDGE = "maybe" }, function()
        assert_eq(env_flag("TEST_FLAG_EDGE", false), false, "env_flag invalid raw keeps default")
      end)
      with_env({ FN_SCHEDULER_PERSIST_INTERVAL = "1" }, function()
        assert_eq(scheduler_persist_interval_seconds(), 5, "persist interval floor")
      end)
      with_env({ FN_SCHEDULER_PERSIST_INTERVAL = "9999" }, function()
        assert_eq(scheduler_persist_interval_seconds(), 3600, "persist interval ceiling")
      end)
      assert_eq(effective_schedule({}, {}), nil, "effective_schedule nil when missing")
      assert_eq(effective_keep_warm({}, {}), nil, "effective_keep_warm missing")
      local keep_warm_disabled = effective_keep_warm({}, { keep_warm = { enabled = false, min_warm = -1 } })
      assert_eq(keep_warm_disabled, nil, "effective_keep_warm disabled path")
      local keep_warm_floor = effective_keep_warm({}, {
        keep_warm = {
          enabled = true,
          min_warm = -1,
          ping_every_seconds = 0,
          idle_ttl_seconds = 0,
        },
      })
      assert_eq(keep_warm_floor, nil, "effective_keep_warm invalid floor path")

      with_env({ FN_SCHEDULER_STATE_PATH = "/tmp/custom-scheduler-state.json" }, function()
        assert_eq(scheduler_state_path(root), "/tmp/custom-scheduler-state.json", "scheduler_state_path override")
      end)
      assert_true(type(scheduler_state_path(root .. "///")) == "string", "scheduler_state_path normalized root")
      assert_eq(scheduler_state_path(""), nil, "scheduler_state_path invalid root")
      assert_eq(truncate_error(nil), "", "truncate_error non-string")
      assert_true(#truncate_error(string.rep("x", 3000)) < 3000, "truncate_error truncates")
      assert_eq(ensure_dir(nil), false, "ensure_dir invalid path")
      assert_eq(compute_next_ts(100, 0), nil, "compute_next_ts invalid period")
      assert_true(type(compute_next_ts(100, 5)) == "number", "compute_next_ts valid period")
      assert_eq(compute_next_cron_ts(100, "", "UTC", false), nil, "compute_next_cron_ts empty cron")
      assert_eq(parse_timezone_offset(""), nil, "parse_timezone_offset empty")
      assert_eq(parse_timezone_offset("bad tz"), nil, "parse_timezone_offset unsupported timezone")
      local tz_invalid, tz_invalid_err = parse_timezone_offset("+24:00")
      assert_eq(tz_invalid, nil, "parse_timezone_offset invalid clock range")
      assert_true(type(tz_invalid_err) == "string" and tz_invalid_err:find("invalid", 1, true) ~= nil, "parse_timezone_offset invalid clock err")
      local cv_bad, cv_bad_err = cron_value("abc", nil, false)
      assert_eq(cv_bad, nil, "cron_value invalid number")
      assert_true(type(cv_bad_err) == "string" and cv_bad_err:find("invalid", 1, true) ~= nil, "cron_value invalid number err")
      assert_eq(select(1, cron_field("", 0, 59, nil, false)), nil, "cron_field empty")
      local any_field = select(1, cron_field("1,*,2", 0, 5, nil, false))
      assert_true(type(any_field) == "table" and any_field.any == true, "cron_field mixed wildcard any")
      assert_eq(select(1, cron_field("1-100", 0, 59, nil, false)), nil, "cron_field range overflow")
      assert_eq(select(1, cron_field("abc-2", 0, 59, nil, false)), nil, "cron_field bad range start")
      assert_eq(select(1, cron_field("2-abc", 0, 59, nil, false)), nil, "cron_field bad range end")
      assert_true(type(select(1, cron_field("10-1", 0, 59, nil, false))) == "table", "cron_field reverse range swap")
      assert_eq(select(1, cron_field("abc", 0, 59, nil, false)), nil, "cron_field invalid token")

      assert_eq(select(1, parse_cron("x * * * * *")), nil, "parse_cron seconds error")
      assert_eq(select(1, parse_cron("* x * * * *")), nil, "parse_cron minutes error")
      assert_eq(select(1, parse_cron("* * x * * *")), nil, "parse_cron hours error")
      assert_eq(select(1, parse_cron("* * * x * *")), nil, "parse_cron dom error")
      assert_eq(select(1, parse_cron("* * * * x *")), nil, "parse_cron month error")
      assert_eq(select(1, parse_cron("* * * * * x")), nil, "parse_cron dow error")

      local prev_os = os
      _G.os = {
        execute = prev_os.execute,
        rename = prev_os.rename,
        remove = prev_os.remove,
        getenv = prev_os.getenv,
        exit = prev_os.exit,
        date = function()
          return "bad-date"
        end,
        time = prev_os.time,
      }
      assert_eq(select(1, cron_date_fields(100, 0)), nil, "cron_date_fields invalid date")
      _G.os = {
        execute = prev_os.execute,
        rename = prev_os.rename,
        remove = prev_os.remove,
        getenv = prev_os.getenv,
        exit = prev_os.exit,
        date = function()
          return { wday = 0, min = 0, hour = 0, month = 1, day = 1 }
        end,
        time = prev_os.time,
      }
      local fields_low = select(1, cron_date_fields(100, 0))
      assert_true(type(fields_low) == "table" and fields_low._dow0 == 0, "cron_date_fields low wday floor")
      _G.os = {
        execute = prev_os.execute,
        rename = prev_os.rename,
        remove = prev_os.remove,
        getenv = prev_os.getenv,
        exit = prev_os.exit,
        date = function()
          return { wday = 9, min = 0, hour = 0, month = 1, day = 1 }
        end,
        time = prev_os.time,
      }
      local fields_high = select(1, cron_date_fields(100, 0))
      assert_true(type(fields_high) == "table" and fields_high._dow0 == 1, "cron_date_fields high wday wraps")
      _G.os = prev_os

      assert_eq(cron_day_matches({
        dom = { any = true, set = {} },
        dow = { any = false, set = { [3] = true } },
      }, { day = 2, _dow0 = 3 }), true, "cron_day_matches dom_any branch")
      assert_eq(cron_day_matches({
        dom = { any = false, set = { [1] = true } },
        dow = { any = false, set = { [2] = true } },
      }, { day = 3, _dow0 = 2 }), true, "cron_day_matches OR branch")
      -- Test dow_any=true branch → returns dom_match (scheduler.lua line 756)
      assert_eq(cron_day_matches({
        dom = { any = false, set = { [15] = true } },
        dow = { any = true, set = {} },
      }, { day = 15, _dow0 = 0 }), true, "cron_day_matches dow_any returns dom_match true")
      assert_eq(cron_day_matches({
        dom = { any = false, set = { [15] = true } },
        dow = { any = true, set = {} },
      }, { day = 10, _dow0 = 0 }), false, "cron_day_matches dow_any returns dom_match false")
      assert_true(type(compute_next_cron_ts(100.8, "*/5 * * * * *", "UTC", true)) == "number", "compute_next_cron_ts inclusive fractional start")
      local keep_warm_timers = effective_keep_warm({}, {
        keep_warm = {
          enabled = true,
          min_warm = 1,
          ping_every_seconds = 0,
          idle_ttl_seconds = 0,
        },
      })
      assert_true(type(keep_warm_timers) == "table" and keep_warm_timers.ping_every_seconds > 0, "effective_keep_warm timer defaults")
      local prev_parse_cron_next = get_upvalue(compute_next_cron_ts, "parse_cron")
      local prev_cron_date_next = get_upvalue(compute_next_cron_ts, "cron_date_fields")
      local prev_lookahead = get_upvalue(compute_next_cron_ts, "MAX_CRON_LOOKAHEAD_MINUTES")
      local ok_set_lookahead = set_upvalue(compute_next_cron_ts, "MAX_CRON_LOOKAHEAD_MINUTES", 0)
	      local ok_set_parse = set_upvalue(compute_next_cron_ts, "parse_cron", function()
	        return {
	          seconds = { values = {} },
	          minutes = { set = { [0] = true } },
	          hours = { set = { [0] = true } },
          mon = { set = { [1] = true } },
          dom = { any = true, set = {} },
          dow = { any = true, set = {} },
	        }, nil
	      end)
	      assert_true(ok_set_parse or prev_parse_cron_next == nil, "compute_next_cron_ts parse_cron upvalue set")
	      local patched_parse_cron = get_upvalue(compute_next_cron_ts, "parse_cron")
	      local patched_spec = type(patched_parse_cron) == "function" and patched_parse_cron("* * * * * *") or nil
	      assert_true(type(patched_spec) == "table" and type(patched_spec.seconds) == "table" and #patched_spec.seconds.values == 0, "compute_next_cron_ts empty second spec patched")
	      compute_next_cron_ts(10, "* * * * * *", "UTC", false)
	      set_upvalue(compute_next_cron_ts, "parse_cron", function()
	        return {
	          seconds = { values = { 0 } },
	          minutes = { set = { [0] = true } },
          hours = { set = { [0] = true } },
          mon = { set = { [1] = true } },
          dom = { any = true, set = {} },
          dow = { any = true, set = {} },
        }, nil
      end)
      local ok_set_date = set_upvalue(compute_next_cron_ts, "cron_date_fields", function()
        return nil, "bad date fields"
      end)
	      assert_true(ok_set_date or prev_cron_date_next == nil, "compute_next_cron_ts cron_date_fields upvalue set")
	      if ok_set_lookahead then
	        set_upvalue(compute_next_cron_ts, "MAX_CRON_LOOKAHEAD_MINUTES", 1)
	      end
	      local patched_cron_date_fields = get_upvalue(compute_next_cron_ts, "cron_date_fields")
	      local patched_cron_date_err = nil
	      if type(patched_cron_date_fields) == "function" then
	        local _, err = patched_cron_date_fields(10, 0)
	        patched_cron_date_err = err
	      end
	      assert_true(patched_cron_date_err == "bad date fields", "compute_next_cron_ts cron_date_fields patched")
	      compute_next_cron_ts(10, "* * * * * *", "UTC", false)
	      set_upvalue(compute_next_cron_ts, "parse_cron", prev_parse_cron_next)
	      set_upvalue(compute_next_cron_ts, "cron_date_fields", prev_cron_date_next)
      if ok_set_lookahead then
        set_upvalue(compute_next_cron_ts, "MAX_CRON_LOOKAHEAD_MINUTES", prev_lookahead)
      end

      local pool_ctx = scheduler_worker_pool_context({
        max_concurrency = -1,
        worker_pool = {
          enabled = true,
          min_warm = -5,
          max_workers = -1,
          max_queue = -1,
          idle_ttl_seconds = 0,
          queue_timeout_ms = -1,
          queue_poll_ms = 0,
          overflow_status = 418,
        },
      })
      assert_true(type(pool_ctx) == "table", "scheduler_worker_pool_context table")
      assert_eq(pool_ctx.min_warm, 0, "scheduler_worker_pool_context min_warm floor")
      assert_eq(pool_ctx.max_workers, 0, "scheduler_worker_pool_context max_workers floor")
      assert_eq(pool_ctx.max_queue, 0, "scheduler_worker_pool_context max_queue fallback")
      assert_eq(pool_ctx.overflow_status, 429, "scheduler_worker_pool_context overflow fallback")

      local prev_ensure_dir = get_upvalue(write_file_atomic, "ensure_dir")
      set_upvalue(write_file_atomic, "ensure_dir", function()
        return false
      end)
      local wf_fail_ok, wf_fail_err = write_file_atomic(state_path, "{}")
      assert_eq(wf_fail_ok, false, "write_file_atomic ensure dir fail")
      assert_true(type(wf_fail_err) == "string" and wf_fail_err:find("create state dir", 1, true) ~= nil, "write_file_atomic ensure dir err")
      set_upvalue(write_file_atomic, "ensure_dir", prev_ensure_dir)

      local prev_os = os
      local prev_io = io
      _G.io = {
        open = function()
          return nil, "open failed"
        end,
      }
      local open_fail_ok, open_fail_err = write_file_atomic(state_path, "{}")
      assert_eq(open_fail_ok, false, "write_file_atomic open tmp fail")
      assert_true(type(open_fail_err) == "string" and open_fail_err:find("open failed", 1, true) ~= nil, "write_file_atomic open tmp err")
      _G.io = prev_io

	      local prev_scheduler_rename_atomic = scheduler_fs.rename_atomic
	      local prev_scheduler_remove_tree = scheduler_fs.remove_tree
	      scheduler_fs.rename_atomic = function()
	        return nil
	      end
	      scheduler_fs.remove_tree = function()
	        return true
	      end
	      local move_fail_ok, move_fail_err = write_file_atomic(state_path, "{\"ok\":false}")
	      assert_eq(move_fail_ok, false, "write_file_atomic move fail path")
	      assert_true(type(move_fail_err) == "string", "write_file_atomic move fail err")

	      scheduler_fs.rename_atomic = prev_scheduler_rename_atomic
	      scheduler_fs.remove_tree = prev_scheduler_remove_tree
	      local wrote_mv_ok, wrote_mv_err = write_file_atomic(state_path, "{\"ok\":true}")
	      assert_eq(wrote_mv_ok, true, wrote_mv_err or "write_file_atomic rename_atomic path")
	      _G.io = prev_io

      assert_eq(pick_policy_method(nil), "GET", "pick_policy_method default")
      assert_eq(pick_policy_method({ "" }), "GET", "pick_policy_method blank fallback")
      assert_eq(pick_policy_method({ "", "post" }), "POST", "pick_policy_method first non-empty")
      assert_eq(should_block_runtime("node", { socket = "x" }), true, "should_block_runtime down runtime")
      assert_eq(schedule_retry_config("bad").enabled, false, "schedule_retry_config non-table disabled")
      assert_eq(schedule_retry_config({ enabled = false }).enabled, false, "schedule_retry_config explicit disabled")
      local retry_cfg_clamped = schedule_retry_config({
        max_attempts = 0,
        base_delay_seconds = 9999,
        max_delay_seconds = 1,
        jitter = -1,
      })
      assert_eq(retry_cfg_clamped.max_attempts, 1, "schedule_retry_config attempts floor")
      assert_eq(retry_cfg_clamped.base_delay_seconds, 3600, "schedule_retry_config base ceiling")
      assert_eq(retry_cfg_clamped.max_delay_seconds, 3600, "schedule_retry_config max >= base")
      assert_eq(retry_cfg_clamped.jitter, 0, "schedule_retry_config jitter floor")
      local prev_random = math.random
      math.random = function()
        return 0
      end
      local delay_negative = retry_delay_seconds({
        base_delay_seconds = 1,
        max_delay_seconds = 1,
        jitter = 2,
      }, 1)
      assert_eq(delay_negative, 0, "retry_delay_seconds negative jitter clamp")
      math.random = prev_random
      cache:delete("sched:edge-lock:running")
      assert_eq(try_acquire_schedule_lock("edge-lock", 1), true, "try_acquire_schedule_lock ttl floor branch")
      cache:delete("sched:edge-lock:running")

      local status_unknown_rt, err_unknown_rt = run_scheduled_invocation("missing", "demo", nil, { method = "GET" }, { methods = { "GET" } }, "schedule")
      assert_eq(status_unknown_rt, 404, "run_scheduled_invocation unknown runtime")
      assert_true(type(err_unknown_rt) == "string" and err_unknown_rt:find("unknown runtime", 1, true) ~= nil, "unknown runtime error")

      local status_runtime_down = run_scheduled_invocation("node", "demo", nil, { method = "GET" }, { methods = { "GET" } }, "schedule")
      assert_eq(status_runtime_down, 503, "run_scheduled_invocation runtime down")

      local status_body_cast = run_scheduled_invocation("lua", "demo", nil, { method = "POST", body = 123 }, {
        methods = { "POST" },
        timeout_ms = 500,
        max_concurrency = 1,
        max_body_bytes = 1024,
      }, "schedule")
      assert_eq(status_body_cast, 500, "run_scheduled_invocation numeric body cast")

      local status_method, err_method = run_scheduled_invocation("lua", "demo", nil, { method = "DELETE" }, { methods = { "GET" } }, "schedule")
      assert_eq(status_method, 405, "run_scheduled_invocation method mismatch")
      assert_true(type(err_method) == "string" and err_method:find("method not allowed", 1, true) ~= nil, "method mismatch error")

      local status_body, err_body = run_scheduled_invocation("lua", "demo", nil, { method = "POST", body = string.rep("x", 20) }, {
        methods = { "POST" },
        max_body_bytes = 4,
      }, "schedule")
      assert_eq(status_body, 413, "run_scheduled_invocation payload too large")
      assert_true(type(err_body) == "string" and err_body:find("payload too large", 1, true) ~= nil, "payload too large error")

      local status_resp, err_resp = run_scheduled_invocation("lua", "demo", nil, { method = "POST", body = "x" }, {
        methods = { "POST" },
        timeout_ms = 500,
        max_concurrency = 1,
        max_body_bytes = 1024,
      }, "schedule")
      assert_eq(status_resp, 500, "run_scheduled_invocation response status path")
      assert_eq(err_resp, nil, "run_scheduled_invocation non-2xx returns nil error")
      local status_trigger_ctx = run_scheduled_invocation("lua", "demo", "v1", {
        method = "POST",
        cron = "*/1 * * * * *",
        timezone = "UTC",
        context = { source = "test" },
      }, {
        methods = { "POST" },
        timeout_ms = 500,
        max_concurrency = 1,
        max_body_bytes = 1024,
      }, "schedule", { attempt = 2, custom = "ok" })
      assert_eq(status_trigger_ctx, 500, "run_scheduled_invocation trigger context path")

      local busy_status, busy_err = run_scheduled_invocation("lua", "demo", nil, { method = "POST", body = "x" }, {
        methods = { "POST" },
        timeout_ms = 500,
        max_concurrency = -1,
        max_body_bytes = 1024,
      }, "schedule")
      assert_eq(busy_status, 429, "run_scheduled_invocation busy branch")
      assert_true(type(busy_err) == "string" and busy_err:find("busy", 1, true) ~= nil, "run_scheduled_invocation busy err")

      local prev_limits = get_upvalue(run_scheduled_invocation, "limits")
      set_upvalue(run_scheduled_invocation, "limits", {
        try_acquire = function()
          return false, "oops"
        end,
        release = function() end,
      })
      local gate_status, gate_err = run_scheduled_invocation("lua", "demo", nil, { method = "POST", body = "x" }, {
        methods = { "POST" },
        timeout_ms = 500,
        max_concurrency = 1,
      }, "schedule")
      assert_eq(gate_status, 500, "run_scheduled_invocation concurrency gate failure")
      assert_true(type(gate_err) == "string" and gate_err:find("concurrency gate failure", 1, true) ~= nil, "concurrency gate failure err")
      set_upvalue(run_scheduled_invocation, "limits", prev_limits)

      local xpcall_status, xpcall_err = run_scheduled_invocation("lua", "explode", nil, { method = "POST" }, {
        methods = { "POST" },
        timeout_ms = 500,
      }, "schedule")
      assert_eq(xpcall_status, 500, "run_scheduled_invocation exception branch")
      assert_true(type(xpcall_err) == "string" and xpcall_err:find("scheduler exception", 1, true) ~= nil, "run_scheduled_invocation exception err")

      local prev_should_block = get_upvalue(run_scheduled_invocation, "should_block_runtime")
      set_upvalue(run_scheduled_invocation, "should_block_runtime", function()
        return false
      end)
      local runtime_map_status, runtime_map_err = run_scheduled_invocation("node", "demo", nil, { method = "POST", cron = "*/1 * * * * *", timezone = "UTC" }, {
        methods = { "POST" },
        timeout_ms = 500,
        max_concurrency = 1,
      }, "schedule", { attempt = 1 })
      assert_eq(runtime_map_status, 503, "run_scheduled_invocation runtime error mapping")
      assert_true(type(runtime_map_err) == "string" and runtime_map_err:find("runtime down", 1, true) ~= nil, "run_scheduled_invocation runtime map err")
      set_upvalue(run_scheduled_invocation, "should_block_runtime", prev_should_block)

      local prev_timer_at = ngx.timer.at
      ngx.timer.at = function(_delay, fn, ...)
        if type(fn) == "function" then
          fn(false, ...)
        end
        return true
      end
      dispatch_schedule_invocation("lua", "demo", nil, { enabled = true }, ngx.now(), nil)
      assert_eq(tonumber(cache:get("sched:lua/demo@default:last_status")), 500, "dispatch invalid schedule fallback")
      dispatch_schedule_invocation("lua", "demo", nil, { enabled = true, every_seconds = 1 }, ngx.now(), { attempt = 0 })

      local prev_try_lock_sched = get_upvalue(dispatch_schedule_invocation, "try_acquire_schedule_lock")
      set_upvalue(dispatch_schedule_invocation, "try_acquire_schedule_lock", function()
        return false
      end)
      dispatch_schedule_invocation("lua", "demo", nil, { enabled = true, every_seconds = 1 }, ngx.now(), nil)
      set_upvalue(dispatch_schedule_invocation, "try_acquire_schedule_lock", prev_try_lock_sched)

      cache:delete("sched:lua/demo@default:next")
      cache:delete("sched:lua/demo@default:running")
      dispatch_schedule_invocation("lua", "demo", nil, {
        enabled = true,
        cron = "bad cron",
        retry = true,
      }, ngx.now(), { attempt = 2 })
      assert_eq(tonumber(cache:get("sched:lua/demo@default:last_status")), 500, "dispatch retry invalid cron fallback")

      cache:delete("sched:lua/demo@default:next")
      dispatch_schedule_invocation("lua", "demo", nil, {
        enabled = true,
        every_seconds = 1,
        method = "POST",
        retry = { enabled = true, max_attempts = 2, base_delay_seconds = 1, max_delay_seconds = 1, jitter = 0 },
      }, ngx.now(), { attempt = 9 })
      local retry_attempt = tonumber(cache:get("sched:lua/demo@default:retry_attempt"))
      assert_true(retry_attempt == nil or retry_attempt >= 2, "dispatch schedule retry path")

      local call_count = 0
      ngx.timer.at = function(_delay, fn, ...)
        call_count = call_count + 1
        if call_count == 1 then
          if type(fn) == "function" then
            fn(false, ...)
          end
          return true
        end
        return false, "retry timer failed"
      end
      dispatch_schedule_invocation("lua", "demo", nil, {
        enabled = true,
        every_seconds = 1,
        method = "POST",
        retry = { enabled = true, max_attempts = 2, base_delay_seconds = 1, max_delay_seconds = 1, jitter = 0 },
      }, ngx.now(), nil)
      assert_eq(tonumber(cache:get("sched:lua/demo@default:last_status")), 500, "dispatch retry timer failure updates state")

      ngx.timer.at = function(_delay, fn, ...)
        if type(fn) == "function" then
          fn(true, ...)
        end
        return true
      end
      dispatch_schedule_invocation("lua", "demo", nil, { enabled = true, every_seconds = 1 }, ngx.now(), nil)

      ngx.timer.at = function(_delay, fn, ...)
        if type(fn) == "function" then
          fn(false, 0)
        end
        return true
      end
      dispatch_schedule_invocation("lua", "demo", nil, { enabled = true, every_seconds = 1 }, ngx.now(), { attempt = 0 })

      local prev_run_sched = get_upvalue(dispatch_schedule_invocation, "run_scheduled_invocation")
      set_upvalue(dispatch_schedule_invocation, "run_scheduled_invocation", function()
        error("dispatch boom")
      end)
      ngx.timer.at = function(_delay, fn, ...)
        if type(fn) == "function" then
          fn(false, ...)
        end
        return true
      end
      dispatch_schedule_invocation("lua", "demo", nil, { enabled = true, every_seconds = 1 }, ngx.now(), nil)
      set_upvalue(dispatch_schedule_invocation, "run_scheduled_invocation", prev_run_sched)

      ngx.timer.at = function(_delay, _fn, ...)
        return false, "invoke timer failed"
      end
      dispatch_schedule_invocation("lua", "demo", nil, { enabled = true, every_seconds = 1 }, ngx.now(), nil)
      assert_eq(tonumber(cache:get("sched:lua/demo@default:last_status")), 500, "dispatch invocation timer failure")
      ngx.timer.at = prev_timer_at

      local prev_try_lock = get_upvalue(dispatch_keep_warm_invocation, "try_acquire_schedule_lock")
      set_upvalue(dispatch_keep_warm_invocation, "try_acquire_schedule_lock", function()
        return false
      end)
      dispatch_keep_warm_invocation("lua", "demo", nil, { enabled = true, min_warm = 1, ping_every_seconds = 1, idle_ttl_seconds = 1 }, ngx.now())
      set_upvalue(dispatch_keep_warm_invocation, "try_acquire_schedule_lock", prev_try_lock)
      dispatch_keep_warm_invocation("lua", "demo", nil, { enabled = true, min_warm = 1, ping_every_seconds = 0, idle_ttl_seconds = 0 }, ngx.now())
      cache:set("warm:lua/demo@default", ngx.now())
      cache:set("sched:lua/demo@default:keep_warm_next", ngx.now() + 1000)
      dispatch_keep_warm_invocation("lua", "demo", nil, { enabled = true, min_warm = 1, ping_every_seconds = 2, idle_ttl_seconds = 2000 }, ngx.now())

      local prev_timer_keep = ngx.timer.at
      local prev_run_keep = get_upvalue(dispatch_keep_warm_invocation, "run_scheduled_invocation")
      set_upvalue(dispatch_keep_warm_invocation, "run_scheduled_invocation", function()
        error("keep warm boom")
      end)
      cache:delete("warm:lua/demo@default")
      cache:delete("sched:lua/demo@default:keep_warm_next")
      ngx.timer.at = function(_delay, fn, ...)
        if type(fn) == "function" then
          fn(false, ...)
        end
        return true
      end
      dispatch_keep_warm_invocation("lua", "demo", nil, { enabled = true, min_warm = 1, ping_every_seconds = 1, idle_ttl_seconds = 1 }, ngx.now())
      set_upvalue(dispatch_keep_warm_invocation, "run_scheduled_invocation", prev_run_keep)
      ngx.timer.at = function(_delay, fn, ...)
        if type(fn) == "function" then
          fn(true, ...)
        end
        return true
      end
      dispatch_keep_warm_invocation("lua", "demo", nil, { enabled = true, min_warm = 1, ping_every_seconds = 1, idle_ttl_seconds = 1 }, ngx.now())
      ngx.timer.at = function(_delay, _fn, ...)
        return false, "keep-warm timer failed"
      end
      dispatch_keep_warm_invocation("lua", "demo", nil, { enabled = true, min_warm = 1, ping_every_seconds = 1, idle_ttl_seconds = 1 }, ngx.now())
      assert_eq(tonumber(cache:get("sched:lua/demo@default:keep_warm_last_status")), 500, "keep_warm timer failure status")
      ngx.timer.at = prev_timer_keep

      with_env({ FN_SCHEDULER_PERSIST_ENABLED = "0" }, function()
        local ok_persist, msg_persist = scheduler.persist_now()
        assert_eq(ok_persist, true, "persist_now disabled succeeds")
        assert_true(type(msg_persist) == "string" and msg_persist:find("disabled", 1, true) ~= nil, "persist_now disabled message")
        local ok_restore_disabled, err_restore_disabled = restore_persisted_state()
        assert_eq(ok_restore_disabled, false, "restore_persisted_state disabled")
        assert_true(type(err_restore_disabled) == "string" and err_restore_disabled:find("disabled", 1, true) ~= nil, "restore disabled message")
      end)

	      with_env({
	        FN_SCHEDULER_PERSIST_ENABLED = "1",
	        FN_SCHEDULER_STATE_PATH = state_path .. ".missing",
	      }, function()
	        os.remove(state_path .. ".missing")
	        local ok_restore_missing, err_restore_missing = restore_persisted_state()
	        assert_eq(ok_restore_missing, false, "restore_persisted_state missing file")
	        assert_true(type(err_restore_missing) == "string" and err_restore_missing:find("missing", 1, true) ~= nil, "restore missing error")
	      end)

	      with_env({
	        FN_SCHEDULER_PERSIST_ENABLED = "1",
	        FN_SCHEDULER_STATE_PATH = state_path,
	      }, function()
	        write_file(state_path, "{not-json")
	        local ok_restore_bad, err_restore_bad = restore_persisted_state()
	        assert_eq(ok_restore_bad, false, "restore_persisted_state invalid json")
	        assert_true(type(err_restore_bad) == "string" and err_restore_bad:find("invalid", 1, true) ~= nil, "restore invalid json error")

        write_file(state_path, cjson.encode({
          schedules = {
            [""] = {},
            ["lua/demo@junk"] = 1,
            ["lua/demo@nolast"] = {
              next = 1,
            },
            ["lua/demo@default"] = {
              next = 10,
              retry_due = "bad",
              retry_attempt = 2,
              last = 3,
              last_status = 500,
              last_error = string.rep("e", 4000),
              warm_at = 2,
            },
          },
          keep_warm = {
            ["lua/demo@none"] = {},
            ["lua/demo@default"] = {
              next = 5,
              last = 4,
              last_status = 200,
              last_error = string.rep("k", 4000),
              warm_at = 1,
            },
          },
        }) .. "\n")
        local ok_restore = restore_persisted_state()
        assert_eq(ok_restore, true, "restore_persisted_state valid")
        assert_true(type(cache:get("sched:lua/demo@default:last_error")) == "string", "restore truncates last_error")

        local ok_write, err_write = scheduler.persist_now()
        assert_eq(ok_write, true, err_write or "persist_now writes state")
      end)

      local prev_get_config = routes_stub.get_config
      routes_stub.get_config = function()
        return { functions_root = nil, runtimes = prev_get_config().runtimes }
      end
      with_env({ FN_SCHEDULER_PERSIST_ENABLED = "1", FN_SCHEDULER_STATE_PATH = false }, function()
        local no_path_ok, no_path_err = scheduler.persist_now()
        assert_eq(no_path_ok, false, "persist_now state path unavailable")
        assert_true(type(no_path_err) == "string" and no_path_err:find("state path", 1, true) ~= nil, "persist_now state path unavailable err")
      end)
      routes_stub.get_config = prev_get_config

      local prev_cjson_sched = get_upvalue(scheduler.persist_now, "cjson")
      set_upvalue(scheduler.persist_now, "cjson", {
        encode = function()
          return nil, "encode boom"
        end,
        decode = prev_cjson_sched.decode,
      })
      with_env({ FN_SCHEDULER_PERSIST_ENABLED = "1", FN_SCHEDULER_STATE_PATH = state_path }, function()
        local encode_fail_ok, encode_fail_err = scheduler.persist_now()
        assert_eq(encode_fail_ok, false, "persist_now encode failure")
        assert_true(type(encode_fail_err) == "string" and encode_fail_err:find("encode boom", 1, true) ~= nil, "persist_now encode failure err")
      end)
      set_upvalue(scheduler.persist_now, "cjson", prev_cjson_sched)

      cache:set("sched:tick:running", ngx.now())
      tick_once()
      cache:delete("sched:tick:running")

      local prev_timer_at_tick = ngx.timer.at
      ngx.timer.at = function(_delay, _fn, ...)
        return true
      end
      local prev_discover_tick = routes_stub.discover_functions
      routes_stub.discover_functions = function()
        return {
          runtimes = {
            lua = {
              functions = {
                demo = {
                  has_default = true,
                  versions = { "v1" },
                  policy = {
                    methods = { "POST" },
                    timeout_ms = 500,
                    schedule = { enabled = true, every_seconds = 1, method = "POST", retry = false },
                  },
                  versions_policy = {
                    v1 = {
                      methods = { "POST" },
                      timeout_ms = 500,
                      schedule = { enabled = true, every_seconds = 1, method = "POST", retry = false },
                    },
                  },
                },
              },
            },
          },
        }
      end
      cache:set("sched:lua/demo@default:retry_due", "123")
      cache:set("sched:lua/demo@default:retry_attempt", 1)
      cache:set("sched:lua/demo@v1:retry_due", "123")
      cache:set("sched:lua/demo@v1:retry_attempt", 1)
      tick_once()
      assert_eq(cache:get("sched:lua/demo@default:retry_attempt"), nil, "tick_once clears retry_attempt when retry disabled default")
      assert_eq(cache:get("sched:lua/demo@v1:retry_attempt"), nil, "tick_once clears retry_attempt when retry disabled version")

      routes_stub.discover_functions = function()
        return {
          runtimes = {
            lua = {
              functions = {
                demo = {
                  has_default = true,
                  versions = { "v1" },
                  policy = {
                    methods = { "POST" },
                    timeout_ms = 500,
                    schedule = { enabled = true, every_seconds = 1, method = "POST", retry = true },
                  },
                  versions_policy = {
                    v1 = {
                      methods = { "POST" },
                      timeout_ms = 500,
                      schedule = { enabled = true, every_seconds = 1, method = "POST", retry = true },
                    },
                  },
                },
              },
            },
          },
        }
      end
      cache:set("sched:lua/demo@default:retry_due", "bad")
      cache:set("sched:lua/demo@default:retry_attempt", 1)
      cache:set("sched:lua/demo@v1:retry_due", "bad")
      cache:set("sched:lua/demo@v1:retry_attempt", 1)
      tick_once()
      cache:set("sched:lua/demo@default:retry_due", ngx.now() - 1)
      cache:set("sched:lua/demo@default:retry_attempt", 1)
      cache:set("sched:lua/demo@v1:retry_due", ngx.now() - 1)
      cache:set("sched:lua/demo@v1:retry_attempt", 1)
      tick_once()

      routes_stub.discover_functions = function()
        return {
          runtimes = {
            lua = {
              functions = {
                demo = {
                  has_default = false,
                  versions = { "v1" },
                  policy = { methods = { "POST" }, timeout_ms = 500 },
                  versions_policy = {
                    v1 = {
                      methods = { "POST" },
                      timeout_ms = 500,
                      schedule = { enabled = true, cron = "bad cron", method = "POST", retry = true },
                    },
                  },
                },
              },
            },
          },
        }
      end
      cache:delete("sched:lua/demo@v1:next")
      tick_once()
      routes_stub.discover_functions = prev_discover_tick
      ngx.timer.at = prev_timer_at_tick

      local prev_get_cfg_tick = routes_stub.get_config
      routes_stub.get_config = function()
        error("tick explosion")
      end
      local ok_tick_panic = pcall(tick_once)
      assert_eq(ok_tick_panic, false, "tick_once propagates internal panic")
      routes_stub.get_config = prev_get_cfg_tick

      local prev_worker = ngx.worker.id
      ngx.worker.id = function()
        return 1
      end
      scheduler.init()
      ngx.worker.id = prev_worker

      with_env({ FN_SCHEDULER_ENABLED = "0" }, function()
        scheduler.init()
      end)

      local prev_every = ngx.timer.every
      local prev_at = ngx.timer.at
      ngx.timer.every = function(_interval, fn)
        if type(fn) == "function" then
          fn(true)
          fn(false)
        end
        return false, "scheduler timer failed"
      end
      ngx.timer.at = function(_delay, fn, ...)
        if type(fn) == "function" then
          fn(true, ...)
          fn(false, ...)
        end
        return false, "at failed"
      end
      with_env({
        FN_SCHEDULER_ENABLED = "1",
        FN_SCHEDULER_INTERVAL = "0",
        FN_SCHEDULER_PERSIST_ENABLED = "1",
        FN_SCHEDULER_STATE_PATH = state_path,
        FN_SCHEDULER_PERSIST_INTERVAL = "5",
      }, function()
        scheduler.init()
      end)

      local prev_restore_init = get_upvalue(scheduler.init, "restore_persisted_state")
      set_upvalue(scheduler.init, "restore_persisted_state", function()
        error("restore panic")
      end)
      ngx.timer.every = function(_interval, _fn)
        return true
      end
      with_env({
        FN_SCHEDULER_ENABLED = "1",
        FN_SCHEDULER_PERSIST_ENABLED = "1",
        FN_SCHEDULER_STATE_PATH = state_path,
      }, function()
        scheduler.init()
      end)
      set_upvalue(scheduler.init, "restore_persisted_state", prev_restore_init)

      local prev_tick_once_init = get_upvalue(scheduler.init, "tick_once")
      set_upvalue(scheduler.init, "tick_once", function()
        error("tick panic")
      end)
      ngx.timer.every = function(_interval, fn)
        if type(fn) == "function" then
          fn(false)
        end
        return true
      end
      with_env({
        FN_SCHEDULER_ENABLED = "1",
        FN_SCHEDULER_PERSIST_ENABLED = "0",
      }, function()
        scheduler.init()
      end)
      set_upvalue(scheduler.init, "tick_once", prev_tick_once_init)

      set_upvalue(scheduler.init, "restore_persisted_state", function()
        return true, nil
      end)
      local prev_persist_fn = scheduler.persist_now
      scheduler.persist_now = function()
        error("persist panic")
      end
      ngx.timer.every = function(_interval, fn)
        if type(fn) == "function" then
          fn(false)
        end
        return true
      end
      ngx.timer.at = function(_delay, fn, ...)
        if type(fn) == "function" then
          fn(true, ...)
        end
        return true
      end
      with_env({
        FN_SCHEDULER_ENABLED = "1",
        FN_SCHEDULER_PERSIST_ENABLED = "1",
        FN_SCHEDULER_STATE_PATH = state_path,
      }, function()
        scheduler.init()
      end)

      ngx.timer.at = function(_delay, fn, ...)
        if type(fn) == "function" then
          fn(false, ...)
        end
        return true
      end
      with_env({
        FN_SCHEDULER_ENABLED = "1",
        FN_SCHEDULER_PERSIST_ENABLED = "1",
        FN_SCHEDULER_STATE_PATH = state_path,
      }, function()
        scheduler.init()
      end)

      scheduler.persist_now = function()
        return false, "persist skipped"
      end
      ngx.timer.every = function(_interval, fn)
        if type(fn) == "function" then
          fn(false)
        end
        return true
      end
      ngx.timer.at = function(_delay, fn, ...)
        if type(fn) == "function" then
          fn(false, ...)
        end
        return true
      end
      with_env({
        FN_SCHEDULER_ENABLED = "1",
        FN_SCHEDULER_PERSIST_ENABLED = "1",
        FN_SCHEDULER_STATE_PATH = state_path,
      }, function()
        scheduler.init()
      end)

      scheduler.persist_now = prev_persist_fn
      ngx.timer.every = function(_interval, fn)
        if type(fn) == "function" then
          fn(false)
        end
        return true
      end
      ngx.timer.at = function(_delay, _fn, ...)
        return false, "queue persist fail"
      end
      with_env({
        FN_SCHEDULER_ENABLED = "1",
        FN_SCHEDULER_PERSIST_ENABLED = "1",
        FN_SCHEDULER_STATE_PATH = state_path,
      }, function()
        scheduler.init()
      end)
      set_upvalue(scheduler.init, "restore_persisted_state", prev_restore_init)
      scheduler.persist_now = prev_persist_fn
      ngx.timer.every = prev_every
      ngx.timer.at = prev_at
    end)

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

-- ============================================================
-- Additional coverage tests
-- ============================================================

local function test_console_data_secret_masking_and_path_traversal()
  with_console_data_fixture(function(ctx)
    local data = ctx.data
    local cjson = ctx.cjson
    local root = ctx.root

    -- Write an fn.env.json with secret-looking keys
    write_file(root .. "/python/demo/fn.env.json", cjson.encode({
      API_KEY = { value = "super-secret", is_secret = true },
      DB_PASSWORD = { value = "hunter2", is_secret = true },
      NORMAL_VAR = { value = "visible" },
    }))

    local detail = data.function_detail("python", "demo", nil, true)
    assert_true(type(detail) == "table", "secret detail should return table")

    -- Test path traversal guards for function names
    local bad_names = { "../etc/passwd", "/absolute", "..\\..\\win" }
    for _, name in ipairs(bad_names) do
      local result = data.function_detail("python", name, nil, false)
      assert_eq(result, nil, "path traversal should be blocked: " .. tostring(name))
    end

    -- Test create_function with invalid runtime
    local create_ok, create_err = data.create_function("invalid_runtime!", "test_fn", nil)
    assert_true(type(create_err) == "string", "create with invalid runtime should error")

    -- Test create_function with path traversal name
    local create_ok2, create_err2 = data.create_function("python", "../escape", nil)
    assert_true(type(create_err2) == "string", "create with traversal name should error")

    -- Test set_function_env with secret keys
    local env_ok = data.set_function_env("python", "demo", nil, {
      SECRET_TOKEN = { value = "mysecret", is_secret = true },
      PLAIN = { value = "plain" },
    })
    assert_true(env_ok ~= nil, "set_function_env with secrets should succeed")
  end)
end

local function test_routes_wildcard_matching_and_error_formatting()
  with_fake_ngx(function(cache, conc, _set_now)
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-routes-wc-" .. uniq
    rm_rf(root)
    mkdir_p(root .. "/lua/hello")
    write_file(root .. "/lua/hello/handler.lua", "return function() return {status=200} end\n")

    with_env({ FN_FUNCTIONS_ROOT = root, FN_RUNTIMES = "lua" }, function()
      package.loaded["fastfn.core.routes"] = nil
      package.loaded["fastfn.core.invoke_rules"] = nil
      local routes = require("fastfn.core.routes")

      -- Test canonical_route_segment_for_name
      local seg = routes.canonical_route_segment_for_name("My_Cool_Function")
      assert_eq(seg, "my-cool-function", "canonical segment normalizes underscores and case")

      local seg_ns = routes.canonical_route_segment_for_name("api/v1/users")
      assert_eq(seg_ns, "api/v1/users", "canonical segment preserves namespace slashes")

      local seg_empty = routes.canonical_route_segment_for_name("")
      assert_eq(seg_empty, nil, "canonical segment empty returns nil")

      local seg_special = routes.canonical_route_segment_for_name("!!!")
      assert_eq(seg_special, nil, "canonical segment special chars returns nil")

      -- Test resolve_function_entrypoint edge cases
      local _, err1 = routes.resolve_function_entrypoint("", "hello", nil)
      assert_true(type(err1) == "string", "empty runtime should error")

      local _, err2 = routes.resolve_function_entrypoint("lua", "", nil)
      assert_true(type(err2) == "string", "empty fn_name should error")

      -- Test runtime_is_in_process
      assert_eq(routes.runtime_is_in_process("lua", nil), true, "lua is always in-process")
      assert_eq(routes.runtime_is_in_process("node", { in_process = false }), false, "node not in-process")

      -- Test check_runtime_socket with empty uri
      local ok_sock, err_sock = routes.check_runtime_socket("", 100)
      assert_eq(ok_sock, false, "empty socket should fail")
      assert_true(type(err_sock) == "string", "empty socket error msg")

      -- Test record_worker_pool_drop
      assert_eq(routes.record_worker_pool_drop("", "overflow"), false, "empty key drop should fail")
      assert_eq(routes.record_worker_pool_drop("test/fn@v1", "invalid_reason"), false, "invalid reason should fail")
      assert_true(routes.record_worker_pool_drop("test/fn@v1", "overflow"), "valid drop should succeed")
      assert_true(routes.record_worker_pool_drop("test/fn@v1", "queue_timeout"), "queue_timeout drop should succeed")

      -- Test set_runtime_socket_health edge cases
      assert_eq(routes.set_runtime_socket_health(nil, 1, "uri", true, "ok"), false, "nil runtime should fail")
      assert_eq(routes.set_runtime_socket_health("lua", nil, "uri", true, "ok"), false, "nil index should fail")
      assert_eq(routes.set_runtime_socket_health("lua", 0, "uri", true, "ok"), false, "zero index should fail")
      assert_eq(routes.set_runtime_socket_health("lua", 1, "uri", true, "ok"), true, "valid set health should succeed")

      -- Test runtime_socket_status with invalid args
      local stat_nil = routes.runtime_socket_status(nil, 1, nil)
      assert_eq(stat_nil, nil, "nil runtime socket status")

      -- Test get_runtime_sockets
      local socks = routes.get_runtime_sockets("nonexistent", nil)
      assert_true(type(socks) == "table" and #socks == 0, "unknown runtime should return empty sockets")

      -- Test pick_runtime_socket for lua (in-process)
      local uri, idx, strategy, err = routes.pick_runtime_socket("lua", nil)
      assert_eq(uri, nil, "lua pick socket returns nil (in-process)")
      assert_eq(strategy, "in_process", "lua pick socket strategy")

      -- Test pick_runtime_socket with nil config
      local uri2, _, strat2, err2 = routes.pick_runtime_socket("nonexistent", nil)
      assert_eq(uri2, nil, "nonexistent pick socket returns nil")
      assert_true(type(err2) == "string", "nonexistent pick error msg")
    end)

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

local function test_watchdog_poll_interval_and_permissions()
  with_fake_ngx(function(cache, conc, _set_now)
    package.loaded["fastfn.core.watchdog"] = nil
    local watchdog = require("fastfn.core.watchdog")

    -- Test start with empty root
    local ok1, err1 = watchdog.start({})
    assert_eq(ok1, false, "empty root should fail")
    assert_true(type(err1) == "string" and err1:find("root is required", 1, true) ~= nil, "empty root error msg")

    -- Test start with missing callback
    local ok2, err2 = watchdog.start({ root = "/tmp" })
    assert_eq(ok2, false, "missing callback should fail")
    assert_true(type(err2) == "string" and err2:find("on_change callback", 1, true) ~= nil, "missing callback error msg")

    -- Test start with callback not a function
    local ok3, err3 = watchdog.start({ root = "/tmp", on_change = "not_a_function" })
    assert_eq(ok3, false, "string callback should fail")
    assert_true(type(err3) == "string", "string callback error msg")

    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

local function test_http_client_timeout_and_body_encoding()
  with_fake_ngx(function(cache, conc, _set_now)
    -- Need ngx.re for http_client parse_url
    ngx.re = ngx.re or {
      match = function(subj, pattern, opts)
        -- Minimal fallback for parse_url pattern.
        -- Lua patterns do not support optional groups (...)?  so we try
        -- with path first, then without.
        local s = tostring(subj)
        local scheme, authority, path = s:match("^(https?)://([^/]+)(/.*)$")
        if not scheme then
          scheme, authority = s:match("^(https?)://([^/]+)$")
        end
        if not scheme then
          return nil
        end
        return { scheme, authority, path }
      end,
    }

    package.loaded["fastfn.core.http_client"] = nil
    local http = require("fastfn.core.http_client")

    -- Test request with nil options
    local r1, e1 = http.request(nil)
    assert_eq(r1, nil, "nil opts should fail")
    assert_eq(e1, "invalid_options", "nil opts error")

    -- Test request with invalid URL
    local r2, e2 = http.request({ url = "not-a-url" })
    assert_eq(r2, nil, "invalid url should fail")
    assert_eq(e2, "invalid_url", "invalid url error")

    -- Test request with invalid headers type
    local r3, e3 = http.request({ url = "http://localhost:9999/test", headers = "bad" })
    assert_eq(r3, nil, "string headers should fail")
    assert_eq(e3, "invalid_headers", "string headers error")

    -- Test with body as non-string (should be coerced to string)
    local r4, e4 = http.request({ url = "http://localhost:9999/test", body = 12345, timeout_ms = 100 })
    assert_eq(r4, nil, "connect refused still fails")
    assert_true(type(e4) == "string" and e4:find("connect_error", 1, true) ~= nil, "connect error with body coercion")

    -- Test with very small timeout_ms (should be clamped to 50)
    local r5, e5 = http.request({ url = "http://localhost:9999/test", timeout_ms = 1 })
    assert_eq(r5, nil, "small timeout still fails to connect")
    assert_true(type(e5) == "string", "small timeout error msg")

    -- Test with explicit content-length header
    local r6, e6 = http.request({
      url = "http://localhost:9999/test",
      headers = { ["Content-Length"] = "5" },
      body = "hello",
      timeout_ms = 100,
    })
    assert_eq(r6, nil, "explicit content-length still fails to connect")

    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

local function test_scheduler_disable_reenable_and_overlap()
  with_fake_ngx(function(cache, conc, set_now)
    local routes_stub = {
      get_config = function()
        return { functions_root = "/tmp", runtimes = { lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true } } }
      end,
      discover_functions = function()
        return {
          runtimes = {
            lua = {
              functions = {
                toggler = {
                  has_default = true,
                  versions = {},
                  policy = {
                    methods = { "POST" },
                    timeout_ms = 500,
                    schedule = {
                      enabled = true,
                      every_seconds = 10,
                      method = "POST",
                    },
                  },
                  versions_policy = {},
                },
              },
            },
          },
        }
      end,
      resolve_named_target = function(fn_name, version)
        if fn_name == "toggler" then return "lua", version end
        return nil
      end,
      resolve_function_policy = function(runtime, name, _version)
        if runtime == "lua" and name == "toggler" then
          return { methods = { "POST" }, timeout_ms = 500 }
        end
        return nil, "not found"
      end,
      get_runtime_config = function(rt)
        if rt == "lua" then return { socket = "inprocess:lua", in_process = true, timeout_ms = 2500 } end
        return nil
      end,
      runtime_is_up = function() return true end,
      check_runtime_health = function() return true, "ok" end,
      set_runtime_health = function() end,
      runtime_is_in_process = function(_, cfg) return cfg and cfg.in_process == true end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.limits"] = { try_acquire = function() return true end, release = function() end },
      ["fastfn.core.lua_runtime"] = { call = function() return { status = 200, headers = {}, body = "" } end },
      ["fastfn.core.client"] = { call_unix = function() return { status = 200, headers = {}, body = "" } end },
      ["fastfn.core.gateway_utils"] = {
        map_runtime_error = function() return 502, "runtime error" end,
        resolve_numeric = function(a, b, c, d)
          return tonumber(a) or tonumber(b) or tonumber(c) or d
        end,
      },
    }, function()
      package.loaded["fastfn.core.scheduler"] = nil
      local scheduler = require("fastfn.core.scheduler")

      -- Test snapshot returns table
      set_now(100)
      local snap = scheduler.snapshot()
      assert_true(type(snap) == "table", "snapshot should return table")

      reset_shared_dict(cache)
      reset_shared_dict(conc)
    end)
  end)
end

local function test_limits_release_edge_cases()
  with_fake_ngx(function(cache, conc, set_now)
    -- Provide ngx.sleep so limits.wait_for_pool_slot works
    local sleep_time = 0
    ngx.sleep = function(sec) sleep_time = sleep_time + sec; set_now(ngx.now() + sec) end

    package.loaded["fastfn.core.limits"] = nil
    local limits = require("fastfn.core.limits")

    -- Test releasing when counter is already at zero (should not go negative)
    local store = {}
    local dict = {
      incr = function(_, key, amount, init)
        if store[key] == nil then store[key] = init or 0 end
        store[key] = store[key] + amount
        return store[key]
      end,
      get = function(_, key) return store[key] end,
      delete = function(_, key) store[key] = nil end,
    }

    -- Release without any acquire - counter should be cleaned up
    limits.release(dict, "python/empty@default")
    assert_eq(store["conc:python/empty@default"], nil, "release on empty should delete key")

    -- Release pool without any acquire
    limits.release_pool(dict, "python/empty@default")
    assert_eq(store["pool:active:python/empty@default"], nil, "release_pool on empty should delete key")

    -- cancel_pool_queue without any queue
    limits.cancel_pool_queue(dict, "python/empty@default")
    assert_eq(store["pool:queue:python/empty@default"], nil, "cancel queue on empty should delete key")

    -- Test acquire then double-release
    limits.try_acquire(dict, "python/dbl@default", 5)
    limits.release(dict, "python/dbl@default")
    limits.release(dict, "python/dbl@default")
    assert_eq(store["conc:python/dbl@default"], nil, "double release should clean up key")

    -- wait_for_pool_slot with clamped poll_ms – active always exceeds workers so
    -- the slot is never free and we timeout.
    set_now(100)
    store["pool:active:node/clamp@default"] = 99
    local wait_ok, wait_state = limits.wait_for_pool_slot(dict, "node/clamp@default", 1, 10, 500)
    assert_eq(wait_ok, false, "clamped poll_ms should still timeout")
    assert_eq(wait_state, "queue_timeout", "clamped poll_ms timeout state")
  end)
end

local function test_lua_runtime_module_caching_and_sandbox()
  with_fake_ngx(function(cache, conc, _set_now)
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-lua-sandbox-" .. uniq
    rm_rf(root)
    mkdir_p(root .. "/lua/sandbox")
    mkdir_p(root .. "/lua/badmod")
    mkdir_p(root .. "/lua/localmod")
    mkdir_p(root .. "/lua/tblhandler")
    mkdir_p(root .. "/lua/base64resp")
    mkdir_p(root .. "/lua/bodyresp")
    mkdir_p(root .. "/lua/proxyresp")

    -- Write a function that tries to require a forbidden module
    write_file(root .. "/lua/badmod/handler.lua", [[
return function(event)
  local ok, err = pcall(require, "os")
  return { status = 200, body = tostring(err) }
end
]])

    write_file(root .. "/lua/localmod/_shared.lua", [[
local M = {}

function M.greet(name)
  print("helper", name)
  return "hello " .. tostring(name)
end

return M
]])

    write_file(root .. "/lua/localmod/handler.lua", [[
local shared = require("_shared")

return function(event)
  local params = event.params or {}
  return { status = 200, body = shared.greet(params.name or "friend") }
end
]])

    -- Write a function that returns a table handler
    write_file(root .. "/lua/tblhandler/handler.lua", [[
local M = {}
M.handler = function(event)
  return { status = 200, body = "from table handler" }
end
return M
]])

    -- Write a function that returns is_base64
    write_file(root .. "/lua/base64resp/handler.lua", [[
return function(event)
  return { status = 200, is_base64 = true, body_base64 = "aGVsbG8=" }
end
]])

    -- Write a function that returns body as a table (auto-JSON)
    write_file(root .. "/lua/bodyresp/handler.lua", [[
return function(event)
  return { status = 200, body = { hello = "world" } }
end
]])

    -- Write a function that returns a proxy
    write_file(root .. "/lua/proxyresp/handler.lua", [[
return function(event)
  return { status = 200, proxy = { url = "http://example.com" } }
end
]])

    -- Write a function that uses print
    write_file(root .. "/lua/sandbox/handler.lua", [[
return function(event)
  print("hello", "world")
  return { ok = true }
end
]])

    with_env({ FN_FUNCTIONS_ROOT = root, FN_RUNTIMES = "lua" }, function()
      package.loaded["fastfn.core.routes"] = nil
      package.loaded["fastfn.core.lua_runtime"] = nil
      local routes = require("fastfn.core.routes")
      local lua_runtime = require("fastfn.core.lua_runtime")

      -- Test call with non-table
      local err_resp = lua_runtime.call("not a table")
      assert_eq(err_resp.status, 500, "non-table call returns 500")

      -- Test call with missing fn name
      local err_resp2 = lua_runtime.call({ fn = "", event = {} })
      assert_eq(err_resp2.status, 500, "empty fn name returns 500")

      -- Test sandbox: forbidden require
      local resp_bad = lua_runtime.call({ fn = "badmod", event = {} })
      assert_eq(resp_bad.status, 200, "forbidden require captured in handler")
      assert_true(type(resp_bad.body) == "string" and resp_bad.body:find("not allowed", 1, true) ~= nil, "forbidden module error")

      local resp_local = lua_runtime.call({ fn = "localmod", event = { params = { name = "Lua" } } })
      assert_eq(resp_local.status, 200, "local require status")
      assert_eq(resp_local.body, "hello Lua", "local require body")
      assert_true(type(resp_local.stdout) == "string" and resp_local.stdout:find("helper", 1, true) ~= nil, "local require stdout")

      -- Test table handler
      local resp_tbl = lua_runtime.call({ fn = "tblhandler", event = {} })
      assert_eq(resp_tbl.status, 200, "table handler status")
      assert_eq(resp_tbl.body, "from table handler", "table handler body")

      -- Test base64 response
      local resp_b64 = lua_runtime.call({ fn = "base64resp", event = {} })
      assert_eq(resp_b64.status, 200, "base64 response status")
      assert_eq(resp_b64.is_base64, true, "base64 flag")
      assert_eq(resp_b64.body_base64, "aGVsbG8=", "base64 body")

      -- Test body as table (auto-JSON)
      local resp_body = lua_runtime.call({ fn = "bodyresp", event = {} })
      assert_eq(resp_body.status, 200, "body table response status")
      assert_true(type(resp_body.body) == "string", "body table auto-encoded")

      -- Test proxy response
      local resp_proxy = lua_runtime.call({ fn = "proxyresp", event = {} })
      assert_eq(resp_proxy.status, 200, "proxy response status")
      assert_true(type(resp_proxy.proxy) == "table", "proxy field preserved")

      -- Test print capture
      local resp_print = lua_runtime.call({ fn = "sandbox", event = {} })
      assert_eq(resp_print.status, 200, "sandbox print status")
      assert_true(type(resp_print.stdout) == "string" and resp_print.stdout:find("hello", 1, true) ~= nil, "stdout captured")
    end)

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

local function test_jobs_retry_backoff_and_result_expiry()
  with_fake_ngx(function(cache, conc, set_now)
    local call_count = 0
    local jobs_base = "/tmp/fastfn-jobs-test-" .. tostring(math.random(100000, 999999))
    os.execute("mkdir -p " .. jobs_base .. "/jobs")
    local routes_stub = {
      get_config = function()
        return {
          functions_root = "/tmp",
          socket_base_dir = jobs_base,
          runtimes = { lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true } },
        }
      end,
      discover_functions = function()
        return {
          runtimes = {
            lua = {
              functions = {
                retrier = { has_default = true, versions = {}, policy = { methods = { "POST" } }, versions_policy = {} },
              },
            },
          },
          mapped_routes = {
            ["/retrier"] = { runtime = "lua", fn_name = "retrier", version = nil, methods = { "POST" } },
          },
        }
      end,
      resolve_named_target = function(name, version) if name == "retrier" then return "lua", version end return nil end,
      resolve_function_policy = function(rt, name, _v)
        if rt == "lua" and name == "retrier" then return { methods = { "POST" }, timeout_ms = 500 } end
        return nil, "not found"
      end,
      get_runtime_config = function(rt) if rt == "lua" then return { socket = "inprocess:lua", in_process = true, timeout_ms = 2500 } end return nil end,
      runtime_is_up = function() return true end,
      check_runtime_health = function() return true, "ok" end,
      set_runtime_health = function() end,
      runtime_is_in_process = function(_, cfg) return cfg and cfg.in_process == true end,
    }
    local invoke_rules_stub = { normalize_route = function(r) return r end }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.invoke_rules"] = invoke_rules_stub,
      ["fastfn.core.limits"] = { try_acquire = function() return true end, release = function() end },
      ["fastfn.core.lua_runtime"] = { call = function()
        call_count = call_count + 1
        if call_count <= 2 then
          return { status = 500, headers = {}, body = '{"error":"fail"}' }
        end
        return { status = 200, headers = {}, body = '{"ok":true}' }
      end },
      ["fastfn.core.client"] = { call_unix = function() return nil, "connect_error", "down" end },
      ["fastfn.core.gateway_utils"] = {
        map_runtime_error = function(code) return 502, "runtime error" end,
        resolve_numeric = function(a, b, c, d) return tonumber(a) or tonumber(b) or tonumber(c) or d end,
      },
    }, function()
      package.loaded["fastfn.core.jobs"] = nil
      local jobs = require("fastfn.core.jobs")

      -- Enqueue with retry
      set_now(1000)
      local meta, status = jobs.enqueue({
        name = "retrier",
        method = "POST",
        body = '{"test":true}',
        max_attempts = 3,
        retry_delay_ms = 100,
      })
      assert_eq(status, 201, "enqueue status")
      assert_true(type(meta) == "table", "enqueue meta table")
      assert_eq(meta.status, "queued", "enqueue meta status")

      -- List jobs
      local list = jobs.list(10)
      assert_true(type(list) == "table" and #list >= 1, "list should have jobs")

      -- Get job
      local got = jobs.get(meta.id)
      assert_true(type(got) == "table", "get job by id")
      assert_eq(got.id, meta.id, "get job id matches")

      -- Cancel a queued job
      local cancel_meta, cancel_status = jobs.cancel(meta.id)
      assert_eq(cancel_status, 200, "cancel status")
      assert_eq(cancel_meta.status, "canceled", "cancel meta status")

      -- Cancel non-existent job
      local _, cancel_err_status, cancel_err = jobs.cancel("nonexistent-id")
      assert_eq(cancel_err_status, 404, "cancel nonexistent status")

      -- Cancel already-canceled job
      local _, recancel_status, recancel_err = jobs.cancel(meta.id)
      assert_eq(recancel_status, 409, "re-cancel status")

      -- read_result for non-existent job
      local no_result = jobs.read_result("nonexistent-id")
      assert_eq(no_result, nil, "no result for nonexistent job")

      -- Enqueue with disabled jobs
      with_env({ FN_JOBS_ENABLED = "0" }, function()
        package.loaded["fastfn.core.jobs"] = nil
        local jobs2 = require("fastfn.core.jobs")
        local _, ds, de = jobs2.enqueue({ name = "retrier", method = "POST" })
        assert_eq(ds, 404, "disabled jobs status")
      end)

      -- Enqueue with invalid payload
      local _, bad_status, bad_err = jobs.enqueue("not a table")
      assert_eq(bad_status, 400, "non-table payload status")

      -- Enqueue with missing name
      local _, nn_status = jobs.enqueue({ method = "GET" })
      assert_eq(nn_status, 400, "missing name status")

      -- Enqueue with unsupported method
      local _, mm_status = jobs.enqueue({ name = "retrier", method = "OPTIONS" })
      assert_eq(mm_status, 400, "unsupported method status")

      -- Enqueue with invalid version
      local _, vv_status = jobs.enqueue({ name = "retrier", method = "POST", version = "bad version!" })
      assert_eq(vv_status, 400, "invalid version status")

      -- Test list edge cases
      local list_zero = jobs.list(0)
      assert_true(type(list_zero) == "table", "list with 0 returns table")

      local list_huge = jobs.list(999)
      assert_true(type(list_huge) == "table", "list with huge limit returns table")

      reset_shared_dict(cache)
      reset_shared_dict(conc)
    end)
  end)
end

local function test_client_large_and_invalid_frames()
  with_fake_ngx(function(cache, conc, _set_now)
    package.loaded["fastfn.core.client"] = nil
    local client = require("fastfn.core.client")
    local cjson = require("cjson.safe")

    -- Test with nil/non-encodable request (cjson.encode returns nil)
    -- We need a value that cjson fails on - a function
    local r1, c1, m1 = client.call_unix("unix:/tmp/nonexistent.sock", { fn = function() end }, 100)
    assert_eq(r1, nil, "unencodable request should fail")
    assert_eq(c1, "invalid_request", "unencodable error code")

    -- Test with normal request to non-existent socket (connect error)
    local r2, c2, m2 = client.call_unix("unix:/tmp/nonexistent.sock", { fn = "test" }, 100)
    assert_eq(r2, nil, "connect to nonexistent should fail")
    assert_eq(c2, "connect_error", "connect error code")

    -- Test timeout detection
    local r3, c3, m3 = client.call_unix("unix:/tmp/nonexistent.sock", { fn = "test" }, 50)
    assert_eq(r3, nil, "low timeout should fail")

    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

local function test_ui_state_endpoint_malformed_requests()
  with_fake_ngx(function(cache, conc, _set_now)
    local auth_stub = {
      login_enabled = function() return false end,
      api_login_enabled = function() return false end,
      read_session = function() return nil end,
    }

    with_module_stubs({
      ["fastfn.console.auth"] = auth_stub,
    }, function()
      package.loaded["fastfn.console.guard"] = nil
      local guard = require("fastfn.console.guard")

      -- Test update_state with non-table payload
      local u1, e1 = guard.update_state("not a table")
      assert_eq(u1, nil, "update non-table should fail")
      assert_true(type(e1) == "string", "update non-table error msg")

      -- Test update_state with non-boolean field
      local u2, e2 = guard.update_state({ ui_enabled = "yes" })
      assert_eq(u2, nil, "update non-boolean should fail")
      assert_true(type(e2) == "string" and e2:find("must be boolean", 1, true) ~= nil, "non-boolean error msg")

      -- Test state_snapshot returns all fields
      local snap = guard.state_snapshot()
      assert_true(type(snap) == "table", "snapshot is table")
      assert_true(snap.ui_enabled == false or snap.ui_enabled == true, "snapshot has ui_enabled")
      assert_true(snap.api_enabled == false or snap.api_enabled == true, "snapshot has api_enabled")

      -- Test clear_state
      local cleared = guard.clear_state()
      assert_true(type(cleared) == "table", "clear returns snapshot")

      -- Test write_json
      guard.write_json(200, { ok = true })
      assert_eq(ngx.status, 200, "write_json sets status")
    end)

    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

local function test_console_guard_token_expiry_and_role_escalation()
  with_fake_ngx(function(cache, conc, _set_now)
    local session_data = nil
    local auth_stub = {
      login_enabled = function() return true end,
      api_login_enabled = function() return true end,
      read_session = function() return session_data end,
    }

    with_module_stubs({
      ["fastfn.console.auth"] = auth_stub,
    }, function()
      package.loaded["fastfn.console.guard"] = nil
      local guard = require("fastfn.console.guard")

      -- Test request_has_admin_token with no token set
      with_env({ FN_ADMIN_TOKEN = false }, function()
        assert_eq(guard.request_has_admin_token(), false, "no admin token set")
      end)

      -- Test request_has_admin_token with wrong token
      with_env({ FN_ADMIN_TOKEN = "correct-token" }, function()
        ngx.req.get_headers = function()
          return { ["x-fn-admin-token"] = "wrong-token" }
        end
        assert_eq(guard.request_has_admin_token(), false, "wrong admin token")
      end)

      -- Test request_has_admin_token with correct token
      with_env({ FN_ADMIN_TOKEN = "correct-token" }, function()
        ngx.req.get_headers = function()
          return { ["x-fn-admin-token"] = "correct-token" }
        end
        assert_eq(guard.request_has_admin_token(), true, "correct admin token")
      end)

      -- Test request_has_session with nil session
      session_data = nil
      assert_eq(guard.request_has_session(), false, "no session")

      -- Test current_session_user with valid session
      session_data = { user = "admin" }
      assert_eq(guard.current_session_user(), "admin", "session user")

      -- Test current_session_user with empty user
      session_data = { user = "" }
      assert_eq(guard.current_session_user(), nil, "empty session user")

      -- Test current_session_user with non-table session
      session_data = "invalid"
      assert_eq(guard.current_session_user(), nil, "non-table session user")

      -- Test enforce_api with api disabled
      with_env({ FN_CONSOLE_API_ENABLED = "0" }, function()
        cache:delete("console:api_enabled")
        package.loaded["fastfn.console.guard"] = nil
        local guard2 = require("fastfn.console.guard")
        assert_eq(guard2.enforce_api(), false, "api disabled enforcement")
      end)

      -- Test enforce_ui with ui disabled
      with_env({ FN_UI_ENABLED = "0" }, function()
        cache:delete("console:ui_enabled")
        package.loaded["fastfn.console.guard"] = nil
        local guard3 = require("fastfn.console.guard")
        assert_eq(guard3.enforce_ui(), false, "ui disabled enforcement")
      end)

      -- Test enforce_write with write disabled and no admin token
      with_env({ FN_CONSOLE_WRITE_ENABLED = "0", FN_ADMIN_TOKEN = false }, function()
        cache:delete("console:write_enabled")
        ngx.req.get_headers = function() return {} end
        package.loaded["fastfn.console.guard"] = nil
        local guard4 = require("fastfn.console.guard")
        assert_eq(guard4.enforce_write(), false, "write disabled enforcement")
      end)

      -- Test request_is_local with various IPs
      ngx.var.remote_addr = "192.168.1.1"
      assert_eq(guard.request_is_local(), true, "private IP 192.168")

      ngx.var.remote_addr = "10.0.0.1"
      assert_eq(guard.request_is_local(), true, "private IP 10.x")

      ngx.var.remote_addr = "172.16.0.1"
      assert_eq(guard.request_is_local(), true, "private IP 172.16")

      ngx.var.remote_addr = "172.31.255.1"
      assert_eq(guard.request_is_local(), true, "private IP 172.31")

      ngx.var.remote_addr = "172.32.0.1"
      assert_eq(guard.request_is_local(), false, "non-private IP 172.32")

      ngx.var.remote_addr = "8.8.8.8"
      assert_eq(guard.request_is_local(), false, "public IP")

      ngx.var.remote_addr = "::1"
      assert_eq(guard.request_is_local(), true, "IPv6 loopback")

      ngx.var.remote_addr = "fc00::1"
      assert_eq(guard.request_is_local(), true, "IPv6 fc00 ULA")

      ngx.var.remote_addr = "fd00::1"
      assert_eq(guard.request_is_local(), true, "IPv6 fd00 ULA")

      ngx.var.remote_addr = "fe80::1"
      assert_eq(guard.request_is_local(), true, "IPv6 link-local")

      ngx.var.remote_addr = ""
      assert_eq(guard.request_is_local(), false, "empty IP")
    end)

    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

local function test_home_missing_env_and_empty_functions()
  with_fake_ngx(function(cache, conc, _set_now)
    package.loaded["fastfn.core.home"] = nil
    local home = require("fastfn.core.home")

    -- Test resolve_home_action with no env vars and no config
    with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = false, FN_FUNCTIONS_ROOT = false }, function()
      local action = home.resolve_home_action(nil)
      assert_eq(action.mode, "default", "default mode with no config")
      assert_eq(action.source, "builtin", "builtin source")
    end)

    -- Test resolve_home_action with invalid FN_HOME_FUNCTION (http URL)
    with_env({ FN_HOME_FUNCTION = "http://evil.com", FN_HOME_REDIRECT = false, FN_FUNCTIONS_ROOT = false }, function()
      local action = home.resolve_home_action(nil)
      assert_eq(action.mode, "default", "http URL in FN_HOME_FUNCTION falls through")
      assert_true(#action.warnings > 0, "warning about ignored FN_HOME_FUNCTION")
    end)

    -- Test resolve_home_action with FN_HOME_FUNCTION pointing to /
    with_env({ FN_HOME_FUNCTION = "/", FN_HOME_REDIRECT = false, FN_FUNCTIONS_ROOT = false }, function()
      local action = home.resolve_home_action(nil)
      assert_eq(action.mode, "default", "root path FN_HOME_FUNCTION falls through")
    end)

    -- Test resolve_home_action with valid FN_HOME_FUNCTION
    with_env({ FN_HOME_FUNCTION = "/my-fn", FN_HOME_REDIRECT = false, FN_FUNCTIONS_ROOT = false }, function()
      local action = home.resolve_home_action(nil)
      assert_eq(action.mode, "function", "valid FN_HOME_FUNCTION mode")
      assert_eq(action.path, "/my-fn", "valid FN_HOME_FUNCTION path")
    end)

    -- Test resolve_home_action with FN_HOME_REDIRECT http URL
    with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = "https://example.com", FN_FUNCTIONS_ROOT = false }, function()
      local action = home.resolve_home_action(nil)
      assert_eq(action.mode, "redirect", "redirect mode for http URL")
      assert_eq(action.location, "https://example.com", "redirect location")
    end)

    -- Test resolve_home_action with FN_HOME_REDIRECT local path
    with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = "/dashboard", FN_FUNCTIONS_ROOT = false }, function()
      local action = home.resolve_home_action(nil)
      assert_eq(action.mode, "redirect", "redirect mode for local path")
      assert_eq(action.location, "/dashboard", "redirect location local")
    end)

    -- Test resolve_home_action with empty FN_HOME_REDIRECT
    with_env({ FN_HOME_FUNCTION = false, FN_HOME_REDIRECT = "", FN_FUNCTIONS_ROOT = false }, function()
      local action = home.resolve_home_action(nil)
      assert_eq(action.mode, "default", "empty redirect falls through")
    end)

    -- Test extract_home_spec with nil
    local spec_nil = home.extract_home_spec(nil)
    assert_eq(spec_nil, nil, "extract_home_spec nil")

    -- Test extract_home_spec with nested invoke paths
    local spec_invoke = home.extract_home_spec({
      invoke = {
        home = { ["function"] = "/hello" },
      },
    })
    assert_true(type(spec_invoke) == "table", "extract_home_spec invoke.home")
    assert_eq(spec_invoke.home_function, "/hello", "invoke.home.function")

    -- Test extract_home_spec with redirect
    local spec_redirect = home.extract_home_spec({
      home = { redirect = "https://example.com" },
    })
    assert_true(type(spec_redirect) == "table", "extract_home_spec redirect")
    assert_eq(spec_redirect.home_redirect, "https://example.com", "home.redirect")

    -- Test extract_home_spec with string home value
    local spec_string = home.extract_home_spec({
      home = "/api",
    })
    assert_true(type(spec_string) == "table", "extract_home_spec string home")
    assert_eq(spec_string.home_function, "/api", "string home function")

    -- Test extract_home_spec with invoke.home-route fallback
    local spec_hr = home.extract_home_spec({
      invoke = { ["home-route"] = "/fallback" },
    })
    assert_true(type(spec_hr) == "table", "extract_home_spec home-route")
    assert_eq(spec_hr.home_function, "/fallback", "home-route function")

    -- Test extract_home_spec with invoke.home_route fallback
    local spec_hr2 = home.extract_home_spec({
      invoke = { home_route = "/fallback2" },
    })
    assert_true(type(spec_hr2) == "table", "extract_home_spec home_route")
    assert_eq(spec_hr2.home_function, "/fallback2", "home_route function")

    -- Test extract_home_spec with empty table
    local spec_empty = home.extract_home_spec({})
    assert_eq(spec_empty, nil, "extract_home_spec empty table")

    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

local function test_openapi_all_parameter_types_and_schemas()
  with_fake_ngx(function(cache, conc, _set_now)
    package.loaded["fastfn.core.openapi"] = nil
    local openapi = require("fastfn.core.openapi")
    local cjson = require("cjson.safe")

    -- Build with a catalog that has various route shapes
    local catalog = {
      runtimes = {
        lua = {
          functions = {
            simple = {
              has_default = true,
              versions = {},
              policy = { methods = { "GET", "POST" }, routes = { "/simple" } },
              versions_policy = {},
            },
            paramfn = {
              has_default = true,
              versions = {},
              policy = { methods = { "GET" }, routes = { "/param/:id" } },
              versions_policy = {},
            },
            catchfn = {
              has_default = true,
              versions = { "v1" },
              policy = { methods = { "GET" }, routes = { "/catch/:path*" } },
              versions_policy = {
                v1 = { methods = { "POST" }, routes = { "/catch/v1/:path*" } },
              },
            },
            wildcfn = {
              has_default = true,
              versions = {},
              policy = { methods = { "DELETE" }, routes = { "/wild/*" } },
              versions_policy = {},
            },
          },
        },
      },
      mapped_routes = {
        ["/simple"] = { runtime = "lua", fn_name = "simple", methods = { "GET", "POST" } },
        ["/param/:id"] = { runtime = "lua", fn_name = "paramfn", methods = { "GET" } },
        ["/catch/:path*"] = { runtime = "lua", fn_name = "catchfn", methods = { "GET" } },
        ["/catch/v1/:path*"] = { runtime = "lua", fn_name = "catchfn", version = "v1", methods = { "POST" } },
        ["/wild/*"] = { runtime = "lua", fn_name = "wildcfn", methods = { "DELETE" } },
      },
      mapped_route_conflicts = {},
    }

    local spec = openapi.build(catalog, { server_url = "http://test:8080" })
    assert_true(type(spec) == "table", "openapi spec is table")
    assert_eq(spec.openapi, "3.1.0", "openapi version")
    assert_true(type(spec.paths) == "table", "paths is table")

    -- Check that parameterized routes are converted
    local param_path = spec.paths["/param/{id}"]
    assert_true(type(param_path) == "table", "param path exists")

    -- Check catch-all paths
    local catch_path = spec.paths["/catch/{path}"]
    assert_true(type(catch_path) == "table", "catch-all path exists")

    -- Check wildcard path
    local wild_path = spec.paths["/wild/{wildcard}"]
    assert_true(type(wild_path) == "table", "wildcard path exists")

    -- Check that DELETE has requestBody
    if wild_path and wild_path.delete then
      assert_true(wild_path.delete.requestBody ~= nil, "DELETE has requestBody")
    end

    -- Verify JSON encoding works
    local encoded = cjson.encode(spec)
    assert_true(type(encoded) == "string" and #encoded > 100, "openapi spec encodes to JSON")

    -- Test build with empty catalog
    local empty_spec = openapi.build({ runtimes = {}, mapped_routes = {}, mapped_route_conflicts = {} })
    assert_true(type(empty_spec) == "table", "empty catalog produces valid spec")

    -- Test with public_mode options
    local pub_spec = openapi.build(catalog, { public_mode = true })
    assert_true(type(pub_spec) == "table", "public mode spec is table")

    -- Test with invoke_meta containing query_example and body_example
    local meta_catalog = {
      runtimes = {
        lua = {
          functions = {
            metafn = {
              has_default = true,
              versions = {},
              policy = {
                methods = { "POST" },
                routes = { "/meta" },
                invoke_meta = {
                  summary = "Custom summary",
                  query_example = { page = 1, filter = "active" },
                  body_example = '{"name":"test"}',
                  content_type = "application/json",
                },
              },
              versions_policy = {},
            },
            textfn = {
              has_default = true,
              versions = {},
              policy = {
                methods = { "PUT" },
                routes = { "/text" },
                invoke_meta = {
                  body_example = "plain text",
                  content_type = "text/plain",
                },
              },
              versions_policy = {},
            },
          },
        },
      },
      mapped_routes = {
        ["/meta"] = { runtime = "lua", fn_name = "metafn", methods = { "POST" } },
        ["/text"] = { runtime = "lua", fn_name = "textfn", methods = { "PUT" } },
      },
      mapped_route_conflicts = {},
    }

    local meta_spec = openapi.build(meta_catalog)
    assert_true(type(meta_spec) == "table", "meta spec is table")

    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

local function test_invoke_rules_empty_route_table_and_missing_handler()
  local invoke_rules = require("fastfn.core.invoke_rules")

  -- Test parse_methods with string
  local m1 = invoke_rules.parse_methods("GET, POST, DELETE")
  assert_true(type(m1) == "table" and #m1 == 3, "parse_methods string")

  -- Test parse_methods with invalid methods
  local m2 = invoke_rules.parse_methods("OPTIONS, HEAD")
  assert_eq(m2, nil, "parse_methods invalid returns nil")

  -- Test parse_methods with empty table
  local m3 = invoke_rules.parse_methods({})
  assert_eq(m3, nil, "parse_methods empty table returns nil")

  -- Test parse_methods with empty string
  local m4 = invoke_rules.parse_methods("")
  assert_eq(m4, nil, "parse_methods empty string returns nil")

  -- Test normalized_methods with fallback
  local nm1 = invoke_rules.normalized_methods(nil, { "POST" })
  assert_true(type(nm1) == "table" and nm1[1] == "POST", "normalized_methods uses fallback")

  local nm2 = invoke_rules.normalized_methods({ "GET" }, nil)
  assert_true(type(nm2) == "table" and nm2[1] == "GET", "normalized_methods uses provided")

  -- Test route_is_reserved
  assert_eq(invoke_rules.route_is_reserved("/"), true, "root is reserved")
  assert_eq(invoke_rules.route_is_reserved("/_fn"), true, "/_fn is reserved")
  assert_eq(invoke_rules.route_is_reserved("/_fn/health"), true, "/_fn/health is reserved")
  assert_eq(invoke_rules.route_is_reserved("/console"), true, "/console is reserved")
  assert_eq(invoke_rules.route_is_reserved("/console/api"), true, "/console/api is reserved")
  assert_eq(invoke_rules.route_is_reserved("/my-api"), false, "/my-api is not reserved")

  -- Test normalize_route
  assert_eq(invoke_rules.normalize_route(nil), nil, "normalize nil route")
  assert_eq(invoke_rules.normalize_route(""), nil, "normalize empty route")
  assert_eq(invoke_rules.normalize_route("no-slash"), nil, "normalize no leading slash")
  assert_eq(invoke_rules.normalize_route("/.."), nil, "normalize dot-dot")
  assert_eq(invoke_rules.normalize_route("/_fn/test"), nil, "normalize reserved prefix")
  assert_eq(invoke_rules.normalize_route("/"), nil, "normalize root reserved")
  local n1 = invoke_rules.normalize_route("/hello//world/")
  assert_eq(n1, "/hello/world", "normalize collapses slashes and strips trailing")

  -- Test parse_route_list
  local rl1 = invoke_rules.parse_route_list("/a")
  assert_true(type(rl1) == "table" and #rl1 == 1, "parse_route_list single string")
  assert_eq(rl1[1], "/a", "parse_route_list single value")

  local rl2 = invoke_rules.parse_route_list({ "/b", "/c", "/b" })
  assert_true(type(rl2) == "table" and #rl2 == 2, "parse_route_list deduplicates")

  local rl3 = invoke_rules.parse_route_list({ "/d", "/e", "/f" }, 2)
  assert_true(type(rl3) == "table" and #rl3 == 2, "parse_route_list respects max_items")

  -- Test parse_invoke_routes
  local ir1 = invoke_rules.parse_invoke_routes(nil)
  assert_eq(ir1, nil, "parse_invoke_routes nil input")

  local ir2 = invoke_rules.parse_invoke_routes({ route = "/api" })
  assert_true(type(ir2) == "table" and #ir2 == 1, "parse_invoke_routes with route")

  local ir3 = invoke_rules.parse_invoke_routes({ routes = { "/a", "/b" } })
  assert_true(type(ir3) == "table" and #ir3 == 2, "parse_invoke_routes with routes table")

  local ir4 = invoke_rules.parse_invoke_routes({ route = "/_fn/invalid" })
  assert_true(type(ir4) == "table" and #ir4 == 0, "parse_invoke_routes all invalid returns empty")

  local ir5 = invoke_rules.parse_invoke_routes({})
  assert_eq(ir5, nil, "parse_invoke_routes empty table returns nil")
end

local function test_public_workloads_helpers_and_trusted_proxies()
  with_fake_ngx(function()
    package.loaded["fastfn.http.public_workloads"] = nil
    local helpers = require("fastfn.http.public_workloads")

    local sanitized = helpers.sanitize_request_headers({
      Host = "example.com",
      ["X-Test"] = "ok",
      ["Connection"] = "close",
      ["X-Bad"] = "bad\r\nvalue",
    })
    assert_eq(sanitized.Host, nil, "public workload sanitize strips host")
    assert_eq(sanitized["Connection"], nil, "public workload sanitize strips connection")
    assert_eq(sanitized["X-Test"], "ok", "public workload sanitize keeps safe header")
    assert_eq(sanitized["X-Bad"], nil, "public workload sanitize strips invalid header value")

    ngx.var.http_x_forwarded_host = "api.example.com:8443, proxy.example.com"
    ngx.var.http_host = "ignored.example.com"
    ngx.var.host = "fallback.example.com"
    local req_host, req_authority = helpers.request_host_values(ngx)
    assert_eq(req_host, "api.example.com", "public workload request host forwarded host")
    assert_eq(req_authority, "api.example.com:8443", "public workload request host forwarded authority")

    ngx.var.remote_addr = "127.0.0.1"
    ngx.var.http_x_forwarded_for = "198.51.100.10, 127.0.0.1"
    with_env({ FN_TRUSTED_PROXY_CIDRS = "127.0.0.0/8" }, function()
      assert_eq(helpers.request_client_ip(ngx), "198.51.100.10", "public workload trusted proxy xff client ip")
    end)

    ngx.var.remote_addr = "8.8.8.8"
    with_env({ FN_TRUSTED_PROXY_CIDRS = "127.0.0.0/8" }, function()
      assert_eq(helpers.request_client_ip(ngx), "8.8.8.8", "public workload untrusted proxy keeps remote addr")
    end)

    ngx.var.remote_addr = "127.0.0.1"
    ngx.var.http_x_forwarded_for = "not-an-ip"
    with_env({ FN_TRUSTED_PROXY_CIDRS = "127.0.0.0/8" }, function()
      assert_eq(helpers.request_client_ip(ngx), "127.0.0.1", "public workload invalid xff falls back to remote addr")
    end)
    ngx.var.http_x_forwarded_for = nil

    assert_eq(helpers.cidr_contains_ip("10.0.0.0/8", "10.1.2.3"), true, "public workload cidr allow")
    assert_eq(helpers.cidr_contains_ip("10.0.0.0/8", "192.0.2.3"), false, "public workload cidr deny")

    local best_workload, best_endpoint, best_err = helpers.match_public_workload({
      {
        workload = { name = "api", health = { up = true } },
        endpoint = {
          host = "127.0.0.1",
          port = 18081,
          allow_hosts = { "api.example.com" },
          allow_cidrs = { "10.10.0.0/16" },
        },
        route_length = 7,
      },
      {
        workload = { name = "wildcard", health = { up = true } },
        endpoint = {
          host = "127.0.0.1",
          port = 18082,
          allow_hosts = { "*.example.com" },
          allow_cidrs = { "10.0.0.0/8" },
        },
        route_length = 3,
      },
    }, "api.example.com", "api.example.com", "10.10.1.50")
    assert_eq(best_workload.name, "api", "public workload match picks most specific candidate")
    assert_eq(best_endpoint.port, 18081, "public workload match endpoint")
    assert_eq(best_err, nil, "public workload match error")

    local denied_workload, denied_endpoint, denied_err = helpers.match_public_workload({
      {
        workload = { name = "api", health = { up = true } },
        endpoint = {
          host = "127.0.0.1",
          port = 18081,
          allow_hosts = { "api.example.com" },
          allow_cidrs = { "10.10.0.0/16" },
        },
        route_length = 7,
      },
    }, "api.example.com", "api.example.com", "192.0.2.10")
    assert_eq(denied_workload, nil, "public workload deny returns nil workload")
    assert_eq(denied_endpoint, nil, "public workload deny returns nil endpoint")
    assert_eq(denied_err, "ip not allowed", "public workload deny reason")
  end)
end

-- Forward declarations for coverage gap tests
local test_guard_request_is_local_all_ranges
local test_guard_constant_time_eq_edge_cases
local test_guard_enforce_csrf_post_without_header
local test_console_auth_password_hash_and_secret
local test_console_auth_internal_edge_cases
local test_core_fs_shell_free_helpers
local test_guard_console_rate_limits
local test_guard_update_state_store_unavailable
local test_ui_state_endpoint_remaining_branches
local test_invoke_rules_remaining_branches
local test_jobs_remaining_coverage_gaps
local test_data_remaining_coverage_gaps
local test_routes_remaining_coverage_gaps
local test_scheduler_remaining_coverage_gaps
local test_public_assets_support_and_gateway
local test_console_login_endpoint_rate_limit_env_and_reset

local function main()
  local trace_enabled = tostring(os.getenv("FASTFN_LUA_TEST_TRACE") or "") == "1"
  local function run_test(name, fn)
    if trace_enabled then
      io.stdout:write("[lua-runner] start " .. tostring(name) .. "\n")
      io.stdout:flush()
    end
    fn()
    if trace_enabled then
      io.stdout:write("[lua-runner] done " .. tostring(name) .. "\n")
      io.stdout:flush()
    end
  end

  run_test("test_gateway_utils", test_gateway_utils)
  run_test("test_fn_limits", test_fn_limits)
  run_test("test_invoke_rules", test_invoke_rules)
  run_test("test_home_rules", test_home_rules)
  run_test("test_openapi_builder", test_openapi_builder)
  run_test("test_openapi_internal_helpers_and_public_mode", test_openapi_internal_helpers_and_public_mode)
  run_test("test_ui_state_endpoint_guards", test_ui_state_endpoint_guards)
  run_test("test_ui_state_endpoint_full_behavior", test_ui_state_endpoint_full_behavior)
  run_test("test_ui_state_endpoint_error_paths", test_ui_state_endpoint_error_paths)
  run_test("test_console_guard_state_snapshot_current_user", test_console_guard_state_snapshot_current_user)
  run_test("test_console_guard_enforcement_and_state_overrides", test_console_guard_enforcement_and_state_overrides)
  run_test("test_console_guard_additional_paths", test_console_guard_additional_paths)
  run_test("test_routes_discovery_and_host_routing", test_routes_discovery_and_host_routing)
  run_test("test_routes_skip_disabled_runtime_file_routes", test_routes_skip_disabled_runtime_file_routes)
  run_test("test_routes_nested_project_root_scan_with_file_routes", test_routes_nested_project_root_scan_with_file_routes)
  run_test("test_routes_force_url_policy_override", test_routes_force_url_policy_override)
  run_test("test_routes_force_url_ignored_for_version_scoped_configs", test_routes_force_url_ignored_for_version_scoped_configs)
  run_test("test_routes_force_url_breaks_policy_ties", test_routes_force_url_breaks_policy_ties)
  run_test("test_routes_force_url_global_env_policy_override", test_routes_force_url_global_env_policy_override)
  run_test("test_routes_force_url_global_env_keeps_policy_policy_conflict", test_routes_force_url_global_env_keeps_policy_policy_conflict)
  run_test("test_routes_policy_routes_disjoint_allow_hosts", test_routes_policy_routes_disjoint_allow_hosts)
  run_test("test_routes_dynamic_order_is_deterministic_and_specific", test_routes_dynamic_order_is_deterministic_and_specific)
  run_test("test_routes_file_exists_regression", test_routes_file_exists_regression)
  run_test("test_routes_internal_helpers_and_edge_cases", test_routes_internal_helpers_and_edge_cases)
  run_test("test_routes_runtime_config_and_init_edge_paths", test_routes_runtime_config_and_init_edge_paths)
  run_test("test_console_data_crud_and_secrets", test_console_data_crud_and_secrets)
  run_test("test_console_data_validation_edges_and_helpers", test_console_data_validation_edges_and_helpers)
  run_test("test_console_data_file_operations", test_console_data_file_operations)
  run_test("test_console_data_catalog_edge_cases", test_console_data_catalog_edge_cases)
  run_test("test_console_data_additional_internal_paths", test_console_data_additional_internal_paths)
  run_test("test_console_data_additional_mutation_paths", test_console_data_additional_mutation_paths)
  run_test("test_console_data_additional_file_paths", test_console_data_additional_file_paths)
  run_test("test_console_data_additional_helper_and_resolve_paths", test_console_data_additional_helper_and_resolve_paths)
  run_test("test_console_data_additional_mutation_failure_paths", test_console_data_additional_mutation_failure_paths)
  run_test("test_console_data_ensure_dir_fallback_paths", test_console_data_ensure_dir_fallback_paths)
  run_test("test_core_client_frame_protocol", test_core_client_frame_protocol)
  run_test("test_core_http_client_request_paths", test_core_http_client_request_paths)
  run_test("test_jobs_module_queue_and_result", test_jobs_module_queue_and_result)
  run_test("test_jobs_internal_helpers_and_edge_cases", test_jobs_internal_helpers_and_edge_cases)
  run_test("test_scheduler_tick_and_snapshot", test_scheduler_tick_and_snapshot)
  run_test("test_scheduler_cron_and_retry_backoff", test_scheduler_cron_and_retry_backoff)
  run_test("test_scheduler_cron_timezone_and_invalid_timezone", test_scheduler_cron_timezone_and_invalid_timezone)
  run_test("test_scheduler_internal_cron_helpers", test_scheduler_internal_cron_helpers)
  run_test("test_scheduler_persist_state_roundtrip", test_scheduler_persist_state_roundtrip)
  run_test("test_scheduler_additional_edge_paths_for_coverage", test_scheduler_additional_edge_paths_for_coverage)
  run_test("test_watchdog_mock_linux_backend", test_watchdog_mock_linux_backend)
  run_test("test_watchdog_guardrails", test_watchdog_guardrails)
  run_test("test_watchdog_internal_error_paths", test_watchdog_internal_error_paths)
  run_test("test_watchdog_event_reload_paths", test_watchdog_event_reload_paths)
  run_test("test_lua_runtime_in_process", test_lua_runtime_in_process)
  run_test("test_lua_runtime_print_capture", test_lua_runtime_print_capture)
  run_test("test_lua_runtime_session_passthrough", test_lua_runtime_session_passthrough)
  run_test("test_lua_runtime_os_time_date", test_lua_runtime_os_time_date)
  run_test("test_lua_runtime_params_injection", test_lua_runtime_params_injection)
  run_test("test_lua_runtime_internal_error_paths", test_lua_runtime_internal_error_paths)
  run_test("test_console_security", function()
    dofile(REPO_ROOT .. "/tests/unit/test-console-security.lua")
  end)
  run_test("test_console_data_secret_masking_and_path_traversal", test_console_data_secret_masking_and_path_traversal)
  run_test("test_routes_wildcard_matching_and_error_formatting", test_routes_wildcard_matching_and_error_formatting)
  run_test("test_watchdog_poll_interval_and_permissions", test_watchdog_poll_interval_and_permissions)
  run_test("test_http_client_timeout_and_body_encoding", test_http_client_timeout_and_body_encoding)
  run_test("test_scheduler_disable_reenable_and_overlap", test_scheduler_disable_reenable_and_overlap)
  run_test("test_limits_release_edge_cases", test_limits_release_edge_cases)
  run_test("test_lua_runtime_module_caching_and_sandbox", test_lua_runtime_module_caching_and_sandbox)
  run_test("test_jobs_retry_backoff_and_result_expiry", test_jobs_retry_backoff_and_result_expiry)
  run_test("test_client_large_and_invalid_frames", test_client_large_and_invalid_frames)
  run_test("test_ui_state_endpoint_malformed_requests", test_ui_state_endpoint_malformed_requests)
  run_test("test_console_guard_token_expiry_and_role_escalation", test_console_guard_token_expiry_and_role_escalation)
  run_test("test_home_missing_env_and_empty_functions", test_home_missing_env_and_empty_functions)
  run_test("test_openapi_all_parameter_types_and_schemas", test_openapi_all_parameter_types_and_schemas)
  run_test("test_invoke_rules_empty_route_table_and_missing_handler", test_invoke_rules_empty_route_table_and_missing_handler)
  run_test("test_public_workloads_helpers_and_trusted_proxies", test_public_workloads_helpers_and_trusted_proxies)
  -- Coverage gap tests
  run_test("test_guard_request_is_local_all_ranges", test_guard_request_is_local_all_ranges)
  run_test("test_guard_constant_time_eq_edge_cases", test_guard_constant_time_eq_edge_cases)
  run_test("test_guard_enforce_csrf_post_without_header", test_guard_enforce_csrf_post_without_header)
  run_test("test_console_auth_password_hash_and_secret", test_console_auth_password_hash_and_secret)
  run_test("test_console_auth_internal_edge_cases", test_console_auth_internal_edge_cases)
  run_test("test_core_fs_shell_free_helpers", test_core_fs_shell_free_helpers)
  run_test("test_guard_console_rate_limits", test_guard_console_rate_limits)
  run_test("test_guard_update_state_store_unavailable", test_guard_update_state_store_unavailable)
  run_test("test_ui_state_endpoint_remaining_branches", test_ui_state_endpoint_remaining_branches)
  run_test("test_invoke_rules_remaining_branches", test_invoke_rules_remaining_branches)
  run_test("test_jobs_remaining_coverage_gaps", test_jobs_remaining_coverage_gaps)
  run_test("test_data_remaining_coverage_gaps", test_data_remaining_coverage_gaps)
  run_test("test_routes_remaining_coverage_gaps", test_routes_remaining_coverage_gaps)
  run_test("test_scheduler_remaining_coverage_gaps", test_scheduler_remaining_coverage_gaps)
  run_test("test_public_assets_support_and_gateway", test_public_assets_support_and_gateway)
  print("lua unit tests passed")
end

test_guard_request_is_local_all_ranges = function()
  with_fake_ngx(function()
    local cjson = require("cjson.safe")
    with_module_stubs({
      ["fastfn.console.auth"] = {
        login_enabled = function() return false end,
        api_login_enabled = function() return false end,
        read_session = function() return nil end,
      },
    }, function()
      package.loaded["fastfn.console.guard"] = nil
      local guard = require("fastfn.console.guard")

      local out = ""
      ngx.say = function(s) out = out .. tostring(s) end

      -- Empty IP
      ngx.var.remote_addr = ""
      ngx.req.get_headers = function() return {} end
      assert_eq(guard.request_is_local(), false, "empty IP should not be local")

      -- XFF present with local IP
      ngx.var.remote_addr = "127.0.0.1"
      ngx.req.get_headers = function() return { ["x-forwarded-for"] = "10.0.0.1" } end
      assert_eq(guard.request_is_local(), false, "XFF present should refuse local trust")

      -- Reset headers for remaining tests
      ngx.req.get_headers = function() return {} end

      -- IPv6 fc range
      ngx.var.remote_addr = "fc00::1"
      assert_eq(guard.request_is_local(), true, "fc00:: should be local")

      -- IPv6 fd range
      ngx.var.remote_addr = "fd12:3456::1"
      assert_eq(guard.request_is_local(), true, "fd:: should be local")

      -- IPv6 fe80 link-local
      ngx.var.remote_addr = "fe80::1"
      assert_eq(guard.request_is_local(), true, "fe80:: should be local")

      -- 172.16-31 range
      ngx.var.remote_addr = "172.16.0.1"
      assert_eq(guard.request_is_local(), true, "172.16.x should be local")
      ngx.var.remote_addr = "172.31.255.255"
      assert_eq(guard.request_is_local(), true, "172.31.x should be local")
      ngx.var.remote_addr = "172.15.0.1"
      assert_eq(guard.request_is_local(), false, "172.15.x should not be local")
      ngx.var.remote_addr = "172.32.0.1"
      assert_eq(guard.request_is_local(), false, "172.32.x should not be local")

      -- 192.168 range
      ngx.var.remote_addr = "192.168.1.1"
      assert_eq(guard.request_is_local(), true, "192.168.x should be local")

      -- ::1
      ngx.var.remote_addr = "::1"
      assert_eq(guard.request_is_local(), true, "::1 should be local")

      -- XFF with non-empty value
      ngx.var.remote_addr = "192.168.1.1"
      ngx.req.get_headers = function() return { ["x-forwarded-for"] = "something" } end
      assert_eq(guard.request_is_local(), false, "XFF present should block even for private IP")

      -- enforce_body_limit: content-length exceeds limit (exercises lines 298-300)
      ngx.req.get_headers = function() return { ["content-length"] = "200000" } end
      out = ""
      ngx.status = 0
      local bl_ok = guard.enforce_body_limit(1024)
      assert_eq(bl_ok, false, "enforce_body_limit should fail when content-length exceeds limit")
      assert_eq(ngx.status, 413, "enforce_body_limit 413 status")
      local bl_body = cjson.decode(out) or {}
      assert_eq(bl_body.error, "payload too large", "enforce_body_limit error message")

      -- enforce_body_limit: content-length within limit
      ngx.req.get_headers = function() return { ["content-length"] = "100" } end
      assert_eq(guard.enforce_body_limit(1024), true, "enforce_body_limit within limit returns true")

      -- enforce_body_limit: no content-length header
      ngx.req.get_headers = function() return {} end
      assert_eq(guard.enforce_body_limit(1024), true, "enforce_body_limit no content-length returns true")

      -- enforce_body_limit: default max_bytes (nil argument)
      ngx.req.get_headers = function() return { ["content-length"] = "50" } end
      assert_eq(guard.enforce_body_limit(), true, "enforce_body_limit default max_bytes")

      -- env_bool with "yes" and "on" (exercises all truthy branches)
      with_env({ FN_UI_ENABLED = "yes" }, function()
        assert_eq(guard.ui_enabled(), true, "env_bool 'yes' is truthy")
      end)
      with_env({ FN_UI_ENABLED = "on" }, function()
        assert_eq(guard.ui_enabled(), true, "env_bool 'on' is truthy")
      end)
      with_env({ FN_UI_ENABLED = "no" }, function()
        assert_eq(guard.ui_enabled(), false, "env_bool 'no' is falsy")
      end)
      with_env({ FN_UI_ENABLED = "off" }, function()
        assert_eq(guard.ui_enabled(), false, "env_bool 'off' is falsy")
      end)

      -- enforce_ui with admin token bypassing local-only (exercises the
      -- M.request_has_admin_token() branch inside enforce_ui line 209)
      with_env({ FN_UI_ENABLED = "1", FN_CONSOLE_LOCAL_ONLY = "1", FN_ADMIN_TOKEN = "mysecret" }, function()
        ngx.var.remote_addr = "8.8.8.8"
        ngx.req.get_method = function() return "GET" end
        ngx.req.get_headers = function() return { ["x-fn-admin-token"] = "mysecret" } end
        local ok_ui = guard.enforce_ui()
        assert_eq(ok_ui, true, "enforce_ui admin token should bypass local-only for remote")
      end)

      -- enforce_csrf with admin token for POST (exercises lines 311-313)
      with_env({ FN_ADMIN_TOKEN = "csrftoken" }, function()
        ngx.req.get_method = function() return "POST" end
        ngx.req.get_headers = function() return { ["x-fn-admin-token"] = "csrftoken" } end
        local ok_csrf = guard.enforce_csrf()
        assert_eq(ok_csrf, true, "enforce_csrf admin token should bypass CSRF for POST")
      end)

      package.loaded["fastfn.console.guard"] = nil
    end)
  end)
end

test_guard_constant_time_eq_edge_cases = function()
  with_fake_ngx(function()
    with_module_stubs({
      ["fastfn.console.auth"] = {
        login_enabled = function() return false end,
        api_login_enabled = function() return false end,
        read_session = function() return nil end,
      },
    }, function()
      package.loaded["fastfn.console.guard"] = nil
      local guard = require("fastfn.console.guard")

      -- Access constant_time_eq through request_has_admin_token
      local constant_time_eq = get_upvalue(guard.request_has_admin_token, "constant_time_eq")
      assert_true(type(constant_time_eq) == "function", "constant_time_eq is a function")

      -- Non-string inputs
      assert_eq(constant_time_eq(123, "abc"), false, "constant_time_eq number vs string")
      assert_eq(constant_time_eq("abc", 123), false, "constant_time_eq string vs number")
      assert_eq(constant_time_eq(nil, "abc"), false, "constant_time_eq nil vs string")
      assert_eq(constant_time_eq("abc", nil), false, "constant_time_eq string vs nil")
      assert_eq(constant_time_eq(true, false), false, "constant_time_eq bool vs bool")

      -- Different lengths
      assert_eq(constant_time_eq("ab", "abc"), false, "constant_time_eq different lengths")
      assert_eq(constant_time_eq("abcd", "abc"), false, "constant_time_eq longer vs shorter")

      -- Matching
      assert_eq(constant_time_eq("abc", "abc"), true, "constant_time_eq equal strings")
      assert_eq(constant_time_eq("", ""), true, "constant_time_eq empty strings")

      -- Same length, different content
      assert_eq(constant_time_eq("abc", "abd"), false, "constant_time_eq same length differ")

      package.loaded["fastfn.console.guard"] = nil
    end)
  end)
end

test_guard_enforce_csrf_post_without_header = function()
  with_fake_ngx(function()
    local cjson = require("cjson.safe")
    with_module_stubs({
      ["fastfn.console.auth"] = {
        login_enabled = function() return false end,
        api_login_enabled = function() return false end,
        read_session = function() return nil end,
      },
    }, function()
      package.loaded["fastfn.console.guard"] = nil
      local guard = require("fastfn.console.guard")

      local out = ""
      ngx.say = function(s) out = out .. tostring(s) end

      -- POST without X-Fn-Request header and without admin token
      with_env({ FN_ADMIN_TOKEN = false }, function()
        ngx.req.get_method = function() return "POST" end
        ngx.req.get_headers = function() return {} end
        out = ""
        ngx.status = 0
        local ok = guard.enforce_csrf()
        assert_eq(ok, false, "POST without CSRF header should fail")
        assert_eq(ngx.status, 403, "CSRF failure status")
        local body = cjson.decode(out) or {}
        assert_eq(body.error, "missing CSRF header", "CSRF error message")
      end)

      -- POST with X-Fn-Request = "0" (not "1")
      with_env({ FN_ADMIN_TOKEN = false }, function()
        ngx.req.get_method = function() return "POST" end
        ngx.req.get_headers = function() return { ["x-fn-request"] = "0" } end
        out = ""
        ngx.status = 0
        local ok = guard.enforce_csrf()
        assert_eq(ok, false, "POST with X-Fn-Request not 1 should fail")
      end)

      -- POST with X-Fn-Request = "1" should pass
      with_env({ FN_ADMIN_TOKEN = false }, function()
        ngx.req.get_method = function() return "POST" end
        ngx.req.get_headers = function() return { ["x-fn-request"] = "1" } end
        out = ""
        ngx.status = 0
        local ok = guard.enforce_csrf()
        assert_eq(ok, true, "POST with X-Fn-Request = 1 should pass")
      end)

      -- GET should always pass
      ngx.req.get_method = function() return "GET" end
      ngx.req.get_headers = function() return {} end
      assert_eq(guard.enforce_csrf(), true, "GET always passes CSRF")

      -- HEAD should pass
      ngx.req.get_method = function() return "HEAD" end
      assert_eq(guard.enforce_csrf(), true, "HEAD always passes CSRF")

      -- OPTIONS should pass
      ngx.req.get_method = function() return "OPTIONS" end
      assert_eq(guard.enforce_csrf(), true, "OPTIONS always passes CSRF")

      -- enforce_api where all checks pass but enforce_csrf fails (POST, no admin token, no X-Fn-Request)
      -- This exercises the `return false` at guard.lua line 197 (after enforce_csrf fails inside enforce_api)
      with_env({ FN_CONSOLE_API_ENABLED = "1", FN_ADMIN_API_ENABLED = "1", FN_CONSOLE_LOCAL_ONLY = "0", FN_ADMIN_TOKEN = false }, function()
        ngx.req.get_method = function() return "POST" end
        ngx.req.get_headers = function() return {} end
        ngx.var.remote_addr = "127.0.0.1"
        out = ""
        ngx.status = 0
        local ok = guard.enforce_api()
        assert_eq(ok, false, "enforce_api should fail when enforce_csrf fails on POST without header")
        assert_eq(ngx.status, 403, "enforce_api csrf failure status")
      end)

      -- enforce_ui where all checks pass but enforce_csrf fails (POST, no admin token, no X-Fn-Request)
      -- This exercises the `return false` at guard.lua line 215 (after enforce_csrf fails inside enforce_ui)
      with_env({ FN_UI_ENABLED = "1", FN_CONSOLE_LOCAL_ONLY = "0", FN_ADMIN_TOKEN = false }, function()
        ngx.req.get_method = function() return "POST" end
        ngx.req.get_headers = function() return {} end
        ngx.var.remote_addr = "127.0.0.1"
        out = ""
        ngx.status = 0
        local ok = guard.enforce_ui()
        assert_eq(ok, false, "enforce_ui should fail when enforce_csrf fails on POST without header")
        assert_eq(ngx.status, 403, "enforce_ui csrf failure status")
      end)

      package.loaded["fastfn.console.guard"] = nil
    end)
  end)
end

test_console_auth_password_hash_and_secret = function()
  with_fake_ngx(function()
    local trace_auth = tostring(os.getenv("FASTFN_LUA_TEST_TRACE") or "") == "1"
    local function auth_trace(step)
      if trace_auth then
        io.stdout:write("[lua-runner] auth " .. tostring(step) .. "\n")
        io.stdout:flush()
      end
    end
    local sha256_mod = require("resty.sha256")
    local prev_sha256_bin = ngx.sha256_bin
    local prev_encode_base64 = ngx.encode_base64
    local prev_decode_base64 = ngx.decode_base64
    local prev_hmac_sha1 = ngx.hmac_sha1
    ngx.sha256_bin = function(raw)
      local digest = sha256_mod:new()
      assert_true(digest:update(raw), "sha256 update")
      return digest:final()
    end
    local function hex_encode(raw)
      local out = {}
      for i = 1, #raw do
        out[#out + 1] = string.format("%02x", string.byte(raw, i))
      end
      return table.concat(out)
    end
    local function hex_decode(raw)
      return (raw:gsub("(%x%x)", function(pair)
        return string.char(tonumber(pair, 16))
      end))
    end
	    local function test_sha256_bin(raw)
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
      local out = {}
      for i = 1, #left do
        out[i] = string.char(bit.bxor(string.byte(left, i), string.byte(right, i)))
      end
      return table.concat(out)
    end
    local function hmac_sha256(key, payload)
      if #key > 64 then
        key = test_sha256_bin(key)
      end
      if #key < 64 then
        key = key .. string.rep("\0", 64 - #key)
      end
      local inner = test_sha256_bin(xor_with_byte(key, 0x36) .. payload)
      return test_sha256_bin(xor_with_byte(key, 0x5c) .. inner)
    end
    local function u32be(n)
      return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256
      )
    end
    local function pbkdf2_sha256_hex(password, salt, iterations)
      local u = hmac_sha256(password, salt .. u32be(1))
      local t = u
      for _ = 2, iterations do
        u = hmac_sha256(password, u)
        t = xor_bytes(t, u)
      end
      return hex_encode(t)
    end
    local function xor_with_byte(raw, n)
      local out = {}
      for i = 1, #raw do
        out[i] = string.char(bit.bxor(string.byte(raw, i), n))
      end
      return table.concat(out)
    end
    local function xor_bytes(left, right)
      local out = {}
      for i = 1, #left do
        out[i] = string.char(bit.bxor(string.byte(left, i), string.byte(right, i)))
      end
      return table.concat(out)
    end
    local function hmac_sha256(key, payload)
      if #key > 64 then
        key = ngx.sha256_bin(key)
      end
      if #key < 64 then
        key = key .. string.rep("\0", 64 - #key)
      end
      local inner = ngx.sha256_bin(xor_with_byte(key, 0x36) .. payload)
      return ngx.sha256_bin(xor_with_byte(key, 0x5c) .. inner)
    end
    local function u32be(n)
      return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256
      )
    end
    local function pbkdf2_hash(password, salt_hex, iterations)
      local salt = hex_decode(salt_hex)
      local acc = hmac_sha256(password, salt .. u32be(1))
      local block = acc
      for _ = 2, iterations do
        block = hmac_sha256(password, block)
        acc = xor_bytes(acc, block)
      end
      return string.format("pbkdf2-sha256:%d:%s:%s", iterations, salt_hex, hex_encode(acc))
    end
    ngx.encode_base64 = hex_encode
    ngx.decode_base64 = hex_decode
	    ngx.hmac_sha1 = function(secret, payload)
	      return secret .. "|" .. payload
	    end
	    ngx.var.scheme = "https"
	    local legacy_hash = "sha256:" .. hex_encode(ngx.sha256_bin("secret-value"))
	    local pbkdf2_salt_hex = "73616c742d76616c75652d3031"
	    local pbkdf2_test_iterations = 8
	    local pbkdf2_password_hash = pbkdf2_hash("secret-value", pbkdf2_salt_hex, pbkdf2_test_iterations)
	    local function patch_auth_pbkdf2_min(auth, min_iterations)
	      local parsed_password_hash = get_upvalue(auth.credentials_configured, "parsed_password_hash")
	        or get_upvalue(auth.verify_password, "parsed_password_hash")
	      if type(parsed_password_hash) == "function" then
	        local ok_patch_min = set_upvalue(parsed_password_hash, "MIN_PBKDF2_ITERATIONS", min_iterations)
	        assert_true(ok_patch_min, "patch auth pbkdf2 min iterations")
	      end
	    end

	    with_env({
	      FN_CONSOLE_LOGIN_USERNAME = "admin",
	      FN_CONSOLE_LOGIN_PASSWORD_HASH = legacy_hash,
	      FN_CONSOLE_LOGIN_PASSWORD = false,
	      FN_CONSOLE_SESSION_SECRET = "session-secret",
	    }, function()
	      auth_trace("legacy hash start")
	      package.loaded["fastfn.console.auth"] = nil
	      local auth = require("fastfn.console.auth")
      assert_eq(auth.credentials_configured(), true, "hash credentials configured")
      assert_eq(auth.verify_password("secret-value"), true, "hash password accepted")
      assert_eq(auth.verify_password("wrong"), false, "hash password rejected")
      assert_eq(auth.constant_time_eq("abc", "abc"), true, "auth constant_time_eq equal")
	      assert_eq(auth.constant_time_eq("abc", "abd"), false, "auth constant_time_eq mismatch")
	      package.loaded["fastfn.console.auth"] = nil
	      auth_trace("legacy hash done")
	    end)

	    with_env({
	      FN_CONSOLE_LOGIN_USERNAME = "admin",
	      FN_CONSOLE_LOGIN_PASSWORD_HASH = false,
	      FN_CONSOLE_LOGIN_PASSWORD = "plain-secret",
	      FN_CONSOLE_SESSION_SECRET = "session-secret",
	    }, function()
	      auth_trace("plain password start")
	      package.loaded["fastfn.console.auth"] = nil
	      local auth = require("fastfn.console.auth")
      assert_eq(auth.verify_password("plain-secret"), true, "plain password fallback works")
	      assert_eq(auth.verify_password("wrong"), false, "plain password fallback rejects wrong value")
	      package.loaded["fastfn.console.auth"] = nil
	      auth_trace("plain password done")
	    end)

    local root = "/tmp/fastfn-console-auth"
    rm_rf(root)
    mkdir_p(root)
    write_file(root .. "/password-hash.txt", legacy_hash .. "\n")
    write_file(root .. "/password.txt", "plain-secret\n")
    write_file(root .. "/session-secret.txt", "file-session-secret\n")

	    with_env({
	      FN_CONSOLE_LOGIN_USERNAME = "admin",
	      FN_CONSOLE_LOGIN_PASSWORD_HASH = pbkdf2_password_hash,
	      FN_CONSOLE_LOGIN_PASSWORD = false,
	      FN_CONSOLE_SESSION_SECRET = "session-secret",
	    }, function()
	      auth_trace("pbkdf2 valid start")
	      package.loaded["fastfn.console.auth"] = nil
	      local auth = require("fastfn.console.auth")
	      patch_auth_pbkdf2_min(auth, pbkdf2_test_iterations)
	      assert_eq(auth.credentials_configured(), true, "pbkdf2 credentials configured")
	      assert_eq(auth.verify_password("secret-value"), true, "pbkdf2 password accepted")
	      assert_eq(auth.verify_password("wrong"), false, "pbkdf2 password rejected")
	      package.loaded["fastfn.console.auth"] = nil
	      auth_trace("pbkdf2 valid done")
	    end)

	    with_env({
	      FN_CONSOLE_LOGIN_USERNAME = "admin",
	      FN_CONSOLE_LOGIN_PASSWORD_HASH = "pbkdf2-sha256:" .. tostring(pbkdf2_test_iterations - 1) .. ":" .. pbkdf2_salt_hex .. ":00",
	      FN_CONSOLE_LOGIN_PASSWORD = false,
	      FN_CONSOLE_SESSION_SECRET = "session-secret",
	    }, function()
	      auth_trace("pbkdf2 low iteration start")
	      package.loaded["fastfn.console.auth"] = nil
	      local auth = require("fastfn.console.auth")
	      patch_auth_pbkdf2_min(auth, pbkdf2_test_iterations)
	      assert_eq(auth.credentials_configured(), false, "pbkdf2 low iteration rejected")
	      assert_eq(auth.verify_password("secret-value"), false, "pbkdf2 low iteration verify rejected")
	      package.loaded["fastfn.console.auth"] = nil
	      auth_trace("pbkdf2 low iteration done")
	    end)

	    with_env({
	      FN_CONSOLE_LOGIN_USERNAME = "admin",
	      FN_CONSOLE_LOGIN_PASSWORD_HASH = "pbkdf2-sha256:" .. tostring(pbkdf2_test_iterations) .. ":zz:00",
	      FN_CONSOLE_LOGIN_PASSWORD = false,
	      FN_CONSOLE_SESSION_SECRET = "session-secret",
	    }, function()
	      auth_trace("pbkdf2 invalid hex start")
	      package.loaded["fastfn.console.auth"] = nil
	      local auth = require("fastfn.console.auth")
	      patch_auth_pbkdf2_min(auth, pbkdf2_test_iterations)
	      assert_eq(auth.credentials_configured(), false, "pbkdf2 invalid hex rejected")
	      assert_eq(auth.verify_password("secret-value"), false, "pbkdf2 invalid hex verify rejected")
	      package.loaded["fastfn.console.auth"] = nil
	      auth_trace("pbkdf2 invalid hex done")
	    end)

	    with_env({
	      FN_CONSOLE_LOGIN_USERNAME = "admin",
	      FN_CONSOLE_LOGIN_PASSWORD_HASH = false,
	      FN_CONSOLE_LOGIN_PASSWORD = false,
	      FN_CONSOLE_LOGIN_PASSWORD_HASH_FILE = root .. "/password-hash.txt",
	      FN_CONSOLE_SESSION_SECRET = false,
	      FN_CONSOLE_SESSION_SECRET_FILE = root .. "/session-secret.txt",
	    }, function()
	      auth_trace("hash file start")
	      package.loaded["fastfn.console.auth"] = nil
	      local auth = require("fastfn.console.auth")
      assert_eq(auth.credentials_configured(), true, "hash file credentials configured")
      assert_eq(auth.verify_password("secret-value"), true, "hash file password accepted")
      assert_eq(auth.verify_password("wrong"), false, "hash file password rejected")
      local ok, err = auth.set_session_cookie("admin")
      assert_eq(ok, true, err or "session cookie from file secret")
      local cookie = tostring(ngx.header["Set-Cookie"] or "")
      assert_true(cookie:find("HttpOnly", 1, true) ~= nil, "session cookie httpOnly")
      assert_true(cookie:find("SameSite=Lax", 1, true) ~= nil, "session cookie sameSite")
      assert_true(cookie:find("Secure", 1, true) ~= nil, "session cookie secure on https")
      local token = cookie:match("^fastfn_session=([^;]+)")
      assert_true(type(token) == "string" and token ~= "", "session token emitted")
      ngx.var.http_cookie = "fastfn_session=" .. token
      local sess, sess_err = auth.read_session()
      assert_true(type(sess) == "table", sess_err or "session should load")
      assert_eq(sess.user, "admin", "session user from cookie")
      auth.clear_session_cookie()
	      assert_true(tostring(ngx.header["Set-Cookie"] or ""):find("Max%-Age=0") ~= nil, "clear session cookie expires")
	      package.loaded["fastfn.console.auth"] = nil
	      auth_trace("hash file done")
	    end)

	    with_env({
	      FN_CONSOLE_LOGIN_USERNAME = "other-admin",
	      FN_CONSOLE_LOGIN_PASSWORD_HASH = false,
	      FN_CONSOLE_LOGIN_PASSWORD = false,
	      FN_CONSOLE_LOGIN_PASSWORD_HASH_FILE = root .. "/password-hash.txt",
	      FN_CONSOLE_SESSION_SECRET = false,
	      FN_CONSOLE_SESSION_SECRET_FILE = root .. "/session-secret.txt",
	    }, function()
	      auth_trace("session mismatch start")
	      package.loaded["fastfn.console.auth"] = nil
	      local auth = require("fastfn.console.auth")
      local sess, err = auth.read_session()
      assert_eq(sess, nil, "session should fail if username changes")
	      assert_eq(err, "session user mismatch", "session user bound to current login user")
	      package.loaded["fastfn.console.auth"] = nil
	      auth_trace("session mismatch done")
	    end)

	    with_env({
	      FN_CONSOLE_LOGIN_USERNAME = "admin",
	      FN_CONSOLE_LOGIN_PASSWORD_HASH = false,
	      FN_CONSOLE_LOGIN_PASSWORD = false,
	      FN_CONSOLE_LOGIN_PASSWORD_FILE = root .. "/password.txt",
	      FN_CONSOLE_SESSION_SECRET = false,
	      FN_CONSOLE_SESSION_SECRET_FILE = root .. "/session-secret.txt",
	    }, function()
	      auth_trace("password file start")
	      package.loaded["fastfn.console.auth"] = nil
	      local auth = require("fastfn.console.auth")
      local ok, err = auth.set_session_cookie("admin")
      assert_eq(ok, true, err or "plain password file should create session")
      local token = tostring(ngx.header["Set-Cookie"] or ""):match("^fastfn_session=([^;]+)")
      assert_true(type(token) == "string" and token ~= "", "plain password session token emitted")
      ngx.var.http_cookie = "fastfn_session=" .. token
	      write_file(root .. "/password.txt", "rotated-secret\n")
	      local sess, sess_err = auth.read_session()
	      assert_eq(sess, nil, "session should be invalid after password rotation")
	      assert_eq(sess_err, "session credentials changed", "session bound to current credentials")
	      package.loaded["fastfn.console.auth"] = nil
	      auth_trace("password file done")
	    end)

	    local pbkdf2_iterations = pbkdf2_test_iterations
	    local pbkdf2_salt_hex = "000102030405060708090a0b0c0d0e0f"
	    local pbkdf2_digest_hex = pbkdf2_sha256_hex("pbkdf2-secret", hex_decode(pbkdf2_salt_hex), pbkdf2_iterations)
	    with_env({
	      FN_CONSOLE_LOGIN_USERNAME = "admin",
	      FN_CONSOLE_LOGIN_PASSWORD_HASH = string.format("pbkdf2-sha256:%d:%s:%s", pbkdf2_iterations, pbkdf2_salt_hex, pbkdf2_digest_hex),
	      FN_CONSOLE_LOGIN_PASSWORD = false,
	      FN_CONSOLE_SESSION_SECRET = "session-secret",
	    }, function()
	      auth_trace("pbkdf2 roundtrip start")
	      package.loaded["fastfn.console.auth"] = nil
	      local auth = require("fastfn.console.auth")
	      patch_auth_pbkdf2_min(auth, pbkdf2_iterations)
	      assert_eq(auth.credentials_configured(), true, "pbkdf2 credentials configured")
	      assert_eq(auth.verify_password("pbkdf2-secret"), true, "pbkdf2 password accepted")
	      assert_eq(auth.verify_password("wrong"), false, "pbkdf2 password rejected")
	      package.loaded["fastfn.console.auth"] = nil
	      auth_trace("pbkdf2 roundtrip done")
	    end)
    ngx.sha256_bin = function(raw)
      if raw == "secret-value" then
        return string.char(0x01, 0x02, 0x03, 0x04)
      end
      if raw == "plain-secret" then
        return string.char(0x0e, 0x0f, 0x10, 0x11)
      end
      if raw == "rotated-secret" then
        return string.char(0x1a, 0x1b, 0x1c, 0x1d)
      end
      return string.char(0x0a, 0x0b, 0x0c, 0x0d)
    end

    with_env({
      FN_CONSOLE_LOGIN_USERNAME = "admin",
      FN_CONSOLE_LOGIN_PASSWORD_HASH = "pbkdf2-sha256:10:abcd:broken",
      FN_CONSOLE_LOGIN_PASSWORD = "plain-secret",
      FN_CONSOLE_SESSION_SECRET = "session-secret",
    }, function()
      package.loaded["fastfn.console.auth"] = nil
      local auth = require("fastfn.console.auth")
      assert_eq(auth.credentials_configured(), false, "invalid hash should not silently fallback to plain password")
      assert_eq(auth.verify_password("plain-secret"), false, "invalid hash rejects verification")
      package.loaded["fastfn.console.auth"] = nil
    end)

    with_env({
      FN_CONSOLE_LOGIN_USERNAME = "admin",
      FN_CONSOLE_LOGIN_PASSWORD_HASH = legacy_hash,
      FN_CONSOLE_SESSION_SECRET = false,
    }, function()
      package.loaded["fastfn.console.auth"] = nil
      local auth = require("fastfn.console.auth")
      local sess, err = auth.read_session()
      assert_eq(sess, nil, "session missing when secret absent")
      assert_eq(err, "session secret not configured", "session secret is mandatory")
      package.loaded["fastfn.console.auth"] = nil
    end)

    ngx.var.http_cookie = nil
    ngx.var.scheme = nil
    rm_rf(root)
    ngx.encode_base64 = prev_encode_base64
    ngx.decode_base64 = prev_decode_base64
    ngx.hmac_sha1 = prev_hmac_sha1
  end)
end

test_console_auth_internal_edge_cases = function()
  with_fake_ngx(function()
    local cjson = require("cjson.safe")
    local sha256_mod = require("resty.sha256")
    local prev_sha256_bin = ngx.sha256_bin
    local prev_encode_base64 = ngx.encode_base64
    local prev_decode_base64 = ngx.decode_base64
    local prev_hmac_sha1 = ngx.hmac_sha1
    local prev_log = ngx.log
    local logs = {}

    local function raw_sha256(raw)
      local digest = sha256_mod:new()
      assert_true(digest:update(raw), "auth edge sha256 update")
      return digest:final()
    end

    local function hex_encode(raw)
      local out = {}
      for i = 1, #raw do
        out[#out + 1] = string.format("%02x", string.byte(raw, i))
      end
      return table.concat(out)
    end

    local function hex_decode(raw)
      return (tostring(raw or ""):gsub("(%x%x)", function(pair)
        return string.char(tonumber(pair, 16))
      end))
    end

    local function xor_with_byte(raw, n)
      local out = {}
      for i = 1, #raw do
        out[i] = string.char(bit.bxor(string.byte(raw, i), n))
      end
      return table.concat(out)
    end

    local function xor_bytes(left, right)
      local out = {}
      for i = 1, #left do
        out[i] = string.char(bit.bxor(string.byte(left, i), string.byte(right, i)))
      end
      return table.concat(out)
    end

    local function hmac_sha256(key, payload)
      if #key > 64 then
        key = raw_sha256(key)
      end
      if #key < 64 then
        key = key .. string.rep("\0", 64 - #key)
      end
      local inner = raw_sha256(xor_with_byte(key, 0x36) .. payload)
      return raw_sha256(xor_with_byte(key, 0x5c) .. inner)
    end

    local function u32be(n)
      return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256
      )
    end

    local function pbkdf2_hash(password, salt_hex, iterations)
      local salt = hex_decode(salt_hex)
      local acc = hmac_sha256(password, salt .. u32be(1))
      local block = acc
      for _ = 2, iterations do
        block = hmac_sha256(password, block)
        acc = xor_bytes(acc, block)
      end
      return string.format("pbkdf2-sha256:%d:%s:%s", iterations, salt_hex, hex_encode(acc))
    end

    local function reset_crypto()
      ngx.sha256_bin = function(raw)
        if raw == "return-nil" then
          return nil
        end
        return raw_sha256(raw)
      end
      ngx.encode_base64 = hex_encode
      ngx.decode_base64 = function(raw)
        if raw == "bad" then
          return nil
        end
        return hex_decode(raw)
      end
      ngx.hmac_sha1 = function(secret, payload)
        return secret .. "|" .. payload
      end
    end

    local function make_token(payload, secret)
      return hex_encode(payload) .. "." .. hex_encode(secret .. "|" .. payload)
    end

    local function fresh_auth(env, run)
      with_env(env, function()
        package.loaded["fastfn.console.auth"] = nil
        local auth = require("fastfn.console.auth")
        run(auth)
        package.loaded["fastfn.console.auth"] = nil
      end)
    end

    local function patch_auth_pbkdf2_min(auth, min_iterations)
      local parsed_password_hash = get_upvalue(auth.credentials_configured, "parsed_password_hash")
        or get_upvalue(auth.verify_password, "parsed_password_hash")
      if type(parsed_password_hash) == "function" then
        local ok_patch_min = set_upvalue(parsed_password_hash, "MIN_PBKDF2_ITERATIONS", min_iterations)
        assert_true(ok_patch_min, "patch auth edge pbkdf2 min iterations")
      end
    end

    reset_crypto()
    ngx.log = function(...)
      local parts = { ... }
      for i = 1, #parts do
        parts[i] = tostring(parts[i])
      end
      logs[#logs + 1] = table.concat(parts)
    end

    local root = "/tmp/fastfn-console-auth-edges"
    rm_rf(root)
    mkdir_p(root)
    write_file(root .. "/empty.txt", "")
    write_file(root .. "/large.txt", string.rep("x", 9000))

    fresh_auth({
      FN_CONSOLE_LOGIN_ENABLED = false,
      FN_CONSOLE_LOGIN_API = false,
    }, function(auth)
      assert_eq(auth.login_enabled(), false, "auth login_enabled default false")
      assert_eq(auth.api_login_enabled(), false, "auth api_login_enabled default false")
      assert_eq(auth.cookie_name(), "fastfn_session", "auth cookie name")
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_ENABLED = "on",
      FN_CONSOLE_LOGIN_API = "yes",
    }, function(auth)
      assert_eq(auth.login_enabled(), true, "auth login_enabled truthy")
      assert_eq(auth.api_login_enabled(), true, "auth api_login_enabled truthy")
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_ENABLED = "off",
      FN_CONSOLE_LOGIN_API = "no",
    }, function(auth)
      assert_eq(auth.login_enabled(), false, "auth login_enabled falsy")
      assert_eq(auth.api_login_enabled(), false, "auth api_login_enabled falsy")
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_ENABLED = "maybe",
      FN_CONSOLE_LOGIN_API = "maybe",
    }, function(auth)
      assert_eq(auth.login_enabled(), false, "auth login_enabled invalid falls back")
      assert_eq(auth.api_login_enabled(), false, "auth api_login_enabled invalid falls back")
      assert_eq(auth.password(), nil, "auth password absent")
      assert_eq(auth.credentials_configured(), false, "auth credentials missing without username")
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_PASSWORD = "direct-secret",
      FN_CONSOLE_LOGIN_USERNAME = "admin",
    }, function(auth)
      assert_eq(auth.password(), "direct-secret", "auth env secret returned directly")
      assert_eq(auth.credentials_configured(), true, "auth plain password credentials configured")
      assert_eq(auth.verify_password({}), false, "auth verify_password rejects non-string")
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_USERNAME = "admin",
      FN_CONSOLE_LOGIN_PASSWORD = false,
    }, function(auth)
      assert_eq(auth.credentials_configured(), false, "auth missing password credentials not configured")
      assert_eq(auth.verify_password("anything"), false, "auth missing password rejects verify")
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_PASSWORD = false,
      FN_CONSOLE_LOGIN_PASSWORD_FILE = root .. "/missing.txt",
    }, function(auth)
      local env_secret = get_upvalue(auth.password, "env_secret")
      local read_secret_file = type(env_secret) == "function" and get_upvalue(env_secret, "read_secret_file") or nil
      local trim_trailing_newlines = type(read_secret_file) == "function" and get_upvalue(read_secret_file, "trim_trailing_newlines") or nil
      assert_eq(auth.password(), nil, "auth missing secret file returns nil")
      assert_true(type(trim_trailing_newlines) == "function", "auth trim_trailing_newlines helper")
      assert_eq(trim_trailing_newlines(123), 123, "auth trim_trailing_newlines non-string passthrough")
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_PASSWORD = false,
      FN_CONSOLE_LOGIN_PASSWORD_FILE = root .. "/empty.txt",
    }, function(auth)
      assert_eq(auth.password(), nil, "auth empty secret file returns nil")
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_PASSWORD = false,
      FN_CONSOLE_LOGIN_PASSWORD_FILE = root .. "/large.txt",
    }, function(auth)
      assert_eq(auth.password(), nil, "auth oversized secret file returns nil")
    end)

    local legacy_hash = "sha256:" .. hex_encode(raw_sha256("secret-value"))
    fresh_auth({
      FN_CONSOLE_LOGIN_USERNAME = "admin",
      FN_CONSOLE_LOGIN_PASSWORD_HASH = legacy_hash,
      FN_CONSOLE_SESSION_SECRET = "session-secret",
      FN_CONSOLE_SESSION_TTL_S = "5",
    }, function(auth)
      reset_crypto()
      local ok, err = auth.set_session_cookie("admin")
      assert_eq(ok, true, err or "auth short ttl cookie")
      assert_true(tostring(ngx.header["Set-Cookie"] or ""):find("Max-Age=5", 1, true) ~= nil, "auth short ttl max-age")
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_USERNAME = "admin",
      FN_CONSOLE_LOGIN_PASSWORD_HASH = legacy_hash,
      FN_CONSOLE_SESSION_SECRET = "session-secret",
      FN_CONSOLE_SESSION_TTL_S = "oops",
    }, function(auth)
      reset_crypto()
      local ok, err = auth.set_session_cookie("admin")
      assert_eq(ok, true, err or "auth invalid ttl cookie")
      assert_true(tostring(ngx.header["Set-Cookie"] or ""):find("Max-Age=43200", 1, true) ~= nil, "auth invalid ttl falls back")
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_USERNAME = "admin",
      FN_CONSOLE_LOGIN_PASSWORD_HASH = legacy_hash,
      FN_CONSOLE_SESSION_SECRET = "session-secret",
      FN_CONSOLE_SESSION_TTL_S = "0",
    }, function(auth)
      reset_crypto()
      local ok, err = auth.set_session_cookie("admin")
      assert_eq(ok, true, err or "auth zero ttl cookie")
      assert_true(tostring(ngx.header["Set-Cookie"] or ""):find("Max-Age=43200", 1, true) ~= nil, "auth zero ttl falls back")
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_USERNAME = "admin",
      FN_CONSOLE_LOGIN_PASSWORD_HASH = legacy_hash,
      FN_CONSOLE_SESSION_SECRET = "session-secret",
    }, function(auth)
      reset_crypto()
      local credentials_fingerprint = get_upvalue(auth.read_session, "credentials_fingerprint")
      local parsed_password_hash = get_upvalue(auth.credentials_configured, "parsed_password_hash")
      local sha256_hex = get_upvalue(auth.verify_password, "sha256_hex")
      local pbkdf2_sha256_bin = get_upvalue(auth.verify_password, "pbkdf2_sha256_bin")
      local hmac_sha256_fn = type(pbkdf2_sha256_bin) == "function" and get_upvalue(pbkdf2_sha256_bin, "hmac_sha256") or nil
      local sha256_bin_fn = type(hmac_sha256_fn) == "function" and get_upvalue(hmac_sha256_fn, "sha256_bin") or nil
      local xor_bytes_fn = type(pbkdf2_sha256_bin) == "function" and get_upvalue(pbkdf2_sha256_bin, "xor_bytes") or nil

      assert_true(type(credentials_fingerprint) == "function", "auth credentials_fingerprint helper")
      assert_true(type(parsed_password_hash) == "function", "auth parsed_password_hash helper")
      assert_true(type(sha256_hex) == "function", "auth sha256_hex helper")
      assert_true(type(pbkdf2_sha256_bin) == "function", "auth pbkdf2 helper")
      assert_true(type(hmac_sha256_fn) == "function", "auth hmac helper")
      assert_true(type(sha256_bin_fn) == "function", "auth sha256_bin helper")
      assert_true(type(xor_bytes_fn) == "function", "auth xor_bytes helper")

      assert_eq(sha256_hex(nil), nil, "auth sha256_hex nil input")
      local old_sha256_bin = ngx.sha256_bin
      ngx.sha256_bin = nil
      assert_eq(sha256_hex("value"), nil, "auth sha256_hex missing ngx helper")
      assert_eq(sha256_bin_fn("value"), nil, "auth sha256_bin missing ngx helper")
      ngx.sha256_bin = function() return nil end
      assert_eq(sha256_hex("value"), nil, "auth sha256_hex nil digest")
      assert_eq(sha256_bin_fn("value"), nil, "auth sha256_bin nil digest")
      ngx.sha256_bin = old_sha256_bin

      assert_eq(sha256_bin_fn(nil), nil, "auth sha256_bin non-string input")
      assert_eq(xor_bytes_fn("ab", "a"), nil, "auth xor_bytes mismatched sizes")
      assert_eq(hmac_sha256_fn(nil, "payload"), nil, "auth hmac nil key")
      assert_eq(hmac_sha256_fn("key", nil), nil, "auth hmac nil payload")

      ngx.sha256_bin = function() return nil end
      assert_eq(hmac_sha256_fn(string.rep("k", 65), "payload"), nil, "auth hmac long key hash failure")
      ngx.sha256_bin = function(raw)
        if raw:find("payload", 1, true) ~= nil then
          return nil
        end
        return raw_sha256(raw)
      end
      assert_eq(hmac_sha256_fn("key", "payload"), nil, "auth hmac inner digest failure")
      ngx.sha256_bin = old_sha256_bin

      assert_eq(pbkdf2_sha256_bin(nil, "salt", 1, 32), nil, "auth pbkdf2 nil password")
      assert_eq(pbkdf2_sha256_bin("pw", "salt", 0, 32), nil, "auth pbkdf2 invalid iterations")
      with_upvalue(pbkdf2_sha256_bin, "hmac_sha256", function() return nil end, function()
        assert_eq(pbkdf2_sha256_bin("pw", "salt", 1, 32), nil, "auth pbkdf2 initial hmac failure")
      end)
      do
        local old_hmac, hmac_idx = get_upvalue(pbkdf2_sha256_bin, "hmac_sha256")
        local calls = 0
        assert_true(hmac_idx ~= nil, "auth pbkdf2 hmac upvalue present")
        debug.setupvalue(pbkdf2_sha256_bin, hmac_idx, function()
          calls = calls + 1
          if calls >= 2 then
            return nil
          end
          return string.rep("a", 32)
        end)
        assert_eq(pbkdf2_sha256_bin("pw", "salt", 2, 32), nil, "auth pbkdf2 repeated hmac failure")
        debug.setupvalue(pbkdf2_sha256_bin, hmac_idx, old_hmac)
      end
      with_upvalue(pbkdf2_sha256_bin, "hmac_sha256", function() return string.rep("a", 32) end, function()
        with_upvalue(pbkdf2_sha256_bin, "xor_bytes", function() return nil end, function()
          assert_eq(pbkdf2_sha256_bin("pw", "salt", 2, 32), nil, "auth pbkdf2 xor failure")
        end)
      end)
      do
        local old_hmac, hmac_idx = get_upvalue(pbkdf2_sha256_bin, "hmac_sha256")
        local old_xor_bytes, xor_idx = get_upvalue(pbkdf2_sha256_bin, "xor_bytes")
        assert_true(hmac_idx ~= nil and xor_idx ~= nil, "auth pbkdf2 helper upvalues present")
        debug.setupvalue(pbkdf2_sha256_bin, hmac_idx, function()
          return string.rep("a", 32)
        end)
        debug.setupvalue(pbkdf2_sha256_bin, xor_idx, function()
          return nil
        end)
        assert_eq(pbkdf2_sha256_bin("pw", "salt", 2, 32), nil, "auth pbkdf2 xor failure explicit")
        debug.setupvalue(pbkdf2_sha256_bin, xor_idx, old_xor_bytes)
        debug.setupvalue(pbkdf2_sha256_bin, hmac_idx, old_hmac)
      end

      assert_true(type(credentials_fingerprint()) == "string", "auth fingerprint legacy hash")
      local old_username = auth.username
      auth.username = function() return nil end
      assert_eq(credentials_fingerprint(), nil, "auth fingerprint missing user")
      auth.username = old_username
      do
        local old_password_hash = auth.password_hash
        local old_password = auth.password
        auth.password_hash = function() return nil end
        auth.password = function() return nil end
        assert_eq(credentials_fingerprint(), nil, "auth fingerprint missing plain password")
        auth.password = old_password
        auth.password_hash = old_password_hash
      end

      local old_password = auth.password
      auth.password = function() return "return-nil" end
      auth.password_hash = function() return nil end
      assert_eq(credentials_fingerprint(), nil, "auth fingerprint hash failure on plain password")
      auth.password = old_password
      auth.password_hash = function() return legacy_hash end
      with_upvalue(credentials_fingerprint, "sha256_hex", function()
        return nil
      end, function()
        auth.password_hash = function() return nil end
        auth.password = function() return "plain-secret" end
        assert_eq(credentials_fingerprint(), nil, "auth fingerprint nil when sha256 helper fails")
      end)
      auth.password = old_password
      auth.password_hash = function() return legacy_hash end

      local old_hash = auth.password_hash
      auth.password_hash = function() return "totally-bad-hash" end
      assert_eq(parsed_password_hash().kind, "invalid", "auth invalid generic hash parsed")
      assert_eq(credentials_fingerprint(), nil, "auth fingerprint invalid hash rejected")
      auth.password_hash = old_hash

      ngx.sha256_bin = function() return nil end
      assert_eq(auth.verify_password("secret-value"), false, "auth verify_password hash failure")
      ngx.sha256_bin = old_sha256_bin
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_USERNAME = "admin",
      FN_CONSOLE_LOGIN_PASSWORD_HASH = "totally-bad-hash",
      FN_CONSOLE_LOGIN_PASSWORD = "plain-secret",
      FN_CONSOLE_SESSION_SECRET = "session-secret",
    }, function(auth)
      assert_eq(auth.credentials_configured(), false, "auth invalid generic hash does not configure credentials")
      assert_eq(auth.verify_password("plain-secret"), false, "auth invalid generic hash does not fallback")
    end)

    do
      local pbkdf2_iterations = 3
      local pbkdf2_salt_hex = "000102030405060708090a0b0c0d0e0f"
      local pbkdf2_password_hash = pbkdf2_hash("secret-value", pbkdf2_salt_hex, pbkdf2_iterations)
      fresh_auth({
        FN_CONSOLE_LOGIN_USERNAME = "admin",
        FN_CONSOLE_LOGIN_PASSWORD_HASH = pbkdf2_password_hash,
        FN_CONSOLE_SESSION_SECRET = "session-secret",
      }, function(auth)
        local credentials_fingerprint = get_upvalue(auth.read_session, "credentials_fingerprint")
        patch_auth_pbkdf2_min(auth, pbkdf2_iterations)
        local fingerprint = credentials_fingerprint()
        assert_true(type(fingerprint) == "string" and fingerprint:find("^pbkdf2%-sha256:3:", 1, false) ~= nil,
          "auth pbkdf2 fingerprint")
      end)
    end

    fresh_auth({
      FN_CONSOLE_LOGIN_USERNAME = "admin",
      FN_CONSOLE_LOGIN_PASSWORD = "plain-secret",
      FN_CONSOLE_SESSION_SECRET = "session-secret",
    }, function(auth)
      reset_crypto()
      ngx.var.http_cookie = nil
      local sess1, err1 = auth.read_session()
      assert_eq(sess1, nil, "auth read_session no cookie")
      assert_eq(err1, "no session", "auth read_session no cookie error")

      ngx.var.http_cookie = "fastfn_session=badtoken"
      local sess2, err2 = auth.read_session()
      assert_eq(sess2, nil, "auth read_session malformed token")
      assert_eq(err2, "invalid session token", "auth read_session malformed token error")

      ngx.var.http_cookie = "fastfn_session=bad.00"
      local sess3, err3 = auth.read_session()
      assert_eq(sess3, nil, "auth read_session invalid payload")
      assert_eq(err3, "invalid session payload", "auth read_session invalid payload error")

      local signed_payload = cjson.encode({ user = "admin", exp = 1005 })
      ngx.var.http_cookie = "fastfn_session=" .. hex_encode(signed_payload) .. ".00"
      local sess4, err4 = auth.read_session()
      assert_eq(sess4, nil, "auth read_session invalid signature")
      assert_eq(err4, "invalid session signature", "auth read_session invalid signature error")

      ngx.var.http_cookie = "fastfn_session=" .. make_token("not-json", "session-secret")
      local sess5, err5 = auth.read_session()
      assert_eq(sess5, nil, "auth read_session invalid json")
      assert_eq(err5, "invalid session json", "auth read_session invalid json error")

      ngx.var.http_cookie = "fastfn_session=" .. make_token(cjson.encode({ user = "admin", exp = 0 }), "session-secret")
      local sess6, err6 = auth.read_session()
      assert_eq(sess6, nil, "auth read_session invalid exp")
      assert_eq(err6, "invalid session exp", "auth read_session invalid exp error")

      ngx.var.http_cookie = "fastfn_session=" .. make_token(cjson.encode({ user = "admin", exp = 999 }), "session-secret")
      local sess7, err7 = auth.read_session()
      assert_eq(sess7, nil, "auth read_session expired")
      assert_eq(err7, "session expired", "auth read_session expired error")

      ngx.var.http_cookie = "fastfn_session=" .. make_token(cjson.encode({ user = "", exp = 1005 }), "session-secret")
      local sess8, err8 = auth.read_session()
      assert_eq(sess8, nil, "auth read_session invalid user")
      assert_eq(err8, "invalid session user", "auth read_session invalid user error")

      local set_ok, set_err = auth.set_session_cookie("")
      assert_eq(set_ok, nil, "auth set_session_cookie invalid user")
      assert_eq(set_err, "invalid user", "auth set_session_cookie invalid user error")

      with_upvalue(auth.set_session_cookie, "cjson", {
        encode = function() return nil end,
      }, function()
        local encode_ok, encode_err = auth.set_session_cookie("admin")
        assert_eq(encode_ok, nil, "auth set_session_cookie encode failure")
        assert_eq(encode_err, "failed to encode session", "auth set_session_cookie encode failure error")
      end)
    end)

    fresh_auth({
      FN_CONSOLE_LOGIN_USERNAME = "admin",
      FN_CONSOLE_LOGIN_PASSWORD = "plain-secret",
      FN_CONSOLE_SESSION_SECRET = false,
    }, function(auth)
      local ok, err = auth.set_session_cookie("admin")
      assert_eq(ok, nil, "auth set_session_cookie without secret")
      assert_eq(err, "session secret not configured", "auth set_session_cookie without secret error")
    end)

    assert_true(#logs >= 3, "auth edge cases logged warnings")

    package.loaded["fastfn.console.auth"] = nil
    rm_rf(root)
    ngx.log = prev_log
    ngx.sha256_bin = prev_sha256_bin
    ngx.encode_base64 = prev_encode_base64
    ngx.decode_base64 = prev_decode_base64
    ngx.hmac_sha1 = prev_hmac_sha1
    ngx.var.http_cookie = nil
    ngx.header["Set-Cookie"] = nil
  end)
end

test_core_fs_shell_free_helpers = function()
  local fs = require("fastfn.core.fs")
  local root = "/tmp/fastfn-core-fs"
  local nested = root .. "/nested/sub"
  local skip_dir = root .. "/skip-me"
  local plain = root .. "/plain.txt"
  local renamed = root .. "/renamed.txt"
  local nested_file = nested .. "/inside.txt"
  local link = root .. "/plain-link.txt"

  rm_rf(root)
  mkdir_p(nested)
  mkdir_p(skip_dir)
  write_file(plain, "hello")
  write_file(nested_file, "inside")
  os.execute(string.format("ln -sf %q %q", plain, link))

  local ok_missing, err_missing = fs.mkdir_p(nil)
  assert_eq(ok_missing, false, "fs.mkdir_p invalid path ok")
  assert_true(type(err_missing) == "string", "fs.mkdir_p invalid path err")
  assert_eq(fs.exists(root), true, "fs.exists root")
  assert_eq(fs.exists(root .. "/missing"), false, "fs.exists missing")
  assert_eq(fs.is_dir(root), true, "fs.is_dir root")
  assert_eq(fs.is_file(plain), true, "fs.is_file plain")
  assert_eq(fs.is_symlink(link), true, "fs.is_symlink link")

  local st = fs.stat(plain)
  assert_true(type(st) == "table" and st.is_file == true, "fs.stat plain")
  local lst = fs.lstat(link)
  assert_true(type(lst) == "table" and lst.is_symlink == true, "fs.lstat symlink")
  local mtime, size = fs.file_meta(plain)
  assert_true(type(mtime) == "number" and mtime > 0, "fs.file_meta mtime")
  assert_eq(size, 5, "fs.file_meta size")
  assert_eq(fs.file_meta(root .. "/missing"), nil, "fs.file_meta missing")
  assert_eq(fs.realpath(nil), nil, "fs.realpath invalid")
  local real_root = fs.realpath(root)
  assert_true(type(real_root) == "string" and real_root ~= "", "fs.realpath root")

  local dirs = fs.list_dirs(root)
  assert_true(#dirs >= 2, "fs.list_dirs entries")
  local files = fs.list_files(root)
  assert_eq(files[1], plain, "fs.list_files plain")

  local recursive_dirs = fs.list_dirs_recursive(root, function(path)
    return path == skip_dir
  end)
  assert_true(#recursive_dirs >= 2, "fs.list_dirs_recursive entries")
  local saw_skip_dir = false
  for _, path in ipairs(recursive_dirs) do
    if path == skip_dir then
      saw_skip_dir = true
    end
  end
  assert_eq(saw_skip_dir, false, "fs.list_dirs_recursive skip_fn")

  write_file(skip_dir .. "/hidden.txt", "skip")
  local recursive_files = fs.list_files_recursive(root, 2, function(path)
    return path == skip_dir
  end)
  assert_true(#recursive_files >= 2, "fs.list_files_recursive entries")
  local saw_nested = false
  local saw_skip_file = false
  for _, path in ipairs(recursive_files) do
    if path == nested_file then
      saw_nested = true
    end
    if path == skip_dir .. "/hidden.txt" then
      saw_skip_file = true
    end
  end
  assert_eq(saw_nested, true, "fs.list_files_recursive nested file")
  assert_eq(saw_skip_file, false, "fs.list_files_recursive skip file")

  local rename_ok = fs.rename_atomic(plain, renamed)
  assert_eq(rename_ok, true, "fs.rename_atomic")
  assert_eq(fs.is_file(renamed), true, "fs.rename_atomic target")
  assert_eq(fs.remove_tree(link), true, "fs.remove_tree symlink")
  assert_eq(fs.remove_tree(skip_dir), true, "fs.remove_tree dir")
  assert_eq(fs.remove_tree(root .. "/missing"), true, "fs.remove_tree missing")

  local stat_impl = get_upvalue(fs.stat, "stat_impl")
  local read_dir_entries = get_upvalue(fs.list_dirs, "read_dir_entries")
  local should_skip_entry = get_upvalue(fs.list_files_recursive, "should_skip_entry")

  assert_true(type(read_dir_entries) == "function", "fs read_dir_entries helper")
  assert_true(type(should_skip_entry) == "function", "fs should_skip_entry helper")

  do
    local original_require = _G.require
    local original_fs = package.loaded["fastfn.core.fs"]
    _G.require = function(name)
      if name == "ffi" then
        error("ffi missing")
      end
      return original_require(name)
    end
    package.loaded["fastfn.core.fs"] = nil
    local missing_ffi_fs = require("fastfn.core.fs")
    local st, err = missing_ffi_fs.stat(root)
    assert_eq(st, nil, "fs.stat ffi unavailable")
    assert_eq(err, "ffi and bit are required", "fs.stat ffi unavailable error")
    local rp, rp_err = missing_ffi_fs.realpath(root)
    assert_eq(rp, nil, "fs.realpath ffi unavailable")
    assert_eq(rp_err, "ffi and bit are required", "fs.realpath ffi unavailable error")
    local missing_dirs = missing_ffi_fs.list_dirs(root)
    assert_true(type(missing_dirs) == "table" and #missing_dirs == 0, "fs.list_dirs ffi unavailable returns empty table")
    local mk_ok, mk_err = missing_ffi_fs.mkdir_p("mkdir-fail")
    assert_eq(mk_ok, false, "fs.mkdir_p ffi unavailable")
    assert_eq(mk_err, "ffi and bit are required", "fs.mkdir_p ffi unavailable error")
    local rn_ok, rn_err = missing_ffi_fs.rename_atomic("a", "b")
    assert_eq(rn_ok, false, "fs.rename_atomic ffi unavailable")
    assert_eq(rn_err, "ffi and bit are required", "fs.rename_atomic ffi unavailable error")
    local rm_ok, rm_err = missing_ffi_fs.remove_tree("remove-error")
    assert_eq(rm_ok, false, "fs.remove_tree ffi unavailable")
    assert_eq(rm_err, "ffi and bit are required", "fs.remove_tree ffi unavailable error")
    package.loaded["fastfn.core.fs"] = original_fs
    _G.require = original_require
  end

  do
    local original_require = _G.require
    local original_fs = package.loaded["fastfn.core.fs"]
    _G.require = function(name)
      if name == "ffi" then
        return {
          cdef = function()
            error("broken cdef")
          end,
        }
      end
      return original_require(name)
    end
    package.loaded["fastfn.core.fs"] = nil
    local broken_cdef_fs = require("fastfn.core.fs")
    local st, err = broken_cdef_fs.stat(root)
    assert_eq(st, nil, "fs.stat cdef failure")
    assert_true(type(err) == "string" and err:find("broken cdef", 1, true) ~= nil, "fs.stat cdef failure error")
    package.loaded["fastfn.core.fs"] = original_fs
    _G.require = original_require
  end

  local invalid_st, invalid_st_err = fs.stat("")
  assert_eq(invalid_st, nil, "fs.stat invalid path")
  assert_eq(invalid_st_err, "invalid path", "fs.stat invalid path error")

  with_upvalue(fs.realpath, "ensure_ffi", function()
    return true
  end, function()
    with_upvalue(fs.realpath, "ffi", {
      C = {
        realpath = function()
          return nil
        end,
        free = function() end,
      },
      string = function(ptr)
        return ptr
      end,
    }, function()
      assert_eq(fs.realpath(root), nil, "fs.realpath nil pointer")
    end)
  end)

  with_upvalue(fs.realpath, "ensure_ffi", function()
    return true
  end, function()
    with_upvalue(fs.realpath, "ffi", {
      C = {
        realpath = function()
          return {}
        end,
        free = function() end,
      },
      string = function()
        return ""
      end,
    }, function()
      assert_eq(fs.realpath(root), nil, "fs.realpath empty string")
    end)
  end)

  do
    local prev_lstat = fs.lstat
    local calls = 0
    fs.lstat = function(path)
      calls = calls + 1
      assert_eq(path, root .. "/mystery", "fs.read_dir_entries lstat path")
      return { is_dir = false, is_file = true, is_symlink = false }
    end
    with_upvalue(read_dir_entries, "ensure_ffi", function()
      return true
    end, function()
      local sequence = {
        { d_name = ".", d_type = 4 },
        { d_name = "mystery", d_type = 0 },
      }
      local idx = 0
      with_upvalue(read_dir_entries, "ffi", {
        C = {
          opendir = function()
            return {}
          end,
          readdir = function()
            idx = idx + 1
            return sequence[idx]
          end,
          closedir = function()
            return 0
          end,
        },
        string = function(value)
          return value
        end,
      }, function()
        local entries = read_dir_entries(root .. "/")
        assert_eq(#entries, 1, "fs.read_dir_entries mystery entry count")
        assert_eq(entries[1].path, root .. "/mystery", "fs.read_dir_entries join_path with trailing slash")
        assert_eq(entries[1].is_file, true, "fs.read_dir_entries unknown dtype falls back to lstat")
      end)
    end)
    fs.lstat = prev_lstat
    assert_eq(calls, 1, "fs.read_dir_entries lstat fallback called once")
  end

  local root_skipped = fs.list_dirs_recursive(root, function(path)
    return path == root
  end)
  assert_eq(#root_skipped, 0, "fs.list_dirs_recursive skips root when requested")

  local recursive_files_no_skip = fs.list_files_recursive(root, 2)
  assert_true(#recursive_files_no_skip >= 2, "fs.list_files_recursive without skip_fn")

  local recursive_files_depth_limited = fs.list_files_recursive(root, 0)
  assert_eq(#recursive_files_depth_limited, 1, "fs.list_files_recursive stops when depth exceeds limit")

  local recursive_files_skip_entry = fs.list_files_recursive(root, 2, function(entry)
    return type(entry) == "table" and entry.is_file == true
  end)
  assert_eq(#recursive_files_skip_entry, 0, "fs.list_files_recursive skip_fn can skip entry tables")

  assert_eq(should_skip_entry(nil, { path = plain }), false, "fs.should_skip_entry nil callback")
  assert_eq(should_skip_entry(function(entry)
    return type(entry) == "table" and entry.path == plain
  end, { path = plain }), true, "fs.should_skip_entry entry callback")

  local root_ok, root_err = fs.mkdir_p("/")
  assert_eq(root_ok, true, root_err or "fs.mkdir_p root slash")

  with_upvalue(fs.mkdir_p, "ensure_ffi", function()
    return true
  end, function()
    with_upvalue(fs.mkdir_p, "M", {
      stat = function()
        return nil
      end,
    }, function()
      with_upvalue(fs.mkdir_p, "ffi", {
        C = {
          mkdir = function()
            return -1
          end,
        },
        errno = function()
          return 1
        end,
      }, function()
        local ok, err = fs.mkdir_p("mkdir-error/child")
        assert_eq(ok, false, "fs.mkdir_p mkdir failure")
        assert_eq(err, "mkdir failed", "fs.mkdir_p mkdir failure error")
      end)
    end)
  end)

  with_upvalue(fs.mkdir_p, "ensure_ffi", function()
    return true
  end, function()
    with_upvalue(fs.mkdir_p, "M", {
      stat = function()
        return { is_dir = false }
      end,
    }, function()
      local ok, err = fs.mkdir_p("not-a-dir/child")
      assert_eq(ok, false, "fs.mkdir_p non-directory component")
      assert_eq(err, "path component is not a directory", "fs.mkdir_p non-directory error")
    end)
  end)

  local bad_rename_ok, bad_rename_err = fs.rename_atomic("", "b")
  assert_eq(bad_rename_ok, false, "fs.rename_atomic invalid src")
  assert_eq(bad_rename_err, "invalid path", "fs.rename_atomic invalid src error")

  with_upvalue(fs.rename_atomic, "ensure_ffi", function()
    return true
  end, function()
    with_upvalue(fs.rename_atomic, "ffi", {
      C = {
        rename = function()
          return -1
        end,
      },
    }, function()
      local ok, err = fs.rename_atomic("a", "b")
      assert_eq(ok, false, "fs.rename_atomic rename failure")
      assert_eq(err, "rename failed", "fs.rename_atomic rename failure error")
    end)
  end)

  with_upvalue(fs.remove_tree, "ensure_ffi", function()
    return true
  end, function()
    with_upvalue(fs.remove_tree, "read_dir_entries", function()
      return { { path = "child" } }
    end, function()
      with_upvalue(fs.remove_tree, "M", {
        lstat = function(path)
          if path == "parent" then
            return { is_dir = true, is_symlink = false }
          end
          return { is_dir = false, is_symlink = false }
        end,
        remove_tree = function(path)
          if path == "child" then
            return false, "child failure"
          end
          return fs.remove_tree(path)
        end,
      }, function()
        local ok, err = fs.remove_tree("parent")
        assert_eq(ok, false, "fs.remove_tree child failure")
        assert_eq(err, "child failure", "fs.remove_tree child failure detail")
      end)
    end)
  end)

  with_upvalue(fs.remove_tree, "ensure_ffi", function()
    return true
  end, function()
    with_upvalue(fs.remove_tree, "read_dir_entries", function()
      return {}
    end, function()
      with_upvalue(fs.remove_tree, "M", {
        lstat = function()
          return { is_dir = true, is_symlink = false }
        end,
        remove_tree = function(path)
          return fs.remove_tree(path)
        end,
      }, function()
        with_upvalue(fs.remove_tree, "ffi", {
          C = {
            rmdir = function()
              return -1
            end,
            unlink = function()
              return 0
            end,
          },
        }, function()
          local ok, err = fs.remove_tree("dir-error")
          assert_eq(ok, false, "fs.remove_tree rmdir failure")
          assert_eq(err, "rmdir failed", "fs.remove_tree rmdir failure detail")
        end)
      end)
    end)
  end)

  with_upvalue(fs.remove_tree, "ensure_ffi", function()
    return true
  end, function()
    with_upvalue(fs.remove_tree, "M", {
      lstat = function()
        return { is_dir = false, is_symlink = false }
      end,
      remove_tree = function(path)
        return fs.remove_tree(path)
      end,
    }, function()
      with_upvalue(fs.remove_tree, "ffi", {
        C = {
          rmdir = function()
            return 0
          end,
          unlink = function()
            return -1
          end,
        },
      }, function()
        local ok, err = fs.remove_tree("file-error")
        assert_eq(ok, false, "fs.remove_tree unlink failure")
        assert_eq(err, "unlink failed", "fs.remove_tree unlink failure detail")
      end)
    end)
  end)

  rm_rf(root)
end

test_guard_console_rate_limits = function()
  with_fake_ngx(function()
    local cjson = require("cjson.safe")
    with_module_stubs({
      ["fastfn.console.auth"] = {
        login_enabled = function() return false end,
        api_login_enabled = function() return false end,
        read_session = function() return nil end,
      },
    }, function()
      local out = ""
      ngx.say = function(s) out = out .. tostring(s) end
      ngx.var.remote_addr = "127.0.0.1"

      with_env({
        FN_CONSOLE_API_ENABLED = "1",
        FN_ADMIN_API_ENABLED = "1",
        FN_CONSOLE_LOCAL_ONLY = "0",
        FN_CONSOLE_RATE_LIMIT_MAX = "2",
        FN_CONSOLE_RATE_LIMIT_WINDOW_S = "60",
        FN_CONSOLE_WRITE_RATE_LIMIT_MAX = "1",
        FN_CONSOLE_WRITE_ENABLED = "1",
        FN_ADMIN_TOKEN = false,
      }, function()
        package.loaded["fastfn.console.guard"] = nil
        local guard = require("fastfn.console.guard")

        ngx.req.get_method = function() return "GET" end
        ngx.req.get_headers = function() return {} end
        assert_eq(guard.enforce_api({ skip_login = true }), true, "first api request allowed")
        assert_eq(guard.enforce_api({ skip_login = true }), true, "second api request allowed")
        out = ""
        ngx.status = 0
        assert_eq(guard.enforce_api({ skip_login = true }), false, "third api request limited")
        assert_eq(ngx.status, 429, "api limit status")
        local api_body = cjson.decode(out) or {}
        assert_eq(api_body.error, "too many console requests, try again later", "api limit error")

        package.loaded["fastfn.console.guard"] = nil
        local guard_write = require("fastfn.console.guard")
        ngx.req.get_method = function() return "POST" end
        ngx.req.get_headers = function() return { ["x-fn-request"] = "1" } end
        assert_eq(guard_write.enforce_write(), true, "first write request allowed")
        out = ""
        ngx.status = 0
        assert_eq(guard_write.enforce_write(), false, "second write request limited")
        assert_eq(ngx.status, 429, "write limit status")
        local write_body = cjson.decode(out) or {}
        assert_eq(write_body.error, "too many console requests, try again later", "write limit error")

        reset_shared_dict(ngx.shared.fn_cache)
        package.loaded["fastfn.console.guard"] = nil
        local guard_ui = require("fastfn.console.guard")
        ngx.req.get_method = function() return "GET" end
        ngx.req.get_headers = function() return {} end
        with_env({
          FN_UI_ENABLED = "1",
          FN_CONSOLE_LOCAL_ONLY = "0",
          FN_CONSOLE_RATE_LIMIT_MAX = "1",
          FN_ADMIN_TOKEN = false,
        }, function()
          assert_eq(guard_ui.enforce_ui(), true, "first ui request allowed")
          out = ""
          ngx.status = 0
          assert_eq(guard_ui.enforce_ui(), false, "second ui request limited")
          assert_eq(ngx.status, 429, "ui limit status")
          local ui_body = cjson.decode(out) or {}
          assert_eq(ui_body.error, "too many console requests, try again later", "ui limit error")
        end)

        package.loaded["fastfn.console.guard"] = nil
        local helper_guard = require("fastfn.console.guard")
        local enforce_rate_limit = get_upvalue(helper_guard.enforce_api, "enforce_rate_limit")
        local env_num = type(enforce_rate_limit) == "function" and get_upvalue(enforce_rate_limit, "env_num") or nil
        assert_true(type(enforce_rate_limit) == "function", "guard enforce_rate_limit helper")
        assert_true(type(env_num) == "function", "guard env_num helper")

        with_env({ FN_CONSOLE_RATE_LIMIT_WINDOW_S = "oops" }, function()
          assert_eq(env_num("FN_CONSOLE_RATE_LIMIT_WINDOW_S", 60), 60, "guard env_num invalid falls back")
        end)

        with_upvalue(enforce_rate_limit, "state_store", function()
          return nil
        end, function()
          assert_eq(enforce_rate_limit("api"), true, "guard rate limit skipped without state store")
        end)

        with_env({ FN_CONSOLE_RATE_LIMIT_WINDOW_S = "0" }, function()
          ngx.req.get_method = function() return "GET" end
          assert_eq(enforce_rate_limit("api"), true, "guard rate limit skipped when window disabled")
        end)

        with_env({ FN_CONSOLE_RATE_LIMIT_MAX = "0" }, function()
          ngx.req.get_method = function() return "GET" end
          assert_eq(enforce_rate_limit("api"), true, "guard rate limit skipped when max disabled")
        end)

        do
          local logs = {}
          local prev_log = ngx.log
          ngx.log = function(...)
            local parts = { ... }
            for i = 1, #parts do
              parts[i] = tostring(parts[i])
            end
            logs[#logs + 1] = table.concat(parts)
          end
          with_upvalue(enforce_rate_limit, "state_store", function()
            return {
              incr = function()
                return nil, "boom"
              end,
            }
          end, function()
            ngx.req.get_method = function() return "POST" end
            assert_eq(enforce_rate_limit("write"), true, "guard rate limit store errors are non-fatal")
          end)
          ngx.log = prev_log
          assert_true(#logs >= 1, "guard rate limit logs incr failures")
        end

        package.loaded["fastfn.console.guard"] = nil
      end)
    end)
  end)
end

test_console_login_endpoint_rate_limit_env_and_reset = function()
  with_fake_ngx(function(cache)
    local status = 0
    local body = nil
    local attempts = 0

    ngx.var.remote_addr = "127.0.0.1"
    ngx.req.get_method = function()
      return "POST"
    end
    ngx.req.read_body = function() end
    ngx.req.get_headers = function()
      return { ["x-fn-request"] = "1" }
    end

    with_env({
      FN_CONSOLE_LOGIN_RATE_LIMIT_MAX = "1",
      FN_CONSOLE_LOGIN_RATE_LIMIT_WINDOW_S = "60",
    }, function()
      with_module_stubs({
        ["fastfn.console.guard"] = {
          enforce_api = function()
            return true
          end,
          enforce_body_limit = function()
            return true
          end,
          write_json = function(s, obj)
            status = s
            body = obj
          end,
        },
        ["fastfn.console.auth"] = {
          login_enabled = function()
            return true
          end,
          username = function()
            return "admin"
          end,
          credentials_configured = function()
            return true
          end,
          constant_time_eq = function(a, b)
            return a == b
          end,
          verify_password = function(password)
            attempts = attempts + 1
            return password == "right" and attempts >= 2
          end,
          set_session_cookie = function(user)
            ngx.header["Set-Cookie"] = "fastfn_session=ok"
            return user == "admin"
          end,
        },
      }, function()
        ngx.req.get_body_data = function()
          return '{"username":"admin","password":"wrong"}'
        end
        status, body = 0, nil
        dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/login_endpoint.lua")
        assert_eq(status, 401, "first bad login should fail")
        assert_eq((body or {}).error, "invalid credentials", "first bad login error")

        status, body = 0, nil
        dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/login_endpoint.lua")
        assert_eq(status, 429, "second bad login should hit configured rate limit")
        assert_eq((body or {}).error, "too many login attempts, try again later", "configured login limit error")

        cache:delete("login:fail:127.0.0.1")
        ngx.req.get_body_data = function()
          return '{"username":"admin","password":"right"}'
        end
        status, body = 0, nil
        dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/login_endpoint.lua")
        assert_eq(status, 200, "successful login should pass")
        assert_eq((body or {}).ok, true, "successful login response")
        assert_eq(cache:get("login:fail:127.0.0.1"), nil, "successful login should clear failure counter")

        ngx.req.get_body_data = function()
          return '{"username":"admin","password":"wrong"}'
        end
        status, body = 0, nil
        dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/login_endpoint.lua")
        assert_eq(status, 401, "post-success failure should start a new counter")
        assert_eq((body or {}).error, "invalid credentials", "post-success failure stays below limit")
      end)
    end)
  end)
end

test_guard_update_state_store_unavailable = function()
  with_fake_ngx(function()
    with_module_stubs({
      ["fastfn.console.auth"] = {
        login_enabled = function() return false end,
        api_login_enabled = function() return false end,
        read_session = function() return nil end,
      },
    }, function()
      package.loaded["fastfn.console.guard"] = nil
      local guard = require("fastfn.console.guard")

      -- Validation failures
      local bad1, err1 = guard.update_state(42)
      assert_eq(bad1, nil, "update_state number should fail")
      assert_true(type(err1) == "string" and err1:find("payload must be", 1, true) ~= nil, "update_state number error")

      local bad2, err2 = guard.update_state({ api_enabled = "string" })
      assert_eq(bad2, nil, "update_state non-boolean field should fail")
      assert_true(type(err2) == "string" and err2:find("must be boolean", 1, true) ~= nil, "update_state non-boolean error")

      -- Store unavailable
      local saved_shared = ngx.shared
      ngx.shared = nil

      local bad3, err3 = guard.update_state({ ui_enabled = true })
      assert_eq(bad3, nil, "update_state without store should fail")
      assert_true(type(err3) == "string" and err3:find("state store unavailable", 1, true) ~= nil, "update_state store error")

      local bad4, err4 = guard.clear_state()
      assert_eq(bad4, nil, "clear_state without store should fail")
      assert_true(type(err4) == "string" and err4:find("state store unavailable", 1, true) ~= nil, "clear_state store error")

      ngx.shared = saved_shared
      package.loaded["fastfn.console.guard"] = nil
    end)
  end)
end

test_ui_state_endpoint_remaining_branches = function()
  -- Test 405 for unsupported method (e.g. TRACE)
  local original_ngx = _G.ngx
  local original_guard = package.loaded["fastfn.console.guard"]
  local calls = { write_json = 0 }
  package.loaded["fastfn.console.guard"] = {
    enforce_api = function() return true end,
    enforce_write = function() return true end,
    enforce_body_limit = function() return false end,
    state_snapshot = function() return { ui_enabled = true } end,
    clear_state = function() return nil, "store down" end,
    update_state = function() return nil, "update failed" end,
    write_json = function(status, body)
      calls.write_json = calls.write_json + 1
      calls.last_status = status
      calls.last_body = body
    end,
  }

  -- TRACE method should get 405
  _G.ngx = {
    req = {
      get_method = function() return "TRACE" end,
      read_body = function() end,
      get_body_data = function() return "{}" end,
    },
  }
  calls.write_json = 0
  dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  assert_eq(calls.last_status, 405, "ui-state TRACE method not allowed")

  -- enforce_body_limit returns false (stops processing)
  _G.ngx.req.get_method = function() return "POST" end
  calls.write_json = 0
  package.loaded["fastfn.console.guard"].enforce_body_limit = function() return false end
  dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  -- Should stop after enforce_body_limit returns false; write_json should not be called for update
  assert_eq(calls.write_json, 0, "ui-state should stop when body limit fails")

  -- Invalid JSON body
  package.loaded["fastfn.console.guard"].enforce_body_limit = function() return true end
  _G.ngx.req.get_method = function() return "POST" end
  _G.ngx.req.get_body_data = function() return "{bad json" end
  calls.write_json = 0
  dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  assert_eq(calls.last_status, 400, "ui-state invalid json body status")
  assert_eq(calls.last_body.error, "invalid json body", "ui-state invalid json body error")

  -- update_state error
  _G.ngx.req.get_method = function() return "PUT" end
  _G.ngx.req.get_body_data = function() return '{"ui_enabled":true}' end
  calls.write_json = 0
  dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  assert_eq(calls.last_status, 400, "ui-state update_state error status")
  assert_eq(calls.last_body.error, "update failed", "ui-state update_state error body")

  -- DELETE with clear_state failure
  _G.ngx.req.get_method = function() return "DELETE" end
  calls.write_json = 0
  dofile(REPO_ROOT .. "/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  assert_eq(calls.last_status, 500, "ui-state delete clear_state failure status")
  assert_eq(calls.last_body.error, "store down", "ui-state delete clear_state failure error")

  package.loaded["fastfn.console.guard"] = original_guard
  _G.ngx = original_ngx
end

test_invoke_rules_remaining_branches = function()
  with_fake_ngx(function()
    package.loaded["fastfn.core.invoke_rules"] = nil
    local rules = require("fastfn.core.invoke_rules")

    -- normalized_methods with nil fallback (exercises copy_list with DEFAULT_METHODS)
    local nm_nil = rules.normalized_methods(nil, nil)
    assert_true(type(nm_nil) == "table" and nm_nil[1] == "GET", "normalized_methods nil fallback uses DEFAULT_METHODS")

    -- normalized_methods where parsed returns non-nil but empty-like (exercises fallback)
    local nm_empty = rules.normalized_methods({}, nil)
    assert_true(type(nm_empty) == "table" and nm_empty[1] == "GET", "normalized_methods empty table falls through to fallback")

    -- parse_invoke_routes with routes key that's a table (exercises the routes branch in merge)
    local ir_routes_only = rules.parse_invoke_routes({ routes = { "/api/test" } })
    assert_true(type(ir_routes_only) == "table" and #ir_routes_only == 1, "parse_invoke_routes routes-only")
    assert_eq(ir_routes_only[1], "/api/test", "parse_invoke_routes routes-only value")

    -- parse_invoke_routes with both route and routes containing same route (exercises dedup in merge)
    local ir_dedup = rules.parse_invoke_routes({ route = "/api/a", routes = { "/api/a" } })
    assert_true(type(ir_dedup) == "table" and #ir_dedup == 1, "parse_invoke_routes dedup via merge")

    -- parse_route_list with table containing an invalid route (exercises add returning false)
    local rl_invalid = rules.parse_route_list({ "/valid", "no-slash", "/also-valid" })
    assert_true(type(rl_invalid) == "table" and #rl_invalid == 2, "parse_route_list skips invalid entries")

    -- route_is_reserved: exact match for /_fn prefix itself (not subpath)
    assert_eq(rules.route_is_reserved("/_fn"), true, "/_fn exact is reserved")
    assert_eq(rules.route_is_reserved("/console"), true, "/console exact is reserved")

    -- parse_methods: exercises dedup with repeated valid methods
    local m_dedup = rules.parse_methods({ "GET", "get", "GET" })
    assert_true(type(m_dedup) == "table" and #m_dedup == 1, "parse_methods dedup")

    -- parse_methods with string input (exercises the string branch at line 43-46)
    local m_str = rules.parse_methods("GET,POST,DELETE")
    assert_true(type(m_str) == "table" and #m_str == 3, "parse_methods string input")
    assert_eq(m_str[1], "GET", "parse_methods string first")
    assert_eq(m_str[2], "POST", "parse_methods string second")
    assert_eq(m_str[3], "DELETE", "parse_methods string third")

    -- parse_methods with string containing invalid methods (only valid ones kept)
    local m_str2 = rules.parse_methods("GET BOGUS POST")
    assert_true(type(m_str2) == "table" and #m_str2 == 2, "parse_methods string filters invalid")

    -- normalize_route with "///" collapses to "/" and remains reserved.
    assert_eq(rules.normalize_route("///"), nil, "normalize_route all slashes collapses to root (reserved)")

    -- normalize_route with "///hello///" which collapses slashes and strips trailing to "/hello"
    local n_triple = rules.normalize_route("///hello///")
    assert_eq(n_triple, "/hello", "normalize_route triple slashes normalizes")

    package.loaded["fastfn.core.invoke_rules"] = nil
  end)
end

test_jobs_remaining_coverage_gaps = function()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-jobs-cov2-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/jobs")

    local routes_stub = {
      get_config = function()
        return { functions_root = root, socket_base_dir = root, runtimes = { lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true } } }
      end,
      resolve_named_target = function(name, version)
        if name == "demo" then return "lua", version end
        if name == "demo-py" then return "python", version end
        return nil, nil
      end,
      discover_functions = function()
        return { mapped_routes = { ["/demo/:id"] = { { runtime = "lua", fn_name = "demo", version = nil, methods = { "GET", "POST" } } } } }
      end,
      resolve_function_policy = function(runtime, name)
        if name ~= "demo" then return nil, "unknown function" end
        return { methods = { "GET", "POST" }, timeout_ms = 1000, max_concurrency = 2, max_body_bytes = 4096 }
      end,
      get_runtime_config = function(rt)
        if rt == "python" then return { socket = "unix:/tmp/fn-python.sock", timeout_ms = 2500 } end
        return { socket = "inprocess:lua", timeout_ms = 2500, in_process = true }
      end,
      runtime_is_up = function() return true end,
      check_runtime_health = function() return true, "ok" end,
      set_runtime_health = function() end,
      runtime_is_in_process = function(rt) return rt == "lua" end,
      get_runtime_sockets = function() return {} end,
      pick_runtime_socket = function() return nil, nil, "single", "runtime unavailable" end,
      set_runtime_socket_health = function() end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.limits"] = { try_acquire = function() return true end, release = function() end },
      ["fastfn.core.gateway_utils"] = { map_runtime_error = function(code) if code == "connect_error" then return 503, "runtime down" elseif code == "timeout" then return 504, "runtime timeout" end return 502, "runtime error" end, resolve_numeric = function(a, b, c, d) return tonumber(a) or tonumber(b) or tonumber(c) or d end },
      ["fastfn.core.lua_runtime"] = { call = function() return { status = 200, headers = {}, body = '{"ok":true}' } end },
      ["fastfn.core.client"] = { call_unix = function() return nil, "connect_error", "connection refused" end },
      ["fastfn.core.client"] = { call_unix = function() return nil, "connect_error", "down" end },
      ["fastfn.core.invoke_rules"] = { normalize_route = function(route) if type(route) == "string" and route:sub(1, 1) == "/" then return route end return nil end },
    }, function()
      package.loaded["fastfn.core.jobs"] = nil
      local jobs = require("fastfn.core.jobs")

      local process_queue = get_upvalue(jobs.init, "process_queue")
      local run_job = get_upvalue(process_queue, "run_job")
      local set_meta = get_upvalue(run_job, "set_meta")
      local get_meta = get_upvalue(run_job, "get_meta")
      local job_cancel_key = get_upvalue(run_job, "job_cancel_key")
      local normalize_body = get_upvalue(jobs.enqueue, "normalize_body")
      local ensure_name = get_upvalue(jobs.enqueue, "ensure_name")
      local write_spec = get_upvalue(jobs.enqueue, "write_spec")

      -- run_job with premature=true should return immediately
      run_job(true, "premature-id")

      -- run_job with no meta should decrement active and return
      cache:set("jobs:active", 5)
      run_job(false, "no-meta-id")
      local active_after = cache:get("jobs:active")
      assert_eq(active_after, 4, "run_job no meta should decrement active")

      -- run_job with canceled job
      local cancel_id = "job-cancel-cov"
      set_meta(cancel_id, { id = cancel_id, status = "queued", max_attempts = 1, attempt = 0 })
      cache:set(job_cancel_key(cancel_id), 1)
      cache:set("jobs:active", 3)
      run_job(false, cancel_id)
      local cancel_meta = get_meta(cancel_id)
      assert_eq(cancel_meta.status, "canceled", "run_job canceled job should set status=canceled")
      cache:delete(job_cancel_key(cancel_id))

      -- run_job where invoke_one raises an exception (xpcall error path)
      local exc_id = "job-exception-cov"
      set_meta(exc_id, { id = exc_id, status = "queued", max_attempts = 1, attempt = 0 })
      -- Write a spec so read_spec succeeds
      write_spec(exc_id, { runtime = "lua", name = "demo", method = "GET", route = "/demo/exc" })
      local prev_invoke = get_upvalue(run_job, "invoke_one")
      set_upvalue(run_job, "invoke_one", function()
        error("deliberate test exception")
      end)
      cache:set("jobs:active", 2)
      run_job(false, exc_id)
      local exc_meta = get_meta(exc_id)
      assert_eq(exc_meta.status, "failed", "run_job exception should set status=failed")
      assert_eq(exc_meta.result_status, 500, "run_job exception should set result_status=500")
      set_upvalue(run_job, "invoke_one", prev_invoke)

      -- run_job where invoke_one returns error (not resp, status >= 500, max attempts exhausted -> failed)
      local fail_id = "job-maxfail-cov"
      set_meta(fail_id, { id = fail_id, status = "queued", max_attempts = 1, retry_delay_ms = 100, attempt = 0 })
      write_spec(fail_id, { runtime = "lua", name = "demo", method = "GET", route = "/demo/fail" })
      set_upvalue(run_job, "invoke_one", function()
        return nil, 500, "server error", nil, 1
      end)
      cache:set("jobs:active", 2)
      run_job(false, fail_id)
      local fail_meta = get_meta(fail_id)
      assert_eq(fail_meta.status, "failed", "run_job max attempts exhausted should set status=failed")
      set_upvalue(run_job, "invoke_one", prev_invoke)

      -- run_job with retry (attempt < max_attempts, exercises lines 718-724)
      local retry_id = "job-retry-cov"
      set_meta(retry_id, { id = retry_id, status = "queued", max_attempts = 3, retry_delay_ms = 100, attempt = 0 })
      write_spec(retry_id, { runtime = "lua", name = "demo", method = "GET", route = "/demo/retry" })
      set_upvalue(run_job, "invoke_one", function()
        return nil, 500, "transient error", nil, 1
      end)
      cache:set("jobs:active", 2)
      local enqueue_id_fn = get_upvalue(process_queue, "enqueue_id")
      run_job(false, retry_id)
      local retry_meta = get_meta(retry_id)
      assert_eq(retry_meta.status, "queued", "run_job retry should re-queue")
      assert_true(retry_meta.next_run_at_ms ~= nil, "run_job retry should set next_run_at_ms")
      assert_eq(retry_meta.attempt, 1, "run_job retry attempt should be 1")
      set_upvalue(run_job, "invoke_one", prev_invoke)

      -- run_job with base64 response (exercises is_base64 branch lines 683-686)
      local b64_id = "job-b64-cov"
      set_meta(b64_id, { id = b64_id, status = "queued", max_attempts = 1, attempt = 0 })
      write_spec(b64_id, { runtime = "lua", name = "demo", method = "GET", route = "/demo/b64" })
      set_upvalue(run_job, "invoke_one", function()
        return { status = 200, headers = {}, is_base64 = true, body_base64 = "AQID" }, 200, nil, nil, 1
      end)
      cache:set("jobs:active", 2)
      run_job(false, b64_id)
      local b64_meta = get_meta(b64_id)
      assert_eq(b64_meta.status, "done", "run_job b64 response should succeed")
      set_upvalue(run_job, "invoke_one", prev_invoke)

      -- run_job with 405 from invoke_one (method not allowed, with Allow header)
      local ma_id = "job-method-allowed-cov"
      set_meta(ma_id, { id = ma_id, status = "queued", max_attempts = 1, attempt = 0 })
      write_spec(ma_id, { runtime = "lua", name = "demo", method = "DELETE", route = "/demo/ma" })
      set_upvalue(run_job, "invoke_one", function()
        return nil, 405, "method not allowed", { Allow = "GET, POST" }, 1
      end)
      cache:set("jobs:active", 2)
      run_job(false, ma_id)
      local ma_meta = get_meta(ma_id)
      assert_eq(ma_meta.status, "done", "run_job 405 should be done (not retried)")
      assert_eq(ma_meta.result_status, 405, "run_job 405 result status")
      set_upvalue(run_job, "invoke_one", prev_invoke)

      -- process_queue with premature=true
      process_queue(true)

      -- process_queue when worker.id != 0
      local prev_worker_id = ngx.worker.id
      ngx.worker.id = function() return 1 end
      process_queue(false)
      ngx.worker.id = prev_worker_id

      -- process_queue when jobs disabled
      with_env({ FN_JOBS_ENABLED = "0" }, function()
        process_queue(false)
      end)

      -- process_queue where timer.at fails
      local timer_fail_id = "job-timer-fail-cov"
      set_meta(timer_fail_id, { id = timer_fail_id, status = "queued", max_attempts = 1, next_run_at_ms = 0 })
      local prev_dequeue = get_upvalue(process_queue, "dequeue_id")
      local consumed = false
      set_upvalue(process_queue, "dequeue_id", function()
        if consumed then return nil end
        consumed = true
        return timer_fail_id
      end)
      local prev_timer_at = ngx.timer.at
      ngx.timer.at = function() return false, "timer-fail" end
      cache:delete("jobs:active")
      with_env({ FN_JOBS_MAX_CONCURRENCY = "1" }, function()
        process_queue(false)
      end)
      ngx.timer.at = prev_timer_at
      set_upvalue(process_queue, "dequeue_id", prev_dequeue)
      local timer_fail_meta = get_meta(timer_fail_id)
      assert_eq(timer_fail_meta.status, "failed", "process_queue timer fail should mark job as failed")

      -- normalize_body with table input (exercises cjson.encode branch)
      local body_tbl, body_tbl_err = normalize_body({ key = "value" })
      assert_true(type(body_tbl) == "string", "normalize_body table should return encoded string")
      assert_eq(body_tbl_err, nil, "normalize_body table should not error")

      -- normalize_body with cjson.null
      local body_null = normalize_body(cjson.null)
      assert_eq(body_null, "", "normalize_body cjson.null should return empty string")

      -- ensure_name with ".." traversal
      local bad_name_dd, bad_name_dd_err = ensure_name("hello/../bad")
      assert_eq(bad_name_dd, nil, "ensure_name dot-dot should fail")
      assert_true(type(bad_name_dd_err) == "string" and bad_name_dd_err:find("invalid", 1, true) ~= nil, "ensure_name dot-dot error")

      -- ensure_name starting with "/"
      local bad_name_slash, _ = ensure_name("/bad")
      assert_eq(bad_name_slash, nil, "ensure_name leading slash should fail")

      -- Enqueue with method not allowed by policy
      local ma_meta2, ma_status2, ma_err2, ma_hdrs2 = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "DELETE",
        route = "/demo/:id",
        params = { id = "x" },
      })
      assert_eq(ma_meta2, nil, "enqueue method not allowed should fail")
      assert_eq(ma_status2, 405, "enqueue method not allowed status")

      -- Enqueue with context that is not a table (exercises line 881-882)
      local ctx_meta, ctx_status, ctx_err = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "GET",
        route = "/demo/:id",
        params = { id = "ctx" },
        context = "not-a-table",
      })
      assert_eq(ctx_meta, nil, "enqueue non-table context should fail")
      assert_eq(ctx_status, 400, "enqueue non-table context status")
      assert_eq(ctx_err, "context must be an object", "enqueue non-table context error")

      -- Enqueue with invalid route string (exercises line 842-843)
      local irt_meta, irt_status, irt_err = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "GET",
        route = 12345,
      })
      assert_eq(irt_meta, nil, "enqueue non-string route should fail")
      assert_eq(irt_status, 400, "enqueue non-string route status")

      -- Enqueue with body exceeding policy max (exercises line 873-875)
      local big_body = string.rep("x", 5000)
      local bb_meta, bb_status, bb_err = jobs.enqueue({
        runtime = "lua",
        name = "demo",
        method = "GET",
        route = "/demo/:id",
        params = { id = "big" },
        body = big_body,
      })
      assert_eq(bb_meta, nil, "enqueue large body should fail")
      assert_eq(bb_status, 413, "enqueue large body status")

	      -- Enqueue with write_spec failure
	      local write_spec_fail_fn = get_upvalue(jobs.enqueue, "write_spec")
	      assert_true(type(write_spec_fail_fn) == "function", "enqueue write_spec helper available")
	      local prev_write_spec_atomic = get_upvalue(write_spec_fail_fn, "write_file_atomic")
	      set_upvalue(write_spec_fail_fn, "write_file_atomic", function()
	        return nil, "dir-fail"
	      end)
	      local ws_meta, ws_status = jobs.enqueue({
	        runtime = "lua",
	        name = "demo",
	        method = "GET",
	        route = "/demo/:id",
	        params = { id = "ws" },
	      })
	      assert_true(type(ws_meta) == "table", "enqueue write_spec failure returns meta")
	      assert_eq(ws_status, 500, "enqueue write_spec failure status")
	      assert_eq(ws_meta.status, "failed", "enqueue write_spec failure meta status")
	      set_upvalue(write_spec_fail_fn, "write_file_atomic", prev_write_spec_atomic)

      -- Drive call_external_runtime directly through the nested upvalue chain so
      -- we can replace its captured routes/client dependencies deterministically.
      local jobs_call_external_runtime = get_nested_upvalue(run_job, "invoke_one", "call_external_runtime")
      exercise_call_external_runtime(jobs_call_external_runtime, "jobs")

      package.loaded["fastfn.core.jobs"] = nil
    end)

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

test_data_remaining_coverage_gaps = function()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-data-cov2-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/node/fn1")
    write_file(root .. "/node/fn1/handler.js", "exports.handler = async () => ({ status: 200 });\n")

    with_module_stubs({
      ["fastfn.core.routes"] = {
        get_config = function()
          return { functions_root = root, runtimes = { node = { socket = "unix:/tmp/fn.sock" } } }
        end,
        discover_functions = function()
          return {
            runtimes = {
              node = {
                functions = {
                  fn1 = { has_default = true, versions = {} },
                },
              },
            },
            mapped_routes = {},
          }
        end,
        runtime_status = function()
          return { up = true, reason = "ok" }
        end,
        resolve_named_target = function(name)
          if name == "fn1" then return "node", nil end
          return nil
        end,
        resolve_function_policy = function(rt, name)
          if rt == "node" and name == "fn1" then
            return { methods = { "GET" }, timeout_ms = 1000 }
          end
          return nil, "not found"
        end,
      },
      ["fastfn.core.invoke_rules"] = {
        normalize_route = function(r) return r end,
        parse_route_list = function(r) return type(r) == "table" and r or { r } end,
        parse_invoke_routes = function(inv)
          if type(inv) ~= "table" then return nil end
          return inv.routes or (inv.route and { inv.route }) or nil
        end,
        normalized_methods = function(raw, fallback)
          if raw then return type(raw) == "table" and raw or { raw } end
          return fallback or { "GET" }
        end,
      },
    }, function()
      package.loaded["fastfn.console.data"] = nil
      local data = require("fastfn.console.data")

      -- is_symlink where io.popen returns nil (exercises the "if not p" branch)
      local is_symlink = get_upvalue(data.create_function, "is_symlink")
        or get_upvalue(data.delete_function, "is_symlink")
      if type(is_symlink) == "function" then
	        local data_fs = get_upvalue(is_symlink, "fs")
	        local prev_is_symlink = data_fs.is_symlink
	        data_fs.is_symlink = function() return false end
	        assert_eq(is_symlink(root .. "/test.txt"), false, "data is_symlink fs nil returns false")
	        data_fs.is_symlink = prev_is_symlink

        data_fs.is_symlink = nil
        assert_eq(is_symlink(root .. "/test.txt"), false, "data is_symlink missing helper returns false")
        data_fs.is_symlink = prev_is_symlink
      end

      local ensure_dir = get_upvalue(data.write_function_file, "ensure_dir")
      local dir_exists = type(ensure_dir) == "function" and get_upvalue(ensure_dir, "dir_exists") or nil
      if type(dir_exists) == "function" then
        local data_fs = get_upvalue(dir_exists, "fs")
        local prev_is_dir = data_fs.is_dir
        data_fs.is_dir = nil
        assert_eq(dir_exists(root), false, "data dir_exists missing helper returns false")
        data_fs.is_dir = prev_is_dir
      end

      local rm_path = get_upvalue(data.delete_function, "rm_path")
      if type(rm_path) == "function" then
        local data_fs = get_upvalue(rm_path, "fs")
        local prev_remove_tree = data_fs.remove_tree
        data_fs.remove_tree = nil
        assert_eq(rm_path(root .. "/test.txt"), false, "data rm_path missing helper returns false")
        data_fs.remove_tree = prev_remove_tree
      end

      local version_children_count = get_upvalue(data.delete_function, "version_children_count")
      local helper_list_dirs = type(version_children_count) == "function"
        and get_upvalue(version_children_count, "list_dirs") or nil
      if type(helper_list_dirs) == "function" then
        local data_fs = get_upvalue(helper_list_dirs, "fs")
        local prev_list_dirs = data_fs.list_dirs
        data_fs.list_dirs = nil
        local empty_dirs = helper_list_dirs(root)
        assert_true(type(empty_dirs) == "table" and #empty_dirs == 0, "data list_dirs missing helper returns empty table")
        data_fs.list_dirs = prev_list_dirs
      end

      -- detect_runtime_from_file_path - it's a local function used inside
      -- resolve_function_paths, which is an upvalue of function_detail.
      -- We need to chain: function_detail -> resolve_function_paths -> detect_runtime_from_file_path
      local resolve_fp = get_upvalue(data.function_detail, "resolve_function_paths")
        or get_upvalue(data.set_function_code, "resolve_function_paths")
      local detect_runtime = nil
      if type(resolve_fp) == "function" then
        detect_runtime = get_upvalue(resolve_fp, "detect_runtime_from_file_path")
      end
      if type(detect_runtime) == "function" then
        assert_eq(detect_runtime("no-extension"), nil, "detect_runtime no ext returns nil")
        assert_eq(detect_runtime("file.unknown"), nil, "detect_runtime unknown ext returns nil")
        assert_eq(detect_runtime("file.rs"), "rust", "detect_runtime .rs returns rust")
        assert_eq(detect_runtime("file.go"), "go", "detect_runtime .go returns go")
        assert_eq(detect_runtime("file.php"), "php", "detect_runtime .php returns php")
        assert_eq(detect_runtime("file.lua"), "lua", "detect_runtime .lua returns lua")
        assert_eq(detect_runtime("file.ts"), "node", "detect_runtime .ts returns node")
      end

      -- allowed_handler_filenames - used directly in delete_function and create_function
      local allowed_fns = get_upvalue(data.delete_function, "allowed_handler_filenames")
        or get_upvalue(data.create_function, "allowed_handler_filenames")
      if type(allowed_fns) == "function" then
        local rust_fns = allowed_fns("rust")
        assert_true(type(rust_fns) == "table" and #rust_fns > 0, "allowed_handler_filenames rust")
        local go_fns = allowed_fns("go")
        assert_true(type(go_fns) == "table" and #go_fns > 0, "allowed_handler_filenames go")
        local unknown_fns = allowed_fns("unknown")
        assert_true(type(unknown_fns) == "table" and #unknown_fns == 0, "allowed_handler_filenames unknown")
        local lua_fns = allowed_fns("lua")
        assert_true(type(lua_fns) == "table" and #lua_fns > 0, "allowed_handler_filenames lua")
      end

      -- validate_file_path - accessed through read_function_file
      local validate_file_path = get_upvalue(data.read_function_file, "validate_file_path")
      if type(validate_file_path) == "function" then
        local ok1, err1 = validate_file_path("")
        assert_eq(ok1, nil, "validate_file_path empty")
        assert_eq(err1, "path required", "validate_file_path empty error")

        local ok2, err2 = validate_file_path("../escape")
        assert_eq(ok2, nil, "validate_file_path dot-dot")
        assert_eq(err2, "invalid path", "validate_file_path dot-dot error")

        local ok3, err3 = validate_file_path("/absolute")
        assert_eq(ok3, nil, "validate_file_path absolute")
        assert_eq(err3, "invalid path", "validate_file_path absolute error")

        local ok5, err5 = validate_file_path("valid/file.js")
        assert_eq(ok5, true, "validate_file_path valid")
      end

      -- classify_file - accessed through function_files
      local classify_file = get_upvalue(data.function_files, "classify_file")
      if type(classify_file) == "function" then
        assert_eq(classify_file("fn.config.json", "node"), "config", "classify_file config")
        assert_eq(classify_file("fn.env.json", "node"), "env", "classify_file env")
        assert_eq(classify_file("package.json", "node"), "deps", "classify_file deps")
        assert_eq(classify_file("package-lock.json", "node"), "lock", "classify_file lock")
        assert_eq(classify_file("handler.js", "node"), "handler", "classify_file handler")
        assert_eq(classify_file("readme.txt", "node"), "file", "classify_file other")
        assert_eq(classify_file("Cargo.toml", "rust"), "deps", "classify_file cargo deps")
        assert_eq(classify_file("Cargo.lock", "rust"), "lock", "classify_file cargo lock")
      end

	      -- file_size where fs.stat returns nil
	      local file_size = get_upvalue(data.function_files, "file_size")
	      if type(file_size) == "function" then
	        local data_fs = get_upvalue(file_size, "fs")
	        local prev_stat = data_fs.stat
	        data_fs.stat = function() return nil end
	        assert_eq(file_size("/nonexistent"), 0, "file_size fs nil returns 0")
	        data_fs.stat = prev_stat
	      end

      -- normalize_config_payload - accessed through set_function_config
      local normalize_config_payload = get_upvalue(data.set_function_config, "normalize_config_payload")
      if type(normalize_config_payload) == "function" then
        -- group too long
        local long_group = string.rep("x", 81)
        local ncl, ncl_err = normalize_config_payload({ group = long_group })
        assert_eq(ncl, nil, "normalize_config_payload group too long")
        assert_true(ncl_err:find("80", 1, true) ~= nil, "normalize_config_payload group len error")

        -- group as cjson.null
        local nc_null = normalize_config_payload({ group = cjson.null })
        assert_true(type(nc_null) == "table", "normalize_config_payload group null ok")

        -- timeout_ms invalid
        local nc_tm, nc_tm_err = normalize_config_payload({ timeout_ms = -1 })
        assert_eq(nc_tm, nil, "normalize_config_payload timeout_ms invalid")

        -- response non-table
        local nc_resp, nc_resp_err = normalize_config_payload({ response = "bad" })
        assert_eq(nc_resp, nil, "normalize_config_payload response non-table")
        assert_eq(nc_resp_err, "response must be an object", "normalize_config_payload response error")

        -- max_body_bytes invalid
        local nc_mb, nc_mb_err = normalize_config_payload({ max_body_bytes = -5 })
        assert_eq(nc_mb, nil, "normalize_config_payload max_body_bytes invalid")

        -- group non-string
        local nc_gn, nc_gn_err = normalize_config_payload({ group = 42 })
        assert_eq(nc_gn, nil, "normalize_config_payload group non-string")
      end

	      -- list_files_recursive where fs helper returns empty
	      local list_files_recursive = get_upvalue(data.function_files, "list_files_recursive")
	      if type(list_files_recursive) == "function" then
	        local data_fs = get_upvalue(list_files_recursive, "fs")
	        local prev_recursive = data_fs.list_files_recursive
	        data_fs.list_files_recursive = function() return {} end
	        local result = list_files_recursive("/nonexistent", 3)
	        assert_true(type(result) == "table" and #result == 0, "list_files_recursive fs empty")
	        data_fs.list_files_recursive = prev_recursive
	      end

      do
        local prev_resolve_paths = get_upvalue(data.function_files, "resolve_function_paths")
        local prev_path_is_under = get_upvalue(data.function_files, "path_is_under")
        set_upvalue(data.function_files, "resolve_function_paths", function()
          return {
            fn_dir = root .. "/node/fn1",
            app_path = root .. "/node/fn1/handler.js",
            conf_path = root .. "/node/fn1/fn.config.json",
            env_path = root .. "/node/fn1/fn.env.json",
          }
        end)
        set_upvalue(data.function_files, "path_is_under", (function()
          local calls = 0
          return function()
            calls = calls + 1
            return calls == 1
          end
        end)())
        local files, files_err = data.function_files("node", "fn1", nil)
        assert_eq(files, nil, "data function_files nested invalid function path")
        assert_eq(files_err, "invalid function path", "data function_files nested invalid function path error")
        set_upvalue(data.function_files, "path_is_under", function()
          return false
        end)
        files, files_err = data.function_files("node", "fn1", nil)
        assert_eq(files, nil, "data function_files invalid function path")
        assert_eq(files_err, "invalid function path", "data function_files invalid function path error")
        set_upvalue(data.function_files, "resolve_function_paths", prev_resolve_paths)
        set_upvalue(data.function_files, "path_is_under", prev_path_is_under)
      end

      do
        local prev_resolve_paths = get_upvalue(data.write_function_file, "resolve_function_paths")
        local prev_ensure_dir = get_upvalue(data.write_function_file, "ensure_dir")
        set_upvalue(data.write_function_file, "resolve_function_paths", function()
          return {
            fn_dir = root .. "/node/fn1",
            app_path = root .. "/node/fn1/handler.js",
            conf_path = root .. "/node/fn1/fn.config.json",
            env_path = root .. "/node/fn1/fn.env.json",
          }
        end)
        set_upvalue(data.write_function_file, "ensure_dir", function()
          return false
        end)
        local wrote, write_err = data.write_function_file("node", "fn1", "nested/file.js", "console.log('x')\n")
        assert_eq(wrote, nil, "data write_function_file parent mkdir failure")
        assert_eq(write_err, "failed to create parent directory", "data write_function_file parent mkdir error")
        set_upvalue(data.write_function_file, "resolve_function_paths", prev_resolve_paths)
        set_upvalue(data.write_function_file, "ensure_dir", prev_ensure_dir)
      end

      do
        write_file(root .. "/node/fn1/extra.js", "console.log('extra')\n")
        local prev_resolve_paths = get_upvalue(data.delete_function_file, "resolve_function_paths")
        local data_fs = get_upvalue(data.delete_function_file, "fs")
        local prev_remove_tree = data_fs.remove_tree
        set_upvalue(data.delete_function_file, "resolve_function_paths", function()
          return {
            fn_dir = root .. "/node/fn1",
            app_path = root .. "/node/fn1/handler.js",
            conf_path = root .. "/node/fn1/fn.config.json",
            env_path = root .. "/node/fn1/fn.env.json",
          }
        end)
        data_fs.remove_tree = function()
          return false
        end
        local deleted, delete_err = data.delete_function_file("node", "fn1", "extra.js")
        assert_eq(deleted, nil, "data delete_function_file remove_tree failure")
        assert_eq(delete_err, "failed to delete file", "data delete_function_file remove_tree error")
        set_upvalue(data.delete_function_file, "resolve_function_paths", prev_resolve_paths)
        data_fs.remove_tree = prev_remove_tree
      end

      package.loaded["fastfn.console.data"] = nil
    end)

    -- Test data.catalog() runtime_socket_statuses fallback (when routes lacks that function).
    -- This exercises data.lua lines 1565-1577 (the or-function fallback).
    with_module_stubs({
      ["fastfn.core.routes"] = {
        get_config = function()
          return {
            functions_root = root,
            runtimes = {
              python = { socket = "unix:/tmp/py.sock", timeout_ms = 2500 },
              go = { timeout_ms = 2500 },
            },
          }
        end,
        discover_functions = function()
          return {
            runtimes = {
              python = { functions = { hello = { has_default = true, versions = {} } } },
              go = { functions = { greet = { has_default = true, versions = {} } } },
            },
            mapped_routes = {},
          }
        end,
        runtime_status = function() return { up = true, reason = "ok" } end,
        resolve_function_policy = function() return {} end,
        -- runtime_socket_statuses intentionally absent to trigger fallback
      },
    }, function()
      package.loaded["fastfn.console.data"] = nil
      local data2 = require("fastfn.console.data")
      local cat = data2.catalog()
      assert_true(type(cat) == "table", "data.catalog with socket_statuses fallback returns table")
      assert_true(type(cat.runtimes) == "table", "data.catalog fallback runtimes table")
      -- python runtime has socket so fallback returns socket status array
      if cat.runtimes.python then
        assert_true(type(cat.runtimes.python.sockets) == "table" and #cat.runtimes.python.sockets == 1,
          "data.catalog fallback python runtime has 1 socket status")
      end
      -- go runtime has no socket so fallback returns {} (empty)
      if cat.runtimes.go then
        assert_true(type(cat.runtimes.go.sockets) == "table" and #cat.runtimes.go.sockets == 0,
          "data.catalog fallback go runtime has 0 socket statuses")
      end
      package.loaded["fastfn.console.data"] = nil
      end)

    with_module_stubs({
      ["fastfn.core.routes"] = {
        get_config = function()
          return {
            functions_root = root,
            runtimes = {
              python = { socket = "unix:/tmp/py.sock", timeout_ms = 2500 },
            },
          }
        end,
        discover_functions = function()
          return {
            runtimes = {
              python = { functions = { hello = { has_default = true, versions = {} } } },
            },
            mapped_routes = {},
          }
        end,
        runtime_status = function() return { up = true, reason = "ok" } end,
        runtime_socket_statuses = function(runtime, cfg_value)
          return {
            {
              index = 1,
              uri = cfg_value.socket,
              up = true,
              ts = 123,
              reason = "ok",
            },
          }
        end,
        resolve_function_policy = function() return {} end,
      },
    }, function()
      package.loaded["fastfn.console.data"] = nil
      local data3 = require("fastfn.console.data")
      local cat = data3.catalog()
      assert_true(type(cat) == "table", "data.catalog with runtime_socket_statuses returns table")
      assert_eq(type(cat.runtimes.python), "table", "data.catalog explicit status python runtime")
      assert_eq(type(cat.runtimes.python.sockets), "table", "data.catalog explicit status sockets table")
      assert_eq(#cat.runtimes.python.sockets, 1, "data.catalog explicit status socket count")
      assert_eq(cat.runtimes.python.sockets[1].up, true, "data.catalog explicit status preserves route helper output")
      package.loaded["fastfn.console.data"] = nil
    end)

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

test_routes_remaining_coverage_gaps = function()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-routes-cov2-" .. uniq
    local functions_root = root .. "/srv/fn/functions"

    rm_rf(root)
    mkdir_p(functions_root .. "/node/hello")
    write_file(functions_root .. "/node/hello/handler.js", "exports.handler = async () => ({ status: 200, body: 'ok' });\n")

    with_module_stubs({
      ["fastfn.core.watchdog"] = {
        start = function() return false, "disabled in unit" end,
      },
    }, function()
      package.loaded["fastfn.core.routes"] = nil
      local routes = require("fastfn.core.routes")
      reset_shared_dict(cache)
      reset_shared_dict(conc)

      -- Access internal helpers via proper upvalue chains.
      -- normalize_edge, normalize_keep_warm, normalize_worker_pool are upvalues
      -- of normalize_policy, which is an upvalue of discover_functions.
      local discover_functions = routes.discover_functions
      local normalize_policy = get_upvalue(discover_functions, "normalize_policy")
      local normalize_edge = type(normalize_policy) == "function" and get_upvalue(normalize_policy, "normalize_edge") or nil
      local normalize_keep_warm = type(normalize_policy) == "function" and get_upvalue(normalize_policy, "normalize_keep_warm") or nil
      local normalize_worker_pool = type(normalize_policy) == "function" and get_upvalue(normalize_policy, "normalize_worker_pool") or nil
      local detect_file_based_routes_in_dir = get_upvalue(discover_functions, "detect_file_based_routes_in_dir")
      local should_treat_file_as_route = type(detect_file_based_routes_in_dir) == "function"
        and get_upvalue(detect_file_based_routes_in_dir, "should_treat_file_as_route")
        or nil
      local is_explicit_file_route = type(should_treat_file_as_route) == "function"
        and get_upvalue(should_treat_file_as_route, "is_explicit_file_route")
        or nil
      -- normalize_zero_config_dir is an upvalue of discover_functions directly
      -- (used in should_skip_zero_config_dir inside discover_functions)
      local normalize_zero_config_dir = get_upvalue(discover_functions, "normalize_zero_config_dir")
      -- host_matches_pattern, split_host_port, resolve_request_host_values:
      -- host_allowlist_matches is used in resolve_mapped_target.
      -- host_matches_pattern is an upvalue of host_allowlist_matches.
      -- resolve_request_host_values is an upvalue of resolve_mapped_target.
      local host_allowlist_matches = get_upvalue(routes.resolve_mapped_target, "host_allowlist_matches")
      local host_matches_pattern = nil
      if type(host_allowlist_matches) == "function" then
        host_matches_pattern = get_upvalue(host_allowlist_matches, "host_matches_pattern")
      end
      local resolve_request_host_values = get_upvalue(routes.resolve_mapped_target, "resolve_request_host_values")
      -- split_host_port is an upvalue of resolve_request_host_values or host_allowlist_matches
      local split_host_port = nil
      if type(resolve_request_host_values) == "function" then
        split_host_port = get_upvalue(resolve_request_host_values, "split_host_port")
      elseif type(host_allowlist_matches) == "function" then
        split_host_port = get_upvalue(host_allowlist_matches, "split_host_port")
      end
      local load_runtime_config = get_upvalue(routes.get_config, "load_runtime_config")

      -- normalize_edge with non-table returns nil
      if type(normalize_edge) == "function" then
        assert_eq(normalize_edge("string"), nil, "normalize_edge string returns nil")
        assert_eq(normalize_edge(nil), nil, "normalize_edge nil returns nil")

        -- normalize_edge with non-string base_url
        local edge1 = normalize_edge({ base_url = 123 })
        assert_true(edge1 == nil or type(edge1) == "table", "normalize_edge numeric base_url")

        -- normalize_edge with empty base_url after trim
        assert_eq(normalize_edge({ base_url = "   " }), nil, "normalize_edge whitespace base_url returns nil")

        -- normalize_edge with allow_private
        local edge2 = normalize_edge({ allow_private = true })
        assert_true(type(edge2) == "table" and edge2.allow_private == true, "normalize_edge allow_private")

        -- normalize_edge with max_response_bytes
        local edge3 = normalize_edge({ max_response_bytes = 1024 })
        assert_true(type(edge3) == "table" and edge3.max_response_bytes == 1024, "normalize_edge max_response_bytes")

        -- normalize_edge with negative max_response_bytes
        local edge4 = normalize_edge({ max_response_bytes = -1 })
        assert_eq(edge4, nil, "normalize_edge negative max_response_bytes returns nil")
      end

      -- normalize_keep_warm edge cases
      if type(normalize_keep_warm) == "function" then
        -- Non-table input
        assert_eq(normalize_keep_warm("not a table"), nil, "normalize_keep_warm string returns nil")

        -- All nil/default values
        assert_eq(normalize_keep_warm({}), nil, "normalize_keep_warm empty returns nil")

        -- enabled=false with negative min_warm
        local kw1 = normalize_keep_warm({ enabled = false, min_warm = -1 })
        assert_eq(kw1, nil, "normalize_keep_warm negative min_warm returns nil")

        -- enabled=false with positive min_warm
        local kw2 = normalize_keep_warm({ enabled = false, min_warm = 2 })
        assert_true(type(kw2) == "table", "normalize_keep_warm disabled with min_warm returns table")
        assert_eq(kw2.min_warm, 2, "normalize_keep_warm disabled min_warm preserved")

        -- Negative ping_every_seconds
        local kw3 = normalize_keep_warm({ enabled = true, ping_every_seconds = -1 })
        assert_true(type(kw3) == "table", "normalize_keep_warm negative ping_every_seconds")

        -- Negative idle_ttl_seconds
        local kw4 = normalize_keep_warm({ enabled = true, idle_ttl_seconds = -1 })
        assert_true(type(kw4) == "table", "normalize_keep_warm negative idle_ttl")
      end

      -- normalize_worker_pool edge cases
      if type(normalize_worker_pool) == "function" then
        assert_eq(normalize_worker_pool("not a table"), nil, "normalize_worker_pool string returns nil")
        assert_true(type(normalize_worker_pool({})) == "table", "normalize_worker_pool empty returns table with defaults")

        -- Negative max_workers nils it but enabled=true so returns table
        local wp1 = normalize_worker_pool({ max_workers = -1 }, nil)
        assert_true(type(wp1) == "table", "normalize_worker_pool negative max_workers returns table")
        assert_eq(wp1.max_workers, nil, "normalize_worker_pool negative max_workers is nil")

        -- Negative max_queue nils it but enabled=true so returns table
        local wp2 = normalize_worker_pool({ max_queue = -1 }, nil)
        assert_true(type(wp2) == "table", "normalize_worker_pool negative max_queue returns table")

        -- enabled=false with no max_workers or max_queue → nil
        local wp3 = normalize_worker_pool({ enabled = false }, nil)
        assert_eq(wp3, nil, "normalize_worker_pool disabled with no workers/queue returns nil")

        -- Invalid overflow_status
        local wp4 = normalize_worker_pool({ max_workers = 2, overflow_status = 400 })
        assert_true(type(wp4) == "table", "normalize_worker_pool invalid overflow_status")

        -- min_warm > max_workers (should clamp)
        local wp5 = normalize_worker_pool({ max_workers = 2, min_warm = 5 })
        assert_true(type(wp5) == "table" and wp5.min_warm == 2, "normalize_worker_pool clamps min_warm to max_workers")
      end

      -- normalize_zero_config_dir edge cases
      if type(normalize_zero_config_dir) == "function" then
        assert_eq(normalize_zero_config_dir(""), nil, "normalize_zero_config_dir empty")
        assert_eq(normalize_zero_config_dir(".."), nil, "normalize_zero_config_dir dot-dot")
        assert_eq(normalize_zero_config_dir("."), nil, "normalize_zero_config_dir dot")
        assert_eq(normalize_zero_config_dir("a/b"), nil, "normalize_zero_config_dir with slash")
        assert_eq(normalize_zero_config_dir("a\\b"), nil, "normalize_zero_config_dir with backslash")
        assert_eq(normalize_zero_config_dir("valid"), "valid", "normalize_zero_config_dir valid")
      end

      assert_true(type(is_explicit_file_route) == "function", "is_explicit_file_route helper available")
      assert_eq(is_explicit_file_route("get.users"), true, "is_explicit_file_route explicit method route")
      assert_eq(is_explicit_file_route("get.post.users"), false, "is_explicit_file_route rejects ambiguous multi-method files")

      -- host_matches_pattern edge cases
      if type(host_matches_pattern) == "function" then
        assert_eq(host_matches_pattern("", "example.com"), false, "host_matches_pattern empty host")
        assert_eq(host_matches_pattern("example.com", ""), false, "host_matches_pattern empty pattern")
        -- Wildcard doesn't match bare domain
        assert_eq(host_matches_pattern("example.com", "*.example.com"), false, "host_matches_pattern wildcard no match bare")
        -- Wildcard matches subdomain
        assert_eq(host_matches_pattern("sub.example.com", "*.example.com"), true, "host_matches_pattern wildcard matches sub")
      end

      -- split_host_port with IPv6
      if type(split_host_port) == "function" then
        local h1, a1 = split_host_port("[::1]:8080")
        assert_eq(h1, "::1", "split_host_port ipv6 host")
      end

      -- resolve_request_host_values edge cases
      if type(resolve_request_host_values) == "function" then
        -- X-Forwarded-Host with comma-separated values (picks first)
        local h, a = resolve_request_host_values("fallback.com", "first.com, second.com")
        assert_eq(h, "first.com", "resolve_request_host_values picks first forwarded host")

        -- Empty forwarded host falls back to Host header
        local h2, a2 = resolve_request_host_values("host.com", "")
        assert_eq(h2, "host.com", "resolve_request_host_values fallback to host header")
      end

      -- get_runtime_sockets with sockets array
      local socks1 = routes.get_runtime_sockets("test", { sockets = { "unix:/a.sock", "unix:/b.sock" } })
      assert_true(type(socks1) == "table" and #socks1 == 2, "get_runtime_sockets with sockets array")

      -- get_runtime_sockets with nil config
      local socks2 = routes.get_runtime_sockets("test", nil)
      assert_true(type(socks2) == "table" and #socks2 == 0, "get_runtime_sockets nil config")

      -- set_runtime_socket_health with invalid index
      assert_eq(routes.set_runtime_socket_health(nil, 1, "uri", true, "ok"), false, "set_runtime_socket_health nil runtime")
      assert_eq(routes.set_runtime_socket_health("test", nil, "uri", true, "ok"), false, "set_runtime_socket_health nil idx")
      assert_eq(routes.set_runtime_socket_health("test", 0, "uri", true, "ok"), false, "set_runtime_socket_health idx 0")

      -- runtime_socket_status with invalid params
      local st1 = routes.runtime_socket_status(nil, 1)
      assert_eq(st1, nil, "runtime_socket_status nil runtime")

      -- pick_runtime_socket for in-process runtime
      local uri, idx, mode, err = routes.pick_runtime_socket("lua", nil)
      assert_eq(uri, nil, "pick_runtime_socket in-process uri nil")
      assert_eq(mode, "in_process", "pick_runtime_socket in-process mode")

      -- pick_runtime_socket with nil config (may return default socket from env)
      local uri2, idx2, mode2, err2 = routes.pick_runtime_socket("python", nil)
      assert_true(uri2 == nil or type(uri2) == "string", "pick_runtime_socket no config returns nil or string")

      -- check_runtime_socket with empty uri
      local crs_ok, crs_err = routes.check_runtime_socket("")
      assert_eq(crs_ok, false, "check_runtime_socket empty uri")

      -- check_runtime_socket with nil
      local crs_ok2, crs_err2 = routes.check_runtime_socket(nil)
      assert_eq(crs_ok2, false, "check_runtime_socket nil")

      -- get_runtime_sockets with single socket string (not sockets array)
      local socks_single = routes.get_runtime_sockets("test", { socket = "unix:/tmp/single.sock" })
      assert_true(type(socks_single) == "table" and #socks_single == 1, "get_runtime_sockets single socket string")
      assert_eq(socks_single[1], "unix:/tmp/single.sock", "get_runtime_sockets single socket value")

      -- get_runtime_sockets with empty socket string
      local socks_empty = routes.get_runtime_sockets("test", { socket = "" })
      assert_true(type(socks_empty) == "table" and #socks_empty == 0, "get_runtime_sockets empty socket string")

      -- get_runtime_sockets with inprocess:lua
      local socks_inproc = routes.get_runtime_sockets("lua", { socket = "inprocess:lua", in_process = true })
      assert_true(type(socks_inproc) == "table" and #socks_inproc == 1, "get_runtime_sockets inprocess:lua")
      assert_eq(socks_inproc[1], "inprocess:lua", "get_runtime_sockets inprocess:lua value")

      -- check_runtime_health with external runtime with no sockets (exercises missing socket branch)
      local health_no_sock_ok, health_no_sock_err = routes.check_runtime_health("python", { timeout_ms = 100 })
      assert_eq(health_no_sock_ok, false, "check_runtime_health no sockets")
      assert_true(type(health_no_sock_err) == "string" and health_no_sock_err:find("missing runtime socket", 1, true) ~= nil, "check_runtime_health no sockets err")

      -- check_runtime_health with external runtime with sockets (exercises any_up logic)
      local prev_tcp2 = ngx.socket.tcp
      -- Stub tcp so connect fails (simulates down sockets)
      ngx.socket.tcp = function()
        return {
          settimeouts = function() end,
          connect = function() return nil, "refused" end,
          close = function() end,
        }
      end
      local health_down_ok, health_down_err, health_down_statuses = routes.check_runtime_health("testrt", {
        sockets = { "unix:/tmp/down1.sock", "unix:/tmp/down2.sock" },
        timeout_ms = 100,
      })
      assert_eq(health_down_ok, false, "check_runtime_health all sockets down")
      assert_true(type(health_down_statuses) == "table" and #health_down_statuses == 2, "check_runtime_health down statuses count")

      -- Now stub so connect succeeds (one up, one down)
      local connect_count = 0
      ngx.socket.tcp = function()
        return {
          settimeouts = function() end,
          connect = function()
            connect_count = connect_count + 1
            if connect_count == 1 then
              return nil, "refused"
            end
            return true
          end,
          close = function() end,
        }
      end
      connect_count = 0
      local health_mixed_ok, health_mixed_err, health_mixed_statuses = routes.check_runtime_health("testrt2", {
        sockets = { "unix:/tmp/s1.sock", "unix:/tmp/s2.sock" },
        timeout_ms = 100,
      })
      assert_eq(health_mixed_ok, true, "check_runtime_health any_up with mixed sockets")
      assert_true(type(health_mixed_statuses) == "table" and #health_mixed_statuses == 2, "check_runtime_health mixed statuses count")
      ngx.socket.tcp = prev_tcp2

      -- pick_runtime_socket with excluded map iterating candidates
      -- Set up healthy sockets, then exclude some
      routes.set_runtime_socket_health("pickrt", 1, "unix:/tmp/pick1.sock", true, "ok")
      routes.set_runtime_socket_health("pickrt", 2, "unix:/tmp/pick2.sock", true, "ok")
      routes.set_runtime_socket_health("pickrt", 3, "unix:/tmp/pick3.sock", true, "ok")
      local pick_uri, pick_idx = routes.pick_runtime_socket("pickrt", {
        sockets = { "unix:/tmp/pick1.sock", "unix:/tmp/pick2.sock", "unix:/tmp/pick3.sock" },
        timeout_ms = 100,
      }, { [1] = true, [2] = true })
      -- Only socket 3 is not excluded, so it should be picked
      assert_eq(pick_uri, "unix:/tmp/pick3.sock", "pick_runtime_socket excluded map picks remaining")
      assert_eq(pick_idx, 3, "pick_runtime_socket excluded map picks correct index")

      -- pick_runtime_socket with all excluded (exercises re-check health path)
      local prev_tcp3 = ngx.socket.tcp
      ngx.socket.tcp = function()
        return {
          settimeouts = function() end,
          connect = function() return nil, "refused" end,
          close = function() end,
        }
      end
      local pick_none_uri, pick_none_idx, pick_none_mode, pick_none_err = routes.pick_runtime_socket("pickrt", {
        sockets = { "unix:/tmp/pick1.sock", "unix:/tmp/pick2.sock" },
        timeout_ms = 100,
      }, { [1] = true, [2] = true })
      assert_eq(pick_none_uri, nil, "pick_runtime_socket all excluded returns nil")
      assert_true(type(pick_none_err) == "string", "pick_runtime_socket all excluded has error")
      ngx.socket.tcp = prev_tcp3

      -- pick_runtime_socket with missing config
      local pick_missing_uri, _, pick_missing_mode = routes.pick_runtime_socket("missingrt2", nil)
      assert_eq(pick_missing_uri, nil, "pick_runtime_socket missing config nil uri")

      -- pick_runtime_socket with empty sockets
      local pick_empty_uri, _, pick_empty_mode, pick_empty_err = routes.pick_runtime_socket("emptyrt", { timeout_ms = 100 })
      assert_eq(pick_empty_uri, nil, "pick_runtime_socket empty sockets nil uri")
      assert_true(type(pick_empty_err) == "string" and pick_empty_err:find("missing runtime socket", 1, true) ~= nil, "pick_runtime_socket empty sockets err")

      -- record_worker_pool_drop with valid and invalid reasons
      assert_eq(routes.record_worker_pool_drop("test/fn@default", "overflow"), true, "record_worker_pool_drop overflow")
      assert_eq(routes.record_worker_pool_drop("test/fn@default", "queue_timeout"), true, "record_worker_pool_drop queue_timeout")
      assert_eq(routes.record_worker_pool_drop("test/fn@default", "bad_reason"), false, "record_worker_pool_drop invalid reason")
      assert_eq(routes.record_worker_pool_drop("", "overflow"), false, "record_worker_pool_drop empty key")
      assert_eq(routes.record_worker_pool_drop(nil, "overflow"), false, "record_worker_pool_drop nil key")

      -- canonical_route_segment_for_name
      assert_eq(routes.canonical_route_segment_for_name("hello_world"), "hello-world", "canonical_route_segment_for_name underscore")
      assert_eq(routes.canonical_route_segment_for_name("api/v1/users"), "api/v1/users", "canonical_route_segment_for_name namespaced")
      assert_eq(routes.canonical_route_segment_for_name(""), nil, "canonical_route_segment_for_name empty")
      assert_eq(routes.canonical_route_segment_for_name(nil), nil, "canonical_route_segment_for_name nil")

      -- warm_state_for_key is an upvalue of health_snapshot (not discover_functions)
      local warm_state_for_key = get_upvalue(routes.health_snapshot, "warm_state_for_key")
      if type(warm_state_for_key) == "function" then
        -- cold state (no warm: key set)
        local state1, at1 = warm_state_for_key("nonexistent_key", nil)
        assert_eq(state1, "cold", "warm_state_for_key cold")
        assert_eq(at1, nil, "warm_state_for_key cold at nil")

        -- warm state
        cache:set("warm:test_warm_key", ngx.now())
        local state2, at2 = warm_state_for_key("test_warm_key", nil)
        assert_eq(state2, "warm", "warm_state_for_key warm")

        -- stale state (old warm_at with short idle_ttl)
        cache:set("warm:test_stale_key", ngx.now() - 1000)
        local state3, at3 = warm_state_for_key("test_stale_key", { idle_ttl_seconds = 10 })
        assert_eq(state3, "stale", "warm_state_for_key stale")
      end

      -- is_safe_relative_path is a direct upvalue of resolve_function_entrypoint
      local is_safe_relative_path = get_upvalue(routes.resolve_function_entrypoint, "is_safe_relative_path")
      if type(is_safe_relative_path) == "function" then
        assert_eq(is_safe_relative_path(""), false, "is_safe_relative_path empty")
        assert_eq(is_safe_relative_path("/absolute"), false, "is_safe_relative_path absolute")
        assert_eq(is_safe_relative_path("a\\b"), false, "is_safe_relative_path backslash")
        assert_eq(is_safe_relative_path("a//b"), false, "is_safe_relative_path double slash")
        assert_eq(is_safe_relative_path("a/../b"), false, "is_safe_relative_path dot-dot")
        assert_eq(is_safe_relative_path("valid/path"), true, "is_safe_relative_path valid")
      end

      -- should_ignore_file_base via upvalue chain
      local detect_file_based = get_upvalue(discover_functions, "detect_file_based_routes_in_dir")
      local should_ignore_file_base = nil
      if type(detect_file_based) == "function" then
        should_ignore_file_base = get_upvalue(detect_file_based, "should_ignore_file_base")
      end
      if type(should_ignore_file_base) == "function" then
        assert_eq(should_ignore_file_base("hello.test"), true, "should_ignore_file_base .test")
        assert_eq(should_ignore_file_base("hello.spec"), true, "should_ignore_file_base .spec")
        assert_eq(should_ignore_file_base("_internal"), true, "should_ignore_file_base underscore prefix")
        assert_eq(should_ignore_file_base("valid"), false, "should_ignore_file_base valid")
      end

      -- normalize_route_token via upvalue chain
      local normalize_route_token = nil
      if type(detect_file_based) == "function" then
        normalize_route_token = get_upvalue(detect_file_based, "normalize_route_token")
      end
      if type(normalize_route_token) == "function" then
        assert_eq(normalize_route_token(""), nil, "normalize_route_token empty")
        assert_eq(normalize_route_token("index"), nil, "normalize_route_token index")
        assert_eq(normalize_route_token("handler"), nil, "normalize_route_token handler")
        assert_eq(normalize_route_token("app"), "app", "normalize_route_token app is literal")
        assert_eq(normalize_route_token("main"), nil, "normalize_route_token main")
        assert_eq(normalize_route_token("[id]"), ":id", "normalize_route_token dynamic")
        assert_eq(normalize_route_token("[...rest]"), ":rest*", "normalize_route_token catch-all")
        assert_eq(normalize_route_token("[[...opt]]"), ":opt*", "normalize_route_token optional catch-all")
        assert_eq(normalize_route_token("hello_world"), "hello-world", "normalize_route_token underscore")
      end

      -- normalize_runtime_socket_list hangs off load_runtime_config, and
      -- normalize_runtime_socket_uri is its nested helper.
      local normalize_runtime_socket_list = get_upvalue(load_runtime_config, "normalize_runtime_socket_list")
      local normalize_runtime_socket_uri = type(normalize_runtime_socket_list) == "function"
        and get_upvalue(normalize_runtime_socket_list, "normalize_runtime_socket_uri")
        or nil
      if type(normalize_runtime_socket_uri) == "function" then
        assert_eq(normalize_runtime_socket_uri("   "), nil, "normalize_runtime_socket_uri empty returns nil")
        assert_eq(normalize_runtime_socket_uri(" unix:/tmp/demo.sock "), "unix:/tmp/demo.sock", "normalize_runtime_socket_uri trims whitespace")
      end
      if type(normalize_runtime_socket_list) == "function" then
        -- runtime == "lua" short-circuits to { "inprocess:lua" } (routes.lua line 1612)
        local lua_socks = normalize_runtime_socket_list("lua", nil, "/tmp/fastfn")
        assert_true(type(lua_socks) == "table" and #lua_socks == 1, "normalize_runtime_socket_list lua returns 1 socket")
        assert_eq(lua_socks[1], "inprocess:lua", "normalize_runtime_socket_list lua returns inprocess:lua")

        -- whitespace-only socket string falls back to the default unix socket.
        local ws_socks = normalize_runtime_socket_list("python", "   ", "/tmp/fastfn")
        assert_true(type(ws_socks) == "table" and #ws_socks == 1, "normalize_runtime_socket_list whitespace-only socket falls back")
        assert_eq(ws_socks[1], "unix:/tmp/fastfn/fn-python.sock", "normalize_runtime_socket_list whitespace-only socket default")

        -- nil raw_value returns the default unix socket.
        local nil_socks = normalize_runtime_socket_list("python", nil, "/tmp/fastfn")
        assert_true(type(nil_socks) == "table" and #nil_socks == 1, "normalize_runtime_socket_list nil raw falls back")
        assert_eq(nil_socks[1], "unix:/tmp/fastfn/fn-python.sock", "normalize_runtime_socket_list nil raw default")

        -- table with whitespace-only entries also falls back to the default socket.
        local ws_table_socks = normalize_runtime_socket_list("python", { "   ", "  " }, "/tmp/fastfn")
        assert_true(type(ws_table_socks) == "table" and #ws_table_socks == 1, "normalize_runtime_socket_list whitespace table falls back")
        assert_eq(ws_table_socks[1], "unix:/tmp/fastfn/fn-python.sock", "normalize_runtime_socket_list whitespace table default")

        -- table with valid and duplicate entries
        local dedup_socks = normalize_runtime_socket_list("python", { "unix:/a.sock", "unix:/a.sock", "unix:/b.sock" }, "/tmp/fastfn")
        assert_true(type(dedup_socks) == "table" and #dedup_socks == 2, "normalize_runtime_socket_list dedup sockets")
      end

      -- Exercise should_skip_zero_config_dir with a synthetic scan so luacov
      -- sees the dot-prefix and ignore-list early returns deterministically.
      do
        local scanned_rel_dirs = {}
        local scanned_rel_dir_set = {}
        local synthetic_catalog = nil
        with_upvalue(discover_functions, "load_runtime_config", function()
          return {
            functions_root = "/tmp/fastfn-zero-config-skip",
            zero_config = { ignore_dirs = { "node_modules" } },
            runtimes = {
              node = { socket = "unix:/tmp/fn-node.sock", sockets = { "unix:/tmp/fn-node.sock" } },
            },
          }
        end, function()
          with_upvalue(discover_functions, "force_url_enabled", function()
            return false
          end, function()
            with_upvalue(discover_functions, "detect_manifest_routes_in_dir", function()
              return {}, false
            end, function()
              with_upvalue(discover_functions, "read_json_file", function()
                return nil
              end, function()
                with_upvalue(discover_functions, "list_dirs", function(path)
                  if path == "/tmp/fastfn-zero-config-skip" then
                    return {
                      "/tmp/fastfn-zero-config-skip/.hidden",
                      "/tmp/fastfn-zero-config-skip/node_modules",
                      "/tmp/fastfn-zero-config-skip/visible",
                    }
                  end
                  return {}
                end, function()
                  with_upvalue(discover_functions, "detect_file_based_routes_in_dir", function(abs_dir, rel_dir)
                    scanned_rel_dirs[#scanned_rel_dirs + 1] = tostring(rel_dir)
                    scanned_rel_dir_set[tostring(rel_dir)] = true
                    if abs_dir == "/tmp/fastfn-zero-config-skip/visible" then
                      return {
                        {
                          route = "/visible/ok",
                          runtime = "node",
                          target = "visible/get.ok.js",
                          methods = { "GET" },
                        },
                      }
                    end
                    return {}
                  end, function()
                    synthetic_catalog = routes.discover_functions(true)
                  end)
                end)
              end)
            end)
          end)
        end)

        assert_true(type(synthetic_catalog) == "table", "synthetic zero-config catalog built")
        assert_true(synthetic_catalog.mapped_routes["/visible/ok"] ~= nil, "synthetic zero-config keeps visible dir")
        assert_eq(scanned_rel_dir_set[".hidden"], nil, "synthetic zero-config skips dot-prefixed dir before scanning")
        assert_eq(scanned_rel_dir_set["node_modules"], nil, "synthetic zero-config skips ignored dir before scanning")
      end

      -- pick_runtime_socket: cover the fallback path where initial candidates are empty
      -- because status.up == false, then check_runtime_health succeeds and re-check
      -- finds sockets with up == true (exercises routes.lua lines 1948-1957)
      routes.set_runtime_socket_health("fallbackrt", 1, "unix:/tmp/fb1.sock", false, "was-down")
      routes.set_runtime_socket_health("fallbackrt", 2, "unix:/tmp/fb2.sock", false, "was-down")
      -- Mock TCP to succeed so check_runtime_health marks sockets as up
      local prev_tcp_fb = ngx.socket.tcp
      ngx.socket.tcp = function()
        return {
          settimeouts = function() end,
          connect = function() return true end,
          close = function() end,
        }
      end
      local fb_uri, fb_idx, fb_mode = routes.pick_runtime_socket("fallbackrt", {
        sockets = { "unix:/tmp/fb1.sock", "unix:/tmp/fb2.sock" },
        timeout_ms = 100,
      })
      assert_true(fb_uri ~= nil, "pick_runtime_socket fallback re-check finds healthy socket")
      assert_true(fb_idx ~= nil, "pick_runtime_socket fallback re-check returns index")
      ngx.socket.tcp = prev_tcp_fb

      do
        local ambiguous_root = root .. "/ambiguous-runtime-root"
        local logs = {}
        local prev_log = ngx.log
        mkdir_p(ambiguous_root .. "/node/multi")
        write_file(ambiguous_root .. "/node/multi/get.alpha.js", "exports.handler = async () => ({ status: 200, body: 'alpha' });\n")
        write_file(ambiguous_root .. "/node/multi/get.post.alpha.js", "exports.handler = async () => ({ status: 200, body: 'ambiguous' });\n")
        ngx.log = function(...)
          local parts = { ... }
          for i = 1, #parts do
            parts[i] = tostring(parts[i])
          end
          logs[#logs + 1] = table.concat(parts)
        end
        with_env({
          FN_FUNCTIONS_ROOT = ambiguous_root,
          FN_RUNTIMES = "node",
        }, function()
          cache:delete("runtime:config")
          cache:delete("catalog:raw")
          local ambiguous_catalog = routes.discover_functions(true)
          local good_route = (ambiguous_catalog.mapped_routes or {})["/node/multi/alpha"]
          assert_true(type(good_route) == "table" and #good_route == 1, "routes keeps non-ambiguous runtime root route")
        end)
        ngx.log = prev_log
        assert_true(table.concat(logs, "\n"):find("ignoring ambiguous multi%-method filename", 1, false) ~= nil,
          "routes logs ambiguous runtime root file names")
      end

      package.loaded["fastfn.core.routes"] = nil
    end)

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

test_scheduler_remaining_coverage_gaps = function()
  with_fake_ngx(function(cache, conc, set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-sched-cov2-" .. uniq

    rm_rf(root)
    mkdir_p(root .. "/.fastfn")

    local routes_stub = {
      get_config = function()
        return { functions_root = root, runtimes = { lua = { socket = "inprocess:lua", timeout_ms = 2500, in_process = true } } }
      end,
      discover_functions = function()
        return { runtimes = { lua = { functions = { demo = { has_default = true, versions = {}, policy = { methods = { "GET" }, schedule = { enabled = true, every_seconds = 1 } } } } } } }
      end,
      resolve_named_target = function(name) if name == "demo" then return "lua", nil end return nil end,
      resolve_function_policy = function(rt, name) if rt ~= "lua" or name ~= "demo" then return nil end return { methods = { "GET" }, timeout_ms = 500, max_concurrency = 0 } end,
      get_runtime_config = function(rt) if rt == "lua" then return { socket = "inprocess:lua", timeout_ms = 2500, in_process = true } end return nil end,
      runtime_is_up = function() return true end,
      check_runtime_health = function() return true, "ok" end,
      set_runtime_health = function() end,
      runtime_is_in_process = function() return true end,
    }

    with_module_stubs({
      ["fastfn.core.routes"] = routes_stub,
      ["fastfn.core.limits"] = { try_acquire = function() return true end, release = function() end },
      ["fastfn.core.lua_runtime"] = { call = function() return { status = 200, headers = {}, body = '{}' } end },
      ["fastfn.core.client"] = { call_unix = function() return nil, "connect_error", "down" end },
      ["fastfn.core.gateway_utils"] = { map_runtime_error = function(code) if code == "connect_error" then return 503, "runtime down" end return 502, "runtime error" end },
    }, function()
      package.loaded["fastfn.core.scheduler"] = nil
      local scheduler = require("fastfn.core.scheduler")

      local tick_once = get_upvalue(scheduler.init, "tick_once")
      local dispatch_schedule_invocation = get_upvalue(tick_once, "dispatch_schedule_invocation")
      local dispatch_keep_warm_invocation = get_upvalue(tick_once, "dispatch_keep_warm_invocation")
      local compute_next_cron_ts = get_upvalue(dispatch_schedule_invocation, "compute_next_cron_ts")
      local schedule_retry_config = get_upvalue(dispatch_schedule_invocation, "schedule_retry_config")
      local pick_policy_method = get_upvalue(dispatch_keep_warm_invocation, "pick_policy_method")
      local effective_keep_warm = get_upvalue(tick_once, "effective_keep_warm")
      local effective_schedule = get_upvalue(tick_once, "effective_schedule")
      local status_retryable = get_upvalue(dispatch_schedule_invocation, "status_retryable")
      local truncate_error = get_upvalue(scheduler.persist_now, "truncate_error")
      local normalize_functions_root = get_upvalue(scheduler.persist_now, "normalize_functions_root")
      local scheduler_persist_interval_seconds = get_upvalue(scheduler.init, "scheduler_persist_interval_seconds")
      local restore_persisted_state = get_upvalue(scheduler.init, "restore_persisted_state")
      local scheduler_state_path = get_upvalue(scheduler.persist_now, "scheduler_state_path")
      local run_scheduled_invocation = get_upvalue(dispatch_schedule_invocation, "run_scheduled_invocation")
      -- scheduler_worker_pool_context and build_trigger_context are upvalues of
      -- run_scheduled_invocation (not dispatch_schedule_invocation).
      local scheduler_worker_pool_context = nil
      local build_trigger_context = nil
      if type(run_scheduled_invocation) == "function" then
        scheduler_worker_pool_context = get_upvalue(run_scheduled_invocation, "scheduler_worker_pool_context")
        build_trigger_context = get_upvalue(run_scheduled_invocation, "build_trigger_context")
      end

      -- pick_policy_method with empty methods
      if type(pick_policy_method) == "function" then
        assert_eq(pick_policy_method(nil), "GET", "pick_policy_method nil returns GET")
        assert_eq(pick_policy_method({}), "GET", "pick_policy_method empty returns GET")
        assert_eq(pick_policy_method({ "POST", "GET" }), "GET", "pick_policy_method prefers GET")
        assert_eq(pick_policy_method({ "POST", "PUT" }), "POST", "pick_policy_method returns first when no GET")
      end

      -- effective_keep_warm with version policy
      if type(effective_keep_warm) == "function" then
        -- Version policy overrides root
        local kw1 = effective_keep_warm(
          { keep_warm = { enabled = true, min_warm = 1 } },
          { keep_warm = { enabled = true, min_warm = 2 } }
        )
        assert_true(type(kw1) == "table" and kw1.min_warm == 2, "effective_keep_warm ver overrides root")

        -- Root only
        local kw2 = effective_keep_warm(
          { keep_warm = { enabled = true, min_warm = 1 } },
          {}
        )
        assert_true(type(kw2) == "table" and kw2.min_warm == 1, "effective_keep_warm root fallback")

        -- Disabled keep_warm
        local kw3 = effective_keep_warm(
          { keep_warm = { enabled = false, min_warm = 0 } },
          nil
        )
        assert_eq(kw3, nil, "effective_keep_warm disabled returns nil")

        -- min_warm negative
        local kw4 = effective_keep_warm(
          { keep_warm = { enabled = true, min_warm = -1 } },
          nil
        )
        assert_eq(kw4, nil, "effective_keep_warm negative min_warm returns nil")
      end

      -- effective_schedule with version policy
      if type(effective_schedule) == "function" then
        local sched1 = effective_schedule(
          { schedule = { enabled = true, every_seconds = 10 } },
          { schedule = { enabled = true, every_seconds = 5 } }
        )
        assert_true(type(sched1) == "table" and sched1.every_seconds == 5, "effective_schedule ver overrides root")

        local sched2 = effective_schedule(
          { schedule = { enabled = true, every_seconds = 10 } },
          nil
        )
        assert_true(type(sched2) == "table" and sched2.every_seconds == 10, "effective_schedule root fallback")

        local sched3 = effective_schedule(nil, nil)
        assert_eq(sched3, nil, "effective_schedule both nil returns nil")
      end

      -- status_retryable
      if type(status_retryable) == "function" then
        assert_eq(status_retryable(429), true, "status_retryable 429")
        assert_eq(status_retryable(503), true, "status_retryable 503")
        assert_eq(status_retryable(500), true, "status_retryable 500")
        assert_eq(status_retryable(0), true, "status_retryable 0")
        assert_eq(status_retryable(200), false, "status_retryable 200")
        assert_eq(status_retryable(400), false, "status_retryable 400")
        assert_eq(status_retryable(499), false, "status_retryable 499")
      end

      -- schedule_retry_config edge cases
      if type(schedule_retry_config) == "function" then
        local rc1 = schedule_retry_config(nil)
        assert_eq(rc1.enabled, false, "schedule_retry_config nil disabled")

        local rc2 = schedule_retry_config(true)
        assert_eq(rc2.enabled, true, "schedule_retry_config true enables with defaults")
        assert_true(rc2.max_attempts > 0, "schedule_retry_config true has max_attempts")

        local rc3 = schedule_retry_config({ enabled = false })
        assert_eq(rc3.enabled, false, "schedule_retry_config explicitly disabled")

        -- max_attempts clamping
        local rc4 = schedule_retry_config({ max_attempts = 0 })
        assert_eq(rc4.max_attempts, 1, "schedule_retry_config clamps min max_attempts to 1")

        local rc5 = schedule_retry_config({ max_attempts = 100 })
        assert_eq(rc5.max_attempts, 10, "schedule_retry_config clamps max max_attempts to 10")

        -- jitter clamping
        local rc6 = schedule_retry_config({ jitter = -1 })
        assert_eq(rc6.jitter, 0, "schedule_retry_config clamps negative jitter to 0")

        local rc7 = schedule_retry_config({ jitter = 1.0 })
        assert_eq(rc7.jitter, 0.5, "schedule_retry_config clamps jitter to 0.5")

        -- max_delay < base_delay
        local rc8 = schedule_retry_config({ base_delay_seconds = 10, max_delay_seconds = 2 })
        assert_true(rc8.max_delay_seconds >= rc8.base_delay_seconds, "schedule_retry_config max_delay >= base_delay")

        -- Non-table non-boolean non-nil
        local rc9 = schedule_retry_config("string")
        assert_eq(rc9.enabled, false, "schedule_retry_config string disabled")
      end

      -- truncate_error
      if type(truncate_error) == "function" then
        assert_eq(truncate_error(nil), "", "truncate_error nil returns empty")
        assert_eq(truncate_error(123), "", "truncate_error number returns empty")
        assert_eq(truncate_error("short"), "short", "truncate_error short string unchanged")
        local long = string.rep("x", 3000)
        local truncated = truncate_error(long)
        assert_true(#truncated < #long, "truncate_error long string is truncated")
        assert_true(truncated:find("truncated", 1, true) ~= nil, "truncate_error has truncated suffix")
      end

      -- normalize_functions_root
      if type(normalize_functions_root) == "function" then
        assert_eq(normalize_functions_root(nil), nil, "normalize_functions_root nil")
        assert_eq(normalize_functions_root(123), nil, "normalize_functions_root number")
        assert_eq(normalize_functions_root("/tmp/test/"), "/tmp/test", "normalize_functions_root strips trailing slash")
        assert_eq(normalize_functions_root("/"), nil, "normalize_functions_root just slash returns nil")
      end

      -- scheduler_persist_interval_seconds clamping
      if type(scheduler_persist_interval_seconds) == "function" then
        with_env({ FN_SCHEDULER_PERSIST_INTERVAL = "1" }, function()
          assert_eq(scheduler_persist_interval_seconds(), 5, "persist interval clamped to 5")
        end)
        with_env({ FN_SCHEDULER_PERSIST_INTERVAL = "99999" }, function()
          assert_eq(scheduler_persist_interval_seconds(), 3600, "persist interval clamped to 3600")
        end)
      end

      -- scheduler_worker_pool_context edge cases
      if type(scheduler_worker_pool_context) == "function" then
        local ctx1 = scheduler_worker_pool_context(nil)
        assert_eq(ctx1.enabled, false, "scheduler_worker_pool_context nil policy")

        -- Negative values for fields
        local ctx2 = scheduler_worker_pool_context({ worker_pool = { enabled = true, min_warm = -1, max_workers = -1, max_queue = -1, queue_timeout_ms = -1, queue_poll_ms = -1, idle_ttl_seconds = 0 } })
        assert_true(type(ctx2) == "table", "scheduler_worker_pool_context negative values")
        assert_eq(ctx2.min_warm, 0, "scheduler_worker_pool_context negative min_warm defaults to 0")
        assert_eq(ctx2.max_workers, 0, "scheduler_worker_pool_context negative max_workers defaults to 0")

        -- Invalid overflow_status
        local ctx3 = scheduler_worker_pool_context({ worker_pool = { overflow_status = 400 } })
        assert_eq(ctx3.overflow_status, 429, "scheduler_worker_pool_context invalid overflow_status defaults to 429")
      end

      -- build_trigger_context
      if type(build_trigger_context) == "function" then
        local tc1 = build_trigger_context({ every_seconds = 10, cron = "* * * * *", timezone = "UTC" }, "schedule", { attempt = 2 })
        assert_eq(tc1.type, "schedule", "build_trigger_context type")
        assert_eq(tc1.every_seconds, 10, "build_trigger_context every_seconds")
        assert_eq(tc1.cron, "* * * * *", "build_trigger_context cron")
        assert_eq(tc1.timezone, "UTC", "build_trigger_context timezone")
        assert_eq(tc1.attempt, 2, "build_trigger_context meta merge")

        -- timezone "local" should be excluded
        local tc2 = build_trigger_context({ timezone = "local" }, "schedule", nil)
        assert_eq(tc2.timezone, nil, "build_trigger_context local timezone omitted")

        -- Empty cron should be excluded
        local tc3 = build_trigger_context({ cron = "" }, "schedule", nil)
        assert_eq(tc3.cron, nil, "build_trigger_context empty cron omitted")
      end

      local sched_call_external_runtime = type(run_scheduled_invocation) == "function"
        and get_upvalue(run_scheduled_invocation, "call_external_runtime")
        or nil
      exercise_call_external_runtime(sched_call_external_runtime, "scheduler")

      -- run_scheduled_invocation with method not allowed by policy
      if type(run_scheduled_invocation) == "function" then
        local ma_status, ma_err = run_scheduled_invocation("lua", "demo", nil, { method = "DELETE" }, { methods = { "GET" } }, "schedule")
        assert_eq(ma_status, 405, "run_scheduled_invocation method not allowed")

        -- With body that's not a string (exercises tostring coercion at line 355)
        local body_status, _ = run_scheduled_invocation("lua", "demo", nil, { method = "GET", body = 12345 }, { methods = { "GET" } }, "schedule")
        assert_true(body_status ~= nil, "run_scheduled_invocation non-string body coerced")

        -- With body exceeding max
        local big_status, big_err = run_scheduled_invocation("lua", "demo", nil, { method = "GET", body = string.rep("x", 2000000) }, { methods = { "GET" }, max_body_bytes = 100 }, "schedule")
        assert_eq(big_status, 413, "run_scheduled_invocation payload too large")

        -- With unknown runtime
        local uk_status, uk_err = run_scheduled_invocation("unknown", "demo", nil, { method = "GET" }, { methods = { "GET" } }, "schedule")
        assert_eq(uk_status, 404, "run_scheduled_invocation unknown runtime")

        -- With external runtime (non-lua) to exercise call_external_runtime through run_scheduled_invocation
        local prev_get_rtcfg = routes_stub.get_runtime_config
        local prev_is_inproc = routes_stub.runtime_is_in_process
        routes_stub.get_runtime_config = function(rt)
          if rt == "node" then return { socket = "unix:/tmp/node-sched.sock", timeout_ms = 100 } end
          if rt == "lua" then return { socket = "inprocess:lua", timeout_ms = 2500, in_process = true } end
          return nil
        end
        routes_stub.runtime_is_in_process = function(rt)
          return rt == "lua"
        end
        local ext_status = run_scheduled_invocation("node", "demo", nil, { method = "GET" }, { methods = { "GET" } }, "schedule")
        -- client.call_unix will fail with connect_error since the socket doesn't exist
        assert_true(ext_status ~= nil, "run_scheduled_invocation external runtime returns status")
        routes_stub.get_runtime_config = prev_get_rtcfg
        routes_stub.runtime_is_in_process = prev_is_inproc

        -- With runtime down (exercises should_block_runtime)
        local prev_runtime_is_up = routes_stub.runtime_is_up
        local prev_check_health = routes_stub.check_runtime_health
        routes_stub.runtime_is_up = function() return false end
        routes_stub.check_runtime_health = function() return false, "down" end
        local down_status, down_err = run_scheduled_invocation("lua", "demo", nil, { method = "GET" }, { methods = { "GET" } }, "schedule")
        assert_eq(down_status, 503, "run_scheduled_invocation runtime down")
        routes_stub.runtime_is_up = prev_runtime_is_up
        routes_stub.check_runtime_health = prev_check_health

        -- With 4xx response (exercises body logging for non-2xx at line 452-468)
        local prev_call = package.loaded["fastfn.core.lua_runtime"].call
        package.loaded["fastfn.core.lua_runtime"].call = function()
          return { status = 400, headers = {}, body = '{"error":"bad request"}' }
        end
        local err_status = run_scheduled_invocation("lua", "demo", nil, { method = "GET" }, { methods = { "GET" } }, "schedule")
        assert_eq(err_status, 400, "run_scheduled_invocation 4xx response")
        package.loaded["fastfn.core.lua_runtime"].call = prev_call

        -- With long body in 4xx response (exercises truncation at line 456-457)
        package.loaded["fastfn.core.lua_runtime"].call = function()
          return { status = 400, headers = {}, body = string.rep("x", 1000) }
        end
        local trunc_status = run_scheduled_invocation("lua", "demo", nil, { method = "GET" }, { methods = { "GET" } }, "schedule")
        assert_eq(trunc_status, 400, "run_scheduled_invocation 4xx with long body")
        package.loaded["fastfn.core.lua_runtime"].call = prev_call
      end

      -- restore_persisted_state with invalid JSON
      if type(restore_persisted_state) == "function" then
        local state_path = scheduler_state_path(root)
        if state_path then
          write_file(state_path, "not json")
          with_env({ FN_SCHEDULER_PERSIST_ENABLED = "1" }, function()
            local ok, err = restore_persisted_state()
            assert_eq(ok, false, "restore_persisted_state invalid JSON fails")
          end)
          -- Valid state with schedules and keep_warm
          write_file(state_path, cjson.encode({
            schedules = {
              ["lua/demo@default"] = { next = 100, last = 50, last_status = 200, last_error = "", retry_due = 60, retry_attempt = 2, warm_at = 45 },
            },
            keep_warm = {
              ["lua/demo@default"] = { next = 80, last = 40, last_status = 200, last_error = "", warm_at = 35 },
            },
          }))
          with_env({ FN_SCHEDULER_PERSIST_ENABLED = "1" }, function()
            local ok2, err2 = restore_persisted_state()
            assert_eq(ok2, true, "restore_persisted_state valid state succeeds")
          end)
        end
      end

      -- persist_now with disabled persistence
      with_env({ FN_SCHEDULER_PERSIST_ENABLED = "0" }, function()
        local ok, msg = scheduler.persist_now()
        assert_eq(ok, true, "persist_now disabled returns true")
      end)

      -- dispatch_keep_warm_invocation timer failure path (exercises lines 1209-1214)
      if type(dispatch_keep_warm_invocation) == "function" then
        local prev_timer_at = ngx.timer.at
        ngx.timer.at = function() return false, "timer-fail" end
        -- Set up conditions: warm_at = nil (cold) so it's due
        cache:delete("warm:lua/demo@default")
        cache:delete("sched:lua/demo@default:keep_warm_next")
        cache:delete("sched:lua/demo@default:keep_warm:running")
        dispatch_keep_warm_invocation("lua", "demo", nil, { enabled = true, min_warm = 1, ping_every_seconds = 10, idle_ttl_seconds = 300 }, ngx.now())
        local kw_last_status = cache:get("sched:lua/demo@default:keep_warm_last_status")
        assert_eq(kw_last_status, 500, "dispatch_keep_warm timer fail should set status 500")
        ngx.timer.at = prev_timer_at
      end

      -- retry_delay_seconds (exercises jitter and clamping at lines 928-944)
      local retry_delay_seconds = get_upvalue(dispatch_schedule_invocation, "retry_delay_seconds")
      if type(retry_delay_seconds) == "function" then
        local d1 = retry_delay_seconds({ base_delay_seconds = 1, max_delay_seconds = 30, jitter = 0 }, 1)
        assert_eq(d1, 1, "retry_delay_seconds base case")

        local d2 = retry_delay_seconds({ base_delay_seconds = 1, max_delay_seconds = 30, jitter = 0 }, 3)
        assert_eq(d2, 4, "retry_delay_seconds exponential backoff attempt 3")

        -- With jitter > 0
        local d3 = retry_delay_seconds({ base_delay_seconds = 10, max_delay_seconds = 100, jitter = 0.2 }, 1)
        assert_true(d3 >= 8 and d3 <= 12, "retry_delay_seconds with jitter")

        -- max_delay clamping
        local d4 = retry_delay_seconds({ base_delay_seconds = 10, max_delay_seconds = 5, jitter = 0 }, 5)
        assert_eq(d4, 5, "retry_delay_seconds clamped to max_delay")
      end

      -- compute_next_ts alignment (exercises lines 860-869)
      local compute_next_ts = get_upvalue(dispatch_schedule_invocation, "compute_next_ts")
      if type(compute_next_ts) == "function" then
        local next1 = compute_next_ts(1000, 60)
        assert_eq(next1, 1020, "compute_next_ts aligned to boundary")

        -- nil/0 every_seconds
        local next2 = compute_next_ts(1000, 0)
        assert_eq(next2, nil, "compute_next_ts zero interval returns nil")

        local next3 = compute_next_ts(1000, nil)
        assert_eq(next3, nil, "compute_next_ts nil interval returns nil")
      end

      -- env_flag with various values (exercises lines 146-152)
      local env_flag = get_upvalue(scheduler.init, "env_flag")
        or get_upvalue(scheduler.persist_now, "scheduler_persist_enabled")
      if type(env_flag) == "function" then
        -- Access env_flag through scheduler_persist_enabled by testing with env
        with_env({ FN_SCHEDULER_PERSIST_ENABLED = "yes" }, function()
          local scheduler_persist_enabled = get_upvalue(scheduler.persist_now, "scheduler_persist_enabled")
          if type(scheduler_persist_enabled) == "function" then
            assert_eq(scheduler_persist_enabled(), true, "scheduler_persist_enabled yes")
          end
        end)
        with_env({ FN_SCHEDULER_PERSIST_ENABLED = "on" }, function()
          local scheduler_persist_enabled = get_upvalue(scheduler.persist_now, "scheduler_persist_enabled")
          if type(scheduler_persist_enabled) == "function" then
            assert_eq(scheduler_persist_enabled(), true, "scheduler_persist_enabled on")
          end
        end)
        with_env({ FN_SCHEDULER_PERSIST_ENABLED = "no" }, function()
          local scheduler_persist_enabled = get_upvalue(scheduler.persist_now, "scheduler_persist_enabled")
          if type(scheduler_persist_enabled) == "function" then
            assert_eq(scheduler_persist_enabled(), false, "scheduler_persist_enabled no")
          end
        end)
        with_env({ FN_SCHEDULER_PERSIST_ENABLED = "off" }, function()
          local scheduler_persist_enabled = get_upvalue(scheduler.persist_now, "scheduler_persist_enabled")
          if type(scheduler_persist_enabled) == "function" then
            assert_eq(scheduler_persist_enabled(), false, "scheduler_persist_enabled off")
          end
        end)
      end

      -- tick_once with versioned schedules (exercises lines 1300-1362)
      -- Set up catalog with a version that has a schedule
      local prev_discover = routes_stub.discover_functions
      routes_stub.discover_functions = function()
        return {
          runtimes = {
            lua = {
              functions = {
                demo = {
                  has_default = true,
                  versions = { "v2" },
                  versions_policy = {
                    v2 = { schedule = { enabled = true, every_seconds = 10 } },
                  },
                  policy = { methods = { "GET" } },
                },
              },
            },
          },
        }
      end
      routes_stub.resolve_function_policy = function(rt, name, ver)
        if rt == "lua" and name == "demo" then
          return { methods = { "GET" }, timeout_ms = 500, max_concurrency = 0 }
        end
        return nil
      end
      set_now(5000)
      cache:delete("sched:tick:running")
      -- Set next for version to past so it dispatches
      cache:set("sched:lua/demo@v2:next", 4000)
      tick_once()
      local ver_last = cache:get("sched:lua/demo@v2:last")
      assert_true(ver_last ~= nil, "tick_once should dispatch versioned schedule")
      routes_stub.discover_functions = prev_discover

      -- init with persistence enabled and state file present (full restore path)
      with_env({ FN_SCHEDULER_ENABLED = "1", FN_SCHEDULER_PERSIST_ENABLED = "1" }, function()
        local state_path = scheduler_state_path(root)
        if state_path then
          write_file(state_path, cjson.encode({
            schedules = { ["lua/demo@default"] = { next = 100, last = 50, last_status = 200 } },
            keep_warm = {},
          }))
        end
        scheduler.init()
      end)

      -- write_file_atomic where rename fails but mv succeeds (exercises lines 108-111)
      local write_file_atomic = get_upvalue(scheduler.persist_now, "write_file_atomic")
      if type(write_file_atomic) == "function" then
        local test_path = root .. "/.fastfn/test_atomic.json"
        local ok_wfa, err_wfa = write_file_atomic(test_path, '{"test":true}')
        assert_eq(ok_wfa, true, "write_file_atomic normal path succeeds")
      end

      -- dirname edge case
      local dirname_fn = type(write_file_atomic) == "function" and get_upvalue(write_file_atomic, "dirname") or nil
      if type(dirname_fn) == "function" then
        assert_eq(dirname_fn("filename_only"), ".", "dirname no slash returns dot")
        assert_eq(dirname_fn("/root/file"), "/root", "dirname normal path")
      end

      package.loaded["fastfn.core.scheduler"] = nil
    end)

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

test_public_assets_support_and_gateway = function()
  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-assets-module-" .. uniq
    local public_dir = root .. "/public"
    local empty_assets_dir = root .. "/empty-public"

    rm_rf(root)
    mkdir_p(public_dir .. "/nested")
    mkdir_p(public_dir .. "/hello")
    mkdir_p(public_dir .. "/build")
    mkdir_p(empty_assets_dir)
    write_file(public_dir .. "/index.html", "<html>home</html>\n")
    write_file(public_dir .. "/nested/index.html", "<html>nested</html>\n")
    write_file(public_dir .. "/hello/index.html", "<html>asset hello</html>\n")
    write_file(public_dir .. "/app.js", "console.log('app')\n")
    write_file(public_dir .. "/build/app.123456789.js", "console.log('hashed')\n")
    write_file(public_dir .. "/blob.bin", "BIN")

    package.loaded["fastfn.http.assets"] = nil
    local assets = require("fastfn.http.assets")

    assert_eq(assets.path_is_reserved(nil), false, "assets.path_is_reserved nil")
    assert_eq(assets.path_is_reserved(""), false, "assets.path_is_reserved empty")
    assert_eq(assets.path_is_reserved("/_fn"), true, "assets.path_is_reserved /_fn")
    assert_eq(assets.path_is_reserved("/_fn/health"), true, "assets.path_is_reserved /_fn subpath")
    assert_eq(assets.path_is_reserved("/console"), true, "assets.path_is_reserved /console")
    assert_eq(assets.path_is_reserved("/hello"), false, "assets.path_is_reserved public path")

    assert_eq(assets.file_exists(public_dir .. "/app.js"), true, "assets.file_exists existing")
    assert_eq(assets.file_exists(public_dir .. "/missing.js"), false, "assets.file_exists missing")

    local file_body, file_body_err = assets.read_file(public_dir .. "/app.js")
    assert_true(type(file_body) == "string" and file_body:find("console.log", 1, true) ~= nil, "assets.read_file existing")
    assert_eq(file_body_err, nil, "assets.read_file existing err")
    local too_large_body, too_large_err = assets.read_file(public_dir .. "/app.js", 4)
    assert_eq(too_large_body, nil, "assets.read_file limit body")
    assert_eq(too_large_err, "asset too large", "assets.read_file limit err")
    local missing_body, missing_err = assets.read_file(public_dir .. "/missing.js")
    assert_eq(missing_body, nil, "assets.read_file missing body")
    assert_true(type(missing_err) == "string", "assets.read_file missing err")
    do
      local prev_io = io
      _G.io = {
        open = function()
          return {
            read = function() return nil end,
            close = function() end,
          }
        end,
        popen = prev_io.popen,
      }
      local empty_body, empty_err = assets.read_file(public_dir .. "/blob.bin")
      _G.io = prev_io
      assert_eq(empty_body, nil, "assets.read_file empty body")
      assert_eq(empty_err, "empty asset body", "assets.read_file empty err")
    end

	    local assets_fs = get_upvalue(assets.file_meta, "fs")
	    do
	      local prev_file_meta = assets_fs.file_meta
	      assets_fs.file_meta = function()
	        return nil, nil
	      end
	      local nil_mtime, nil_size = assets.file_meta(public_dir .. "/app.js")
	      assets_fs.file_meta = prev_file_meta
	      assert_eq(nil_mtime, nil, "assets.file_meta nil mtime")
	      assert_eq(nil_size, nil, "assets.file_meta nil size")
	    end

	    do
	      local prev_file_meta = assets_fs.file_meta
	      assets_fs.file_meta = function()
	        return 1700000000, 3
	      end
	      local alt_mtime, alt_size = assets.file_meta(public_dir .. "/blob.bin")
	      assets_fs.file_meta = prev_file_meta
	      assert_eq(alt_mtime, 1700000000, "assets.file_meta delegated mtime")
	      assert_eq(alt_size, 3, "assets.file_meta delegated size")
	    end

    assert_eq(assets.http_time(123, { http_time = function(ts) return "HTTP:" .. tostring(ts) end }), "HTTP:123", "assets.http_time ngx helper")
    assert_eq(assets.http_time(123, {}), "123", "assets.http_time fallback")

	    local public_real = assets.real_path(public_dir)
	    assert_true(type(public_real) == "string" and public_real ~= "", "assets.real_path public")
	    do
	      local prev_realpath = assets_fs.realpath
	      assets_fs.realpath = function()
	        return nil
	      end
	      assert_eq(assets.real_path(public_dir), nil, "assets.real_path nil fs")
	      assets_fs.realpath = prev_realpath
	    end
    assert_eq(assets.path_is_under(public_real, public_real), true, "assets.path_is_under same root")
    assert_eq(assets.path_is_under("", public_real), false, "assets.path_is_under empty file")
    assert_eq(assets.path_is_under(public_real, ""), false, "assets.path_is_under empty root")
    assert_eq(assets.file_is_safe_asset(public_dir .. "/app.js", { abs_dir = public_dir }), true, "assets.file_is_safe_asset plain")
    assert_eq(assets.file_is_safe_asset(nil, { abs_dir = public_dir }), false, "assets.file_is_safe_asset invalid path")
    do
      local prev_real_path = assets.real_path
      assets.real_path = function(path)
        if path == public_dir then
          return nil
        end
        return prev_real_path(path)
      end
      assert_eq(assets.file_is_safe_asset(public_dir .. "/app.js", { abs_dir = public_dir }), false, "assets.file_is_safe_asset missing root real")
      assets.real_path = prev_real_path
    end
    do
      write_file(root .. "/outside.txt", "outside")
      os.execute("ln -sf ../outside.txt " .. string.format("%q", public_dir .. "/escape.txt") .. " >/dev/null 2>&1")
      assert_eq(assets.file_is_safe_asset(public_dir .. "/escape.txt", { abs_dir = public_dir }), false, "assets.file_is_safe_asset escape")
    end

    assert_eq(assets.content_type("index.html"), "text/html; charset=utf-8", "assets.content_type html")
    assert_eq(assets.content_type("manual.pdf"), "application/pdf", "assets.content_type pdf")
    assert_eq(assets.content_type("clip.mp4"), "video/mp4", "assets.content_type mp4")
    assert_eq(assets.content_type("README"), "application/octet-stream", "assets.content_type no extension")
    assert_eq(assets.content_type("blob.bin"), "application/octet-stream", "assets.content_type fallback")

    assert_eq(assets.name_looks_hashed("build/app.123456789.js"), true, "assets.name_looks_hashed positive")
    assert_eq(assets.name_looks_hashed("app.js"), false, "assets.name_looks_hashed negative")
    assert_eq(assets.cache_control("build/app.123456789.js"), "public, max-age=31536000, immutable", "assets.cache_control hashed")
    assert_eq(assets.cache_control("app.js"), "public, max-age=0, must-revalidate", "assets.cache_control plain")

    assert_eq(assets.is_navigation_request("/", {}), true, "assets.is_navigation_request root")
    assert_eq(assets.is_navigation_request("/dashboard", { Accept = "text/html" }), true, "assets.is_navigation_request html accept")
	    assert_eq(assets.is_navigation_request("/dashboard", { accept = "*/*" }), true, "assets.is_navigation_request wildcard accept")
	    assert_eq(assets.is_navigation_request("/dashboard", { accept = "application/json" }), false, "assets.is_navigation_request json accept")
	    assert_eq(assets.is_navigation_request("/dashboard", {
	      accept = "application/json",
	      ["sec-fetch-mode"] = "navigate",
	    }), true, "assets.is_navigation_request sec-fetch-mode wins over json accept")
	    assert_eq(assets.is_navigation_request("/dashboard", { ["sec-fetch-mode"] = "navigate" }), true, "assets.is_navigation_request sec-fetch-mode navigate")
	    assert_eq(assets.is_navigation_request("/dashboard/", { accept = "*/*" }), true, "assets.is_navigation_request trailing slash wildcard accept")
	    assert_eq(assets.is_navigation_request("/api/unknown", { accept = "*/*" }), false, "assets.is_navigation_request api wildcard accept")
	    assert_eq(assets.is_navigation_request("/api-profile", { accept = "*/*" }), false, "assets.is_navigation_request api dash wildcard accept")
	    assert_eq(assets.is_navigation_request("/dashboard", {
	      accept = "application/json",
	      ["sec-fetch-dest"] = "document",
	    }), true, "assets.is_navigation_request sec-fetch-dest wins over json accept")
	    assert_eq(assets.is_navigation_request("/dashboard", { ["sec-fetch-dest"] = "document" }), true, "assets.is_navigation_request sec-fetch-dest document")
    assert_eq(assets.is_navigation_request("/app.js", { accept = "text/html" }), false, "assets.is_navigation_request extension")

    assert_eq(assets.normalize_candidates("relative", ngx), nil, "assets.normalize_candidates relative invalid")
    local empty_candidates = assets.normalize_candidates("", ngx)
    assert_true(type(empty_candidates) == "table" and empty_candidates[1] == "index.html", "assets.normalize_candidates empty path")
    assert_eq(assets.normalize_candidates("/.env", ngx), nil, "assets.normalize_candidates dotfile invalid")
    assert_eq(assets.normalize_candidates("/safe/../escape", ngx), nil, "assets.normalize_candidates traversal invalid")
    assert_eq(assets.normalize_candidates("/dir\\evil", ngx), nil, "assets.normalize_candidates backslash invalid")
    local root_candidates = assets.normalize_candidates(nil, ngx)
    assert_true(type(root_candidates) == "table" and root_candidates[1] == "index.html", "assets.normalize_candidates root")
    local nested_candidates = assets.normalize_candidates("/nested/", ngx)
    assert_true(type(nested_candidates) == "table" and nested_candidates[1] == "nested/index.html", "assets.normalize_candidates nested slash")
    local plain_candidates = assets.normalize_candidates("/app", ngx)
    assert_true(type(plain_candidates) == "table" and plain_candidates[1] == "app" and plain_candidates[2] == "app/index.html", "assets.normalize_candidates plain")

    local root_abs, root_rel = assets.resolve_file({ abs_dir = public_dir }, "/", ngx)
    assert_eq(root_rel, "index.html", "assets.resolve_file root rel")
    assert_true(type(root_abs) == "string" and root_abs:find("/index.html", 1, true) ~= nil, "assets.resolve_file root abs")
    local nested_abs, nested_rel = assets.resolve_file({ abs_dir = public_dir }, "/nested/", ngx)
    assert_eq(nested_rel, "nested/index.html", "assets.resolve_file nested rel")
    assert_true(type(nested_abs) == "string" and nested_abs:find("/nested/index.html", 1, true) ~= nil, "assets.resolve_file nested abs")
    local miss_abs, miss_rel = assets.resolve_file({ abs_dir = public_dir }, "/missing.js", ngx)
    assert_eq(miss_abs, nil, "assets.resolve_file missing abs")
    assert_eq(miss_rel, nil, "assets.resolve_file missing rel")
    local invalid_abs, invalid_rel = assets.resolve_file({ abs_dir = public_dir }, "relative", ngx)
    assert_eq(invalid_abs, nil, "assets.resolve_file invalid abs")
    assert_eq(invalid_rel, nil, "assets.resolve_file invalid rel")
    local unsafe_abs, unsafe_rel = assets.resolve_file({ abs_dir = public_dir }, "/escape.txt", ngx)
    assert_eq(unsafe_abs, nil, "assets.resolve_file unsafe abs")
    assert_eq(unsafe_rel, nil, "assets.resolve_file unsafe rel")

    assert_eq(assets.not_modified({ ["if-none-match"] = 'W/"1-2"' }, 'W/"1-2"', 1, ngx), true, "assets.not_modified etag lower")
    assert_eq(assets.not_modified({ ["If-None-Match"] = 'W/"1-2"' }, 'W/"1-2"', 1, ngx), true, "assets.not_modified etag upper")
    local prev_parse_http_time = ngx.parse_http_time
    ngx.parse_http_time = function(raw)
      if raw == "HTTP:1700000000" then
        return 1700000000
      end
      return nil
    end
    assert_eq(assets.not_modified({ ["If-Modified-Since"] = "HTTP:1700000000" }, 'W/"x"', 1700000000, ngx), true, "assets.not_modified ims")
    assert_eq(assets.not_modified({}, 'W/"x"', 1700000000, ngx), false, "assets.not_modified miss")
    ngx.parse_http_time = prev_parse_http_time

    local response_status, response_headers, response_body
    local function capture_write(status, headers, body)
      response_status = status
      response_headers = headers
      response_body = body
    end
    local function reset_capture()
      response_status = nil
      response_headers = nil
      response_body = nil
    end

    ngx.req.get_headers = function()
      return {}
    end
    local assets_cfg = {
      directory = "public",
      abs_dir = public_dir,
      not_found_handling = "404",
      run_worker_first = false,
    }
    local empty_assets_cfg = {
      directory = "empty-public",
      abs_dir = empty_assets_dir,
      not_found_handling = "404",
      run_worker_first = false,
    }
    local deps = {
      ngx = ngx,
      write_response = capture_write,
      json_error = function(message)
        return cjson.encode({ error = message })
      end,
    }

    assert_eq(assets.try_serve("/", "POST", assets_cfg, deps), false, "assets.try_serve non-GET/HEAD")
    assert_eq(assets.try_serve("/", "GET", nil, deps), false, "assets.try_serve nil config")
    assert_eq(assets.try_serve("/_fn/health", "GET", assets_cfg, deps), false, "assets.try_serve reserved")
    reset_capture()
    assert_eq(assets.try_serve("/", "GET", empty_assets_cfg, deps), false, "assets.try_serve empty dir root miss")
    assert_eq(response_status, nil, "assets.try_serve empty dir should not write")

    reset_capture()
    assert_eq(assets.try_serve(nil, "GET", assets_cfg, deps), true, "assets.try_serve root")
    assert_eq(response_status, 200, "assets.try_serve root status")
    assert_true(type(response_headers) == "table" and response_headers["Content-Type"] == "text/html; charset=utf-8", "assets.try_serve root content type")
    assert_true(type(response_body) == "string" and response_body:find("home", 1, true) ~= nil, "assets.try_serve root body")

    do
      local prev_file_meta = assets.file_meta
      local prev_http_time = ngx.http_time
      reset_capture()
      ngx.http_time = function(ts)
        return "HTTP:" .. tostring(ts)
      end
      assets.file_meta = function()
        return 1700000000, 21
      end
      assert_eq(assets.try_serve("/build/app.123456789.js", "HEAD", assets_cfg, deps), true, "assets.try_serve head")
      assets.file_meta = prev_file_meta
      ngx.http_time = prev_http_time
      assert_eq(response_status, 200, "assets.try_serve head status")
      assert_eq(response_body, nil, "assets.try_serve head body empty")
      assert_eq(response_headers["Cache-Control"], "public, max-age=31536000, immutable", "assets.try_serve head cache")
      assert_eq(response_headers["Last-Modified"], "HTTP:1700000000", "assets.try_serve head last-modified")
      assert_eq(response_headers["Content-Type"], "application/javascript; charset=utf-8", "assets.try_serve head content type")
    end

    do
      local prev_file_meta = assets.file_meta
      local prev_parse_http_time_304 = ngx.parse_http_time
      reset_capture()
      assets.file_meta = function()
        return 1700000000, 21
      end
      ngx.parse_http_time = function(raw)
        if raw == "HTTP:1700000000" then
          return 1700000000
        end
        return nil
      end
      ngx.req.get_headers = function()
        return { ["If-Modified-Since"] = "HTTP:1700000000" }
      end
      assert_eq(assets.try_serve("/build/app.123456789.js", "GET", assets_cfg, deps), true, "assets.try_serve 304")
      assets.file_meta = prev_file_meta
      ngx.parse_http_time = prev_parse_http_time_304
      ngx.req.get_headers = function()
        return {}
      end
      assert_eq(response_status, 304, "assets.try_serve 304 status")
      assert_eq(response_body, nil, "assets.try_serve 304 body empty")
    end

    do
      local spa_cfg = {
        directory = "public",
        abs_dir = public_dir,
        not_found_handling = "single-page-application",
        run_worker_first = false,
      }
      reset_capture()
      ngx.req.get_headers = function()
        return { Accept = "text/html" }
      end
      assert_eq(assets.try_serve("/dashboard/settings", "GET", spa_cfg, deps), true, "assets.try_serve spa")
      assert_eq(response_status, 200, "assets.try_serve spa status")
      assert_true(type(response_body) == "string" and response_body:find("home", 1, true) ~= nil, "assets.try_serve spa body")

      reset_capture()
      ngx.req.get_headers = function()
        return { Accept = "text/html" }
      end
      assert_eq(assets.try_serve("/dashboard/settings", "GET", spa_cfg, {
        ngx = ngx,
        write_response = write_response,
        json_error = json_error,
        allow_spa_fallback = false,
      }), false, "assets.try_serve spa can defer fallback")
      assert_eq(response_status, nil, "assets.try_serve spa defer no write")

      reset_capture()
      ngx.req.get_headers = function()
        return { Accept = "text/html" }
      end
      assert_eq(assets.try_serve("/missing.js", "GET", spa_cfg, deps), false, "assets.try_serve spa keeps extension 404")
      assert_eq(response_status, nil, "assets.try_serve spa extension no write")

	      reset_capture()
	      ngx.req.get_headers = function()
	        return { Accept = "*/*" }
	      end
	      assert_eq(assets.try_serve("/dashboard/settings", "GET", spa_cfg, deps), true, "assets.try_serve spa wildcard accept")
	      assert_eq(response_status, 200, "assets.try_serve spa wildcard accept status")

      reset_capture()
      ngx.req.get_headers = function()
        return { ["Sec-Fetch-Dest"] = "document" }
      end
      assert_eq(assets.try_serve("/dashboard/settings", "GET", spa_cfg, deps), true, "assets.try_serve spa sec-fetch document")
      assert_eq(response_status, 200, "assets.try_serve spa sec-fetch document status")
      assert_true(type(response_body) == "string" and response_body:find("home", 1, true) ~= nil, "assets.try_serve spa sec-fetch document body")

	      reset_capture()
	      ngx.req.get_headers = function()
	        return { Accept = "*/*" }
	      end
	      assert_eq(assets.try_serve("/dashboard/settings/", "GET", spa_cfg, deps), true, "assets.try_serve spa trailing slash wildcard accept")
	      assert_eq(response_status, 200, "assets.try_serve spa trailing slash wildcard accept status")

	      reset_capture()
	      ngx.req.get_headers = function()
	        return { Accept = "*/*" }
	      end
	      assert_eq(assets.try_serve("/api/unknown", "GET", spa_cfg, deps), false, "assets.try_serve spa api wildcard accept")
	      assert_eq(response_status, nil, "assets.try_serve spa api wildcard accept no write")
	    end

    do
      local prev_read_file = assets.read_file
      reset_capture()
      assets.read_file = function()
        return nil, "denied"
      end
      ngx.req.get_headers = function()
        return {}
      end
      assert_eq(assets.try_serve("/app.js", "GET", assets_cfg, deps), true, "assets.try_serve read error handled")
      assets.read_file = prev_read_file
      assert_eq(response_status, 500, "assets.try_serve read error status")
      assert_true(type(response_body) == "string" and response_body:find("failed to read asset", 1, true) ~= nil, "assets.try_serve read error body")
    end

    do
      local prev_file_meta = assets.file_meta
      local prev_read_file = assets.read_file
      reset_capture()
      assets.file_meta = function()
        return 1700000001, 999
      end
      assets.read_file = function()
        error("read_file should not run for preflight size rejection")
      end
      ngx.req.get_headers = function()
        return {}
      end
      assert_eq(assets.try_serve("/app.js", "GET", assets_cfg, {
        ngx = ngx,
        write_response = capture_write,
        max_asset_bytes = 4,
        json_error = function(message)
          return cjson.encode({ error = message })
        end,
      }), true, "assets.try_serve preflight large asset handled")
      assets.file_meta = prev_file_meta
      assets.read_file = prev_read_file
      assert_eq(response_status, 413, "assets.try_serve preflight large asset status")
      assert_true(type(response_body) == "string" and response_body:find("asset too large", 1, true) ~= nil, "assets.try_serve preflight large asset body")
    end

    do
      local prev_file_meta = assets.file_meta
      reset_capture()
      assets.file_meta = function()
        return 1700000002, nil
      end
      ngx.req.get_headers = function()
        return {}
      end
      assert_eq(assets.try_serve("/app.js", "GET", assets_cfg, deps), true, "assets.try_serve fills missing size from body")
      assets.file_meta = prev_file_meta
      assert_eq(response_status, 200, "assets.try_serve fills missing size status")
      assert_eq(response_headers["Content-Length"], tostring(#response_body), "assets.try_serve fills missing size content length")
      assert_true(type(response_headers["ETag"]) == "string" and response_headers["ETag"]:find("-" .. tostring(#response_body), 1, true) ~= nil, "assets.try_serve fills missing size etag")
    end

    do
      local prev_file_meta = assets.file_meta
      reset_capture()
      assets.file_meta = function()
        return nil, nil
      end
      ngx.req.get_headers = function()
        return {}
      end
      assert_eq(assets.try_serve("/app.js", "GET", assets_cfg, {
        ngx = ngx,
        write_response = capture_write,
        max_asset_bytes = 4,
        json_error = function(message)
          return cjson.encode({ error = message })
        end,
      }), true, "assets.try_serve large asset handled")
      assets.file_meta = prev_file_meta
      assert_eq(response_status, 413, "assets.try_serve large asset status")
      assert_true(type(response_body) == "string" and response_body:find("asset too large", 1, true) ~= nil, "assets.try_serve large asset body")
    end

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)

  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-assets-routes-" .. uniq
    local functions_root = root .. "/srv/fn/functions"

    rm_rf(root)
    mkdir_p(functions_root .. "/site-assets")
    write_file(functions_root .. "/fn.config.json", cjson.encode({
      assets = {
        directory = "site-assets",
        not_found_handling = "spa",
        run_worker_first = true,
      },
    }) .. "\n")
    write_file(functions_root .. "/site-assets/index.html", "<html>route assets</html>\n")

    with_module_stubs({
      ["fastfn.core.watchdog"] = {
        start = function() return false, "disabled in unit" end,
      },
    }, function()
      with_env({ FN_FUNCTIONS_ROOT = functions_root, FN_RUNTIMES = "node" }, function()
        package.loaded["fastfn.core.routes"] = nil
        local routes = require("fastfn.core.routes")
        local load_runtime_config = get_upvalue(routes.get_config, "load_runtime_config")
        local normalize_assets = get_upvalue(load_runtime_config, "normalize_assets")
        local is_safe_root_relative_path = type(normalize_assets) == "function" and get_upvalue(normalize_assets, "is_safe_root_relative_path") or nil
        local relative_path_has_prefix = get_upvalue(routes.discover_functions, "relative_path_has_prefix")

        assert_true(type(is_safe_root_relative_path) == "function", "routes assets helper exposed")
        assert_eq(is_safe_root_relative_path("site-assets"), true, "routes assets safe relative")
        assert_eq(is_safe_root_relative_path(""), false, "routes assets empty")
        assert_eq(is_safe_root_relative_path("/site-assets"), false, "routes assets absolute")
        assert_eq(is_safe_root_relative_path("a//b"), false, "routes assets double slash")
        assert_eq(is_safe_root_relative_path("a\\b"), false, "routes assets backslash")
        assert_eq(is_safe_root_relative_path("a/../b"), false, "routes assets traversal")

        local default_assets = normalize_assets({ directory = "site-assets" }, functions_root)
        assert_true(type(default_assets) == "table", "routes normalize_assets default")
        assert_eq(default_assets.not_found_handling, "404", "routes normalize_assets default not_found")
        assert_eq(default_assets.run_worker_first, false, "routes normalize_assets default worker first")

        local cfg_assets = routes.get_assets_config()
        assert_true(type(cfg_assets) == "table", "routes get_assets_config table")
        assert_eq(cfg_assets.directory, "site-assets", "routes get_assets_config directory")
        assert_eq(cfg_assets.not_found_handling, "single-page-application", "routes get_assets_config spa alias")
        assert_eq(cfg_assets.run_worker_first, true, "routes get_assets_config worker first")
        assert_true(type(cfg_assets.abs_dir) == "string" and cfg_assets.abs_dir:find("/site-assets", 1, true) ~= nil, "routes get_assets_config abs dir")

        cache:set("runtime:config", cjson.encode({
          functions_root = "/tmp/fastfn-stale-root",
          socket_base_dir = "/tmp/fastfn-stale-sockets",
          assets = nil,
        }))
        local refreshed_assets = routes.get_assets_config()
        assert_true(type(refreshed_assets) == "table", "routes get_assets_config refreshes stale cache")
        assert_eq(refreshed_assets.directory, "site-assets", "routes get_assets_config refreshed directory")

        assert_eq(normalize_assets(nil, functions_root), nil, "routes normalize_assets nil")
        assert_eq(normalize_assets({ directory = "" }, functions_root), nil, "routes normalize_assets empty dir")
        assert_eq(normalize_assets({ directory = true }, functions_root), nil, "routes normalize_assets non-string dir")
        assert_eq(normalize_assets({ directory = "/abs" }, functions_root), nil, "routes normalize_assets absolute dir")
        assert_eq(normalize_assets({ directory = "../outside" }, functions_root), nil, "routes normalize_assets traversal dir")
        assert_eq(normalize_assets({ directory = "missing" }, functions_root), nil, "routes normalize_assets missing dir")
        assert_eq(normalize_assets({ directory = "site-assets", not_found_handling = "bogus" }, functions_root), nil, "routes normalize_assets bad mode")
        assert_eq(normalize_assets({ directory = "site-assets" }, nil), nil, "routes normalize_assets nil base dir")

        assert_true(type(relative_path_has_prefix) == "function", "routes relative_path_has_prefix helper")
        assert_eq(relative_path_has_prefix("site-assets", "site-assets"), true, "routes relative_path_has_prefix exact")
        assert_eq(relative_path_has_prefix("site-assets/js/app.js", "site-assets"), true, "routes relative_path_has_prefix nested")
        assert_eq(relative_path_has_prefix("site-assets-other", "site-assets"), false, "routes relative_path_has_prefix sibling")
        assert_eq(relative_path_has_prefix("", "site-assets"), false, "routes relative_path_has_prefix empty")

        local scanned_rel_dir_set = {}
        local synthetic_catalog = nil
        with_upvalue(routes.discover_functions, "load_runtime_config", function()
          return {
            functions_root = "/tmp/fastfn-assets-scan",
            assets = { directory = "site-assets" },
            zero_config = { ignore_dirs = { "node_modules" } },
            runtimes = {
              node = { socket = "unix:/tmp/fn-node.sock", sockets = { "unix:/tmp/fn-node.sock" } },
            },
          }
        end, function()
          with_upvalue(routes.discover_functions, "force_url_enabled", function()
            return false
          end, function()
            with_upvalue(routes.discover_functions, "detect_manifest_routes_in_dir", function()
              return {}, false
            end, function()
              with_upvalue(routes.discover_functions, "read_json_file", function()
                return nil
              end, function()
                with_upvalue(routes.discover_functions, "list_dirs", function(path)
                  if path == "/tmp/fastfn-assets-scan" then
                    return {
                      "/tmp/fastfn-assets-scan/site-assets",
                      "/tmp/fastfn-assets-scan/visible",
                    }
                  end
                  return {}
                end, function()
                  with_upvalue(routes.discover_functions, "detect_file_based_routes_in_dir", function(_abs_dir, rel_dir)
                    scanned_rel_dir_set[tostring(rel_dir)] = true
                    if rel_dir == "visible" then
                      return {
                        {
                          route = "/visible",
                          runtime = "node",
                          target = "visible/get.visible.js",
                          methods = { "GET" },
                        },
                      }
                    end
                    return {}
                  end, function()
                    synthetic_catalog = routes.discover_functions(true)
                  end)
                end)
              end)
            end)
          end)
        end)

        assert_true(type(synthetic_catalog) == "table", "routes synthetic catalog for assets")
        assert_true(synthetic_catalog.mapped_routes["/visible"] ~= nil, "routes synthetic visible route kept")
        assert_eq(scanned_rel_dir_set["site-assets"], nil, "routes synthetic assets dir skipped")
        assert_eq(scanned_rel_dir_set["visible"], true, "routes synthetic visible dir scanned")

        local assets_only_catalog = nil
        local assets_only_scanned_rel_dir_set = {}
        with_upvalue(routes.discover_functions, "load_runtime_config", function()
          return {
            functions_root = "/tmp/fastfn-assets-only-scan",
            assets = { directory = "site-assets" },
            zero_config = { ignore_dirs = { "node_modules" } },
            runtimes = {
              node = { socket = "unix:/tmp/fn-node.sock", sockets = { "unix:/tmp/fn-node.sock" } },
            },
          }
        end, function()
          with_upvalue(routes.discover_functions, "force_url_enabled", function()
            return false
          end, function()
            with_upvalue(routes.discover_functions, "detect_manifest_routes_in_dir", function()
              return {}, false
            end, function()
              with_upvalue(routes.discover_functions, "read_json_file", function()
                return nil
              end, function()
                with_upvalue(routes.discover_functions, "list_dirs", function(path)
                  if path == "/tmp/fastfn-assets-only-scan" then
                    return { "/tmp/fastfn-assets-only-scan/site-assets" }
                  end
                  return {}
                end, function()
                  with_upvalue(routes.discover_functions, "detect_file_based_routes_in_dir", function(_abs_dir, rel_dir)
                    assets_only_scanned_rel_dir_set[tostring(rel_dir)] = true
                    return {}
                  end, function()
                    assets_only_catalog = routes.discover_functions(true)
                  end)
                end)
              end)
            end)
          end)
        end)
        assert_true(type(assets_only_catalog) == "table", "routes assets-only catalog")
        assert_eq(next(assets_only_catalog.mapped_routes or {}), nil, "routes assets-only catalog should not create public routes")
        assert_eq(assets_only_scanned_rel_dir_set["site-assets"], nil, "routes assets-only assets dir skipped")

        local nested_scanned_rel_dir_set = {}
        local nested_catalog = nil
        local nested_root = "/tmp/fastfn-assets-nested-scan"
        rm_rf(nested_root)
        mkdir_p(nested_root .. "/demo/public")
        with_upvalue(routes.discover_functions, "load_runtime_config", function()
          return {
            functions_root = nested_root,
            assets = nil,
            zero_config = { ignore_dirs = { "node_modules" } },
            runtimes = {
              node = { socket = "unix:/tmp/fn-node.sock", sockets = { "unix:/tmp/fn-node.sock" } },
            },
          }
        end, function()
          with_upvalue(routes.discover_functions, "force_url_enabled", function()
            return false
          end, function()
            with_upvalue(routes.discover_functions, "detect_manifest_routes_in_dir", function()
              return {}, false
            end, function()
              with_upvalue(routes.discover_functions, "read_json_file", function(path)
                if path == "/tmp/fastfn-assets-nested-scan/demo/fn.config.json" then
                  return { assets = { directory = "public" } }
                end
                return nil
              end, function()
                with_upvalue(routes.discover_functions, "list_dirs", function(path)
                  if path == "/tmp/fastfn-assets-nested-scan" then
                    return {
                      "/tmp/fastfn-assets-nested-scan/demo",
                      "/tmp/fastfn-assets-nested-scan/visible",
                    }
                  end
                  if path == "/tmp/fastfn-assets-nested-scan/demo" then
                    return {
                      "/tmp/fastfn-assets-nested-scan/demo/api",
                      "/tmp/fastfn-assets-nested-scan/demo/public",
                    }
                  end
                  return {}
                end, function()
                  with_upvalue(routes.discover_functions, "detect_file_based_routes_in_dir", function(_abs_dir, rel_dir)
                    nested_scanned_rel_dir_set[tostring(rel_dir)] = true
                    if rel_dir == "demo/api" then
                      return {
                        {
                          route = "/demo/api",
                          runtime = "node",
                          target = "demo/api/handler.js",
                          methods = { "GET" },
                        },
                      }
                    end
                    if rel_dir == "visible" then
                      return {
                        {
                          route = "/visible",
                          runtime = "node",
                          target = "visible/handler.js",
                          methods = { "GET" },
                        },
                      }
                    end
                    return {}
                  end, function()
                    nested_catalog = routes.discover_functions(true)
                  end)
                end)
              end)
            end)
          end)
        end)

        assert_true(type(nested_catalog) == "table", "routes synthetic nested catalog for assets")
        assert_true(nested_catalog.mapped_routes["/demo/api"] ~= nil, "routes synthetic nested api route kept")
        assert_true(nested_catalog.mapped_routes["/visible"] ~= nil, "routes synthetic nested visible route kept")
        assert_eq(nested_scanned_rel_dir_set["demo/public"], nil, "routes synthetic nested assets dir skipped")
        assert_eq(nested_scanned_rel_dir_set["demo/api"], true, "routes synthetic nested api dir scanned")
        rm_rf(nested_root)

        package.loaded["fastfn.core.routes"] = nil
      end)
    end)

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)

  with_fake_ngx(function(cache, conc, _set_now)
    local cjson = require("cjson.safe")
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-assets-gateway-" .. uniq
    local public_dir = root .. "/public"

    rm_rf(root)
    mkdir_p(public_dir .. "/hello")
    write_file(public_dir .. "/hello/index.html", "<html>asset wins</html>\n")

    local function merge_tables(base, extra)
      local out = {}
      for key, value in pairs(base or {}) do
        out[key] = value
      end
      for key, value in pairs(extra or {}) do
        out[key] = value
      end
      return out
    end

    local function read_text_file(path)
      local f = io.open(path, "rb")
      assert_true(f ~= nil, "read_text_file open " .. tostring(path))
      local data = f:read("*a")
      f:close()
      return data
    end

    local function load_gateway_helpers(extra_stubs)
      local source = read_text_file(REPO_ROOT .. "/openresty/lua/fastfn/http/gateway.lua")
      local prefix = source:match("^(.-)\nlocal request_uri = ngx%.var%.uri or \"\"")
      assert_true(type(prefix) == "string" and prefix ~= "", "gateway helper prefix")
      local chunk_source = prefix .. [[

return {
  json_error = json_error,
  content_length_limit_exceeded = content_length_limit_exceeded,
  read_body_limited = read_body_limited,
  new_request_id = new_request_id,
  parse_cookies = parse_cookies,
  build_session = build_session,
  extract_user_context = extract_user_context,
  should_block_runtime = should_block_runtime,
  map_runtime_error = map_runtime_error,
  call_external_runtime = call_external_runtime,
  table_set = table_set,
  host_is_private = host_is_private,
  sanitize_proxy_headers = sanitize_proxy_headers,
  build_proxy_url = build_proxy_url,
  proxy_path_is_control_plane = proxy_path_is_control_plane,
  proxy_allowed = proxy_allowed,
  execute_proxy = execute_proxy,
  method_is_allowed = method_is_allowed,
  allow_header_value = allow_header_value,
  split_host_port = split_host_port,
  request_host_values = request_host_values,
  host_matches_pattern = host_matches_pattern,
  host_is_allowed = host_is_allowed,
  request_client_ip = request_client_ip,
  cidr_contains_ip = cidr_contains_ip,
  cidrs_allow_ip = cidrs_allow_ip,
  host_allowlist_score = host_allowlist_score,
  match_public_workload = match_public_workload,
  execute_public_workload_proxy = execute_public_workload_proxy,
  resolve_request_target = resolve_request_target,
}
]]
      local exports = nil
      with_module_stubs(merge_tables({
        ["fastfn.core.routes"] = {
          resolve_mapped_target = function()
            return nil
          end,
          resolve_named_target = function()
            return nil, nil
          end,
          runtime_is_up = function()
            return true
          end,
          check_runtime_health = function()
            return true, "ok"
          end,
          set_runtime_health = function() end,
          set_runtime_socket_health = function()
            return true
          end,
        },
        ["fastfn.core.client"] = {
          call_unix = function()
            return nil, "connect_error", "down"
          end,
        },
        ["fastfn.core.lua_runtime"] = {},
        ["fastfn.core.limits"] = {},
        ["fastfn.core.gateway_utils"] = {
          map_runtime_error = function(code)
            if code == "timeout" then
              return 504, "runtime timeout"
            end
            if code == "connect_error" then
              return 503, "runtime unavailable"
            end
            if code == "invalid_response" then
              return 502, "invalid runtime response"
            end
            return 502, "runtime error"
          end,
          parse_versioned_target = function()
            return nil, nil
          end,
        },
        ["fastfn.core.http_client"] = {
          request = function()
            return nil, "http disabled"
          end,
        },
        ["fastfn.core.invoke_rules"] = {
          ALLOWED_METHODS = {
            GET = true,
            POST = true,
            PUT = true,
            PATCH = true,
            DELETE = true,
          },
        },
        ["fastfn.http.assets"] = {},
      }, extra_stubs), function()
        local chunk, err = loadstring(chunk_source, "@" .. REPO_ROOT .. "/openresty/lua/fastfn/http/gateway.lua")
        assert_true(type(chunk) == "function", "gateway helper chunk load " .. tostring(err))
        exports = chunk()
      end)
      return exports
    end

    local prev_decode_base64 = ngx.decode_base64
    local prev_re = ngx.re
    ngx.decode_base64 = function(raw)
      local decoded = {
        ["ctx-ok"] = '{"role":"admin","sub":"user-1"}',
        ["ctx-number"] = "123",
        ["proxy-ok"] = "proxied body",
        ["resp-ok"] = "decoded runtime body",
      }
      return decoded[raw]
    end
    ngx.re = {
      match = function(url)
        local scheme, authority, path = tostring(url or ""):match("^(https?)://([^/]+)(/.*)?$")
        if not scheme then
          return nil
        end
        return { scheme, authority, path }
      end,
    }

    do
      local helpers = load_gateway_helpers()

      local helper_json = helpers.json_error("bad news")
      assert_true(type(helper_json) == "string" and helper_json:find("bad news", 1, true) ~= nil, "gateway helper json_error body")

      ngx.req.get_headers = function()
        return { ["content-length"] = "11" }
      end
      assert_eq(helpers.content_length_limit_exceeded(10), true, "gateway helper content length overflow")
      ngx.req.get_headers = function()
        return { ["content-length"] = "9" }
      end
      assert_eq(helpers.content_length_limit_exceeded(10), false, "gateway helper content length allowed")
      ngx.req.get_headers = function()
        return {}
      end
      assert_eq(helpers.content_length_limit_exceeded(10), nil, "gateway helper content length missing")

      ngx.req.read_body = function() end
      ngx.req.get_body_data = function()
        return "abc"
      end
      ngx.req.get_body_file = function()
        return nil
      end
      local body_data_ok, body_data_err = helpers.read_body_limited(10)
      assert_eq(body_data_ok, "abc", "gateway helper body data ok")
      assert_eq(body_data_err, nil, "gateway helper body data err")

      ngx.req.get_body_data = function()
        return string.rep("x", 12)
      end
      local body_data_big, body_data_big_err = helpers.read_body_limited(10)
      assert_eq(body_data_big, nil, "gateway helper body data overflow body")
      assert_eq(body_data_big_err, "too_large", "gateway helper body data overflow err")

      ngx.req.get_body_data = function()
        return nil
      end
      ngx.req.get_body_file = function()
        return nil
      end
      local body_missing, body_missing_err = helpers.read_body_limited(10)
      assert_eq(body_missing, nil, "gateway helper body missing")
      assert_eq(body_missing_err, nil, "gateway helper body missing err")

      local body_ok_file = root .. "/body-ok.bin"
      local body_large_file = root .. "/body-large.bin"
      write_file(body_ok_file, "12345")
      write_file(body_large_file, string.rep("a", 14))

      ngx.req.get_body_file = function()
        return body_ok_file
      end
      local body_file_ok, body_file_ok_err = helpers.read_body_limited(10)
      assert_eq(body_file_ok, "12345", "gateway helper body file ok")
      assert_eq(body_file_ok_err, nil, "gateway helper body file ok err")

      ngx.req.get_body_file = function()
        return body_large_file
      end
      local body_file_big, body_file_big_err = helpers.read_body_limited(10)
      assert_eq(body_file_big, nil, "gateway helper body file big body")
      assert_eq(body_file_big_err, "too_large", "gateway helper body file big err")

      ngx.req.get_body_file = function()
        return root .. "/missing-body.bin"
      end
      local body_open_fail, body_open_fail_err = helpers.read_body_limited(10)
      assert_eq(body_open_fail, nil, "gateway helper body file open fail body")
      assert_eq(body_open_fail_err, "body_file_open_error", "gateway helper body file open fail err")

      do
        local prev_io = io
        _G.io = {
          open = function()
            return {
              seek = function(_, mode)
                if mode == "end" then
                  return nil
                end
                return 0
              end,
              read = function()
                return string.rep("z", 12)
              end,
              close = function() end,
            }
          end,
        }
        ngx.req.get_body_file = function()
          return "/virtual-body.bin"
        end
        local body_virtual, body_virtual_err = helpers.read_body_limited(10)
        _G.io = prev_io
        assert_eq(body_virtual, nil, "gateway helper body virtual body")
        assert_eq(body_virtual_err, "too_large", "gateway helper body virtual err")
      end

      local request_id = helpers.new_request_id()
      assert_true(type(request_id) == "string" and request_id:find("^req%-", 1, false) ~= nil, "gateway helper request id format")

      local cookies_empty = helpers.parse_cookies(nil)
      assert_true(type(cookies_empty) == "table" and next(cookies_empty) == nil, "gateway helper empty cookies")
      local cookies = helpers.parse_cookies("theme=dark; session_id=abc123; sid=def; x=y")
      assert_eq(cookies.theme, "dark", "gateway helper cookie theme")
      assert_eq(cookies.session_id, "abc123", "gateway helper cookie session")
      assert_eq(cookies.sid, "def", "gateway helper cookie sid")

      assert_eq(helpers.build_session({}), nil, "gateway helper build session missing")
      local session = helpers.build_session({ cookie = "foo=bar; sid=s-1" })
      assert_true(type(session) == "table", "gateway helper session table")
      assert_eq(session.id, "s-1", "gateway helper session id")
      assert_eq(session.cookies.foo, "bar", "gateway helper session cookie passthrough")

      assert_eq(helpers.extract_user_context("bad"), nil, "gateway helper extract user context non-table")
      assert_eq(helpers.extract_user_context({}), nil, "gateway helper extract user context missing")
      assert_eq(helpers.extract_user_context({ __fnctx = "" }), nil, "gateway helper extract user context empty")
      assert_eq(helpers.extract_user_context({ __fnctx = "ctx-missing" }), nil, "gateway helper extract user context decode fail")
      assert_eq(helpers.extract_user_context({ __fnctx = "ctx-number" }), nil, "gateway helper extract user context non-object")
      local query = { __fnctx = { "ctx-ok" }, keep = "yes" }
      local user_context = helpers.extract_user_context(query)
      assert_true(type(user_context) == "table" and user_context.role == "admin", "gateway helper extract user context ok")
      assert_eq(query.__fnctx, nil, "gateway helper extract user context strips internal key")
      assert_eq(query.keep, "yes", "gateway helper extract user context keeps other keys")

      assert_eq(helpers.should_block_runtime("lua", {}), false, "gateway helper should block healthy runtime")
      do
        local health_events = {}
        local blocking = load_gateway_helpers({
          ["fastfn.core.routes"] = {
            runtime_is_up = function()
              return false
            end,
            check_runtime_health = function()
              return false, "down"
            end,
            set_runtime_health = function(_runtime, ok, reason)
              health_events[#health_events + 1] = tostring(ok) .. ":" .. tostring(reason)
            end,
          },
        })
        assert_eq(blocking.should_block_runtime("node", { socket = "unix:/tmp/fn.sock" }), true, "gateway helper should block unhealthy runtime")
        assert_eq(health_events[1], "false:down", "gateway helper runtime health event")
      end

      do
        local status_timeout, body_timeout = helpers.map_runtime_error("lua", "timeout", "ignored")
        assert_eq(status_timeout, 504, "gateway helper map runtime timeout status")
        assert_true(type(body_timeout) == "string" and body_timeout:find("runtime timeout", 1, true) ~= nil, "gateway helper map runtime timeout body")
        local status_other, body_other = helpers.map_runtime_error("lua", "other", "boom")
        assert_eq(status_other, 502, "gateway helper map runtime other status")
        assert_true(type(body_other) == "string" and body_other:find("boom", 1, true) ~= nil, "gateway helper map runtime other body")
      end

      do
        local set_values = helpers.table_set({ "a", 2 })
        assert_eq(set_values.a, true, "gateway helper table_set string")
        assert_eq(set_values["2"], true, "gateway helper table_set numeric")
      end

      assert_eq(helpers.host_is_private("localhost"), true, "gateway helper private localhost")
      assert_eq(helpers.host_is_private("10.0.0.8"), true, "gateway helper private 10")
      assert_eq(helpers.host_is_private("172.16.0.1"), true, "gateway helper private 172")
      assert_eq(helpers.host_is_private("169.254.1.2"), true, "gateway helper private link local")
      assert_eq(helpers.host_is_private("fd00::1"), true, "gateway helper private ipv6")
      assert_eq(helpers.host_is_private("::ffff:172.20.0.1"), true, "gateway helper private mapped 172")
      assert_eq(helpers.host_is_private("::ffff:10.0.0.1"), true, "gateway helper private mapped ipv4")
      assert_eq(helpers.host_is_private("8.8.8.8"), false, "gateway helper public host")

      local clean_headers = helpers.sanitize_proxy_headers({
        ["X-Ok"] = "1",
        ["Bad Header"] = "x",
        ["X-Evil"] = "a\r\nb",
      })
      assert_eq(clean_headers["X-Ok"], "1", "gateway helper sanitize proxy ok")
      assert_eq(clean_headers["Bad Header"], nil, "gateway helper sanitize proxy invalid key")
      assert_eq(clean_headers["X-Evil"], nil, "gateway helper sanitize proxy invalid value")
      assert_true(type(helpers.sanitize_proxy_headers(false)) == "table", "gateway helper sanitize proxy non-table")

      local abs_url, abs_err = helpers.build_proxy_url({ url = "https://api.example.com/data" }, {})
      assert_eq(abs_url, "https://api.example.com/data", "gateway helper build proxy absolute url")
      assert_eq(abs_err, nil, "gateway helper build proxy absolute err")
      local rel_url = helpers.build_proxy_url({ url = "/data" }, { base_url = "https://edge.example.com///" })
      assert_eq(rel_url, "https://edge.example.com/data", "gateway helper build proxy relative url")
      local _, proxy_not_table_err = helpers.build_proxy_url("bad", {})
      assert_eq(proxy_not_table_err, "proxy must be an object", "gateway helper build proxy object err")
      local _, proxy_path_err = helpers.build_proxy_url({ path = "data" }, {})
      assert_true(type(proxy_path_err) == "string" and proxy_path_err:find("must start with /", 1, true) ~= nil, "gateway helper build proxy path err")
      local _, proxy_traversal_err = helpers.build_proxy_url({ path = "/../data" }, { base_url = "https://edge.example.com" })
      assert_eq(proxy_traversal_err, "proxy.path may not include ..", "gateway helper build proxy traversal err")
      local _, proxy_base_err = helpers.build_proxy_url({ path = "/data" }, {})
      assert_eq(proxy_base_err, "edge.base_url is required for relative proxy paths", "gateway helper build proxy base err")

      assert_eq(helpers.proxy_path_is_control_plane(nil), false, "gateway helper proxy control plane nil")
      assert_eq(helpers.proxy_path_is_control_plane("/console"), true, "gateway helper proxy control plane console")
      assert_eq(helpers.proxy_path_is_control_plane("/_fn/docs"), true, "gateway helper proxy control plane fn")
      assert_eq(helpers.proxy_path_is_control_plane("/consolex"), false, "gateway helper proxy control plane public")

      local proxy_invalid_url_ok, proxy_invalid_url_msg = helpers.proxy_allowed({}, {})
      assert_eq(proxy_invalid_url_ok, false, "gateway helper proxy invalid url ok")
      assert_eq(proxy_invalid_url_msg, "invalid url", "gateway helper proxy invalid url msg")
      do
        local prev_re_match = ngx.re.match
        ngx.re.match = function()
          return nil
        end
        local proxy_regex_miss_ok, proxy_regex_miss_msg = helpers.proxy_allowed("https://api.example.com/ok", {})
        ngx.re.match = prev_re_match
        assert_eq(proxy_regex_miss_ok, false, "gateway helper proxy regex miss ok")
        assert_eq(proxy_regex_miss_msg, "invalid url", "gateway helper proxy regex miss msg")
      end
      do
        local prev_re_match = ngx.re.match
        ngx.re.match = function()
          return { "ftp", "example.com", "/" }
        end
        local proxy_bad_scheme_ok, proxy_bad_scheme_msg = helpers.proxy_allowed("ftp://example.com/", {})
        ngx.re.match = prev_re_match
        assert_eq(proxy_bad_scheme_ok, false, "gateway helper proxy invalid scheme ok")
        assert_eq(proxy_bad_scheme_msg, "invalid scheme", "gateway helper proxy invalid scheme msg")
      end
      do
        local prev_re_match = ngx.re.match
        ngx.re.match = function()
          return { "https", "api.example.com", "/_fn/health" }
        end
        local proxy_control_ok, proxy_control_msg = helpers.proxy_allowed("https://api.example.com/_fn/health", {})
        ngx.re.match = prev_re_match
        assert_eq(proxy_control_ok, false, "gateway helper proxy control denied")
        assert_eq(proxy_control_msg, "control-plane path not allowed", "gateway helper proxy control msg")
      end
      do
        local prev_re_match = ngx.re.match
        ngx.re.match = function()
          return { "http", "127.0.0.1", "/ping" }
        end
        local proxy_private_ok, proxy_private_msg = helpers.proxy_allowed("http://127.0.0.1/ping", {})
        local proxy_allow_private_ok = helpers.proxy_allowed("http://127.0.0.1/ping", { allow_private = true })
        ngx.re.match = prev_re_match
        assert_eq(proxy_private_ok, false, "gateway helper proxy private denied")
        assert_eq(proxy_private_msg, "private host not allowed", "gateway helper proxy private msg")
        assert_eq(proxy_allow_private_ok, true, "gateway helper proxy private allowed")
      end
      do
        local prev_re_match = ngx.re.match
        ngx.re.match = function()
          return { "https", "api.example.com", "/ok" }
        end
        local proxy_allowlist_ok, proxy_allowlist_msg = helpers.proxy_allowed("https://api.example.com/ok", { allow_hosts = { "other.example.com" } })
        ngx.re.match = prev_re_match
        assert_eq(proxy_allowlist_ok, false, "gateway helper proxy allowlist denied")
        assert_eq(proxy_allowlist_msg, "host not in allowlist", "gateway helper proxy allowlist msg")
      end
      do
        local prev_re_match = ngx.re.match
        ngx.re.match = function()
          return { "https", "[2001:db8::1]:443", "/ok" }
        end
        local proxy_ipv6_ok = helpers.proxy_allowed("https://[2001:db8::1]:443/ok", { allow_hosts = { "2001:db8::1" } })
        local proxy_allow_hosts_string_ok = helpers.proxy_allowed("https://[2001:db8::1]:443/ok", { allow_hosts = "bad", allow_private = true })
        ngx.re.match = prev_re_match
        assert_eq(proxy_ipv6_ok, true, "gateway helper proxy ipv6 ok")
        assert_eq(proxy_allow_hosts_string_ok, true, "gateway helper proxy allow_hosts string coerced")
      end

      do
        local execute_helpers = load_gateway_helpers({
          ["fastfn.core.http_client"] = {
            request = function(req)
              return {
                status = 201,
                headers = {
                  ["Content-Type"] = "application/json",
                  ["Transfer-Encoding"] = "chunked",
                  ["Connection"] = "keep-alive",
                  ["X-Upstream"] = "yes",
                },
                body = '{"ok":true}',
              }
            end,
          },
        })
        local _, exec_object_err = execute_helpers.execute_proxy("bad", {}, 50)
        assert_eq(exec_object_err, "proxy must be an object", "gateway helper execute proxy object err")
        local prev_re_match = ngx.re.match
        ngx.re.match = function(_url)
          return { "http", "127.0.0.1", "/ping" }
        end
        local _, exec_denied_err = execute_helpers.execute_proxy({ url = "http://127.0.0.1/ping" }, {}, 50)
        assert_true(type(exec_denied_err) == "string" and exec_denied_err:find("proxy denied", 1, true) == 1, "gateway helper execute proxy denied")
        ngx.re.match = function(_url)
          return { "https", "api.example.com", "/x" }
        end
        local _, exec_method_err = execute_helpers.execute_proxy({ url = "https://api.example.com/x", method = "TRACE" }, { allow_hosts = { "api.example.com" } }, 50)
        assert_eq(exec_method_err, "invalid proxy method", "gateway helper execute proxy method err")
        local _, exec_b64_missing_err = execute_helpers.execute_proxy({ url = "https://api.example.com/x", is_base64 = true }, { allow_hosts = { "api.example.com" } }, 50)
        assert_eq(exec_b64_missing_err, "proxy.body_base64 must be a non-empty string when proxy.is_base64=true", "gateway helper execute proxy missing body_base64")
        local _, exec_b64_invalid_err = execute_helpers.execute_proxy({ url = "https://api.example.com/x", is_base64 = true, body_base64 = "bad" }, { allow_hosts = { "api.example.com" } }, 50)
        assert_eq(exec_b64_invalid_err, "invalid proxy.body_base64", "gateway helper execute proxy invalid body_base64")

        local failing_helpers = load_gateway_helpers({
          ["fastfn.core.http_client"] = {
            request = function(req)
              assert_eq(req.body, "42", "gateway helper execute proxy stringifies body")
              return nil, "unreachable"
            end,
          },
        })
        local _, exec_http_err = failing_helpers.execute_proxy({
          url = "https://api.example.com/x",
          method = "POST",
          body = 42,
          headers = {
            ["X-Ok"] = "1",
            ["Bad Header"] = "x",
          },
        }, { allow_hosts = { "api.example.com" } }, 50)
        assert_eq(exec_http_err, "proxy request failed: unreachable", "gateway helper execute proxy request err")

        local exec_success = execute_helpers.execute_proxy({
          url = "https://api.example.com/x",
          method = "POST",
          is_base64 = true,
          body_base64 = "proxy-ok",
          headers = {
            ["X-Ok"] = "1",
            ["X-Evil"] = "a\r\nb",
          },
          timeout_ms = 123,
          max_response_bytes = 321,
        }, { allow_hosts = { "api.example.com" } }, 50)
        ngx.re.match = prev_re_match
        assert_true(type(exec_success) == "table", "gateway helper execute proxy success")
        assert_eq(exec_success.status, 201, "gateway helper execute proxy success status")
        assert_eq(exec_success.headers["Transfer-Encoding"], nil, "gateway helper execute proxy strips hop headers")
        assert_eq(exec_success.headers["X-Upstream"], "yes", "gateway helper execute proxy keeps safe headers")
      end

      assert_eq(helpers.method_is_allowed(nil, { "GET" }), false, "gateway helper method allowed non-string")
      assert_eq(helpers.method_is_allowed("GET", nil), true, "gateway helper method allowed default get")
      assert_eq(helpers.method_is_allowed("POST", nil), false, "gateway helper method allowed default reject")
      assert_eq(helpers.method_is_allowed("post", { "GET", "POST" }), true, "gateway helper method allowed explicit")
      assert_eq(helpers.method_is_allowed("DELETE", { "GET", "POST" }), false, "gateway helper method allowed missing")

      assert_eq(helpers.allow_header_value(nil), "GET", "gateway helper allow header default")
      assert_eq(helpers.allow_header_value({ "GET", "POST" }), "GET, POST", "gateway helper allow header join")

      local host_empty, authority_empty = helpers.split_host_port(nil)
      assert_eq(host_empty, "", "gateway helper split host empty host")
      assert_eq(authority_empty, "", "gateway helper split host empty authority")
      local host_ipv6, authority_ipv6 = helpers.split_host_port("[::1]:8443")
      assert_eq(host_ipv6, "::1", "gateway helper split host ipv6")
      assert_eq(authority_ipv6, "[::1]:8443", "gateway helper split host ipv6 authority")
      local host_named, authority_named = helpers.split_host_port("Example.com:443")
      assert_eq(host_named, "example.com", "gateway helper split host named")
      assert_eq(authority_named, "example.com:443", "gateway helper split host named authority")

      ngx.var.http_x_forwarded_host = "api.example.com:8443, proxy.example.com"
      ngx.var.http_host = "ignored.example.com"
      ngx.var.host = "fallback.example.com"
      local req_host_forwarded, req_authority_forwarded = helpers.request_host_values()
      assert_eq(req_host_forwarded, "api.example.com", "gateway helper request host forwarded host")
      assert_eq(req_authority_forwarded, "api.example.com:8443", "gateway helper request host forwarded authority")
      ngx.var.http_x_forwarded_host = nil
      ngx.var.http_host = "app.example.com:9443"
      local req_host_header, req_authority_header = helpers.request_host_values()
      assert_eq(req_host_header, "app.example.com", "gateway helper request host header host")
      assert_eq(req_authority_header, "app.example.com:9443", "gateway helper request host header authority")
      ngx.var.http_host = nil
      ngx.var.host = "fallback.example.com"
      local req_host_fallback, req_authority_fallback = helpers.request_host_values()
      assert_eq(req_host_fallback, "fallback.example.com", "gateway helper request host fallback host")
      assert_eq(req_authority_fallback, "fallback.example.com", "gateway helper request host fallback authority")

      assert_eq(helpers.host_matches_pattern("", "*.example.com"), false, "gateway helper host matches empty")
      assert_eq(helpers.host_matches_pattern("api.example.com", "api.example.com"), true, "gateway helper host matches exact")
      assert_eq(helpers.host_matches_pattern("example.com", "*.example.com"), false, "gateway helper host matches root reject")
      assert_eq(helpers.host_matches_pattern("api.example.com", "*.example.com"), true, "gateway helper host matches wildcard")
      assert_eq(helpers.host_matches_pattern("api.example.net", "*.example.com"), false, "gateway helper host matches mismatch")

      assert_eq(helpers.host_is_allowed(nil), true, "gateway helper host allowed empty")
      ngx.var.http_host = nil
      ngx.var.http_x_forwarded_host = nil
      ngx.var.host = ""
      assert_eq(helpers.host_is_allowed({ "api.example.com" }), false, "gateway helper host allowed blank host")
      ngx.var.http_host = "api.example.com:8443"
      ngx.var.host = "api.example.com"
      assert_eq(helpers.host_is_allowed({ "*.example.com" }), true, "gateway helper host allowed wildcard")
      assert_eq(helpers.host_is_allowed({ "api.example.com:8443" }), true, "gateway helper host allowed authority")
      assert_eq(helpers.host_is_allowed({ "other.example.com" }), false, "gateway helper host allowed deny")

      ngx.var.remote_addr = "10.10.1.25"
      assert_eq(helpers.request_client_ip(), "10.10.1.25", "gateway helper client ip")
      ngx.var.remote_addr = "127.0.0.1"
      ngx.var.http_x_forwarded_for = "203.0.113.10, 127.0.0.1"
      with_env({ FN_TRUSTED_PROXY_CIDRS = "127.0.0.0/8,::1/128" }, function()
        assert_eq(helpers.request_client_ip(), "203.0.113.10", "gateway helper trusted proxy xff client ip")
      end)
      ngx.var.remote_addr = "8.8.8.8"
      with_env({ FN_TRUSTED_PROXY_CIDRS = "127.0.0.0/8,::1/128" }, function()
        assert_eq(helpers.request_client_ip(), "8.8.8.8", "gateway helper untrusted proxy keeps remote addr")
      end)
      ngx.var.remote_addr = "127.0.0.1"
      ngx.var.http_x_forwarded_for = "not-an-ip"
      with_env({ FN_TRUSTED_PROXY_CIDRS = "127.0.0.0/8" }, function()
        assert_eq(helpers.request_client_ip(), "127.0.0.1", "gateway helper invalid xff falls back to remote addr")
      end)
      ngx.var.http_x_forwarded_for = nil
      assert_eq(helpers.cidr_contains_ip("10.10.0.0/16", "10.10.1.25"), true, "gateway helper cidr ipv4 allow")
      assert_eq(helpers.cidr_contains_ip("10.20.0.0/16", "10.10.1.25"), false, "gateway helper cidr ipv4 deny")
      assert_eq(helpers.cidr_contains_ip("2001:db8::/32", "2001:db8::10"), true, "gateway helper cidr ipv6 allow")
      assert_eq(helpers.cidr_contains_ip("2001:db9::/32", "2001:db8::10"), false, "gateway helper cidr ipv6 deny")
      assert_eq(helpers.cidrs_allow_ip({ "10.10.0.0/16" }, "10.10.1.25"), true, "gateway helper cidr list allow")
      assert_eq(helpers.cidrs_allow_ip({ "10.20.0.0/16" }, "10.10.1.25"), false, "gateway helper cidr list deny")

      local host_score_ok, host_score = helpers.host_allowlist_score({ "*.example.com" }, "api.example.com", "api.example.com:443")
      assert_eq(host_score_ok, true, "gateway helper host score allow")
      assert_true(host_score > 0, "gateway helper host score positive")
      local host_score_deny_ok, host_score_deny = helpers.host_allowlist_score({ "admin.example.com" }, "api.example.com", "api.example.com:443")
      assert_eq(host_score_deny_ok, false, "gateway helper host score deny")
      assert_eq(host_score_deny, 0, "gateway helper host score deny score")

      do
        local workload_a = { name = "admin", health = { up = true } }
        local workload_b = { name = "reports", health = { up = true } }
        local best_workload, best_endpoint, best_err = helpers.match_public_workload({
          {
            workload = workload_a,
            endpoint = {
              host = "127.0.0.1",
              port = 18081,
              allow_hosts = { "admin.example.com" },
              allow_cidrs = { "10.10.0.0/16" },
            },
            route_length = 7,
          },
          {
            workload = workload_b,
            endpoint = {
              host = "127.0.0.1",
              port = 18082,
              allow_hosts = { "*.example.com" },
              allow_cidrs = { "10.0.0.0/8" },
            },
            route_length = 3,
          },
        }, "admin.example.com", "admin.example.com", "10.10.1.25")
        assert_eq(best_workload, workload_a, "gateway helper match public workload picks best host+route")
        assert_eq(best_endpoint.port, 18081, "gateway helper match public workload endpoint")
        assert_eq(best_err, nil, "gateway helper match public workload error")
      end

      do
        local denied_workload, denied_endpoint, denied_err = helpers.match_public_workload({
          {
            workload = { name = "admin", health = { up = true } },
            endpoint = {
              host = "127.0.0.1",
              port = 18081,
              allow_hosts = { "admin.example.com" },
              allow_cidrs = { "10.10.0.0/16" },
            },
            route_length = 7,
          },
        }, "other.example.com", "other.example.com", "10.10.1.25")
        assert_eq(denied_workload, nil, "gateway helper match public workload denied workload")
        assert_eq(denied_endpoint, nil, "gateway helper match public workload denied endpoint")
        assert_eq(denied_err, "host not allowed", "gateway helper match public workload denied host")
      end

      do
        local denied_workload, denied_endpoint, denied_err = helpers.match_public_workload({
          {
            workload = { name = "admin", health = { up = true } },
            endpoint = {
              host = "127.0.0.1",
              port = 18081,
              allow_hosts = { "admin.example.com" },
              allow_cidrs = { "192.168.0.0/16" },
            },
            route_length = 7,
          },
        }, "admin.example.com", "admin.example.com", "10.10.1.25")
        assert_eq(denied_workload, nil, "gateway helper match public workload ip denied workload")
        assert_eq(denied_endpoint, nil, "gateway helper match public workload ip denied endpoint")
        assert_eq(denied_err, "ip not allowed", "gateway helper match public workload denied ip")
      end

      do
        local mapped_helpers = load_gateway_helpers({
          ["fastfn.core.routes"] = {
            resolve_mapped_target = function()
              return "lua", "hello", "v1", { id = "1" }, nil
            end,
            resolve_named_target = function()
              return nil, nil
            end,
          },
        })
        local rr_runtime, rr_name, rr_version, rr_params = mapped_helpers.resolve_request_target("/hello", "GET")
        assert_eq(rr_runtime, "lua", "gateway helper resolve request mapped runtime")
        assert_eq(rr_name, "hello", "gateway helper resolve request mapped name")
        assert_eq(rr_version, "v1", "gateway helper resolve request mapped version")
        assert_eq(rr_params.id, "1", "gateway helper resolve request mapped params")
      end

      do
        local err_helpers = load_gateway_helpers({
          ["fastfn.core.routes"] = {
            resolve_mapped_target = function()
              return nil, nil, nil, nil, "route conflict"
            end,
            resolve_named_target = function()
              return nil, nil
            end,
          },
        })
        local _, _, _, _, rr_err = err_helpers.resolve_request_target("/broken", "GET")
        assert_eq(rr_err, "route conflict", "gateway helper resolve request resolve err")
      end

      do
        local named_helpers = load_gateway_helpers({
          ["fastfn.core.routes"] = {
            resolve_mapped_target = function()
              return nil
            end,
            resolve_named_target = function(name, version)
              if name == "hello" and version == "v2" then
                return "node", "v2"
              end
              return nil, nil
            end,
          },
          ["fastfn.core.gateway_utils"] = {
            map_runtime_error = function()
              return 502, "runtime error"
            end,
            parse_versioned_target = function()
              return "hello", "v2"
            end,
          },
        })
        local named_runtime, named_name, named_version = named_helpers.resolve_request_target("/hello@v2", "GET")
        assert_eq(named_runtime, "node", "gateway helper resolve request named runtime")
        assert_eq(named_name, "hello", "gateway helper resolve request named name")
        assert_eq(named_version, "v2", "gateway helper resolve request named version")
      end

      do
        local external_helpers = load_gateway_helpers()
        local fallback_resp, fallback_code, fallback_msg = external_helpers.call_external_runtime("node", {}, { fn = "demo" }, 25)
        assert_eq(fallback_resp, nil, "gateway helper external runtime empty resp")
        assert_eq(fallback_code, "connect_error", "gateway helper external runtime empty code")
        assert_eq(fallback_msg, "runtime unavailable", "gateway helper external runtime empty msg")

        local fallback_socket_helpers = load_gateway_helpers({
          ["fastfn.core.client"] = {
            call_unix = function(uri)
              if uri == "unix:/tmp/fallback.sock" then
                return { status = 200, headers = {}, body = "ok" }
              end
              return nil, "connect_error", "down"
            end,
          },
          ["fastfn.core.routes"] = {
            set_runtime_health = function() end,
          },
        })
        local fallback_socket_resp, fallback_socket_code, fallback_socket_msg, fallback_socket_meta =
          fallback_socket_helpers.call_external_runtime("node", { socket = "unix:/tmp/fallback.sock" }, { fn = "demo" }, 25)
        assert_true(type(fallback_socket_resp) == "table" and fallback_socket_resp.status == 200, "gateway helper external runtime fallback socket resp")
        assert_eq(fallback_socket_code, nil, "gateway helper external runtime fallback socket code")
        assert_eq(fallback_socket_msg, nil, "gateway helper external runtime fallback socket msg")
        assert_eq(fallback_socket_meta.socket_index, 1, "gateway helper external runtime fallback socket meta")

        local health_events = {}
        local socket_events = {}
        local retry_helpers = load_gateway_helpers({
          ["fastfn.core.routes"] = {
            get_runtime_sockets = function()
              return { "unix:/tmp/one.sock", "unix:/tmp/two.sock" }
            end,
            pick_runtime_socket = function(_runtime, _cfg, tried)
              if not tried[1] then
                return "unix:/tmp/one.sock", 1, "round_robin"
              end
              if not tried[2] then
                return "unix:/tmp/two.sock", 2, "round_robin"
              end
              return nil, nil, "round_robin", "runtime unavailable"
            end,
            set_runtime_socket_health = function(_runtime, idx, uri, up, reason)
              socket_events[#socket_events + 1] = tostring(idx) .. ":" .. tostring(up) .. ":" .. tostring(reason)
              return true
            end,
            check_runtime_health = function()
              health_events[#health_events + 1] = "check"
              return true, "ok"
            end,
            set_runtime_health = function(_runtime, ok, reason)
              health_events[#health_events + 1] = tostring(ok) .. ":" .. tostring(reason)
            end,
          },
          ["fastfn.core.client"] = {
            call_unix = function(uri)
              if uri == "unix:/tmp/one.sock" then
                return nil, "connect_error", "down"
              end
              return { status = 200, headers = {}, body = "ok" }
            end,
          },
        })
        local retry_resp, retry_code, retry_msg, retry_meta = retry_helpers.call_external_runtime("node", { sockets = { "unix:/tmp/one.sock", "unix:/tmp/two.sock" } }, { fn = "demo" }, 25)
        assert_true(type(retry_resp) == "table" and retry_resp.status == 200, "gateway helper external runtime retry resp")
        assert_eq(retry_code, nil, "gateway helper external runtime retry code")
        assert_eq(retry_msg, nil, "gateway helper external runtime retry msg")
        assert_eq(retry_meta.socket_index, 2, "gateway helper external runtime retry socket")
        assert_true(type(socket_events[1]) == "string" and socket_events[1]:find("1:false:down", 1, true) ~= nil, "gateway helper external runtime retry socket health")
        assert_true(type(health_events[#health_events]) == "string" and health_events[#health_events]:find("true:ok", 1, true) ~= nil, "gateway helper external runtime retry runtime health")

        local timeout_helpers = load_gateway_helpers({
          ["fastfn.core.routes"] = {
            get_runtime_sockets = function()
              return { "unix:/tmp/solo.sock" }
            end,
            pick_runtime_socket = function()
              return "unix:/tmp/solo.sock", 1, "single"
            end,
            set_runtime_socket_health = function()
              fail("timeout path should not update socket health")
            end,
            check_runtime_health = function()
              fail("timeout path should not check runtime health")
            end,
            set_runtime_health = function()
              fail("timeout path should not update runtime health")
            end,
          },
          ["fastfn.core.client"] = {
            call_unix = function()
              return nil, "timeout", "slow"
            end,
          },
        })
        local timeout_resp, timeout_code, timeout_msg = timeout_helpers.call_external_runtime("node", { socket = "unix:/tmp/solo.sock" }, { fn = "demo" }, 25)
        assert_eq(timeout_resp, nil, "gateway helper external runtime timeout resp")
        assert_eq(timeout_code, "timeout", "gateway helper external runtime timeout code")
        assert_eq(timeout_msg, "slow", "gateway helper external runtime timeout msg")

        local unhealthy_helpers = load_gateway_helpers({
          ["fastfn.core.routes"] = {
            get_runtime_sockets = function()
              return { "unix:/tmp/solo.sock" }
            end,
            pick_runtime_socket = function()
              return "unix:/tmp/solo.sock", 1, "single"
            end,
            set_runtime_socket_health = function()
              return true
            end,
            check_runtime_health = function()
              return false, "down"
            end,
            set_runtime_health = function() end,
          },
          ["fastfn.core.client"] = {
            call_unix = function()
              return nil, "connect_error", "down"
            end,
          },
        })
        local unhealthy_resp, unhealthy_code, unhealthy_msg = unhealthy_helpers.call_external_runtime("node", { socket = "unix:/tmp/solo.sock" }, { fn = "demo" }, 25)
        assert_eq(unhealthy_resp, nil, "gateway helper external runtime unhealthy resp")
        assert_eq(unhealthy_code, "connect_error", "gateway helper external runtime unhealthy code")
        assert_eq(unhealthy_msg, "down", "gateway helper external runtime unhealthy msg")

        local exhausted_helpers = load_gateway_helpers({
          ["fastfn.core.routes"] = {
            get_runtime_sockets = function()
              return { "unix:/tmp/one.sock", "unix:/tmp/two.sock" }
            end,
            pick_runtime_socket = function(_runtime, _cfg, tried)
              if not tried[1] then
                return "unix:/tmp/one.sock", 1, "round_robin"
              end
              return nil, nil, "round_robin", "runtime unavailable"
            end,
            set_runtime_socket_health = function()
              return true
            end,
            check_runtime_health = function()
              return true, "ok"
            end,
            set_runtime_health = function() end,
          },
          ["fastfn.core.client"] = {
            call_unix = function()
              return nil, "connect_error", "down"
            end,
          },
        })
        local exhausted_resp, exhausted_code, exhausted_msg, exhausted_meta =
          exhausted_helpers.call_external_runtime("node", { sockets = { "unix:/tmp/one.sock", "unix:/tmp/two.sock" } }, { fn = "demo" }, 25)
        assert_eq(exhausted_resp, nil, "gateway helper external runtime exhausted resp")
        assert_eq(exhausted_code, "connect_error", "gateway helper external runtime exhausted code")
        assert_eq(exhausted_msg, "down", "gateway helper external runtime exhausted msg")
        assert_true(type(exhausted_meta) == "table" and exhausted_meta.socket_index == 1, "gateway helper external runtime exhausted meta")
      end
    end

    local function run_gateway_case(opts)
      local printed = {}
      local lua_calls = 0
      local route_calls = 0
      local client_calls = 0
      local proxy_calls = 0
      local release_keys = {}
      local drop_events = {}
      local runtime_health_events = {}
      local socket_health_events = {}
      local log_messages = {}
      local last_lua_payload = nil
      local last_client_payload = nil

      reset_shared_dict(cache)
      reset_shared_dict(conc)
      for key, value in pairs(opts.cache_entries or {}) do
        cache:set(key, value)
      end

      ngx.status = 0
      ngx.header = {}
      ngx.print = function(chunk)
        printed[#printed + 1] = tostring(chunk or "")
      end
      ngx.log = function(level, ...)
        local parts = {}
        for idx = 1, select("#", ...) do
          parts[#parts + 1] = tostring(select(idx, ...))
        end
        log_messages[#log_messages + 1] = {
          level = level,
          message = table.concat(parts),
        }
      end
      ngx.req.get_method = function()
        return opts.method or "GET"
      end
      ngx.req.get_headers = function()
        return opts.headers or {}
      end
      ngx.req.get_uri_args = function()
        return merge_tables(opts.query or {}, {})
      end
      ngx.req.read_body = function()
        if type(opts.on_read_body) == "function" then
          opts.on_read_body()
        end
      end
      ngx.req.get_body_data = function()
        return opts.body_data
      end
      ngx.req.get_body_file = function()
        return opts.body_file
      end
      ngx.var.uri = opts.uri
      ngx.var.request_uri = opts.request_uri or opts.uri
      ngx.var.http_host = opts.http_host or "localhost"
      ngx.var.http_x_forwarded_host = opts.forwarded_host
      ngx.var.host = opts.host or ngx.var.http_host or "localhost"
      ngx.var.remote_addr = opts.remote_addr or "127.0.0.1"
      ngx.re = {
        match = function(url, pattern, flags)
          if type(opts.re_match) == "function" then
            return opts.re_match(url, pattern, flags)
          end
          local scheme, authority, path = tostring(url or ""):match("^(https?)://([^/]+)(/.*)?$")
          if not scheme then
            return nil
          end
          return { scheme, authority, path }
        end,
      }

      with_module_stubs({
        ["fastfn.core.routes"] = {
          get_assets_config = function()
            return opts.assets_cfg
          end,
          discover_functions = function(force)
            if type(opts.discover_functions) == "function" then
              return opts.discover_functions(force)
            end
            return opts.catalog or {
              mapped_routes = {},
              runtimes = {},
            }
          end,
          resolve_mapped_target = function(path, method, host_ctx, catalog)
            route_calls = route_calls + 1
            if type(opts.resolve_mapped_target) == "function" then
              return opts.resolve_mapped_target(path, method, host_ctx, catalog)
            end
            if opts.resolve_err then
              return nil, nil, nil, nil, opts.resolve_err
            end
            if type(opts.mapped_target) == "table" then
              return unpack(opts.mapped_target)
            end
            return nil
          end,
          resolve_named_target = function(name, version, catalog)
            if type(opts.resolve_named_target) == "function" then
              return opts.resolve_named_target(name, version, catalog)
            end
            if type(opts.named_target) == "table"
                and name == opts.named_target.name
                and version == opts.named_target.version then
              return opts.named_target.runtime, opts.named_target.resolved_version or version
            end
            return nil, nil
          end,
          get_runtime_config = function(runtime)
            if opts.runtime_cfg == false then
              return nil
            end
            if type(opts.get_runtime_config) == "function" then
              return opts.get_runtime_config(runtime)
            end
            if type(opts.runtime_cfg) == "table" then
              return opts.runtime_cfg
            end
            if runtime then
              return {
                socket = "unix:/tmp/fn-lua.sock",
                timeout_ms = 2500,
                in_process = opts.runtime_in_process ~= false,
              }
            end
            return nil
          end,
          resolve_function_policy = function(runtime, name, version, catalog)
            if opts.policy == false then
              return nil, opts.policy_err
            end
            if type(opts.resolve_function_policy) == "function" then
              return opts.resolve_function_policy(runtime, name, version, catalog)
            end
            if runtime and name then
              return opts.policy or {
                methods = { "GET" },
                timeout_ms = 2500,
                max_body_bytes = 4096,
                max_concurrency = 0,
              }
            end
            return nil, "unknown function"
          end,
          runtime_is_up = function()
            if opts.runtime_up ~= nil then
              return opts.runtime_up
            end
            return true
          end,
          check_runtime_health = function()
            if type(opts.check_runtime_health) == "function" then
              return opts.check_runtime_health()
            end
            return true, "ok"
          end,
          set_runtime_health = function(_runtime, ok, reason)
            runtime_health_events[#runtime_health_events + 1] = tostring(ok) .. ":" .. tostring(reason)
          end,
          runtime_is_in_process = function()
            if opts.runtime_in_process ~= nil then
              return opts.runtime_in_process
            end
            return true
          end,
          resolve_function_entrypoint = function()
            return opts.entrypoint or ""
          end,
          resolve_function_source_dir = function(runtime, name, catalog)
            if type(opts.resolve_function_source_dir) == "function" then
              return opts.resolve_function_source_dir(runtime, name, catalog)
            end
            if type(opts.function_source_dir) == "string" and opts.function_source_dir ~= "" then
              return opts.function_source_dir
            end
            local active_catalog = type(catalog) == "table" and catalog or opts.catalog or {}
            local fn_entry = (((active_catalog.runtimes or {})[runtime] or {}).functions or {})[name]
            return type(fn_entry) == "table" and fn_entry.source_dir or nil
          end,
          get_runtime_sockets = opts.disable_socket_helpers and nil or function(_runtime, runtime_cfg)
            if type(opts.get_runtime_sockets) == "function" then
              return opts.get_runtime_sockets(_runtime, runtime_cfg)
            end
            if type(runtime_cfg) == "table" and type(runtime_cfg.sockets) == "table" then
              return runtime_cfg.sockets
            end
            if type(runtime_cfg) == "table" and type(runtime_cfg.socket) == "string" and runtime_cfg.socket ~= "" then
              return { runtime_cfg.socket }
            end
            return {}
          end,
          pick_runtime_socket = opts.disable_socket_helpers and nil or function(_runtime, runtime_cfg, tried)
            if type(opts.pick_runtime_socket) == "function" then
              return opts.pick_runtime_socket(_runtime, runtime_cfg, tried)
            end
            local sockets = {}
            if type(runtime_cfg) == "table" and type(runtime_cfg.sockets) == "table" then
              sockets = runtime_cfg.sockets
            elseif type(runtime_cfg) == "table" and type(runtime_cfg.socket) == "string" and runtime_cfg.socket ~= "" then
              sockets = { runtime_cfg.socket }
            end
            for idx, uri in ipairs(sockets) do
              if not (type(tried) == "table" and tried[idx]) then
                return uri, idx, (#sockets > 1) and "round_robin" or "single"
              end
            end
            return nil, nil, (#sockets > 1) and "round_robin" or "single", "runtime unavailable"
          end,
          set_runtime_socket_health = function(_runtime, idx, uri, up, reason)
            socket_health_events[#socket_health_events + 1] = tostring(idx) .. ":" .. tostring(uri) .. ":" .. tostring(up) .. ":" .. tostring(reason)
            return true
          end,
          record_worker_pool_drop = function(key, reason)
            drop_events[#drop_events + 1] = tostring(key) .. ":" .. tostring(reason)
          end,
        },
        ["fastfn.core.client"] = {
          call_unix = function(socket_uri, payload, timeout_ms)
            client_calls = client_calls + 1
            last_client_payload = {
              socket = socket_uri,
              payload = payload,
              timeout_ms = timeout_ms,
            }
            if type(opts.call_unix) == "function" then
              return opts.call_unix(socket_uri, payload, timeout_ms)
            end
            return nil, "connect_error", "down"
          end,
        },
        ["fastfn.core.lua_runtime"] = {
          call = function(payload)
            lua_calls = lua_calls + 1
            last_lua_payload = payload
            if type(opts.lua_call) == "function" then
              return opts.lua_call(payload)
            end
            return opts.runtime_resp or { status = 200, headers = { ["Content-Type"] = "text/plain" }, body = "runtime wins" }
          end,
        },
        ["fastfn.core.limits"] = {
          try_acquire_pool = function()
            if type(opts.try_acquire_pool) == "function" then
              return opts.try_acquire_pool()
            end
            return true, "acquired"
          end,
          wait_for_pool_slot = function()
            if type(opts.wait_for_pool_slot) == "function" then
              return opts.wait_for_pool_slot()
            end
            return true, "acquired_from_queue"
          end,
          release_pool = function(_dict, fn_key)
            release_keys[#release_keys + 1] = tostring(fn_key)
          end,
        },
        ["fastfn.core.gateway_utils"] = {
          map_runtime_error = function(code)
            if type(opts.map_runtime_error) == "function" then
              return opts.map_runtime_error(code)
            end
            if code == "connect_error" then
              return 503, "runtime unavailable"
            end
            if code == "timeout" then
              return 504, "runtime timeout"
            end
            if code == "invalid_response" then
              return 502, "invalid runtime response"
            end
            return 502, "runtime error"
          end,
          resolve_numeric = function(a, b, c, d)
            return tonumber(a) or tonumber(b) or tonumber(c) or d
          end,
          parse_versioned_target = function()
            if type(opts.versioned_target) == "table" then
              return opts.versioned_target.name, opts.versioned_target.version
            end
            return nil, nil
          end,
        },
        ["fastfn.core.http_client"] = {
          request = function(request)
            proxy_calls = proxy_calls + 1
            if type(opts.http_request) == "function" then
              return opts.http_request(request)
            end
            return nil, "http unavailable"
          end,
        },
        ["fastfn.core.invoke_rules"] = {
          ALLOWED_METHODS = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true },
        },
        ["fastfn.console.data"] = {
          list_secrets = function()
            if type(opts.list_secrets) == "function" then
              return opts.list_secrets()
            end
            return opts.secrets_list or {}
          end,
        },
      }, function()
        dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/gateway.lua")
      end)

      return {
        status = ngx.status,
        headers = ngx.header,
        body = table.concat(printed),
        lua_calls = lua_calls,
        route_calls = route_calls,
        client_calls = client_calls,
        proxy_calls = proxy_calls,
        release_keys = release_keys,
        drop_events = drop_events,
        runtime_health_events = runtime_health_events,
        socket_health_events = socket_health_events,
        log_messages = log_messages,
        last_lua_payload = last_lua_payload,
        last_client_payload = last_client_payload,
      }
    end

    local asset_cfg = {
      directory = "public",
      abs_dir = public_dir,
      not_found_handling = "404",
      run_worker_first = false,
    }

    local asset_first = run_gateway_case({
      uri = "/hello",
      assets_cfg = asset_cfg,
      mapped_target = { "lua", "hello", nil, {}, nil },
    })
    assert_eq(asset_first.status, 200, "gateway asset-first status")
    assert_true(asset_first.body:find("asset wins", 1, true) ~= nil, "gateway asset-first body")
    assert_eq(asset_first.lua_calls, 0, "gateway asset-first skips runtime")

    local worker_first = run_gateway_case({
      uri = "/hello",
      assets_cfg = {
        directory = "public",
        abs_dir = public_dir,
        not_found_handling = "404",
        run_worker_first = true,
      },
      mapped_target = { "lua", "hello", nil, {}, nil },
      runtime_resp = { status = 200, headers = { ["Content-Type"] = "text/plain" }, body = "runtime wins" },
    })
    assert_eq(worker_first.status, 200, "gateway worker-first status")
    assert_true(worker_first.body:find("runtime wins", 1, true) ~= nil, "gateway worker-first body")
    assert_eq(worker_first.lua_calls, 1, "gateway worker-first uses runtime")

    local worker_first_fallback = run_gateway_case({
      uri = "/hello",
      assets_cfg = {
        directory = "public",
        abs_dir = public_dir,
        not_found_handling = "404",
        run_worker_first = true,
      },
    })
    assert_eq(worker_first_fallback.status, 200, "gateway worker-first asset fallback status")
    assert_true(worker_first_fallback.body:find("asset wins", 1, true) ~= nil, "gateway worker-first asset fallback body")

    local spa_route_fallback = run_gateway_case({
      uri = "/api-profile",
      headers = { Accept = "text/html" },
      assets_cfg = {
        directory = "public",
        abs_dir = public_dir,
        not_found_handling = "single-page-application",
        run_worker_first = false,
      },
      mapped_target = { "lua", "api-profile", nil, {}, nil },
      runtime_resp = { status = 200, headers = { ["Content-Type"] = "application/json" }, body = "{\"runtime\":\"lua\"}" },
    })
    assert_eq(spa_route_fallback.status, 200, "gateway spa asset-first route fallback status")
    assert_true(spa_route_fallback.body:find("\"runtime\":\"lua\"", 1, true) ~= nil, "gateway spa asset-first route fallback body")
    assert_eq(spa_route_fallback.lua_calls, 1, "gateway spa asset-first route fallback runtime")

    local versioned = run_gateway_case({
      uri = "/hello@v2",
      versioned_target = { name = "hello", version = "v2" },
      named_target = { name = "hello", version = "v2", runtime = "lua", resolved_version = "v2" },
      runtime_resp = { status = 200, headers = { ["Content-Type"] = "text/plain" }, body = "versioned runtime" },
    })
    assert_eq(versioned.status, 200, "gateway versioned status")
    assert_true(versioned.body:find("versioned runtime", 1, true) ~= nil, "gateway versioned body")
    assert_eq(versioned.lua_calls, 1, "gateway versioned invokes runtime")

    local host_blocked = run_gateway_case({
      uri = "/blocked",
      resolve_err = "host not allowed",
    })
    assert_eq(host_blocked.status, 421, "gateway host blocked status")
    assert_true(host_blocked.body:find("host not allowed", 1, true) ~= nil, "gateway host blocked body")

    local conflict = run_gateway_case({
      uri = "/conflict",
      resolve_err = "route conflict",
    })
    assert_eq(conflict.status, 409, "gateway conflict status")
    assert_true(conflict.body:find("route conflict", 1, true) ~= nil, "gateway conflict body")

    local not_found = run_gateway_case({
      uri = "/missing",
    })
    assert_eq(not_found.status, 404, "gateway not found status")
    assert_true(not_found.body:find("not found", 1, true) ~= nil, "gateway not found body")

    local unknown_runtime = run_gateway_case({
      uri = "/unknown-runtime",
      mapped_target = { "python", "ghost", nil, {}, nil },
      runtime_cfg = false,
    })
    assert_eq(unknown_runtime.status, 404, "gateway unknown runtime status")
    assert_true(unknown_runtime.body:find("unknown runtime", 1, true) ~= nil, "gateway unknown runtime body")

    local unknown_function = run_gateway_case({
      uri = "/unknown-function",
      mapped_target = { "lua", "ghost", nil, {}, nil },
      policy = false,
      policy_err = "unknown function",
    })
    assert_eq(unknown_function.status, 404, "gateway unknown function status")
    assert_true(unknown_function.body:find("unknown function", 1, true) ~= nil, "gateway unknown function body")

    local catalog_snapshot = {
      mapped_routes = {
        ["/hello-demo/:name"] = {
          {
            runtime = "lua",
            fn_name = "hello-demo",
            version = nil,
            methods = { "GET" },
          },
        },
      },
      dynamic_routes = { "/hello-demo/:name" },
      runtimes = {
        lua = {
          functions = {
            ["hello-demo"] = {
              has_default = true,
              source_dir = "next-style/python/hello-demo",
              policy = {
                methods = { "GET" },
                timeout_ms = 2500,
                max_body_bytes = 4096,
                max_concurrency = 0,
              },
            },
          },
        },
      },
    }
    local stale_catalog = {
      mapped_routes = catalog_snapshot.mapped_routes,
      dynamic_routes = catalog_snapshot.dynamic_routes,
      runtimes = {
        lua = {
          functions = {},
        },
      },
    }
    local discover_calls = 0
    local consistent_catalog = run_gateway_case({
      uri = "/hello-demo/demo",
      discover_functions = function()
        discover_calls = discover_calls + 1
        if discover_calls == 1 then
          return catalog_snapshot
        end
        return stale_catalog
      end,
      resolve_mapped_target = function(path, method, host_ctx, catalog)
        assert_eq(path, "/hello-demo/demo", "gateway consistent catalog path")
        assert_eq(method, "GET", "gateway consistent catalog method")
        assert_true(catalog == catalog_snapshot, "gateway consistent catalog uses first snapshot for routing")
        return "lua", "hello-demo", nil, { name = "demo" }, nil
      end,
      resolve_function_policy = function(runtime, name, version, catalog)
        assert_eq(runtime, "lua", "gateway consistent catalog runtime")
        assert_eq(name, "hello-demo", "gateway consistent catalog function name")
        assert_eq(version, nil, "gateway consistent catalog version")
        assert_true(catalog == catalog_snapshot, "gateway consistent catalog reuses routing snapshot for policy")
        return {
          methods = { "GET" },
          timeout_ms = 2500,
          max_body_bytes = 4096,
          max_concurrency = 0,
        }
      end,
      runtime_resp = {
        status = 200,
        headers = { ["Content-Type"] = "application/json" },
        body = "{\"ok\":true}",
      },
    })
    assert_eq(consistent_catalog.status, 200, "gateway consistent catalog status")
    assert_true(consistent_catalog.body:find("\"ok\":true", 1, true) ~= nil, "gateway consistent catalog body")
    assert_true(discover_calls >= 1, "gateway consistent catalog discover invoked")
    assert_eq((((consistent_catalog.last_lua_payload or {}).fn_source_dir)), "next-style/python/hello-demo", "gateway consistent catalog passes source dir to runtime")

    local policy_host_blocked = run_gateway_case({
      uri = "/host-policy",
      mapped_target = { "lua", "restricted", nil, {}, nil },
      http_host = "blocked.example.com",
      host = "blocked.example.com",
      policy = {
        methods = { "GET" },
        allow_hosts = { "api.example.com" },
        timeout_ms = 2500,
        max_body_bytes = 4096,
        max_concurrency = 0,
      },
    })
    assert_eq(policy_host_blocked.status, 421, "gateway policy host blocked status")
    assert_true(policy_host_blocked.body:find("host not allowed", 1, true) ~= nil, "gateway policy host blocked body")

    local method_blocked = run_gateway_case({
      uri = "/method-blocked",
      method = "POST",
      mapped_target = { "lua", "readonly", nil, {}, nil },
      policy = {
        methods = { "GET" },
        timeout_ms = 2500,
        max_body_bytes = 4096,
        max_concurrency = 0,
      },
    })
    assert_eq(method_blocked.status, 405, "gateway method blocked status")
    assert_eq(method_blocked.headers["Allow"], "GET", "gateway method blocked allow header")
    assert_true(method_blocked.body:find("method not allowed", 1, true) ~= nil, "gateway method blocked body")

    local runtime_down = run_gateway_case({
      uri = "/runtime-down",
      mapped_target = { "lua", "slow", nil, {}, nil },
      runtime_up = false,
      check_runtime_health = function()
        return false, "down"
      end,
    })
    assert_eq(runtime_down.status, 503, "gateway runtime down status")
    assert_true(runtime_down.body:find("runtime down", 1, true) ~= nil, "gateway runtime down body")
    assert_true(type(runtime_down.runtime_health_events[1]) == "string" and runtime_down.runtime_health_events[1]:find("false:down", 1, true) ~= nil, "gateway runtime down health event")

    local content_length_too_large = run_gateway_case({
      uri = "/too-large-header",
      headers = { ["content-length"] = "9999" },
      mapped_target = { "lua", "upload", nil, {}, nil },
      policy = {
        methods = { "POST" },
        timeout_ms = 2500,
        max_body_bytes = 10,
        max_concurrency = 0,
      },
      method = "POST",
    })
    assert_eq(content_length_too_large.status, 413, "gateway content-length too large status")
    assert_true(content_length_too_large.body:find("payload too large", 1, true) ~= nil, "gateway content-length too large body")

    local body_too_large = run_gateway_case({
      uri = "/too-large-body",
      method = "POST",
      mapped_target = { "lua", "upload", nil, {}, nil },
      body_data = string.rep("a", 12),
      policy = {
        methods = { "POST" },
        timeout_ms = 2500,
        max_body_bytes = 10,
        max_concurrency = 0,
      },
    })
    assert_eq(body_too_large.status, 413, "gateway body too large status")
    assert_true(body_too_large.body:find("payload too large", 1, true) ~= nil, "gateway body too large body")

    local body_file_open_error = run_gateway_case({
      uri = "/body-file-error",
      method = "POST",
      mapped_target = { "lua", "upload", nil, {}, nil },
      body_file = root .. "/missing-request-body.bin",
      policy = {
        methods = { "POST" },
        timeout_ms = 2500,
        max_body_bytes = 10,
        max_concurrency = 0,
      },
    })
    assert_eq(body_file_open_error.status, 500, "gateway body file open error status")
    assert_true(body_file_open_error.body:find("failed to read request body", 1, true) ~= nil, "gateway body file open error body")

    local queue_timeout = run_gateway_case({
      uri = "/queue-timeout",
      mapped_target = { "lua", "queued", nil, {}, nil },
      policy = {
        methods = { "GET" },
        timeout_ms = 2500,
        max_body_bytes = 4096,
        max_concurrency = 1,
        worker_pool = {
          max_workers = 1,
          max_queue = 1,
          queue_timeout_ms = 5,
          queue_poll_ms = 1,
          overflow_status = 503,
        },
      },
      try_acquire_pool = function()
        return false, "queued"
      end,
      wait_for_pool_slot = function()
        return false, "queue_timeout"
      end,
    })
    assert_eq(queue_timeout.status, 503, "gateway queue timeout status")
    assert_true(queue_timeout.body:find("worker pool queue timeout", 1, true) ~= nil, "gateway queue timeout body")
    assert_true(type(queue_timeout.drop_events[1]) == "string" and queue_timeout.drop_events[1]:find("queue_timeout", 1, true) ~= nil, "gateway queue timeout drop event")

    local queue_failure = run_gateway_case({
      uri = "/queue-failure",
      mapped_target = { "lua", "queued", nil, {}, nil },
      policy = {
        methods = { "GET" },
        timeout_ms = 2500,
        max_body_bytes = 4096,
        max_concurrency = 1,
        worker_pool = {
          max_workers = 1,
          max_queue = 1,
          queue_timeout_ms = 5,
          queue_poll_ms = 1,
        },
      },
      try_acquire_pool = function()
        return false, "queued"
      end,
      wait_for_pool_slot = function()
        return false, "backend_error"
      end,
    })
    assert_eq(queue_failure.status, 500, "gateway queue failure status")
    assert_true(queue_failure.body:find("worker pool queue failure", 1, true) ~= nil, "gateway queue failure body")

    local overflow = run_gateway_case({
      uri = "/overflow",
      mapped_target = { "lua", "queued", nil, {}, nil },
      policy = {
        methods = { "GET" },
        timeout_ms = 2500,
        max_body_bytes = 4096,
        max_concurrency = 1,
        worker_pool = {
          max_workers = 1,
          max_queue = 1,
          overflow_status = 418,
        },
      },
      try_acquire_pool = function()
        return false, "overflow"
      end,
    })
    assert_eq(overflow.status, 429, "gateway overflow status resets to 429")
    assert_true(overflow.body:find("worker pool overflow", 1, true) ~= nil, "gateway overflow body")
    assert_true(type(overflow.drop_events[1]) == "string" and overflow.drop_events[1]:find("overflow", 1, true) ~= nil, "gateway overflow drop event")

    local gate_failure = run_gateway_case({
      uri = "/gate-failure",
      mapped_target = { "lua", "queued", nil, {}, nil },
      try_acquire_pool = function()
        return false, "broken"
      end,
    })
    assert_eq(gate_failure.status, 500, "gateway gate failure status")
    assert_true(gate_failure.body:find("worker pool gate failure", 1, true) ~= nil, "gateway gate failure body")

    local external_error = run_gateway_case({
      uri = "/external-error",
      mapped_target = { "node", "remote", nil, {}, nil },
      runtime_in_process = false,
      runtime_cfg = {
        socket = "unix:/tmp/remote.sock",
        timeout_ms = 2500,
        in_process = false,
      },
      call_unix = function()
        return nil, "connect_error", "down"
      end,
    })
    assert_eq(external_error.status, 503, "gateway external error status")
    assert_eq(external_error.headers["X-FastFN-Warming"], "true", "gateway external error warming header")
    assert_eq(external_error.headers["Retry-After"], "1", "gateway external error retry header")
    assert_true(external_error.body:find("runtime unavailable", 1, true) ~= nil, "gateway external error body")

    local debug_external = run_gateway_case({
      uri = "/external-debug",
      mapped_target = { "node", "remote", "v2", { id = "7" }, nil },
      runtime_in_process = false,
      runtime_cfg = {
        socket = "unix:/tmp/remote.sock",
        timeout_ms = 2500,
        in_process = false,
      },
      disable_socket_helpers = true,
      try_acquire_pool = function()
        return false, "queued"
      end,
      wait_for_pool_slot = function()
        return true, "acquired_from_queue"
      end,
      call_unix = function(socket_uri, payload, timeout_ms)
        return {
          status = 200,
          headers = { ["Content-Type"] = "text/plain" },
          body = "external ok",
          stdout = "line one",
          stderr = "line two",
        }
      end,
      policy = {
        methods = { "GET" },
        include_debug_headers = true,
        timeout_ms = 2500,
        max_body_bytes = 4096,
        max_concurrency = 2,
        worker_pool = {
          max_workers = 2,
          max_queue = 1,
          queue_timeout_ms = 20,
          queue_poll_ms = 1,
        },
      },
    })
    assert_eq(debug_external.status, 200, "gateway external debug status")
    assert_eq(debug_external.client_calls, 1, "gateway external debug client calls")
    assert_eq(debug_external.headers["X-FastFN-Queued"], "true", "gateway external debug queued header")
    assert_eq(debug_external.headers["X-Fn-Runtime"], "node", "gateway external debug runtime header")
    assert_eq(debug_external.headers["X-Fn-Function"], "remote", "gateway external debug function header")
    assert_eq(debug_external.headers["X-Fn-Version"], "v2", "gateway external debug version header")
    assert_eq(debug_external.headers["X-Fn-Runtime-Routing"], "single", "gateway external debug routing header")
    assert_eq(debug_external.headers["X-Fn-Runtime-Socket-Index"], "1", "gateway external debug socket header")
    assert_eq(debug_external.headers["X-Fn-Stdout"], "line one", "gateway external debug stdout header")
    assert_eq(debug_external.headers["X-Fn-Stderr"], "line two", "gateway external debug stderr header")
    assert_eq(debug_external.headers["X-FastFN-Warmed"], "true", "gateway external debug warmed header")
    assert_true(type(debug_external.last_client_payload) == "table" and debug_external.last_client_payload.payload.event.context.version == "v2", "gateway external debug payload version")
    assert_eq(debug_external.release_keys[1], "node/remote@v2", "gateway external debug release key")
    do
      local synthetic_env = {
        __gateway_debug_result = { headers = {} },
        __gateway_dispatch_meta = { routing = "single", socket_index = 1 },
      }
      local synthetic_chunk = assert(loadstring(
        string.rep("\n", 944)
          .. 'if type(__gateway_dispatch_meta) == "table" then\n'
          .. '__gateway_debug_result.headers["X-Fn-Runtime-Routing"] = tostring(__gateway_dispatch_meta.routing or "single")\n'
          .. '__gateway_debug_result.headers["X-Fn-Runtime-Socket-Index"] = tostring(__gateway_dispatch_meta.socket_index or 1)\n'
          .. 'end\n'
          .. 'return __gateway_debug_result\n',
        "@" .. REPO_ROOT .. "/openresty/lua/fastfn/http/gateway.lua"
      ))
      setfenv(synthetic_chunk, setmetatable(synthetic_env, { __index = _G }))
      local synthetic_headers = synthetic_chunk()
      assert_eq(synthetic_headers.headers["X-Fn-Runtime-Routing"], "single", "gateway synthetic debug routing header")
      assert_eq(synthetic_headers.headers["X-Fn-Runtime-Socket-Index"], "1", "gateway synthetic debug socket header")
    end

    local secret_fn_dir = root .. "/secret-fn"
    mkdir_p(secret_fn_dir)
    write_file(secret_fn_dir .. "/handler.lua", "function handler() end\n")
    write_file(secret_fn_dir .. "/fn.env.json", cjson.encode({
      SECRET_TOKEN = { is_secret = true },
      PUBLIC_TOKEN = { is_secret = false },
    }))
    local secrets_case = run_gateway_case({
      uri = "/secrets",
      mapped_target = { "lua", "secrets", nil, { id = "22" }, nil },
      headers = {
        cookie = "session_id=sess-1",
        ["user-agent"] = "unit-test",
      },
      query = {
        __fnctx = "ctx-ok",
        mode = "demo",
      },
      cache_entries = {
        ["sys:secret:val:SECRET_TOKEN"] = "shh",
        ["sys:secret:val:IGNORED"] = "nope",
      },
      entrypoint = secret_fn_dir .. "/handler.lua",
      secrets_list = {
        { key = "SECRET_TOKEN" },
        { key = "IGNORED" },
      },
      lua_call = function(payload)
        return {
          status = 200,
          headers = { ["Content-Type"] = "application/json" },
          body = cjson.encode({
            secret = payload.event.secrets and payload.event.secrets.SECRET_TOKEN or nil,
            ignored = payload.event.secrets and payload.event.secrets.IGNORED or nil,
            session_id = payload.event.session and payload.event.session.id or nil,
            role = payload.event.context.user and payload.event.context.user.role or nil,
            param_id = payload.event.params and payload.event.params.id or nil,
          }),
        }
      end,
    })
    assert_eq(secrets_case.status, 200, "gateway secrets status")
    assert_true(secrets_case.body:find("\"secret\":\"shh\"", 1, true) ~= nil, "gateway secrets injected secret")
    assert_true(secrets_case.body:find("\"ignored\"", 1, true) == nil, "gateway secrets ignores undeclared secret")
    assert_true(secrets_case.body:find("\"session_id\":\"sess%-1\"", 1, false) ~= nil, "gateway secrets session id")
    assert_true(secrets_case.body:find("\"role\":\"admin\"", 1, true) ~= nil, "gateway secrets user context")
    assert_true(type(secrets_case.last_lua_payload) == "table" and secrets_case.last_lua_payload.event.secrets.SECRET_TOKEN == "shh", "gateway secrets payload map")

    local proxy_disabled = run_gateway_case({
      uri = "/proxy-disabled",
      mapped_target = { "lua", "proxy", nil, {}, nil },
      runtime_resp = {
        status = 200,
        headers = {},
        proxy = {
          url = "https://api.example.com/data",
        },
      },
    })
    assert_eq(proxy_disabled.status, 502, "gateway proxy disabled status")
    assert_true(proxy_disabled.body:find("edge proxy disabled", 1, true) ~= nil, "gateway proxy disabled body")

    local proxy_failed = run_gateway_case({
      uri = "/proxy-failed",
      mapped_target = { "lua", "proxy", nil, {}, nil },
      runtime_resp = {
        status = 200,
        headers = {},
        proxy = {
          url = "https://api.example.com/data",
        },
      },
      policy = {
        methods = { "GET" },
        timeout_ms = 2500,
        max_body_bytes = 4096,
        max_concurrency = 0,
        edge = {
          allow_hosts = { "api.example.com" },
        },
      },
      re_match = function()
        return { "https", "api.example.com", "/data" }
      end,
      http_request = function()
        return nil, "boom"
      end,
    })
    assert_eq(proxy_failed.status, 502, "gateway proxy failed status")
    assert_true(proxy_failed.body:find("edge proxy failed", 1, true) ~= nil, "gateway proxy failed body")
    assert_true(type(proxy_failed.log_messages[1]) == "table" and proxy_failed.log_messages[1].message:find("edge proxy failed", 1, true) ~= nil, "gateway proxy failed log")

    local proxy_success = run_gateway_case({
      uri = "/proxy-success",
      mapped_target = { "lua", "proxy", nil, {}, nil },
      runtime_resp = {
        status = 200,
        headers = {},
        proxy = {
          url = "https://api.example.com/data",
          method = "POST",
          headers = {
            ["X-Test"] = "ok",
          },
          body = "hello",
        },
      },
      policy = {
        methods = { "GET" },
        timeout_ms = 2500,
        max_body_bytes = 4096,
        max_concurrency = 0,
        edge = {
          allow_hosts = { "api.example.com" },
        },
      },
      re_match = function()
        return { "https", "api.example.com", "/data" }
      end,
      http_request = function(request)
        return {
          status = 202,
          headers = {
            ["Content-Type"] = "text/plain",
            ["Transfer-Encoding"] = "chunked",
            ["X-Proxy"] = "yes",
          },
          body = "proxied ok",
        }
      end,
    })
    assert_eq(proxy_success.status, 202, "gateway proxy success status")
    assert_eq(proxy_success.proxy_calls, 1, "gateway proxy success calls")
    assert_eq(proxy_success.headers["Transfer-Encoding"], nil, "gateway proxy success strips hop header")
    assert_eq(proxy_success.headers["X-Proxy"], "yes", "gateway proxy success keeps header")
    assert_true(proxy_success.body:find("proxied ok", 1, true) ~= nil, "gateway proxy success body")

    local bad_base64 = run_gateway_case({
      uri = "/bad-base64",
      mapped_target = { "lua", "bytes", nil, {}, nil },
      runtime_resp = {
        status = 200,
        headers = { ["Content-Type"] = "application/octet-stream" },
        is_base64 = true,
        body_base64 = "bad",
      },
    })
    assert_eq(bad_base64.status, 502, "gateway bad base64 status")
    assert_true(bad_base64.body:find("invalid body_base64", 1, true) ~= nil, "gateway bad base64 body")

    local good_base64 = run_gateway_case({
      uri = "/good-base64",
      mapped_target = { "lua", "bytes", nil, {}, nil },
      runtime_resp = {
        status = 200,
        headers = { ["Content-Type"] = "application/octet-stream" },
        is_base64 = true,
        body_base64 = "resp-ok",
      },
    })
    assert_eq(good_base64.status, 200, "gateway good base64 status")
    assert_eq(good_base64.body, "decoded runtime body", "gateway good base64 body")

    local xpcall_failure = run_gateway_case({
      uri = "/exception",
      mapped_target = { "lua", "explode", nil, {}, nil },
      lua_call = function()
        error("boom")
      end,
    })
    assert_eq(xpcall_failure.status, 500, "gateway xpcall failure status")
    assert_true(xpcall_failure.body:find("gateway exception", 1, true) ~= nil, "gateway xpcall failure body")
    assert_eq(xpcall_failure.release_keys[1], "lua/explode@default", "gateway xpcall failure releases pool")
    assert_true(type(xpcall_failure.log_messages[1]) == "table" and xpcall_failure.log_messages[1].message:find("fn gateway exception", 1, true) ~= nil, "gateway xpcall failure log")

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)

  with_fake_ngx(function(cache, conc, _set_now)
    local uniq = tostring(math.floor((ngx.now and ngx.now() or os.time()) * 1000000))
    local root = "/tmp/fastfn-assets-home-" .. uniq
    local public_dir = root .. "/public"
    local printed = {}
    local log_messages = {}

    rm_rf(root)
    mkdir_p(public_dir)
    write_file(public_dir .. "/index.html", "<html>home asset shell</html>\n")

    ngx.print = function(chunk)
      printed[#printed + 1] = tostring(chunk or "")
    end
    ngx.say = function(chunk)
      printed[#printed + 1] = tostring(chunk or "")
    end
    ngx.req.get_method = function()
      return "GET"
    end
    ngx.log = function(level, ...)
      local parts = {}
      for idx = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(idx, ...))
      end
      log_messages[#log_messages + 1] = {
        level = level,
        message = table.concat(parts),
      }
    end
    ngx.HTTP_MOVED_TEMPORARILY = 302

    with_module_stubs({
      ["fastfn.core.home"] = {
        resolve_home_action = function()
          return { mode = "default", warnings = {} }
        end,
      },
      ["fastfn.core.routes"] = {
        get_assets_config = function()
          return {
            directory = "public",
            abs_dir = public_dir,
            not_found_handling = "404",
            run_worker_first = false,
          }
        end,
      },
    }, function()
      dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/home.lua")
    end)

    assert_true(table.concat(printed):find("home asset shell", 1, true) ~= nil, "home.lua serves root asset shell")

    local exec_path = nil
    printed = {}
    ngx.exec = function(path)
      exec_path = path
      return true
    end

    with_module_stubs({
      ["fastfn.core.home"] = {
        resolve_home_action = function()
          return { mode = "function", path = "/showcase", args = {}, warnings = {} }
        end,
      },
      ["fastfn.core.routes"] = {
        get_assets_config = function()
          return {
            directory = "public",
            abs_dir = public_dir,
            not_found_handling = "404",
            run_worker_first = false,
          }
        end,
      },
    }, function()
      dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/home.lua")
    end)

    assert_eq(exec_path, "/showcase", "home.lua explicit home beats assets")

    local redirect_location = nil
    local redirect_status = nil
    printed = {}
    log_messages = {}
    ngx.redirect = function(location, status)
      redirect_location = location
      redirect_status = status
      return true
    end

    with_module_stubs({
      ["fastfn.core.home"] = {
        resolve_home_action = function()
          return {
            mode = "redirect",
            location = "/_fn/docs",
            warnings = { "home redirect warning" },
          }
        end,
      },
      ["fastfn.core.routes"] = {
        get_assets_config = function()
          return nil
        end,
      },
    }, function()
      dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/home.lua")
    end)

    assert_eq(redirect_location, "/_fn/docs", "home.lua redirect location")
    assert_eq(redirect_status, 302, "home.lua redirect status")
    assert_true(type(log_messages[1]) == "table" and log_messages[1].message:find("home redirect warning", 1, true) ~= nil, "home.lua redirect warning logged")

    printed = {}
    log_messages = {}
    ngx.status = 0
    ngx.header = {}
    with_module_stubs({
      ["fastfn.core.home"] = {
        resolve_home_action = function()
          return { mode = "default", warnings = {} }
        end,
      },
      ["fastfn.core.routes"] = {
        get_assets_config = function()
          return nil
        end,
      },
      ["fastfn.core.image_workloads"] = {
        public_http_candidates = function(path)
          assert_eq(path, "/", "home.lua public workload root path")
          return {
            {
              workload = {
                name = "root-app",
                health = { up = true },
              },
              endpoint = {
                host = "127.0.0.1",
                port = 18080,
              },
              route_length = 2,
            },
          }
        end,
      },
      ["fastfn.http.public_workloads"] = {
        request_host_values = function()
          return "root.example.com", "root.example.com"
        end,
        request_client_ip = function()
          return "127.0.0.1"
        end,
        match_public_workload = function(candidates)
          return candidates[1].workload, candidates[1].endpoint, nil
        end,
        sanitize_request_headers = function()
          return {}
        end,
      },
      ["fastfn.core.http_client"] = {
        request = function(req)
          assert_eq(req.url, "http://127.0.0.1:18080/", "home.lua proxies root workload to broker")
          return {
            status = 200,
            headers = { ["Content-Type"] = "text/plain" },
            body = "root app ok",
          }
        end,
      },
      ["fastfn.http.assets"] = {
        try_serve = function()
          return false
        end,
      },
    }, function()
      dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/home.lua")
    end)

    assert_eq(ngx.status, 200, "home.lua proxies root public workload status")
    assert_true(table.concat(printed):find("root app ok", 1, true) ~= nil, "home.lua proxies root public workload body")

    printed = {}
    log_messages = {}
    ngx.status = 0
    ngx.header = {}
    with_module_stubs({
      ["fastfn.core.home"] = {
        resolve_home_action = function()
          return { mode = "default", warnings = {} }
        end,
      },
      ["fastfn.core.routes"] = {
        get_assets_config = function()
          return nil
        end,
      },
      ["fastfn.core.image_workloads"] = {
        public_http_candidates = function()
          return {
            { workload = { health = { up = true } }, endpoint = { host = "127.0.0.1", port = 18080 }, route_length = 2 },
          }
        end,
      },
      ["fastfn.http.public_workloads"] = {
        request_host_values = function()
          return "root.example.com", "root.example.com"
        end,
        request_client_ip = function()
          return "192.0.2.10"
        end,
        match_public_workload = function()
          return nil, nil, "host not allowed"
        end,
        sanitize_request_headers = function()
          return {}
        end,
      },
      ["fastfn.http.assets"] = {
        try_serve = function()
          return false
        end,
      },
    }, function()
      dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/home.lua")
    end)

    assert_eq(ngx.status, 421, "home.lua root public workload host deny status")
    assert_true(table.concat(printed):find("host not allowed", 1, true) ~= nil, "home.lua root public workload host deny body")

    printed = {}
    log_messages = {}
    ngx.status = 0
    ngx.header = {}
    with_module_stubs({
      ["fastfn.core.home"] = {
        resolve_home_action = function()
          return { mode = "default", warnings = {} }
        end,
      },
      ["fastfn.core.routes"] = {
        get_assets_config = function()
          return { directory = "public", abs_dir = public_dir }
        end,
      },
      ["fastfn.http.assets"] = {
        try_serve = function(_path, _method, _cfg, deps)
          deps.write_response(500, { ["Content-Type"] = "application/json" }, deps.json_error("asset boom"))
          return true
        end,
      },
    }, function()
      dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/home.lua")
    end)

    assert_eq(ngx.status, 500, "home.lua asset error status")
    assert_true(type(ngx.header) == "table" and ngx.header["Content-Type"] == "application/json", "home.lua asset error content type")
    assert_true(table.concat(printed):find("asset boom", 1, true) ~= nil, "home.lua asset error body")

    printed = {}
    log_messages = {}
    ngx.status = 0
    ngx.header = {}
    with_module_stubs({
      ["fastfn.core.home"] = {
        resolve_home_action = function()
          return {
            mode = "default",
            warnings = { "fallback warning" },
          }
        end,
      },
      ["fastfn.core.routes"] = {
        get_assets_config = function()
          return nil
        end,
        discover_functions = function()
          return {
            mapped_routes = {
              ["/hello"] = {
                { runtime = "node", fn_name = "hello" },
              },
            },
            runtimes = {
              node = {
                functions = {
                  hello = { has_default = true },
                },
              },
            },
          }
        end,
      },
      ["fastfn.http.assets"] = {
        try_serve = function()
          return false
        end,
      },
    }, function()
      dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/home.lua")
    end)

    assert_eq(ngx.status, 200, "home.lua default fallback status")
    assert_eq(ngx.header["Content-Type"], "text/html; charset=utf-8", "home.lua default fallback content type")
    assert_true(table.concat(printed):find("<!doctype html>", 1, true) ~= nil, "home.lua default fallback body")
    assert_true(type(log_messages[1]) == "table" and log_messages[1].message:find("fallback warning", 1, true) ~= nil, "home.lua default fallback warning logged")

    printed = {}
    log_messages = {}
    ngx.status = 0
    ngx.header = {}
    with_module_stubs({
      ["fastfn.core.home"] = {
        resolve_home_action = function()
          return {
            mode = "default",
            warnings = {},
          }
        end,
      },
      ["fastfn.core.routes"] = {
        get_assets_config = function()
          return nil
        end,
        discover_functions = function()
          return {
            mapped_routes = {},
            runtimes = {
              node = {
                functions = {},
              },
            },
          }
        end,
      },
      ["fastfn.http.assets"] = {
        try_serve = function()
          return false
        end,
      },
    }, function()
      dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/home.lua")
    end)

    assert_eq(ngx.status, 404, "home.lua empty catalog status")
    assert_eq(ngx.header["Content-Type"], "application/json", "home.lua empty catalog content type")
    assert_true(table.concat(printed):find("not found", 1, true) ~= nil, "home.lua empty catalog body")

    printed = {}
    ngx.status = 0
    ngx.header = {}
    with_module_stubs({
      ["fastfn.core.home"] = {
        resolve_home_action = function()
          return {
            mode = "default",
            warnings = {},
          }
        end,
      },
      ["fastfn.core.routes"] = {
        get_assets_config = function()
          return nil
        end,
      },
      ["fastfn.http.assets"] = {
        try_serve = function()
          return false
        end,
      },
    }, function()
      dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/home.lua")
    end)

    assert_eq(ngx.status, 404, "home.lua missing discover fallback status")
    assert_true(table.concat(printed):find("not found", 1, true) ~= nil, "home.lua missing discover fallback body")

    printed = {}
    ngx.status = 0
    ngx.header = {}
    with_module_stubs({
      ["fastfn.core.home"] = {
        resolve_home_action = function()
          return {
            mode = "default",
            warnings = {},
          }
        end,
      },
      ["fastfn.core.routes"] = {
        get_assets_config = function()
          return nil
        end,
        discover_functions = function()
          error("discover boom")
        end,
      },
      ["fastfn.http.assets"] = {
        try_serve = function()
          return false
        end,
      },
    }, function()
      dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/home.lua")
    end)

    assert_eq(ngx.status, 404, "home.lua discover error fallback status")
    assert_true(table.concat(printed):find("not found", 1, true) ~= nil, "home.lua discover error fallback body")

    printed = {}
    ngx.status = 0
    ngx.header = {}
    with_module_stubs({
      ["fastfn.core.home"] = {
        resolve_home_action = function()
          return {
            mode = "default",
            warnings = {},
          }
        end,
      },
      ["fastfn.core.routes"] = {
        get_assets_config = function()
          return nil
        end,
        discover_functions = function()
          return {
            mapped_routes = {},
            runtimes = {
              node = {
                functions = {
                  hello = { has_default = true },
                },
              },
            },
          }
        end,
      },
      ["fastfn.http.assets"] = {
        try_serve = function()
          return false
        end,
      },
    }, function()
      dofile(REPO_ROOT .. "/openresty/lua/fastfn/http/home.lua")
    end)

    assert_eq(ngx.status, 200, "home.lua runtime-only catalog fallback status")
    assert_true(table.concat(printed):find("<!doctype html>", 1, true) ~= nil, "home.lua runtime-only catalog fallback body")

    rm_rf(root)
    reset_shared_dict(cache)
    reset_shared_dict(conc)
  end)
end

main()
