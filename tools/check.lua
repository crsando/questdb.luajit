-- Diagnostic: report which shared library the module resolves on this host.
-- Run with: LUA_PATH='./lua/?.lua;./lua/?/init.lua;;' luajit tools/check.lua

local native = require "questdb.native"

print("platform:  " .. native.platform)
print("library:   " .. native.library_name)
print("repo root: " .. tostring(native.repo_root))
print(native.explain())

local ok, lib = pcall(native.load)
if not ok then
  io.stderr:write("\nFAILED TO LOAD\n" .. tostring(lib) .. "\n")
  os.exit(1)
end

print("\nloaded from: " .. tostring(native.loaded_from(lib)))
print("symbols:     " .. #native.required_symbols .. " required, all present")
print("now_us:      " .. tostring(lib.line_sender_now_micros()))
print("now_ns:      " .. tostring(lib.line_sender_now_nanos()))
