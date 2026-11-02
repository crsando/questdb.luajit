-- Pure platform knowledge: how a platform names its shared libraries and
-- where it conventionally keeps them. No filesystem or FFI access here, so
-- every platform can be unit-tested from any host.

local M = {}

-- LuaJIT reports the host in `jit.os` as one of
-- OSX / Linux / Windows / BSD / POSIX / Other.
local BY_JIT_OS = {
  OSX = "macos",
  Linux = "linux",
  Windows = "windows",
  BSD = "bsd",
  POSIX = "posix",
}

--- Map a `jit.os` value to an internal platform id.
function M.from_jit_os(os_name)
  return BY_JIT_OS[os_name] or "unknown"
end

local SPECS = {
  macos = { extension = "dylib", filename = "libquestdb_client.dylib" },
  linux = { extension = "so", filename = "libquestdb_client.so" },
  bsd = { extension = "so", filename = "libquestdb_client.so" },
  posix = { extension = "so", filename = "libquestdb_client.so" },
  -- MinGW has no "lib" prefix for DLLs.
  windows = { extension = "dll", filename = "questdb_client.dll" },
  unknown = { extension = nil, filename = "libquestdb_client" },
}

--- Return `{ extension = ..., filename = ... }` for a platform id.
function M.spec(platform)
  return SPECS[platform] or SPECS.unknown
end

-- Consulted only after explicit paths, environment variables and the
-- repository-local build directories.
local SYSTEM_LIB_DIRS = {
  macos = {
    "/opt/homebrew/lib", -- Apple Silicon Homebrew
    "/usr/local/lib",    -- Intel Homebrew and manual installs
    "/opt/local/lib",    -- MacPorts
  },
  linux = {
    "/usr/local/lib",
    "/usr/lib",
    "/usr/lib64",
    "/usr/lib/x86_64-linux-gnu",
    "/usr/lib/aarch64-linux-gnu",
    "/usr/lib/arm-linux-gnueabihf",
  },
  bsd = { "/usr/local/lib", "/usr/lib" },
  posix = { "/usr/local/lib", "/usr/lib" },
  windows = {},
  unknown = { "/usr/local/lib" },
}

--- Return the system library directories for a platform id.
function M.system_lib_dirs(platform)
  return SYSTEM_LIB_DIRS[platform] or SYSTEM_LIB_DIRS.unknown
end

return M
