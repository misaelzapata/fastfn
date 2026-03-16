#!/usr/bin/env resty

local REPO_ROOT = os.getenv("FASTFN_REPO_ROOT") or "/app"
package.path = REPO_ROOT .. "/openresty/lua/?.lua;" .. REPO_ROOT .. "/openresty/lua/?/init.lua;" .. package.path

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
  io.stderr:write("FAIL: " .. msg .. "\n")
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
  assert_true(rules.normalize_route("/api/%.%./bad") == nil, "normalize rejects literal dot-traversal marker")

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
      root .. "/python/hello/app.py",
      "def handler(event):\n"
        .. "    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n"
    )
    write_file(
      root .. "/python/hello/v2/app.py",
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
      root .. "/node/hello/app.js",
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
    assert_true(catalog.mapped_route_conflicts["/conflict"] == true, "conflict route tracked")

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
      root .. "/node/policyfn/app.js",
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
        root .. "/node/demo/app.js",
        "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n"
      )

      -- Version-scoped config wants to take the same route with force-url. This must not override
      -- an already-mapped URL unless FN_FORCE_URL is enabled globally by the operator.
      write_file(
        root .. "/node/demo/test/app.js",
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

    write_file(root .. "/node/a/app.js", "exports.handler = async () => ({ status: 200, headers: {}, body: '{}' });\n")
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
      root .. "/python/b/app.py",
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
        root .. "/node/policyfn/app.js",
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

      write_file(root .. "/node/a/app.js", "exports.handler = async () => ({ status: 200, headers: {}, body: '{}' });\n")
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
        root .. "/python/b/app.py",
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

    write_file(root .. "/node/a/app.js", "exports.handler = async () => ({ status: 200, headers: {}, body: '{}' });\n")
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
      root .. "/python/b/app.py",
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

        io.popen = function()
          return nil
        end
        local no_dirs = list_dirs_recursive(root)
        assert_true(type(no_dirs) == "table" and #no_dirs == 0, "list_dirs_recursive handles popen failure")
        io.popen = original_io_popen

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
      root .. "/lua/hello/app.lua",
      "local cjson = require('cjson.safe')\n"
        .. "function handler(event)\n"
        .. "  local q = event.query or {}\n"
        .. "  return { status = 200, headers = { ['Content-Type'] = 'application/json' }, body = cjson.encode({ runtime = 'lua', name = q.name or 'World' }) }\n"
        .. "end\n"
    )
    write_file(
      root .. "/lua/raw/app.lua",
      "function handler(_event)\n"
        .. "  return { ok = true, answer = 42 }\n"
        .. "end\n"
    )
    write_file(
      root .. "/lua/envos/app.lua",
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
      root .. "/lua/printfn/app.lua",
      "function handler(event)\n"
        .. "  print('hello from lua')\n"
        .. "  print('line two', 42)\n"
        .. "  return { status = 200, headers = {}, body = 'ok' }\n"
        .. "end\n"
    )
    write_file(
      root .. "/lua/silent/app.lua",
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
      root .. "/lua/sesstest/app.lua",
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
      root .. "/lua/timefn/app.lua",
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
      root .. "/lua/paramfn/app.lua",
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
      write_file(root .. "/lua/envtest/app.lua", "function handler(event) return { status = 200, body = 'ok' } end\n")
      write_file(root .. "/lua/envtest/fn.env.json", "")
      local rf1 = read_function_env(root .. "/lua/envtest/app.lua")
      assert_true(type(rf1) == "table" and next(rf1) == nil, "lua read_function_env empty file")

      write_file(root .. "/lua/envtest/fn.env.json", "{\"TOKEN\":{\"value\":\"abc\"},\"N\":1}\n")
      local rf2 = read_function_env(root .. "/lua/envtest/app.lua")
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
      root .. "/lua/admin/session-demo/app.lua",
      "return function(event) return {status=200,body='ok'} end\n"
    )
    write_file(
      root .. "/python/user/hello/app.py",
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
    assert_true(lua_entry:match("app%.lua$") ~= nil, "lua entrypoint is app.lua, got: " .. tostring(lua_entry))

    local py_entry, py_err = routes.resolve_function_entrypoint("python", "user/hello", nil)
    assert_true(py_entry ~= nil, "python entrypoint resolved: " .. tostring(py_err))
    assert_true(py_entry:match("app%.py$") ~= nil, "python entrypoint is app.py, got: " .. tostring(py_entry))

    -- Accessing the internal file_exists via upvalue chain to verify directly
    local resolve_fn = routes.resolve_function_entrypoint
    local file_exists = get_upvalue(resolve_fn, "file_exists")
    if type(file_exists) == "function" then
      -- file_exists must return true for a real file
      assert_true(file_exists(root .. "/lua/admin/session-demo/app.lua"), "file_exists: regular file")
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
    local m1, parts1, explicit1 = parse_method_and_tokens("post.users.[id]")
    assert_eq(m1, "POST", "parse_method_and_tokens method")
    assert_eq(explicit1, true, "parse_method_and_tokens explicit flag")
    assert_true(type(parts1) == "table" and parts1[1] == "users", "parse_method_and_tokens parts")
    local m2, parts2, explicit2 = parse_method_and_tokens("users.index")
    assert_eq(m2, "GET", "parse_method_and_tokens default method")
    assert_eq(explicit2, false, "parse_method_and_tokens default explicit flag")
    assert_true(type(parts2) == "table" and #parts2 == 2, "parse_method_and_tokens default parts")

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
      root .. "/python/existing/app.py",
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
      assert_eq(default_handler_filename("python"), "app.py", "default_handler_filename python")
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

    local del_fail1, del_fail1_err = data.delete_function_file("python", "files_demo", "app.py", nil)
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
    write_file(root .. "/python/demo/app.py", "def handler(event):\n    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n")
    write_file(root .. "/python/demo/fn.config.json", "{\n  \"invoke\": {\"methods\": [\"GET\"]}\n}\n")
    write_file(root .. "/python/demo/fn.env.json", "{}\n")
    write_file(root .. "/node/demo/app.js", "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n")
    write_file(root .. "/node/demo/fn.config.json", "{\n  \"invoke\": {\"methods\": [\"GET\"]}\n}\n")
    write_file(root .. "/node/demo/npm-shrinkwrap.json", "{}\n")
    write_file(root .. "/node/demo/v1/app.js", "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: '{}' });\n")
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
    write_file(py_dir .. "/v2/app.py", "def handler(event):\n    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n")
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
    local build_env_view = get_upvalue(data.function_detail, "build_env_view")
    local scalar_value = get_upvalue(build_env_view, "scalar_value")

    assert_eq(is_file_target_name(123), false, "is_file_target_name non-string")
    assert_eq(file_target_name_allowed("demo//app.py"), false, "file_target_name_allowed //")
    assert_eq(file_target_name_allowed(123), false, "file_target_name_allowed non-string")
    assert_eq(function_name_allowed(123), false, "function_name_allowed non-string")
    assert_eq(path_is_under(nil, root), false, "path_is_under invalid type")
    assert_eq(path_is_under("", root), false, "path_is_under empty root")

    local old_io = io
    io = { open = old_io.open, popen = function() return nil end }
    assert_eq(is_symlink(root), false, "is_symlink popen fail")
    assert_eq(dir_exists(root), false, "dir_exists popen fail")
    assert_eq(#list_dirs(root), 0, "list_dirs popen fail")
    assert_eq(version_children_count(root), 0, "version_children_count popen fail")
    assert_eq(file_size(root .. "/missing.txt"), 0, "file_size popen fail")
    assert_eq(#list_files_recursive(root, 2), 0, "list_files_recursive popen fail")
    io = old_io

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
    set_upvalue(resolve_function_paths, "detect_app_file", function() return root .. "/python/demo/app.py" end)
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
    os.execute(string.format("ln -sf %q %q", root .. "/python/demo/app.py", root .. "/link.py"))
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
        app_path = root .. "/python/demo/app.py",
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
        app_path = root .. "/python/demo/app.py",
        conf_path = "/tmp/outside-fn.config.json",
        env_path = root .. "/python/demo/fn.env.json",
      }
    end)
    assert_eq(select(1, data.set_function_config("python", "demo", nil, {})), nil, "set_function_config invalid config path branch")
    set_upvalue(data.set_function_config, "resolve_function_paths", prev_resolve_cfg_path)

    local prev_read_cfg = get_upvalue(data.set_function_config, "read_json_file")
    set_upvalue(data.set_function_config, "read_json_file", function() return "bad" end)
    assert_true(data.set_function_config("python", "demo", nil, {}) ~= nil, "set_function_config non-table base")
    set_upvalue(data.set_function_config, "read_json_file", prev_read_cfg)

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
        app_path = root .. "/python/demo/app.py",
        conf_path = root .. "/python/demo/fn.config.json",
        env_path = "/tmp/outside-fn.env.json",
      }
    end)
    assert_eq(select(1, data.set_function_env("python", "demo", nil, {})), nil, "set_function_env invalid env path branch")
    set_upvalue(data.set_function_env, "resolve_function_paths", prev_resolve_env_path)

    local prev_norm_env = get_upvalue(data.set_function_env, "normalize_env_payload")
    set_upvalue(data.set_function_env, "normalize_env_payload", function() return { updates = { GHOST = {} } } end)
    assert_true(data.set_function_env("python", "demo", nil, {}) ~= nil, "set_function_env base delete branch")
    set_upvalue(data.set_function_env, "normalize_env_payload", prev_norm_env)

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
        app_path = root .. "/python/demo/app.py",
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
      local original_os_execute = os.execute
      os.execute = function()
        return 1
      end
      local ensure_dir_ok1, ensure_dir_err1 = ensure_dir("/tmp/fastfn-jobs-mkdir-fail-" .. uniq)
      os.execute = original_os_execute
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

      local original_os_rename = os.rename
      local original_os_remove = os.remove
      io.open = function()
        return {
          write = function() end,
          close = function() end,
        }
      end
      os.rename = function()
        return nil, "rename-fail"
      end
      os.remove = function()
        return true
      end
      local wf_ok1, wf_err1 = write_file_atomic(root .. "/x.tmp2", "abc")
      io.open = original_io_open
      os.rename = original_os_rename
      os.remove = original_os_remove
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

      local prev_write_spec = get_upvalue(jobs.enqueue, "write_spec")
      set_upvalue(jobs.enqueue, "write_spec", function()
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
      set_upvalue(jobs.enqueue, "write_spec", prev_write_spec)

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

    write_file(functions_root .. "/node/hasdefault/app.js", "exports.handler = async () => ({ status: 200, body: 'ok' });\n")
    write_file(functions_root .. "/node/versioned/v1/handler.js", "exports.handler = async () => ({ status: 200, body: 'v1' });\n")
    write_file(functions_root .. "/python/hello/app.py", "def handler(event):\n    return {'status':200,'headers':{},'body':'ok'}\n")
    write_file(functions_root .. "/php/basic/app.php", "<?php echo 'ok';\n")
    write_file(functions_root .. "/lua/echo/app.lua", "return function(_event) return {status=200, body='ok'} end\n")
    write_file(functions_root .. "/rust/exp/app.rs", "fn main() {}\n")
    write_file(functions_root .. "/go/exp/main.go", "package main\nfunc main() {}\n")
    write_file(functions_root .. "/node/aa_force_on/app.js", "exports.handler = async () => ({ status: 200, body: 'force-on' });\n")
    write_file(functions_root .. "/node/ab_force_off/app.js", "exports.handler = async () => ({ status: 200, body: 'force-off' });\n")
    write_file(functions_root .. "/node/ba_force_off/app.js", "exports.handler = async () => ({ status: 200, body: 'replace-old' });\n")
    write_file(functions_root .. "/node/bb_force_on/app.js", "exports.handler = async () => ({ status: 200, body: 'replace-new' });\n")
    write_file(functions_root .. "/manifest-wins.py", "def handler(event):\n    return {'status':200,'headers':{},'body':'wins'}\n")
    write_file(functions_root .. "/node/runtime_manifest/fn.routes.json", cjson.encode({
      routes = {
        ["/runtime-manifest"] = "node/runtime_manifest/app.js",
      },
    }) .. "\n")
    write_file(functions_root .. "/node/runtime_manifest/app.js", "exports.handler = async () => ({ status: 200, body: 'runtime-manifest' });\n")
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
        ["GET /from-manifest"] = "node/hasdefault/app.js",
        ["/from-manifest-default"] = "python/hello/app.py",
        ["/manifest-wins"] = "node/hasdefault/app.js",
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
      local detect_runtime_from_file = get_upvalue(resolve_entry, "detect_runtime_from_file")
      local has_valid_config_entrypoint = get_upvalue(discover_functions, "has_valid_config_entrypoint")
      local file_exists = get_upvalue(resolve_entry, "file_exists")
      local list_files = get_upvalue(resolve_entry, "list_files")
      local is_safe_relative_path = get_upvalue(resolve_entry, "is_safe_relative_path")
      local worker_pool_snapshot = get_upvalue(routes.health_snapshot, "worker_pool_snapshot")
      local read_nonneg_counter = get_upvalue(worker_pool_snapshot, "read_nonneg_counter")
      local warm_state_for_key = get_upvalue(routes.health_snapshot, "warm_state_for_key")
      local hot_reload_enabled = get_upvalue(routes.init, "hot_reload_enabled")
      local hot_reload_watchdog_enabled = get_upvalue(routes.init, "hot_reload_watchdog_enabled")
      local dir_exists = get_upvalue(detect_functions_root, "dir_exists")
      local list_dirs = get_upvalue(load_runtime_config, "list_dirs")
      local has_app_file = get_upvalue(discover_functions, "has_app_file")

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
      assert_true(type(has_app_file) == "function", "has_app_file helper")
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

      assert_eq(should_ignore_file_base("_private"), true, "should_ignore_file_base underscore")
      assert_eq(should_ignore_file_base("demo.spec"), true, "should_ignore_file_base spec")
      assert_eq(should_ignore_file_base("demo"), false, "should_ignore_file_base normal")
      local patch_method, patch_parts, patch_explicit = parse_method_and_tokens("patch.users.[id]")
      assert_eq(patch_method, "PATCH", "parse_method_and_tokens patch")
      assert_eq(patch_explicit, true, "parse_method_and_tokens patch explicit")
      assert_true(type(patch_parts) == "table" and #patch_parts >= 1, "parse_method_and_tokens patch parts")
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
      local root_pattern, root_names = compile_dynamic_route_pattern("/")
      assert_eq(root_pattern, "^/$", "compile_dynamic_route_pattern root")
      assert_true(type(root_names) == "table" and #root_names == 0, "compile_dynamic_route_pattern root names")
      local wild_pattern, wild_names = compile_dynamic_route_pattern("/a/*/*")
      assert_true(type(wild_pattern) == "string" and wild_pattern:find("%(%.%+%)", 1) ~= nil, "compile_dynamic_route_pattern wildcard regex")
      assert_true(type(wild_names) == "table" and #wild_names == 2 and wild_names[1] ~= wild_names[2], "compile_dynamic_route_pattern wildcard unique names")
      local wild3_pattern, wild3_names = compile_dynamic_route_pattern("/a/*/*/*")
      assert_true(type(wild3_pattern) == "string" and type(wild3_names) == "table" and #wild3_names == 3, "compile_dynamic_route_pattern third wildcard")
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
      local prev_io = io
      _G.io = {
        open = prev_io.open,
        popen = function()
          return nil
        end,
      }
      local list_dirs_none = list_dirs(functions_root)
      local list_files_none = list_files(functions_root)
      assert_true(type(list_dirs_none) == "table" and #list_dirs_none == 0, "list_dirs popen nil")
      assert_true(type(list_files_none) == "table" and #list_files_none == 0, "list_files popen nil")
      assert_eq(dir_exists(functions_root), false, "dir_exists popen nil")
      assert_eq(has_app_file(functions_root), false, "has_app_file popen nil")
      _G.io = prev_io

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
      assert_true(fallback_entry ~= nil and fallback_entry:find("custom.js", 1, true) ~= nil, fallback_entry_err or "resolve_function_entrypoint list_files fallback")

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
        local rt1, fn1 = routes.resolve_mapped_target("/from-manifest", "GET", { host = "localhost" })
        assert_eq(rt1, "node", "manifest route runtime")
        assert_eq(fn1, "node/hasdefault/app.js", "manifest route target")
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
      assert_true(manifest_wins_fn == nil or manifest_wins_fn == "node/hasdefault/app.js", "manifest/file route target resolution")

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
          ["/from-runtime-manifest"] = "node/hasdefault/app.js",
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
            { route = nil, runtime = "node", target = "node/hasdefault/app.js", methods = { "GET" } },
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
      assert_eq(select(1, compute_next_cron_ts(10, "* * * * * *", "UTC", false)), nil, "compute_next_cron_ts empty second set")
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
      local no_date_ts, no_date_err = compute_next_cron_ts(10, "* * * * * *", "UTC", false)
      assert_eq(no_date_ts, nil, "compute_next_cron_ts cron_date_fields failure")
      assert_true(type(no_date_err) == "string" and no_date_err:find("bad date fields", 1, true) ~= nil, "compute_next_cron_ts cron_date_fields err")
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

      _G.os = {
        execute = (function()
          local calls = 0
          return function()
            calls = calls + 1
            if calls == 1 then
              return 0 -- ensure_dir
            end
            return 1 -- mv fallback
          end
        end)(),
        rename = function()
          return nil
        end,
        remove = function()
          return true
        end,
        getenv = prev_os.getenv,
        exit = prev_os.exit,
        date = prev_os.date,
        time = prev_os.time,
      }
      local move_fail_ok, move_fail_err = write_file_atomic(state_path, "{\"ok\":false}")
      assert_eq(move_fail_ok, false, "write_file_atomic move fail path")
      assert_true(type(move_fail_err) == "string", "write_file_atomic move fail err")

      _G.os = {
        execute = function()
          return 0
        end,
        rename = function()
          return nil
        end,
        remove = function()
          return true
        end,
        getenv = prev_os.getenv,
        exit = prev_os.exit,
        date = prev_os.date,
        time = prev_os.time,
      }
      local wrote_mv_ok, wrote_mv_err = write_file_atomic(state_path, "{\"ok\":true}")
      assert_eq(wrote_mv_ok, true, wrote_mv_err or "write_file_atomic mv fallback")
      _G.os = prev_os
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
        FN_SCHEDULER_STATE_PATH = state_path,
      }, function()
        local ok_restore_missing, err_restore_missing = restore_persisted_state()
        assert_eq(ok_restore_missing, false, "restore_persisted_state missing file")
        assert_true(type(err_restore_missing) == "string" and err_restore_missing:find("missing", 1, true) ~= nil, "restore missing error")

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
  print("lua unit tests passed")
end

main()
