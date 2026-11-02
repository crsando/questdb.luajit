-- Row/buffer lifecycle and failure semantics. No server is needed: the sender
-- points at a closed port and only fails once a flush is attempted.

local qdb = require "questdb"
local time = qdb.time

-- An explicit protocol_version skips HTTP auto-detection, which would otherwise
-- connect while the sender is being created.
local OFFLINE_CONF = "http::addr=127.0.0.1:1;protocol_version=2;retry_timeout=0;"

local function new_buffer()
  local sender = assert(qdb.sender { conf = OFFLINE_CONF })
  return assert(sender:buffer()), sender
end

local function assert_rejected(code, ok, err)
  assert(ok == nil, "operation must be rejected")
  assert(err and err.code == code,
    "expected error " .. code .. ", got " .. tostring(err and err.code))
end

-- Replaces the network call: clears the buffer like a successful flush does.
local function stub_successful_flush(buffer)
  local real = buffer._lib
  local flushed = { count = 0 }
  buffer._lib = setmetatable({
    line_sender_flush = function(_, ptr)
      flushed.count = flushed.count + 1
      real.line_sender_buffer_clear(ptr)
      return true
    end,
  }, { __index = real })
  return flushed
end

----------------------------------------------------------------------
-- A completed row must not reach into the row that follows it
----------------------------------------------------------------------
do
  local buffer, sender = new_buffer()
  local first = assert(buffer:row("one"))
  assert(first:int64("x", 1))
  assert(first:at(time.us(1)))

  assert_rejected("invalid_api_call", first:int64("late", 1))
  assert_rejected("invalid_api_call", first:at(time.us(2)))

  local before = buffer:size()
  local second = assert(buffer:row("two"))
  assert(second:int64("x", 2))
  local size_with_second = buffer:size()
  assert(size_with_second > before)

  assert_rejected("invalid_api_call", first:int64("stale", 99))
  assert_rejected("invalid_api_call", first:at_now())
  assert_rejected("invalid_api_call", first:send())
  assert(buffer:size() == size_with_second, "a stale row must not write anything")
  assert(buffer:row_count() == 1, "a stale row must not complete the open row")

  assert(second:at(time.us(2)))
  assert(buffer:row_count() == 2)
  sender:close()
end

----------------------------------------------------------------------
-- row:send() covers one row; buffer:flush() covers the batch
----------------------------------------------------------------------
do
  local buffer, sender = new_buffer()
  local flushed = stub_successful_flush(buffer)

  local first = assert(buffer:row("batch"))
  assert(first:int64("x", 1))
  assert(first:at(time.us(1)))
  local second = assert(buffer:row("batch"))
  assert(second:int64("x", 2))
  assert(second:at(time.us(2)))

  assert_rejected("invalid_api_call", second:send())
  assert(flushed.count == 0, "row:send() must not flush someone else's rows")
  assert(buffer:row_count() == 2)

  assert(buffer:flush())
  assert(flushed.count == 1)
  assert(buffer:row_count() == 0)
  assert_rejected("invalid_api_call", second:at_now())

  -- The usual one-row flow, and reuse of the buffer afterwards.
  for i = 1, 2 do
    local row = assert(sender:row("single"))
    assert(row:int64("x", i))
    assert_rejected("invalid_timestamp", row:send())
    assert(row:at(time.us(i)))
    assert(row:send())
    assert_rejected("invalid_api_call", row:send())
    assert_rejected("invalid_api_call", row:int64("late", 1))
  end
  assert(flushed.count == 3)
  sender:close()
end

----------------------------------------------------------------------
-- clear() and close() retire every outstanding row
----------------------------------------------------------------------
do
  local buffer, sender = new_buffer()
  local row = assert(buffer:row("cleared"))
  assert(row:int64("x", 1))
  assert(buffer:clear())
  assert_rejected("invalid_api_call", row:int64("y", 2))
  assert_rejected("invalid_api_call", row:at_now())

  local open = assert(buffer:row("closed"))
  sender:close()
  assert_rejected("closed", open:int64("y", 2))
  assert_rejected("closed", open:at_now())
  assert_rejected("closed", open:send())
  assert_rejected("closed", buffer:flush())
  assert_rejected("closed", sender:row("after_close"))
  assert(sender:close(), "close must stay idempotent")
  assert(buffer:close(), "close must stay idempotent")
end

----------------------------------------------------------------------
-- Upstream's own row-order rules still surface as errors, not crashes
----------------------------------------------------------------------
do
  local buffer, sender = new_buffer()
  local row = assert(buffer:row("order"))
  assert(row:int64("x", 1))

  assert_rejected("invalid_api_call", buffer:row("second_open_row"))
  assert_rejected("invalid_api_call", buffer:flush())
  assert(row:int64("y", 2), "a failed row start must not retire the open row")

  assert_rejected("invalid_api_call", row:symbol("sym", "symbols come first"))
  assert_rejected("invalid_name", row:int64("bad/name", 1))
  -- Upstream only offers DATE columns over QWP; this sender speaks ILP.
  assert_rejected("invalid_api_call", row:date("created", time.ms(1)))
  assert(row:at(time.us(1)), "a rejected field must leave the row usable")

  assert_rejected("invalid_name", buffer:row("bad/table?"))
  sender:close()
end

----------------------------------------------------------------------
-- Argument validation happens before the C ABI
----------------------------------------------------------------------
do
  local buffer, sender = new_buffer()
  local row = assert(buffer:row("args"))
  assert_rejected("invalid_argument", row:bool("b", "yes"))
  assert_rejected("invalid_argument", row:double("d", "1.0"))
  assert_rejected("invalid_argument", row:int64("i", {}))
  assert_rejected("invalid_argument", row:int64("i", 1.5))
  assert_rejected("invalid_argument", row:string("s", 1))
  assert_rejected("invalid_argument", row:timestamp("t", 1700000000))
  assert_rejected("invalid_argument", row:at(1700000000))
  assert_rejected("invalid_argument", buffer:reserve(-1))
  assert_rejected("invalid_argument", buffer:row(nil))
  sender:close()

  assert_rejected("invalid_argument", qdb.sender(nil))
  assert_rejected("invalid_argument", qdb.sender { conf = 1 })
  assert_rejected("config_error", qdb.sender { conf = "nonsense::addr=localhost:9000;" })
end

----------------------------------------------------------------------
-- A failed flush keeps the data and reports it faithfully
----------------------------------------------------------------------
do
  local buffer, sender = new_buffer()
  local row = assert(buffer:row("unreachable"))
  assert(row:int64("x", 1))
  assert(row:at(time.us(1)))

  local ok, err = row:send()
  assert(ok == nil, "flushing to a closed port must fail")
  assert(err.code == "socket_error", "unexpected failure: " .. tostring(err))
  assert(type(err.in_doubt) == "boolean")
  assert(type(err.native_code) == "number")
  assert(type(err.message) == "string" and err.message ~= "")
  assert(tostring(err):find("socket_error", 1, true))

  assert(buffer:row_count() == 1, "a failed flush must keep the rows")
  assert(sender:must_close() == false, "ILP over HTTP never latches a failure")

  -- The caller decides whether to retry: the row stays sendable.
  local retried, retry_err = row:send()
  assert(retried == nil and retry_err.code == "socket_error")
  assert(buffer:clear())
  assert(buffer:row_count() == 0)
  assert_rejected("invalid_api_call", row:send())
  sender:close()
  assert(sender:must_close() == true)
end

----------------------------------------------------------------------
-- The GC fallback must actually be able to run
----------------------------------------------------------------------
do
  local alive = setmetatable({}, { __mode = "v" })
  do
    local buffer, sender = new_buffer()
    alive.buffer, alive.sender = buffer, sender
  end
  for _ = 1, 4 do collectgarbage("collect") end
  assert(alive.buffer == nil and alive.sender == nil,
    "an abandoned sender/buffer pair must be collectable")
end

print("row tests passed")
