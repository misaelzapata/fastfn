#!/usr/bin/env resty

package.path = "/app/openresty/lua/?.lua;/app/openresty/lua/?/init.lua;" .. package.path

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

  local spec = openapi.build({
    runtimes = {
      python = {
        functions = {
          hello = { has_default = true, versions = { "v2" }, policy = { methods = { "GET" } }, versions_policy = { v2 = { methods = { "GET" } } } },
          risk_score = { has_default = true, versions = {}, policy = { methods = { "GET", "POST" } }, versions_policy = {} },
        },
      },
      node = {
        functions = {
          hello = { has_default = true, versions = {}, policy = { methods = { "GET" } }, versions_policy = {} },
        },
      },
      php = {
        functions = {
          php_profile = { has_default = true, versions = {}, policy = { methods = { "GET" } }, versions_policy = {} },
        },
      },
      rust = {
        functions = {
          rust_profile = { has_default = true, versions = {}, policy = { methods = { "GET" } }, versions_policy = {} },
        },
      },
    },
    mapped_routes = {
      ["/api/hello"] = { runtime = "python", fn_name = "hello", version = nil, methods = { "GET" } },
      ["/api/hello-v2"] = { runtime = "python", fn_name = "hello", version = "v2", methods = { "GET" } },
    },
  }, {
    server_url = "http://localhost:8080",
    title = "Test API",
    version = "test",
  })

  assert_eq(spec.openapi, "3.1.0", "openapi version")
  assert_eq(spec.info.title, "Test API", "openapi title")
  assert_eq(spec.info.version, "test", "openapi info version")

  assert_true(spec.paths["/fn/hello"] ~= nil, "default hello path")
  assert_true(spec.paths["/fn/hello@v2"] ~= nil, "versioned hello path")
  assert_true(spec.paths["/fn/risk_score"] ~= nil, "risk path")
  assert_true(spec.paths["/fn/php_profile"] ~= nil, "php path")
  assert_true(spec.paths["/fn/rust_profile"] ~= nil, "rust path")
  assert_true(spec.paths["/api/hello"] ~= nil, "mapped route path")
  assert_true(spec.paths["/api/hello-v2"] ~= nil, "mapped version route path")
  assert_true(spec.paths["/_fn/health"] ~= nil, "health path")
  assert_true(spec.paths["/_fn/reload"] ~= nil, "reload path")
  assert_true(spec.paths["/_fn/schedules"] ~= nil, "schedules path")
  assert_true(spec.paths["/_fn/ui-state"] ~= nil, "ui-state path")
  assert_true(spec.paths["/_fn/ui-state"].post ~= nil, "ui-state post exists")
  assert_true(spec.paths["/_fn/ui-state"].patch ~= nil, "ui-state patch exists")
  assert_true(spec.paths["/_fn/ui-state"].delete ~= nil, "ui-state delete exists")
  assert_true(spec.paths["/fn/hello"].get ~= nil, "hello get exists")
  assert_eq(spec.paths["/fn/hello"].post, nil, "hello post not published")
  assert_true(spec.paths["/fn/risk_score"].get ~= nil, "risk get exists")
  assert_true(spec.paths["/fn/risk_score"].post ~= nil, "risk post exists")
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
  dofile("/app/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  assert_eq(calls.enforce_api, 1, "ui-state should enforce api")
  assert_eq(calls.enforce_write, 1, "ui-state should enforce write on mutating methods")
  assert_eq(calls.write_json, 0, "ui-state should stop when write guard denies")

  calls.enforce_api = 0
  calls.enforce_write = 0
  calls.write_json = 0
  _G.ngx.req.get_method = function() return "GET" end
  dofile("/app/openresty/lua/fastfn/console/ui_state_endpoint.lua")
  assert_eq(calls.enforce_api, 1, "ui-state get should enforce api")
  assert_eq(calls.enforce_write, 0, "ui-state get should not enforce write")
  assert_eq(calls.write_json, 1, "ui-state get should return snapshot")
  assert_eq(calls.last_status, 200, "ui-state get status")

  package.loaded["fastfn.console.guard"] = original_guard
  _G.ngx = original_ngx
end

local function main()
  test_gateway_utils()
  test_fn_limits()
  test_invoke_rules()
  test_openapi_builder()
  test_ui_state_endpoint_guards()
  local ok = os.execute("resty /app/tests/unit/test_console_security.lua >/tmp/test_console_security.out 2>/tmp/test_console_security.err")
  if ok ~= true and ok ~= 0 then
    local f = io.open("/tmp/test_console_security.err", "rb")
    local err = f and f:read("*a") or "unknown"
    if f then f:close() end
    fail("console security tests failed: " .. tostring(err))
  end
  print("lua unit tests passed")
end

main()
