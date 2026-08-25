local qdb = require "questdb"

local conf = os.getenv("QUESTDB_CLIENT_CONF") or "http::addr=localhost:9000;"
local sender, err = qdb.sender { conf = conf }
assert(sender, tostring(err))

local row
row, err = sender:row("trades")
if not row then
  sender:close()
  error(tostring(err))
end

local function must(ok, operation_error)
  if not ok then
    sender:close()
    error(tostring(operation_error))
  end
end

must(row:symbol("sym", "BTC-USD"))
must(row:double("price", 42000.25))
must(row:int64("qty", 2))
-- This example uses TIMESTAMP (microseconds), which is supported by QuestDB 8.x.
-- Use qdb.time.ns(...) only when the table column is TIMESTAMP_NANOS.
must(row:at(qdb.time.us("1700000000123456")))
must(row:send())
sender:close()

print("row sent")
