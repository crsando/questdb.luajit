local qdb = require "questdb"
local ffi = qdb.native.ffi

local lib = qdb.native.load()
local micros = lib.line_sender_now_micros()
local nanos = lib.line_sender_now_nanos()

assert(tonumber(micros) > 1000000000000000)
assert(tonumber(nanos) > 1000000000000000000)
assert(qdb.time.us(micros):unit() == "us")
assert(qdb.time.ns(nanos):unit() == "ns")

-- Regression coverage for LuaJIT's by-value struct ABI calls. The wrapper
-- must not forward these arguments through a Lua vararg helper.
local buffer = lib.line_sender_buffer_new(1)
assert(buffer ~= nil)
local err_out = ffi.new("line_sender_error*[1]")
local table_name = ffi.new("line_sender_table_name[1]")
local column_name = ffi.new("line_sender_column_name[1]")
local symbol_value = ffi.new("line_sender_utf8[1]")
assert(lib.line_sender_table_name_init(table_name, 9, "ffi_smoke", err_out))
assert(lib.line_sender_column_name_init(column_name, 3, "sym", err_out))
assert(lib.line_sender_utf8_init(symbol_value, 7, "ABI-test", err_out))
assert(lib.line_sender_buffer_table(buffer, table_name[0], err_out))
assert(lib.line_sender_buffer_symbol(buffer, column_name[0], symbol_value[0], err_out))
assert(lib.line_sender_buffer_at_micros(buffer, 1700000000123456, err_out))
assert(tonumber(lib.line_sender_buffer_row_count(buffer)) == 1)
lib.line_sender_buffer_free(buffer)

-- Closed buffers must be rejected before entering the C ABI.
local wrapped = lib.line_sender_buffer_new(1)
assert(wrapped ~= nil)
local wrapped_buffer = setmetatable({
  _lib = lib,
  _ptr = wrapped,
  _sender = { _closed = false },
  _closed = false,
}, qdb.Buffer)
assert(wrapped_buffer:close())
local reserve_ok, reserve_err = wrapped_buffer:reserve(1)
assert(not reserve_ok and reserve_err.code == "closed")

print("FFI smoke passed")
