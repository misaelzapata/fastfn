#!/usr/bin/env resty

package.path = "/app/openresty/lua/?.lua;/app/openresty/lua/?/init.lua;" .. package.path

local function fail(msg)
  io.stderr:write("FAIL: " .. msg .. "\n")
  os.exit(1)
end

local function assert_true(v, msg)
  if not v then
    fail(msg or "assert_true failed")
  end
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or "assert_eq") .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
  end
end

local function mk(path)
  os.execute("mkdir -p " .. string.format("%q", path))
end

local function write(path, data)
  local f = io.open(path, "wb")
  if not f then
    fail("cannot write " .. path)
  end
  f:write(data)
  f:close()
end

local function main()
  local root = "/tmp/fnsec"
  os.execute("rm -rf " .. string.format("%q", root))
  mk(root .. "/functions/python/safe")
  write(root .. "/functions/python/safe/app.py", "def handler(event):\n    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n")
  write(root .. "/functions/python/safe/fn.config.json", "{\"invoke\":{\"methods\":[\"GET\"]}}\n")

  local outside = root .. "/outside.py"
  write(outside, "def handler(event):\n    return {'status':200,'headers':{},'body':'x'}\n")

  os.execute("rm -f " .. string.format("%q", root .. "/functions/python/safe/app.py"))
  os.execute("ln -sf " .. string.format("%q", outside) .. " " .. string.format("%q", root .. "/functions/python/safe/app.py"))

  local cfg = {
    functions_root = root .. "/functions",
    socket_base_dir = "/tmp/fastfn",
    runtime_order = { "python" },
    defaults = { timeout_ms = 2500, max_concurrency = 20, max_body_bytes = 1048576 },
    runtimes = { python = { socket = "unix:/tmp/fastfn/fn-python.sock", timeout_ms = 2500 } },
  }

  local cache = {
    store = {},
    set = function(self, k, v) self.store[k] = v end,
    get = function(self, k) return self.store[k] end,
  }

  _G.ngx = {
    shared = { fn_cache = cache },
    now = function() return 0 end,
    worker = { pid = function() return 1 end },
    re = { match = function() return nil end },
    escape_uri = function(s) return s end,
  }

  local cjson = require("cjson.safe")
  cache:set("runtime:config", cjson.encode(cfg))

  package.loaded["fastfn.core.routes"] = nil
  local routes = require("fastfn.core.routes")
  routes.discover_functions(true)

  package.loaded["fastfn.console.data"] = nil
  local console = require("fastfn.console.data")

  local detail, err = console.function_detail("python", "safe", nil, false)
  assert_true(detail == nil, "symlink handler must be rejected")
  local accepted = (err == "function code not found") or (err == "unknown function")
  assert_true(accepted, "symlink rejection error")

  os.execute("rm -f " .. string.format("%q", root .. "/functions/python/safe/app.py"))
  write(root .. "/functions/python/safe/app.py", "def handler(event):\n    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{}'}\n")
  routes.discover_functions(true)
  local detail2, err2 = console.function_detail("python", "safe", nil, false)
  assert_true(detail2 ~= nil, err2 or "expected detail")
  assert_true(detail2.fn_config == nil, "fn_config must not be exposed")
  assert_true(detail2.metadata ~= nil and detail2.metadata.env ~= nil, "metadata present")
  assert_true(detail2.metadata.env.path == nil, "env path must not be exposed")

  local updated, err3 = console.set_function_code("python", "safe", nil, { code = "# changed\ndef handler(event):\n    return {'status':200,'headers':{'Content-Type':'application/json'},'body':'{\\\"ok\\\":true}'}\n" })
  assert_true(updated ~= nil, err3 or "expected code update")
  assert_true(type(updated.code) == "string", "updated code returned")

  print("console security unit tests passed")
end

main()
