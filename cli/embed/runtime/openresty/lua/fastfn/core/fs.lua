local M = {}

local ffi_ok, ffi = pcall(require, "ffi")
local bit_ok, bit = pcall(require, "bit")
local cdef_loaded = false

local S_IFMT = 0xF000
local S_IFDIR = 0x4000
local S_IFREG = 0x8000
local S_IFLNK = 0xA000

local DT_UNKNOWN = 0
local DT_DIR = 4
local DT_REG = 8
local DT_LNK = 10

local EEXIST = 17

local function ensure_ffi()
  if not ffi_ok or not bit_ok then
    return nil, "ffi and bit are required"
  end
  if cdef_loaded then
    return true
  end
  local ok, err = pcall(ffi.cdef, [[
    typedef long int __syscall_slong_t;
    typedef unsigned long int __dev_t;
    typedef unsigned long int __ino_t;
    typedef unsigned int __mode_t;
    typedef unsigned int __uid_t;
    typedef unsigned int __gid_t;
    typedef long int __off_t;
    typedef long int __blksize_t;
    typedef long int __blkcnt_t;
    typedef long int __time_t;
    typedef struct __dirstream DIR;
    struct timespec {
      __time_t tv_sec;
      __syscall_slong_t tv_nsec;
    };
    struct stat {
      __dev_t st_dev;
      __ino_t st_ino;
      __ino_t st_nlink;
      __mode_t st_mode;
      __uid_t st_uid;
      __gid_t st_gid;
      int __pad0;
      __dev_t st_rdev;
      __off_t st_size;
      __blksize_t st_blksize;
      __blkcnt_t st_blocks;
      struct timespec st_atim;
      struct timespec st_mtim;
      struct timespec st_ctim;
      __syscall_slong_t __glibc_reserved[3];
    };
    struct dirent {
      unsigned long d_ino;
      long d_off;
      unsigned short d_reclen;
      unsigned char d_type;
      char d_name[256];
    };
    int stat(const char *pathname, struct stat *statbuf);
    int lstat(const char *pathname, struct stat *statbuf);
    char *realpath(const char *path, char *resolved_path);
    void free(void *ptr);
    DIR *opendir(const char *name);
    struct dirent *readdir(DIR *dirp);
    int closedir(DIR *dirp);
    int mkdir(const char *pathname, unsigned int mode);
    int rename(const char *oldpath, const char *newpath);
    int unlink(const char *pathname);
    int rmdir(const char *pathname);
  ]])
  if not ok then
    local msg = tostring(err or "")
    if not msg:find("redecl", 1, true) and not msg:find("redefinition", 1, true) then
      return nil, err
    end
  end
  cdef_loaded = true
  return true
end

local function stat_impl(path, nofollow)
  local ok, err = ensure_ffi()
  if not ok then
    return nil, err
  end
  if type(path) ~= "string" or path == "" then
    return nil, "invalid path"
  end
  local st = ffi.new("struct stat[1]")
  local rc
  if nofollow then
    rc = ffi.C.lstat(path, st)
  else
    rc = ffi.C.stat(path, st)
  end
  if rc ~= 0 then
    return nil
  end
  local mode = tonumber(st[0].st_mode)
  local kind = bit.band(mode, S_IFMT)
  return {
    mode = mode,
    size = tonumber(st[0].st_size),
    mtime = tonumber(st[0].st_mtim.tv_sec),
    is_dir = kind == S_IFDIR,
    is_file = kind == S_IFREG,
    is_symlink = kind == S_IFLNK,
  }
end

function M.stat(path)
  return stat_impl(path, false)
end

function M.lstat(path)
  return stat_impl(path, true)
end

function M.exists(path)
  return M.stat(path) ~= nil
end

function M.is_dir(path)
  local st = M.stat(path)
  return st ~= nil and st.is_dir == true
end

function M.is_file(path)
  local st = M.stat(path)
  return st ~= nil and st.is_file == true
end

function M.is_symlink(path)
  local st = M.lstat(path)
  return st ~= nil and st.is_symlink == true
end

function M.file_meta(path)
  local st = M.stat(path)
  if not st or not st.is_file then
    return nil, nil
  end
  return st.mtime, st.size
end

function M.realpath(path)
  local ok, err = ensure_ffi()
  if not ok then
    return nil, err
  end
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local ptr = ffi.C.realpath(path, nil)
  if ptr == nil then
    return nil
  end
  local resolved = ffi.string(ptr)
  ffi.C.free(ptr)
  if resolved == "" then
    return nil
  end
  return resolved
end

local function join_path(base, name)
  if base:sub(-1) == "/" then
    return base .. name
  end
  return base .. "/" .. name
end

local function read_dir_entries(path)
  local ok, err = ensure_ffi()
  if not ok then
    return nil, err
  end
  if type(path) ~= "string" or path == "" then
    return {}, nil
  end
  local dir = ffi.C.opendir(path)
  if dir == nil then
    return {}, nil
  end
  local entries = {}
  while true do
    local ent = ffi.C.readdir(dir)
    if ent == nil then
      break
    end
    local name = ffi.string(ent.d_name)
    if name ~= "." and name ~= ".." then
      local full = join_path(path, name)
      local dtype = tonumber(ent.d_type)
      local item = {
        name = name,
        path = full,
      }
      if dtype == DT_DIR then
        item.is_dir = true
      elseif dtype == DT_REG then
        item.is_file = true
      elseif dtype == DT_LNK then
        item.is_symlink = true
      else
        local st = M.lstat(full)
        item.is_dir = st ~= nil and st.is_dir == true
        item.is_file = st ~= nil and st.is_file == true
        item.is_symlink = st ~= nil and st.is_symlink == true
      end
      entries[#entries + 1] = item
    end
  end
  ffi.C.closedir(dir)
  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  return entries
end

local function should_skip_entry(skip_fn, entry)
  if type(skip_fn) ~= "function" then
    return false
  end
  if skip_fn(entry) then
    return true
  end
  if type(entry) == "table" and type(entry.path) == "string" and skip_fn(entry.path) then
    return true
  end
  return false
end

function M.list_dirs(path)
  local entries = read_dir_entries(path) or {}
  local out = {}
  for _, entry in ipairs(entries) do
    if entry.is_dir then
      out[#out + 1] = entry.path
    end
  end
  return out
end

function M.list_files(path)
  local entries = read_dir_entries(path) or {}
  local out = {}
  for _, entry in ipairs(entries) do
    if entry.is_file then
      out[#out + 1] = entry.path
    end
  end
  return out
end

function M.list_dirs_recursive(path, skip_fn)
  local out = {}
  if not M.is_dir(path) then
    return out
  end
  local function walk(dir)
    if type(skip_fn) == "function" and skip_fn(dir) then
      return
    end
    out[#out + 1] = dir
    for _, child in ipairs(M.list_dirs(dir)) do
      walk(child)
    end
  end
  walk(path)
  table.sort(out)
  return out
end

function M.list_files_recursive(path, max_depth, skip_fn)
  local out = {}
  local limit = tonumber(max_depth) or 3

  local function walk(dir, depth)
    if depth > limit then
      return
    end
    local entries = read_dir_entries(dir) or {}
    for _, entry in ipairs(entries) do
      if not should_skip_entry(skip_fn, entry) then
        if entry.is_file then
          out[#out + 1] = entry.path
        elseif entry.is_dir and not entry.is_symlink then
          walk(entry.path, depth + 1)
        end
      end
    end
  end

  if M.is_dir(path) then
    walk(path, 0)
  end
  table.sort(out)
  return out
end

function M.mkdir_p(path, mode)
  if type(path) ~= "string" or path == "" then
    return false, "invalid path"
  end
  local ok, err = ensure_ffi()
  if not ok then
    return false, err
  end
  mode = tonumber(mode) or 493
  local normalized = tostring(path):gsub("/+$", "")
  if normalized == "" then
    return true
  end

  local prefix = ""
  if normalized:sub(1, 1) == "/" then
    prefix = "/"
  end

  local current = prefix
  for segment in normalized:gmatch("[^/]+") do
    if current == "" or current == "/" then
      current = current .. segment
    else
      current = current .. "/" .. segment
    end
    local st = M.stat(current)
    if st == nil then
      local rc = ffi.C.mkdir(current, mode)
      if rc ~= 0 and ffi.errno() ~= EEXIST then
        return false, "mkdir failed"
      end
      st = M.stat(current)
    end
    if not st or not st.is_dir then
      return false, "path component is not a directory"
    end
  end
  return true
end

function M.rename_atomic(src, dst)
  local ok, err = ensure_ffi()
  if not ok then
    return false, err
  end
  if type(src) ~= "string" or src == "" or type(dst) ~= "string" or dst == "" then
    return false, "invalid path"
  end
  if ffi.C.rename(src, dst) ~= 0 then
    return false, "rename failed"
  end
  return true
end

function M.remove_tree(path)
  local ok, err = ensure_ffi()
  if not ok then
    return false, err
  end
  local st = M.lstat(path)
  if not st then
    return true
  end
  if st.is_dir and not st.is_symlink then
    local entries = read_dir_entries(path) or {}
    for _, entry in ipairs(entries) do
      local removed, remove_err = M.remove_tree(entry.path)
      if not removed then
        return false, remove_err
      end
    end
    if ffi.C.rmdir(path) ~= 0 then
      return false, "rmdir failed"
    end
    return true
  end
  if ffi.C.unlink(path) ~= 0 then
    return false, "unlink failed"
  end
  return true
end

return M
