local native = require "questdb.native"
local time = require "questdb.time"
local errors = require "questdb.error"

local ffi = native.ffi
local Sender = {}
local Buffer = {}
local Row = {}

Sender.__index = Sender
Buffer.__index = Buffer
Row.__index = Row

local function native_error(lib, err_out)
  return errors.from_native_with_ffi(ffi, lib, err_out[0])
end

-- LuaJIT cannot safely forward a by-value C struct through a Lua vararg
-- function. Keep these calls explicit: the UTF-8/name views are structs
-- passed by value in the upstream ABI.
local function call_table(lib, ptr, view)
  local err_out = ffi.new("line_sender_error*[1]")
  local ok = lib.line_sender_buffer_table(ptr, view, err_out)
  if ok then return true end
  return nil, native_error(lib, err_out)
end

local function call_symbol(lib, ptr, name_view, value_view)
  local err_out = ffi.new("line_sender_error*[1]")
  local ok = lib.line_sender_buffer_symbol(ptr, name_view, value_view, err_out)
  if ok then return true end
  return nil, native_error(lib, err_out)
end

local function call_text_column(lib, ptr, name_view, value_view)
  local err_out = ffi.new("line_sender_error*[1]")
  local ok = lib.line_sender_buffer_column_str(ptr, name_view, value_view, err_out)
  if ok then return true end
  return nil, native_error(lib, err_out)
end

local function call_column(lib, kind, ptr, name_view, value)
  local err_out = ffi.new("line_sender_error*[1]")
  local fn = lib[kind]
  local ok
  if kind == "line_sender_buffer_column_bool" then
    ok = fn(ptr, name_view, value, err_out)
  elseif kind == "line_sender_buffer_column_i64" or
      kind == "line_sender_buffer_column_date" or
      kind == "line_sender_buffer_column_ts_micros" or
      kind == "line_sender_buffer_column_ts_nanos" then
    ok = fn(ptr, name_view, value, err_out)
  elseif kind == "line_sender_buffer_column_f64" then
    ok = fn(ptr, name_view, value, err_out)
  else
    return nil, errors.local_error("invalid_argument", "unsupported column API: " .. kind)
  end
  if ok then return true end
  return nil, native_error(lib, err_out)
end

local function call_timestamp(lib, fn, ptr, value)
  local err_out = ffi.new("line_sender_error*[1]")
  local ok = fn(ptr, value, err_out)
  if ok then return true end
  return nil, native_error(lib, err_out)
end

local function call_at_now(lib, ptr)
  local err_out = ffi.new("line_sender_error*[1]")
  local ok = lib.line_sender_buffer_at_now(ptr, err_out)
  if ok then return true end
  return nil, native_error(lib, err_out)
end

local function call_flush(lib, sender_ptr, buffer_ptr)
  local err_out = ffi.new("line_sender_error*[1]")
  local ok = lib.line_sender_flush(sender_ptr, buffer_ptr, err_out)
  if ok then return true end
  return nil, native_error(lib, err_out)
end

local function call_reserve(lib, ptr, additional)
  local err_out = ffi.new("line_sender_error*[1]")
  local ok = lib.line_sender_buffer_reserve(ptr, additional, err_out)
  if ok then return true end
  return nil, native_error(lib, err_out)
end

local function require_string(value, label)
  if type(value) ~= "string" then
    return nil, errors.local_error("invalid_argument", label .. " must be a string")
  end
  return value
end

local function make_view(self, kind, initializer, value, label)
  local text, err = require_string(value, label)
  if not text then return nil, err end
  local out = ffi.new(kind .. "[1]")
  local err_out = ffi.new("line_sender_error*[1]")
  local ok = initializer(out, #text, text, err_out)
  if not ok then return nil, native_error(self._lib, err_out) end
  return out[0], text
end

local function ensure_open(object, name)
  if object._closed or object._ptr == nil then
    return nil, errors.local_error("closed", name .. " is closed")
  end
  return true
end

function Buffer:_table(name)
  local ok, err = ensure_open(self, "buffer")
  if not ok then return nil, err end
  local view, keep = make_view(self, "line_sender_table_name",
    self._lib.line_sender_table_name_init, name, "table name")
  if not view then return nil, keep end
  self._keep = keep
  return call_table(self._lib, self._ptr, view)
end

function Buffer:_symbol(name, value)
  local ok, err = ensure_open(self, "buffer")
  if not ok then return nil, err end
  local name_view, name_keep = make_view(self, "line_sender_column_name",
    self._lib.line_sender_column_name_init, name, "column name")
  if not name_view then return nil, name_keep end
  local value_view, value_keep = make_view(self, "line_sender_utf8",
    self._lib.line_sender_utf8_init, value, "symbol value")
  if not value_view then return nil, value_keep end
  self._keep = { name_keep, value_keep }
  return call_symbol(self._lib, self._ptr, name_view, value_view)
end

function Buffer:_column(name, value, kind)
  local ok, err = ensure_open(self, "buffer")
  if not ok then return nil, err end
  local name_view, keep = make_view(self, "line_sender_column_name",
    self._lib.line_sender_column_name_init, name, "column name")
  if not name_view then return nil, keep end
  self._keep = keep
  return call_column(self._lib, kind, self._ptr, name_view, value)
end

function Buffer:_text_column(name, value)
  local ok, err = ensure_open(self, "buffer")
  if not ok then return nil, err end
  local name_view, name_keep = make_view(self, "line_sender_column_name",
    self._lib.line_sender_column_name_init, name, "column name")
  if not name_view then return nil, name_keep end
  local value_view, value_keep = make_view(self, "line_sender_utf8",
    self._lib.line_sender_utf8_init, value, "column value")
  if not value_view then return nil, value_keep end
  self._keep = { name_keep, value_keep }
  return call_text_column(self._lib, self._ptr, name_view, value_view)
end

function Buffer:table(name) return self:_table(name) end
function Buffer:symbol(name, value) return self:_symbol(name, value) end
function Buffer:string(name, value) return self:_text_column(name, value) end
function Buffer:bool(name, value)
  if type(value) ~= "boolean" then
    return nil, errors.local_error("invalid_argument", "boolean value required")
  end
  return self:_column(name, value, "line_sender_buffer_column_bool")
end
function Buffer:int64(name, value)
  if not (type(value) == "number" or type(value) == "string" or
      ffi.istype("int64_t", value) or ffi.istype("uint64_t", value)) then
    return nil, errors.local_error("invalid_argument", "int64 value required")
  end
  local ok, converted = pcall(function() return time.ns(value):raw() end)
  if not ok then return nil, errors.local_error("invalid_argument", converted) end
  return self:_column(name, converted, "line_sender_buffer_column_i64")
end
function Buffer:double(name, value)
  if type(value) ~= "number" then
    return nil, errors.local_error("invalid_argument", "double value required")
  end
  return self:_column(name, value, "line_sender_buffer_column_f64")
end

local function timestamp_column(self, name, value, target)
  if not time.is_timestamp(value) then
    return nil, errors.local_error("invalid_argument", "timestamp value required")
  end
  local ok, converted = pcall(function()
    if target == "ms" then return value:to_ms() end
    if target == "us" then return value:to_us() end
    return value:to_ns()
  end)
  if not ok then return nil, errors.local_error("invalid_timestamp", converted) end
  local kind = target == "ms" and "line_sender_buffer_column_date" or
    (target == "us" and "line_sender_buffer_column_ts_micros" or
      "line_sender_buffer_column_ts_nanos")
  return self:_column(name, converted:raw(), kind)
end

function Buffer:date(name, value) return timestamp_column(self, name, value, "ms") end
function Buffer:timestamp(name, value)
  if not time.is_timestamp(value) then
    return nil, errors.local_error("invalid_argument", "timestamp value required")
  end
  if value:unit() == "ns" then
    return timestamp_column(self, name, value, "ns")
  end
  return timestamp_column(self, name, value, "us")
end
function Buffer:timestamp_us(name, value) return timestamp_column(self, name, value, "us") end
function Buffer:timestamp_ns(name, value) return timestamp_column(self, name, value, "ns") end

function Buffer:at(value)
  local ok, err = ensure_open(self, "buffer")
  if not ok then return nil, err end
  if not time.is_timestamp(value) then
    return nil, errors.local_error("invalid_argument", "designated timestamp required")
  end
  local fn
  local converted
  local success, result = pcall(function()
    if value:unit() == "ns" then
      fn = self._lib.line_sender_buffer_at_nanos
      converted = value:raw()
    else
      fn = self._lib.line_sender_buffer_at_micros
      converted = value:to_us():raw()
    end
  end)
  if not success then return nil, errors.local_error("invalid_timestamp", result) end
  local result_ok, result_err = call_timestamp(self._lib, fn, self._ptr, converted)
  if result_ok then self._row_open = false end
  return result_ok, result_err
end

function Buffer:at_now()
  local ok, err = ensure_open(self, "buffer")
  if not ok then return nil, err end
  local result_ok, result_err = call_at_now(self._lib, self._ptr)
  if result_ok then self._row_open = false end
  return result_ok, result_err
end

function Buffer:flush()
  local ok, err = ensure_open(self, "buffer")
  if not ok then return nil, err end
  if self._sender._closed then
    return nil, errors.local_error("closed", "sender is closed")
  end
  local result_ok, result_err = call_flush(self._lib,
    self._sender._ptr, self._ptr)
  if result_ok then
    self._keep = nil
    self._row_open = false
  end
  return result_ok, result_err
end

function Buffer:clear()
  local ok, err = ensure_open(self, "buffer")
  if not ok then return nil, err end
  self._lib.line_sender_buffer_clear(self._ptr)
  self._keep = nil
  self._row_open = false
  return true
end

function Buffer:reserve(additional)
  local ok, err = ensure_open(self, "buffer")
  if not ok then return nil, err end
  if type(additional) ~= "number" or additional < 0 or additional % 1 ~= 0 then
    return nil, errors.local_error("invalid_argument", "reserve size must be a non-negative integer")
  end
  return call_reserve(self._lib, self._ptr, additional)
end

function Buffer:size()
  local ok, err = ensure_open(self, "buffer")
  if not ok then return nil, err end
  return tonumber(self._lib.line_sender_buffer_size(self._ptr))
end

function Buffer:row_count()
  local ok, err = ensure_open(self, "buffer")
  if not ok then return nil, err end
  return tonumber(self._lib.line_sender_buffer_row_count(self._ptr))
end

function Buffer:row(table_name)
  local row, err = Row.new(self, table_name)
  if not row then return nil, err end
  return row
end

function Buffer:close()
  if self._closed then return true end
  self._closed = true
  local ptr = self._ptr
  self._ptr = nil
  if ptr ~= nil then
    ffi.gc(ptr, nil)
    self._lib.line_sender_buffer_free(ptr)
  end
  self._keep = nil
  return true
end

function Row.new(buffer, table_name)
  local ok, err = buffer:_table(table_name)
  if not ok then return nil, err end
  return setmetatable({
    _buffer = buffer,
    _ended = false,
    _timestamped = false,
  }, Row)
end

local function row_call(self, method, ...)
  if self._ended then
    return nil, errors.local_error("invalid_api_call", "row is already complete")
  end
  return self._buffer[method](self._buffer, ...)
end

function Row:symbol(name, value) return row_call(self, "symbol", name, value) end
function Row:string(name, value) return row_call(self, "string", name, value) end
function Row:bool(name, value) return row_call(self, "bool", name, value) end
function Row:int64(name, value) return row_call(self, "int64", name, value) end
function Row:double(name, value) return row_call(self, "double", name, value) end
function Row:date(name, value) return row_call(self, "date", name, value) end
function Row:timestamp(name, value) return row_call(self, "timestamp", name, value) end
function Row:timestamp_us(name, value) return row_call(self, "timestamp_us", name, value) end
function Row:timestamp_ns(name, value) return row_call(self, "timestamp_ns", name, value) end

function Row:at(value)
  local ok, err = row_call(self, "at", value)
  if ok then self._timestamped = true end
  return ok, err
end

function Row:at_now()
  local ok, err = row_call(self, "at_now")
  if ok then self._timestamped = true end
  return ok, err
end

function Row:send()
  if self._ended then
    return nil, errors.local_error("invalid_api_call", "row is already complete")
  end
  if not self._timestamped then
    return nil, errors.local_error("invalid_timestamp", "call row:at() or row:at_now() before send()")
  end
  local ok, err = self._buffer:flush()
  if ok then self._ended = true end
  return ok, err
end

function Sender.new(options)
  if type(options) == "string" then options = { conf = options } end
  if type(options) ~= "table" then
    return nil, errors.local_error("invalid_argument", "sender options table or config string required")
  end
  if type(options.conf) ~= "string" then
    return nil, errors.local_error("invalid_argument", "sender.conf must be a config string")
  end

  local loaded, lib = pcall(native.load, options.lib or options.library)
  if not loaded then
    return nil, errors.local_error("library", tostring(lib))
  end
  local config, keep_or_err = make_view({ _lib = lib }, "line_sender_utf8",
    lib.line_sender_utf8_init, options.conf, "sender config")
  if not config then return nil, keep_or_err end
  local err_out = ffi.new("line_sender_error*[1]")
  local ptr = lib.line_sender_from_conf(config, err_out)
  if ptr == nil then return nil, native_error(lib, err_out) end

  local sender = setmetatable({
    _lib = lib,
    _ptr = ptr,
    _closed = false,
    _config_keep = keep_or_err,
    _buffer = nil,
  }, Sender)
  ffi.gc(ptr, function(p)
    if p ~= nil then lib.line_sender_close(p) end
  end)
  if options.reserve then
    local buffer, err = sender:buffer()
    if not buffer then sender:close(); return nil, err end
    local ok, reserve_err = buffer:reserve(options.reserve)
    if not ok then sender:close(); return nil, reserve_err end
  end
  return sender
end

function Sender:buffer()
  local ok, err = ensure_open(self, "sender")
  if not ok then return nil, err end
  if self._buffer and not self._buffer._closed then return self._buffer end
  local ptr = self._lib.line_sender_buffer_new_for_sender(self._ptr)
  if ptr == nil then
    return nil, errors.local_error("allocation", "unable to create line sender buffer")
  end
  local buffer = setmetatable({
    _lib = self._lib,
    _ptr = ptr,
    _sender = self,
    _closed = false,
    _keep = nil,
    _row_open = false,
  }, Buffer)
  ffi.gc(ptr, function(p)
    if p ~= nil then self._lib.line_sender_buffer_free(p) end
  end)
  self._buffer = buffer
  return buffer
end

function Sender:row(table_name)
  local buffer, err = self:buffer()
  if not buffer then return nil, err end
  return buffer:row(table_name)
end

function Sender:flush()
  local buffer, err = self:buffer()
  if not buffer then return nil, err end
  return buffer:flush()
end

function Sender:must_close()
  if self._closed then return true end
  return self._lib.line_sender_must_close(self._ptr) and true or false
end

function Sender:close()
  if self._closed then return true end
  self._closed = true
  if self._buffer then self._buffer:close() end
  local ptr = self._ptr
  self._ptr = nil
  if ptr ~= nil then
    ffi.gc(ptr, nil)
    self._lib.line_sender_close(ptr)
  end
  self._config_keep = nil
  return true
end

return {
  Sender = Sender,
  Buffer = Buffer,
  Row = Row,
  new = Sender.new,
}
