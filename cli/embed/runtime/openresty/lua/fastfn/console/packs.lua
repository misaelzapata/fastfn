local routes = require "fastfn.core.routes"
local cjson = require "cjson.safe"
local fs = require "fastfn.core.fs"

local M = {}

local NAME_RE = "^[a-zA-Z0-9_-]+$"

local function list_dirs(path)
  return fs.list_dirs(path)
end

local function basename(path)
  return tostring(path):match("([^/]+)$")
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if not f then
    return false
  end
  f:close()
  return true
end

local function dir_exists(path)
  return fs.is_dir(path)
end

local function packs_root(functions_root)
  return tostring(functions_root) .. "/.fastfn/packs"
end

function M.list()
  local cfg = routes.get_config()
  local root = packs_root(cfg.functions_root)
  local out = {
    generated_at = ngx.now(),
    packs_root = root,
    runtimes = {},
  }

  for _, rt_dir in ipairs(list_dirs(root)) do
    local runtime = basename(rt_dir)
    if runtime and runtime:match(NAME_RE) then
      local packs = {}
      for _, pdir in ipairs(list_dirs(rt_dir)) do
        local name = basename(pdir)
        if name and name:match(NAME_RE) then
          local entry = {
            name = name,
            dir = pdir,
          }
          if runtime == "python" then
            entry.requirements_txt = file_exists(pdir .. "/requirements.txt")
            entry.deps_dir = dir_exists(pdir .. "/.deps")
          elseif runtime == "node" then
            entry.package_json = file_exists(pdir .. "/package.json")
            entry.lock_file = file_exists(pdir .. "/package-lock.json") and "package-lock.json"
              or (file_exists(pdir .. "/npm-shrinkwrap.json") and "npm-shrinkwrap.json" or nil)
            entry.node_modules = dir_exists(pdir .. "/node_modules")
          end
          packs[#packs + 1] = entry
        end
      end
      out.runtimes[runtime] = { packs = packs }
    end
  end

  return out
end

function M.as_json()
  return cjson.encode(M.list()) or "{}"
end

return M
