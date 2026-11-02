local qdb = require "questdb"
local n = qdb.native
assert(n.private_library_dir, "installed module must have a private library location")
local candidates = n.candidates()
assert(#candidates == 1, "installed modules must not silently fall back to system libraries")
assert(candidates[1] == n.private_library_dir .. "/" .. n.library_name)
local lib = n.load()
assert(n.loaded_from(lib) == candidates[1])
local info = assert(io.open(n.private_library_dir .. "/build-info.txt")):read("*a")
assert(info:find("commit=", 1, true))
assert(info:find("repository=", 1, true))
assert(qdb.time.now_ns():unit() == "ns")
local source = debug.getinfo(qdb.sender, "S").source
assert(source:find(assert(os.getenv("EXPECT_MODULE")), 1, true), source)
print("private library loaded; metadata and module location verified")
