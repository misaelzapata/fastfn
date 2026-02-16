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
    now = function()
      return now_value
    end,
    time = function()
      return now_value
    end,
    var = {
      host = "localhost",
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

local function test_gateway_utils()
  local utils = require("fastfn.core.gateway_utils")

  local name, version = utils.parse_legacy_target("/fn/hello")
  assert_eq(name, "hello", "parse name")
  assert_eq(version, nil, "parse nil version")

  local name2, version2 = utils.parse_legacy_target("/fn/hello@v2")
  assert_eq(name2, "hello", "parse versioned name")
  assert_eq(version2, "v2", "parse version")

  local n3 = utils.parse_legacy_target("/bad/path")
  assert_eq(n3, nil, "parse invalid")

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

  assert_true(spec.paths["/fn/hello"] == nil, "legacy default hello path hidden")
  assert_true(spec.paths["/fn/hello@v2"] == nil, "legacy versioned hello path hidden")
  assert_true(spec.paths["/fn/risk-score"] == nil, "legacy risk path hidden")
  assert_true(spec.paths["/fn/php-profile"] == nil, "legacy php path hidden")
  assert_true(spec.paths["/fn/rust-profile"] == nil, "legacy rust path hidden")
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

    local legacy_rt, legacy_ver = routes.resolve_legacy_target("hello", nil)
    assert_eq(legacy_rt, "node", "legacy target uses runtime order")
    assert_eq(legacy_ver, nil, "legacy target version default")

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

    local cfg = {
      functions_root = root,
      socket_base_dir = "/tmp/fastfn",
      runtime_order = { "python", "go" },
      defaults = {
        timeout_ms = 2500,
        max_concurrency = 20,
        max_body_bytes = 1048576,
      },
      runtimes = {
        python = { socket = "unix:/tmp/fastfn/fn-python.sock", timeout_ms = 2500 },
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
        return { functions_root = root, runtimes = { lua = runtime_cfg } }
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

        local missing_runtime, missing_runtime_status, missing_runtime_err = jobs.enqueue({ name = "demo" })
        assert_eq(missing_runtime, nil, "jobs missing runtime response")
        assert_eq(missing_runtime_status, 400, "jobs missing runtime status")
        assert_eq(missing_runtime_err, "runtime is required", "jobs missing runtime error")

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

    rm_rf(root)
  end)
end

local function main()
  test_gateway_utils()
  test_fn_limits()
  test_invoke_rules()
  test_openapi_builder()
  test_ui_state_endpoint_guards()
  test_console_guard_state_snapshot_current_user()
  test_routes_discovery_and_host_routing()
  test_routes_skip_disabled_runtime_file_routes()
  test_routes_nested_project_root_scan_with_file_routes()
  test_routes_force_url_policy_override()
  test_routes_force_url_ignored_for_version_scoped_configs()
  test_routes_force_url_breaks_policy_ties()
  test_routes_force_url_global_env_policy_override()
  test_routes_force_url_global_env_keeps_policy_policy_conflict()
  test_routes_policy_routes_disjoint_allow_hosts()
  test_routes_dynamic_order_is_deterministic_and_specific()
  test_console_data_crud_and_secrets()
  test_core_client_frame_protocol()
  test_core_http_client_request_paths()
  test_assistant_modes_and_providers()
  test_jobs_module_queue_and_result()
  test_scheduler_tick_and_snapshot()
  test_scheduler_cron_and_retry_backoff()
  test_scheduler_persist_state_roundtrip()
  test_watchdog_mock_linux_backend()
  test_lua_runtime_in_process()
  test_watchdog_guardrails()
  dofile(REPO_ROOT .. "/tests/unit/test-console-security.lua")
  print("lua unit tests passed")
end

main()
