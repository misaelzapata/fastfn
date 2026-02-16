local M = {}

local IGNORED_DIRS = {
  [".git"] = true,
  ["node_modules"] = true,
  ["__pycache__"] = true,
  [".fastfn"] = true,
  [".rust-build"] = true,
}

local O_NONBLOCK = 2048
local O_CLOEXEC = 524288
local EAGAIN = 11
local EWOULDBLOCK = 11

local IN_MODIFY = 0x00000002
local IN_ATTRIB = 0x00000004
local IN_CLOSE_WRITE = 0x00000008
local IN_MOVED_FROM = 0x00000040
local IN_MOVED_TO = 0x00000080
local IN_CREATE = 0x00000100
local IN_DELETE = 0x00000200
local IN_DELETE_SELF = 0x00000400
local IN_MOVE_SELF = 0x00000800
local IN_Q_OVERFLOW = 0x00004000
local IN_IGNORED = 0x00008000
local IN_ISDIR = 0x40000000

local ffi_ok, ffi = pcall(require, "ffi")
local bit_ok, bit = pcall(require, "bit")
local cdef_loaded = false

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function has_ignored_segment(path)
  for part in tostring(path or ""):gmatch("[^/]+") do
    if IGNORED_DIRS[part] then
      return true
    end
  end
  return false
end

local function list_dirs_recursive(root)
  local cmd = string.format(
    "find %s \\( -name '.git' -o -name 'node_modules' -o -name '__pycache__' -o -name '.fastfn' -o -name '.rust-build' \\) -prune -o -type d -print 2>/dev/null",
    shell_quote(root)
  )
  local p = io.popen(cmd)
  if not p then
    return {}
  end
  local out = {}
  for line in p:lines() do
    if line and line ~= "" then
      out[#out + 1] = line
    end
  end
  p:close()
  table.sort(out)
  return out
end

local function ensure_ffi_cdef()
  if cdef_loaded then
    return true
  end
  local ok, err = pcall(ffi.cdef, [[
    typedef unsigned int uint32_t;
    typedef int int32_t;
    typedef unsigned long size_t;
    typedef long ssize_t;
    struct inotify_event {
      int wd;
      uint32_t mask;
      uint32_t cookie;
      uint32_t len;
      char name[0];
    };
    int inotify_init1(int flags);
    int inotify_add_watch(int fd, const char *pathname, uint32_t mask);
    int inotify_rm_watch(int fd, uint32_t wd);
    ssize_t read(int fd, void *buf, size_t count);
    int close(int fd);
  ]])
  if not ok then
    local msg = tostring(err or "")
    if not msg:find("redefinition", 1, true) then
      return false, err
    end
  end
  cdef_loaded = true
  return true
end

local function linux_luajit_ready()
  if type(jit) ~= "table" then
    return false
  end
  return tostring(jit.os or "") == "Linux"
end

function M.start(opts)
  opts = opts or {}
  local root = tostring(opts.root or "")
  if root == "" then
    return false, "watchdog root is required"
  end
  if type(opts.on_change) ~= "function" then
    return false, "watchdog on_change callback is required"
  end
  if not linux_luajit_ready() then
    return false, "watchdog requires Linux LuaJIT"
  end
  if not ffi_ok then
    return false, "watchdog requires ffi"
  end
  if not bit_ok then
    return false, "watchdog requires bit library"
  end

  local ok_cdef, cdef_err = ensure_ffi_cdef()
  if not ok_cdef then
    return false, "watchdog ffi init failed: " .. tostring(cdef_err)
  end

  local fd = ffi.C.inotify_init1(O_NONBLOCK + O_CLOEXEC)
  if fd == nil or fd < 0 then
    return false, "inotify_init1 failed errno=" .. tostring(ffi.errno())
  end

  local watch_mask = bit.bor(
    IN_MODIFY,
    IN_ATTRIB,
    IN_CLOSE_WRITE,
    IN_MOVED_FROM,
    IN_MOVED_TO,
    IN_CREATE,
    IN_DELETE,
    IN_DELETE_SELF,
    IN_MOVE_SELF,
    IN_Q_OVERFLOW
  )
  local watch_interest = bit.bor(
    IN_MODIFY,
    IN_ATTRIB,
    IN_CLOSE_WRITE,
    IN_MOVED_FROM,
    IN_MOVED_TO,
    IN_CREATE,
    IN_DELETE,
    IN_DELETE_SELF,
    IN_MOVE_SELF,
    IN_Q_OVERFLOW
  )

  local wd_to_path = {}
  local path_to_wd = {}
  local watch_count = 0

  local function close_fd()
    if fd and fd >= 0 then
      ffi.C.close(fd)
      fd = -1
    end
  end

  local function add_watch(path)
    if path == "" or has_ignored_segment(path) then
      return true
    end
    if path_to_wd[path] then
      return true
    end
    local wd = ffi.C.inotify_add_watch(fd, path, watch_mask)
    if wd == nil or wd < 0 then
      return false, "inotify_add_watch failed path=" .. path .. " errno=" .. tostring(ffi.errno())
    end
    local num = tonumber(wd)
    wd_to_path[num] = path
    path_to_wd[path] = num
    watch_count = watch_count + 1
    return true
  end

  for _, dir in ipairs(list_dirs_recursive(root)) do
    local ok_add, add_err = add_watch(dir)
    if not ok_add then
      close_fd()
      return false, add_err
    end
  end

  local poll_interval = tonumber(opts.poll_interval_s) or 0.20
  if poll_interval < 0.05 then
    poll_interval = 0.05
  end
  local debounce_ms = tonumber(opts.debounce_ms) or 150
  if debounce_ms < 25 then
    debounce_ms = 25
  end
  local debounce_s = debounce_ms / 1000

  local buf_size = 65536
  local buf = ffi.new("uint8_t[?]", buf_size)
  local event_size = ffi.sizeof("struct inotify_event")
  local pending_since = nil
  local reload_scheduled = false

  local function schedule_reload()
    if reload_scheduled then
      return
    end
    reload_scheduled = true
    local ok_timer, timer_err = ngx.timer.at(0, function(premature)
      reload_scheduled = false
      if premature then
        return
      end
      local ok_cb, cb_err = pcall(opts.on_change)
      if not ok_cb then
        ngx.log(ngx.ERR, "catalog watchdog callback failed: ", tostring(cb_err))
      end
    end)
    if not ok_timer then
      reload_scheduled = false
      ngx.log(ngx.ERR, "catalog watchdog failed to queue reload: ", tostring(timer_err))
    end
  end

  local function drain_events()
    local changed = false
    while true do
      local n = ffi.C.read(fd, buf, buf_size)
      if n == nil or n <= 0 then
        local errno = ffi.errno()
        if errno == EAGAIN or errno == EWOULDBLOCK or n == 0 then
          break
        end
        return nil, "inotify read failed errno=" .. tostring(errno)
      end

      local offset = 0
      local total = tonumber(n)
      while offset < total do
        local ev = ffi.cast("struct inotify_event*", ffi.cast("uint8_t*", buf) + offset)
        local mask = tonumber(ev.mask)
        local wd = tonumber(ev.wd)
        local parent = wd_to_path[wd]
        local name = ""
        local ev_len = tonumber(ev.len)
        if ev_len > 0 then
          name = ffi.string(ev.name, ev_len):gsub("%z+$", "")
        end

        if bit.band(mask, IN_IGNORED) ~= 0 then
          local prev = wd_to_path[wd]
          if prev then
            wd_to_path[wd] = nil
            path_to_wd[prev] = nil
          end
        end

        if parent and name ~= "" and bit.band(mask, IN_ISDIR) ~= 0 and bit.band(mask, bit.bor(IN_CREATE, IN_MOVED_TO)) ~= 0 then
          local subdir = parent .. "/" .. name
          if not has_ignored_segment(subdir) then
            add_watch(subdir)
          end
        end

        local full_path = parent or ""
        if parent and name ~= "" then
          full_path = parent .. "/" .. name
        end
        if bit.band(mask, watch_interest) ~= 0 and not has_ignored_segment(full_path) then
          changed = true
        end

        offset = offset + event_size + ev_len
      end
    end
    return changed
  end

  local ok_poll, poll_err = ngx.timer.every(poll_interval, function(premature)
    if premature then
      return
    end
    local changed, read_err = drain_events()
    if changed == nil then
      ngx.log(ngx.ERR, "catalog watchdog error: ", tostring(read_err))
      return
    end
    if changed then
      pending_since = ngx.now()
    end
    if pending_since and (ngx.now() - pending_since) >= debounce_s then
      pending_since = nil
      schedule_reload()
    end
  end)

  if not ok_poll then
    close_fd()
    return false, "watchdog timer failed: " .. tostring(poll_err)
  end

  return true, {
    backend = "inotify_ffi",
    watches = watch_count,
    poll_interval_s = poll_interval,
    debounce_ms = debounce_ms,
  }
end

return M
