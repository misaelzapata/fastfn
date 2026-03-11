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

  assert_true(rules.normalize_route("/api/hello") == "/api/hello", "normalize valid route")
  assert_true(rules.normalize_route("api/hello") == nil, "normalize invalid route")
  assert_true(rules.normalize_route("/_fn/health") == nil, "normalize reserved route")

  local invoke_routes = rules.parse_invoke_routes({ route = "/api/a", routes = { "/api/a", "/api/b" } })
  assert_eq(invoke_routes[1], "/api/a", "invoke routes first")
  assert_eq(invoke_routes[2], "/api/b", "invoke routes second")
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
  assert_true(logs_file ~= nil and logs_file["in"] == "query", "logs file query param")
  assert_true(logs_lines ~= nil and logs_lines["in"] == "query", "logs lines query param")
  assert_true(logs_format ~= nil and logs_format["in"] == "query", "logs format query param")
  assert_eq(logs_file.schema.default, "error", "logs file default")
  assert_eq(logs_lines.schema.default, 200, "logs lines default")
  assert_eq(logs_format.schema.default, "text", "logs format default")

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
  end)
end

local function test_assistant_modes_and_providers()
  local cjson = require("cjson.safe")
  local http_mode = "openai_ok"
  local http_stub = {
    request = function(opts)
      local url = tostring((opts or {}).url or "")
      if url:find("/responses", 1, true) then
        if http_mode == "openai_fail" then
          return { status = 500, body = "{\"error\":\"boom\"}" }
        end
        if http_mode == "openai_no_text" then
          return {
            status = 200,
            body = cjson.encode({
              output = {
                {
                  type = "message",
                  role = "assistant",
                  content = {
                    { type = "input_text", text = "no output_text payload" },
                  },
                },
              },
            }),
          }
        end
        return {
          status = 200,
          body = cjson.encode({
            output = {
              {
                type = "message",
                role = "assistant",
                content = {
                  { type = "output_text", text = "openai-text" },
                },
              },
            },
          }),
        }
      end
      if url:find("/v1/messages", 1, true) then
        if http_mode == "claude_fail" then
          return { status = 500, body = "{\"error\":\"boom\"}" }
        end
        if http_mode == "claude_no_text" then
          return {
            status = 200,
            body = cjson.encode({
              content = {
                { type = "image", source = "none" },
              },
            }),
          }
        end
        return {
          status = 200,
          body = cjson.encode({
            content = {
              { type = "text", text = "claude-text" },
            },
          }),
        }
      end
      return nil, "unknown_url"
    end,
  }

  with_module_stubs({
    ["fastfn.core.http_client"] = http_stub,
  }, function()
    package.loaded["fastfn.core.assistant"] = nil
    local assistant = require("fastfn.core.assistant")

    with_env({
      FN_ASSISTANT_ENABLED = "0",
      FN_ASSISTANT_PROVIDER = "mock",
    }, function()
      local text, err, mode = assistant.generate({ prompt = "hello" })
      assert_eq(text, nil, "assistant disabled text")
      assert_eq(err, "assistant disabled", "assistant disabled err")
      assert_eq(mode, "generate", "assistant disabled mode")
    end)

    with_env({
      FN_ASSISTANT_ENABLED = "1",
      FN_ASSISTANT_PROVIDER = "mock",
    }, function()
      local text, err, mode = assistant.generate({
        runtime = "python",
        name = "demo",
        mode = "auto",
        prompt = "Why this function?",
        current_code = "return { proxy = { upstream = 'x' } }",
        chat_history = {
          { role = "user", text = "first" },
          { role = "assistant", text = "second" },
        },
        test_result = { ok = false, status = 500, latency_ms = 3, route = "/x", error = "boom" },
      })
      assert_eq(err, nil, "assistant mock err")
      assert_eq(mode, "chat", "assistant auto chat mode")
      assert_true(type(text) == "string" and text:find("provider=mock", 1, true) ~= nil, "assistant mock chat text")
    end)

    with_env({
      FN_ASSISTANT_ENABLED = "1",
      FN_ASSISTANT_PROVIDER = "openai",
      OPENAI_API_KEY = false,
    }, function()
      local text, err, mode = assistant.generate({ prompt = "generate sample" })
      assert_eq(text, nil, "assistant openai missing key text")
      assert_true(type(err) == "string" and err:find("OPENAI_API_KEY not set", 1, true) ~= nil, "assistant openai missing key err")
      assert_eq(mode, "generate", "assistant openai generate mode")
    end)

    with_env({
      FN_ASSISTANT_ENABLED = "1",
      FN_ASSISTANT_PROVIDER = "openai",
      OPENAI_API_KEY = "test-key",
    }, function()
      http_mode = "openai_ok"
      local text, err, mode = assistant.generate({
        runtime = "node",
        name = "demo",
        template = "hello-json",
        prompt = "build hello",
      })
      assert_eq(err, nil, "assistant openai err")
      assert_eq(mode, "generate", "assistant openai mode")
      assert_true(type(text) == "string" and text:find("openai-text", 1, true) ~= nil, "assistant openai text")
    end)

    with_env({
      FN_ASSISTANT_ENABLED = "1",
      FN_ASSISTANT_PROVIDER = "openai",
      OPENAI_API_KEY = "test-key",
    }, function()
      http_mode = "openai_fail"
      local text, err, mode = assistant.generate({ prompt = "cause failure" })
      assert_eq(text, nil, "assistant openai fail text")
      assert_eq(mode, "generate", "assistant openai fail mode")
      assert_true(type(err) == "string" and err:find("assistant request failed", 1, true) ~= nil, "assistant openai fail err")
    end)

    with_env({
      FN_ASSISTANT_ENABLED = "1",
      FN_ASSISTANT_PROVIDER = "openai",
      OPENAI_API_KEY = "test-key",
    }, function()
      http_mode = "openai_no_text"
      local text, err = assistant.generate({ prompt = "no text" })
      assert_eq(text, nil, "assistant openai no-text result")
      assert_true(type(err) == "string" and err:find("no text output", 1, true) ~= nil, "assistant openai no-text err")
    end)

    with_env({
      FN_ASSISTANT_ENABLED = "1",
      FN_ASSISTANT_PROVIDER = "anthropic",
      ANTHROPIC_API_KEY = "test-key",
    }, function()
      http_mode = "claude_ok"
      local status = assistant.status()
      assert_eq(status.provider, "claude", "assistant anthropic alias to claude")
      local text, err, mode = assistant.generate({
        mode = "chat",
        prompt = "explain this",
        current_code = "def handler(event): return {'status':200,'body':'ok'}",
      })
      assert_eq(err, nil, "assistant claude err")
      assert_eq(mode, "chat", "assistant claude mode")
      assert_true(type(text) == "string" and text:find("claude-text", 1, true) ~= nil, "assistant claude text")
    end)

    with_env({
      FN_ASSISTANT_ENABLED = "1",
      FN_ASSISTANT_PROVIDER = "claude",
      ANTHROPIC_API_KEY = "test-key",
    }, function()
      http_mode = "claude_fail"
      local text, err = assistant.generate({ prompt = "claude fail" })
      assert_eq(text, nil, "assistant claude fail text")
      assert_true(type(err) == "string" and err:find("assistant request failed", 1, true) ~= nil, "assistant claude fail err")
    end)

    with_env({
      FN_ASSISTANT_ENABLED = "1",
      FN_ASSISTANT_PROVIDER = "claude",
      ANTHROPIC_API_KEY = "test-key",
    }, function()
      http_mode = "claude_no_text"
      local text, err = assistant.generate({ prompt = "claude no text" })
      assert_eq(text, nil, "assistant claude no-text text")
      assert_true(type(err) == "string" and err:find("no text output", 1, true) ~= nil, "assistant claude no-text err")
    end)

    with_env({
      FN_ASSISTANT_ENABLED = "1",
      FN_ASSISTANT_PROVIDER = "auto",
      OPENAI_API_KEY = "test-key",
      ANTHROPIC_API_KEY = false,
    }, function()
      http_mode = "openai_ok"
      local status = assistant.status()
      assert_eq(status.provider, "openai", "assistant auto provider should pick openai when key exists")
    end)

    with_env({
      FN_ASSISTANT_ENABLED = "1",
      FN_ASSISTANT_PROVIDER = "unknown-provider",
    }, function()
      local text, err, mode = assistant.generate({ prompt = "x" })
      assert_eq(text, nil, "assistant unknown provider text")
      assert_eq(err, "unknown assistant provider", "assistant unknown provider err")
      assert_eq(mode, "generate", "assistant unknown provider mode")
    end)
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
      local impossible_next, impossible_next_err = compute_next_cron_ts(1700000000, "0 0 31 2 *", "UTC", false)
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

    local original_jit = _G.jit
    local ok_watchdog, watchdog_err = pcall(function()
      with_module_stubs({
        ["ffi"] = fake_ffi,
        ["bit"] = fake_bit,
      }, function()
        _G.jit = { os = "Linux" }
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
    _G.jit = original_jit
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

    local original_jit = _G.jit
    local original_timer_every = ngx.timer.every
    local original_timer_at = ngx.timer.at
    local ok_case, case_err = pcall(function()
      with_module_stubs({
        ["ffi"] = fake_ffi,
        ["bit"] = fake_bit,
      }, function()
        _G.jit = { os = "Linux" }
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
    _G.jit = original_jit
    ngx.timer.every = original_timer_every
    ngx.timer.at = original_timer_at
    if not ok_case then
      error(case_err)
    end

    assert_true(close_calls >= 2, "watchdog close should run on setup failures")
    assert_true(add_calls >= 1, "watchdog add_watch should run in patched scenarios")
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
    assert_true(type(merge_invoke) == "function", "merge_invoke helper")
    assert_true(type(build_query_string) == "function", "build_query_string helper")
    assert_true(type(merge_unique_routes) == "function", "merge_unique_routes helper")

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

    local reqs = parse_requirements_file("requests==2.0.0\n# comment\nfastapi>=0.1\n")
    assert_true(type(reqs) == "table" and #reqs == 2, "parse_requirements_file count")
    assert_eq(reqs[1], "fastapi", "parse_requirements_file sorted first")
    local cargo_deps = parse_cargo_dependency_names("[dependencies]\nserde = \"1\"\nserde_json = \"1\"\n\n[dev-dependencies]\ninsta = \"1\"\n")
    assert_true(type(cargo_deps) == "table" and #cargo_deps == 2, "parse_cargo_dependency_names count")
    local qs = build_query_string({ b = 2, a = "x", no = { bad = true } })
    assert_eq(qs, "a=x&b=2", "build_query_string sorted and scalar-only")
    local merged = merge_unique_routes({ "/a", "/b" }, { "/b", "/c" })
    assert_true(type(merged) == "table" and #merged == 3, "merge_unique_routes dedupe")

    local bad_create0, bad_create0_err = data.create_function("python", "bad/name", nil, {})
    assert_eq(bad_create0, nil, "create_function invalid name")
    assert_true(type(bad_create0_err) == "string" and bad_create0_err:find("invalid function", 1, true) ~= nil, "create_function invalid name error")

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

    rm_rf(root)
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
      resolve_function_policy = function()
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
  run_test("test_openapi_builder", test_openapi_builder)
  run_test("test_ui_state_endpoint_guards", test_ui_state_endpoint_guards)
  run_test("test_ui_state_endpoint_full_behavior", test_ui_state_endpoint_full_behavior)
  run_test("test_console_guard_state_snapshot_current_user", test_console_guard_state_snapshot_current_user)
  run_test("test_console_guard_enforcement_and_state_overrides", test_console_guard_enforcement_and_state_overrides)
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
  run_test("test_console_data_crud_and_secrets", test_console_data_crud_and_secrets)
  run_test("test_console_data_validation_edges_and_helpers", test_console_data_validation_edges_and_helpers)
  run_test("test_core_client_frame_protocol", test_core_client_frame_protocol)
  run_test("test_core_http_client_request_paths", test_core_http_client_request_paths)
  run_test("test_assistant_modes_and_providers", test_assistant_modes_and_providers)
  run_test("test_jobs_module_queue_and_result", test_jobs_module_queue_and_result)
  run_test("test_jobs_internal_helpers_and_edge_cases", test_jobs_internal_helpers_and_edge_cases)
  run_test("test_scheduler_tick_and_snapshot", test_scheduler_tick_and_snapshot)
  run_test("test_scheduler_cron_and_retry_backoff", test_scheduler_cron_and_retry_backoff)
  run_test("test_scheduler_cron_timezone_and_invalid_timezone", test_scheduler_cron_timezone_and_invalid_timezone)
  run_test("test_scheduler_internal_cron_helpers", test_scheduler_internal_cron_helpers)
  run_test("test_scheduler_persist_state_roundtrip", test_scheduler_persist_state_roundtrip)
  run_test("test_watchdog_mock_linux_backend", test_watchdog_mock_linux_backend)
  run_test("test_watchdog_guardrails", test_watchdog_guardrails)
  run_test("test_watchdog_internal_error_paths", test_watchdog_internal_error_paths)
  run_test("test_lua_runtime_in_process", test_lua_runtime_in_process)
  run_test("test_lua_runtime_print_capture", test_lua_runtime_print_capture)
  run_test("test_lua_runtime_session_passthrough", test_lua_runtime_session_passthrough)
  run_test("test_lua_runtime_os_time_date", test_lua_runtime_os_time_date)
  run_test("test_lua_runtime_params_injection", test_lua_runtime_params_injection)
  run_test("test_console_security", function()
    dofile(REPO_ROOT .. "/tests/unit/test-console-security.lua")
  end)
  print("lua unit tests passed")
end

main()
