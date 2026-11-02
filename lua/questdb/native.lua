local ffi = require "ffi"
local cdef = require "questdb.cdef"
local platform = require "questdb.platform"

-- The ABI boundary for the row-oriented MVP. Declarations live in
-- `questdb.cdef` and are registered once per Lua state: reloading this module
-- must not trip an `ffi.cdef` redefinition error.
if not pcall(ffi.typeof, "line_sender") then
  ffi.cdef(cdef)
end

local M = {
  ffi = ffi,
}

-- Every function declared in the cdef. A library missing any of them is not one
-- this module can drive, however cleanly it loads.
M.required_symbols = {}
for name in cdef:gmatch("(line_sender_[%w_]+)%s*%(") do
  M.required_symbols[#M.required_symbols + 1] = name
end

local function detect_platform()
  local ok, jit = pcall(require, "jit")
  return platform.from_jit_os(ok and type(jit) == "table" and jit.os or nil)
end

local current = detect_platform()
local spec = platform.spec(current)

M.platform = current
M.library_extension = spec.extension
M.library_name = spec.filename
M.system_lib_dirs = platform.system_lib_dirs(current)

-- Resolve the repository root from this file's location so that a checkout
-- works without any environment variables after `make deps`.
local function repo_root()
  local info = debug.getinfo(1, "S")
  local source = info and info.source or ""
  local path = source:match("^@(.*)$")
  if not path then return nil end
  path = path:gsub("\\", "/")
  -- .../<root>/lua/questdb/native.lua -> .../<root>
  local root = path:match("^(.*)/lua/questdb/[^/]+$")
  return root
end

local module_source = debug.getinfo(1, "S").source
local module_dir = module_source:match("^@(.+)[/\\][^/\\]+$")
local install_config
if module_dir then
  -- Read only the config next to THIS native.lua. require() could accidentally
  -- find an installed config when running an uninstalled checkout.
  local config_file = module_dir .. "/_install.lua"
  local file = io.open(config_file, "r")
  if file then
    file:close()
    install_config = assert(loadfile(config_file))()
    assert(type(install_config) == "string", "invalid questdb install configuration")
  end
end
M.private_library_dir = install_config and (module_dir .. "/" .. install_config) or nil

M.repo_root = repo_root()

local function add_candidate(out, seen, value)
  if value and value ~= "" and not seen[value] then
    seen[value] = true
    out[#out + 1] = value
  end
end

local function is_directory(path)
  local file = io.open(path, "r")
  if not file then return false end
  -- Opening a directory succeeds on POSIX; reading it reports the error.
  local data, read_error = file:read(1)
  file:close()
  return data == nil and read_error ~= nil
end

-- The library the caller asked for, if any. `path` wins over the environment.
local function requested_library(path)
  local function non_empty(value)
    if value and value ~= "" then return value end
  end
  return non_empty(path)
    or non_empty(os.getenv("QUESTDB_CLIENT_LIB"))
    or non_empty(os.getenv("QUESTDB_CLIENT_LIBRARY"))
end

--- The automatic search order, used when no library was asked for by name.
function M.discovery_candidates()
  local out = {}
  local seen = {}

  if M.private_library_dir then
    add_candidate(out, seen, M.private_library_dir .. "/" .. M.library_name)
  end

  local root = M.repo_root
  if root then
    add_candidate(out, seen, root .. "/build/lib/" .. M.library_name)
    add_candidate(out, seen, root .. "/build/" .. M.library_name)
    add_candidate(out, seen, root .. "/lib/" .. M.library_name)
    add_candidate(out, seen, root .. "/build/c-questdb-client/build-" .. M.platform ..
      "/" .. M.library_name)
  end

  -- Bare names are resolved by the platform loader (dlopen / dyld / LoadLibrary).
  add_candidate(out, seen, "questdb_client")
  add_candidate(out, seen, M.library_name)

  for _, dir in ipairs(M.system_lib_dirs) do
    add_candidate(out, seen, dir .. "/" .. M.library_name)
  end

  return out
end

--- What `load(path)` would try. A named library is the only candidate: quietly
-- falling back would run against some other build than the one asked for.
function M.candidates(path)
  local requested = requested_library(path)
  if not requested then
    if M.private_library_dir then
      return { M.private_library_dir .. "/" .. M.library_name }
    end
    return M.discovery_candidates()
  end
  if requested:find("[/\\]$") or is_directory(requested) then
    return { (requested:gsub("[/\\]+$", "")) .. "/" .. M.library_name }
  end
  return { requested }
end

--- Return the search path as a human-readable string (for error messages).
function M.explain(path)
  local lines = {}
  for _, candidate in ipairs(M.candidates(path)) do
    lines[#lines + 1] = "  " .. candidate
  end
  local mode = requested_library(path) and "requested library" or "search path"
  return "platform: " .. M.platform .. "\n" .. mode .. ":\n" ..
    table.concat(lines, "\n")
end

-- `ffi.load` proves the file is loadable, not that it is this client.
local function open_library(name)
  local ok, lib = pcall(ffi.load, name)
  if not ok then return nil, tostring(lib) end
  local missing = {}
  for _, symbol in ipairs(M.required_symbols) do
    if not pcall(function() return lib[symbol] end) then
      missing[#missing + 1] = symbol
    end
  end
  if #missing > 0 then
    return nil, "not a compatible c-questdb-client, missing " .. #missing ..
      " of " .. #M.required_symbols .. " symbols (first: " .. missing[1] .. ")"
  end
  return lib
end

local loaded = {}
local origins = setmetatable({}, { __mode = "k" })
local default_lib = nil

--- Load the client library. With no `path`, the first library loaded in this
-- Lua state stays the default, so `qdb.time.now_*` and `sender { lib = ... }`
-- agree on one library.
function M.load(path)
  if not path and default_lib then return default_lib end

  local failures = {}
  for _, name in ipairs(M.candidates(path)) do
    if loaded[name] then return loaded[name] end

    local lib, failure = open_library(name)
    if lib then
      loaded[name] = lib
      origins[lib] = name
      default_lib = default_lib or lib
      return lib
    end
    failures[#failures + 1] = name .. ": " .. failure
  end

  error("unable to load c-questdb-client shared library on " .. M.platform ..
    " (expected " .. M.library_name .. "):\n  " ..
    table.concat(failures, "\n  ") ..
    (requested_library(path) and
      "\nThe library was requested by name, so no other location was tried." or
      (M.private_library_dir and
        "\nThe installed private library is missing or incompatible; run make && make install again, or set QUESTDB_CLIENT_LIB explicitly." or
        "\nBuild it with `make deps`, or set QUESTDB_CLIENT_LIB to the library path.")), 2)
end

--- The candidate a library handle was loaded from.
function M.loaded_from(lib)
  return origins[lib]
end

return M
