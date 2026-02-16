local guard = require "fastfn.console.guard"
local console = require "fastfn.console.data"

if not guard.enforce_api() then
  return
end

if ngx.req.get_method() ~= "GET" then
  guard.write_json(405, { error = "method not allowed" })
  return
end

local catalog = console.catalog()
local functions = {}

if catalog and catalog.runtimes then
  for runtime_name, runtime_data in pairs(catalog.runtimes) do
    local fn_list = runtime_data and runtime_data.functions
    if type(fn_list) == "table" then
      for _, fn in ipairs(fn_list) do
        if type(fn) == "table" then
          local copy = {}
          for k, v in pairs(fn) do
            copy[k] = v
          end
          copy.runtime = runtime_name
          table.insert(functions, copy)
        end
      end
    end
  end
end

guard.write_json(200, functions)
