-- Platform resolution tests. Every platform's naming rules are checked
-- explicitly, so a Linux-only regression (the original bug: a hard-coded .so
-- filename) fails on any machine. Only the loading checks need the library.

local platform = require "questdb.platform"

local function assert_equal(actual, expected, message)
  assert(actual == expected, (message or "values differ") ..
    ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
end

local function contains(list, needle)
  for _, value in ipairs(list) do
    if value == needle then return true end
  end
  return false
end

----------------------------------------------------------------------
-- jit.os -> platform id
----------------------------------------------------------------------
assert_equal(platform.from_jit_os("OSX"), "macos")
assert_equal(platform.from_jit_os("Linux"), "linux")
assert_equal(platform.from_jit_os("Windows"), "windows")
assert_equal(platform.from_jit_os("BSD"), "bsd")
assert_equal(platform.from_jit_os("POSIX"), "posix")
assert_equal(platform.from_jit_os("Something"), "unknown")
assert_equal(platform.from_jit_os(nil), "unknown")

----------------------------------------------------------------------
-- Shared library naming per platform
----------------------------------------------------------------------
local expected = {
  macos = "libquestdb_client.dylib",
  linux = "libquestdb_client.so",
  bsd = "libquestdb_client.so",
  posix = "libquestdb_client.so",
  windows = "questdb_client.dll",
  unknown = "libquestdb_client",
}

for id, filename in pairs(expected) do
  assert_equal(platform.spec(id).filename, filename, "filename for " .. id)
end

-- The ABI boundary must distinguish these: macOS uses .dylib, Linux .so,
-- Windows .dll with no "lib" prefix.
assert_equal(platform.spec("macos").extension, "dylib")
assert_equal(platform.spec("linux").extension, "so")
assert_equal(platform.spec("windows").extension, "dll")
assert(platform.spec("windows").filename:find("^questdb_client"),
  "Windows DLLs conventionally have no 'lib' prefix")
assert(platform.spec("nonexistent-platform").filename == "libquestdb_client",
  "unknown platforms must fall back, not error")

----------------------------------------------------------------------
-- System library directories
----------------------------------------------------------------------
assert(contains(platform.system_lib_dirs("macos"), "/opt/homebrew/lib"),
  "macOS must search Apple Silicon Homebrew")
assert(contains(platform.system_lib_dirs("macos"), "/usr/local/lib"),
  "macOS must search Intel Homebrew / manual installs")
assert(contains(platform.system_lib_dirs("linux"), "/usr/lib"),
  "Linux must search /usr/lib")
assert(contains(platform.system_lib_dirs("linux"), "/usr/lib/x86_64-linux-gnu"),
  "Linux must search the multiarch triplet dir")
assert(#platform.system_lib_dirs("windows") == 0,
  "Windows resolves DLLs from the loader search order, not fixed dirs")
assert(#platform.system_lib_dirs("nonexistent-platform") > 0,
  "unknown platforms need a fallback")

----------------------------------------------------------------------
-- Host-specific wiring in native.lua
----------------------------------------------------------------------
local native = require "questdb.native"

local host_os = jit and jit.os or ""
local host_spec = platform.spec(platform.from_jit_os(host_os))
assert_equal(native.platform, platform.from_jit_os(host_os), "host platform")
assert_equal(native.library_name, host_spec.filename, "host library name")
assert_equal(native.library_extension, host_spec.extension, "host extension")

if host_os == "OSX" then
  assert_equal(native.library_name, "libquestdb_client.dylib")
elseif host_os == "Linux" then
  assert_equal(native.library_name, "libquestdb_client.so")
end

----------------------------------------------------------------------
-- Candidate search path
----------------------------------------------------------------------
local candidates = native.discovery_candidates()
assert(#candidates > 0, "candidate list must not be empty")

-- A fresh checkout must work after `make deps` with no environment variables,
-- so the repo's own build directory has to be searched.
assert(native.repo_root, "repository root must be resolvable from lua/questdb/")
assert(contains(candidates, native.repo_root .. "/build/lib/" .. native.library_name),
  "repo build/lib candidate missing from search path")
assert(contains(candidates, "questdb_client"),
  "bare library name must be a candidate")
assert(contains(candidates, native.library_name),
  "platform library filename must be a candidate")

-- Windows must never be handed a Unix filename, nor a "lib"-prefixed DLL.
if native.platform == "windows" then
  for _, candidate in ipairs(candidates) do
    assert(not candidate:find("%.so$") and not candidate:find("%.dylib$"),
      "Windows search path leaked a Unix library: " .. candidate)
    assert(not candidate:find("libquestdb_client.dll$"),
      "Windows search path invented a 'lib' prefix: " .. candidate)
  end
end

-- Every candidate must end in the platform's own extension (or be a bare
-- loader name), regardless of the host running the test.
for _, candidate in ipairs(candidates) do
  local bare = candidate == "questdb_client" or candidate == native.library_name
  local right_ext = native.library_extension ~= nil and
    candidate:sub(-#native.library_extension - 1) == "." .. native.library_extension
  assert(bare or right_ext, "candidate has the wrong extension: " .. candidate)
end

-- No duplicate entries: the loader would retry the same failing path.
local seen = {}
for _, candidate in ipairs(candidates) do
  assert(not seen[candidate], "duplicate candidate: " .. candidate)
  seen[candidate] = true
end

-- A library asked for by name is the only candidate; never fall back from it.
local explicit = native.candidates("/tmp/custom/" .. native.library_name)
assert_equal(#explicit, 1, "explicit path must not fall back")
assert_equal(explicit[1], "/tmp/custom/" .. native.library_name,
  "explicit path must be tried as given")

-- A directory is expanded to the platform filename, with or without a slash.
assert_equal(native.candidates("/tmp/libdir/")[1], "/tmp/libdir/" .. native.library_name,
  "directory path must be expanded with the platform filename")
assert_equal(#native.candidates("/tmp/libdir/"), 1)
if native.platform ~= "windows" then
  assert_equal(native.candidates("/")[1], "/" .. native.library_name)
  assert_equal(native.candidates("/tmp")[1], "/tmp/" .. native.library_name,
    "an existing directory must be detected")
end

-- Loading: a missing library named explicitly must fail, not find another one.
local missing_ok, missing_err = pcall(native.load, "/nonexistent/" .. native.library_name)
assert(not missing_ok, "a missing explicit library must not fall back")
assert(tostring(missing_err):find("requested by name", 1, true), tostring(missing_err))

-- Loading: a real library that is not this client must be refused by name.
local foreign = ({ OSX = "/usr/lib/libz.dylib", Linux = "libm.so.6" })[host_os]
if foreign then
  local foreign_ok, foreign_err = pcall(native.load, foreign)
  assert(not foreign_ok, "a library without the client's symbols must be refused")
  assert(tostring(foreign_err):find("not a compatible c-questdb-client", 1, true),
    tostring(foreign_err))
end

-- Every function declared in the cdef is required, and the list is not empty
-- because of a parsing slip.
assert(#native.required_symbols >= 30, "required symbols: " .. #native.required_symbols)
assert(contains(native.required_symbols, "line_sender_flush"))
assert(contains(native.required_symbols, "line_sender_error_free"))

-- A handle reports where it came from, and stays the default for later calls.
local lib = native.load()
assert(type(native.loaded_from(lib)) == "string", "loaded_from must name the candidate")
assert(native.load() == lib, "the first library must stay the default")

-- System directories are searched, but only after the repo-local and
-- bare-name candidates.
for _, dir in ipairs(native.system_lib_dirs) do
  local entry = dir .. "/" .. native.library_name
  assert(contains(candidates, entry), "system lib dir not searched: " .. dir)
  local dir_index = nil
  for i, value in ipairs(candidates) do
    if value == entry then dir_index = i end
  end
  local bare_index = nil
  for i, value in ipairs(candidates) do
    if value == "questdb_client" then bare_index = i end
  end
  assert(dir_index and bare_index and dir_index > bare_index,
    "system dirs must come after bare names: " .. entry)
end

-- explain() is what the load-failure message shows.
local explanation = native.explain()
assert(explanation:find("platform: " .. native.platform, 1, true),
  "explain() must report the platform")
assert(explanation:find(native.library_name, 1, true),
  "explain() must report the expected filename")

print("platform tests passed (" .. native.platform .. ")")
