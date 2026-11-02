-- Live write/read integration test against a running QuestDB.
--
--   QUESTDB_TEST_HTTP=localhost:9000          server to test against (default)
--   QUESTDB_TEST_TABLE_PREFIX=luajit_it       prefix for the tables it creates
--
-- Safe to point at a server holding other data: every table gets a name unique
-- to this run, creation fails rather than reusing a table that already exists,
-- and only tables this run created are ever dropped.
--
-- An unreachable server is a failure, not a skip. This file is only run on
-- request (`make integration`), and a skipped test must not read as a pass.

local qdb = require "questdb"
local json = require "minijson"

local host = os.getenv("QUESTDB_TEST_HTTP") or "localhost:9000"
local prefix = os.getenv("QUESTDB_TEST_TABLE_PREFIX") or "luajit_it"

-- Both end up in a shell command or in SQL.
assert(host:match("^[%w%.%-]+:%d+$"), "QUESTDB_TEST_HTTP must be host:port, got: " .. host)
assert(prefix:match("^[%a_][%w_]*$"), "invalid QUESTDB_TEST_TABLE_PREFIX: " .. prefix)

local function exec(sql)
  local query = sql:gsub("[^%w ]", function(c)
    return string.format("%%%02X", c:byte())
  end):gsub(" ", "+")
  local pipe = assert(io.popen(string.format(
    "curl -sS -m 10 'http://%s/exec?query=%s' 2>&1", host, query)))
  local body = pipe:read("*a")
  pipe:close()
  local ok, decoded = pcall(json.decode, body)
  if not ok then error("unreadable response to [" .. sql .. "]: " .. body, 2) end
  return decoded
end

local function must_exec(sql)
  local result = exec(sql)
  if result.error then error("[" .. sql .. "] failed: " .. result.error, 2) end
  return result
end

local probe_ok, probe = pcall(exec, "select build()")
if not probe_ok or not probe.dataset then
  error("no QuestDB reachable at " .. host .. ": " .. tostring(probe), 0)
end
print("integration test against " .. host .. ": " .. tostring(probe.dataset[1][1]))

----------------------------------------------------------------------
-- Tables owned by this run
----------------------------------------------------------------------
math.randomseed(os.time())
local run_id = string.format("%d_%06d", os.time(), math.random(0, 999999))
local created = {}

local function create_table(suffix, columns)
  local name = prefix .. "_" .. run_id .. "_" .. suffix
  -- Deliberately no IF NOT EXISTS: a name collision must stop the test.
  must_exec("CREATE TABLE " .. name .. " (" .. columns ..
    ") TIMESTAMP(ts) PARTITION BY DAY WAL")
  created[#created + 1] = name
  return name
end

local function drop_created()
  local all_dropped = true
  for _, name in ipairs(created) do
    local result = exec("DROP TABLE " .. name)
    if result.error then
      all_dropped = false
      io.stderr:write("warning: could not drop " .. name .. ": " .. result.error .. "\n")
    end
  end
  return all_dropped
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function assert_equal(actual, expected, what)
  if actual ~= expected then
    error(what .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected), 2)
  end
end

-- HTTP ILP returns once the server has accepted the rows; WAL tables make them
-- visible to queries a moment later.
local function wait_for_rows(name, expected)
  local deadline = os.time() + 20
  local count
  repeat
    count = must_exec("select count() from " .. name).dataset[1][1]
    if count >= expected then break end
    os.execute("sleep 0.2")
  until os.time() > deadline
  assert_equal(count, expected, "row count of " .. name)
end

local function new_sender()
  return assert(qdb.sender { conf = "http::addr=" .. host .. ";" })
end

----------------------------------------------------------------------
-- Every column type, one row per send
----------------------------------------------------------------------
local function test_all_types()
  local name = create_table("types",
    "sym SYMBOL, price DOUBLE, qty LONG, note STRING, active BOOLEAN, " ..
    "created DATE, event_us TIMESTAMP, event_ns TIMESTAMP_NS, ts TIMESTAMP")
  local sender = new_sender()

  local rows = {
    { "BTC-USD", 42000.25, 2, "first", true, "1700000000123000",
      "1700000000123456", "1700000000123456789", "1700000000123456" },
    { "ETH-USD", 1800.5, "9007199254740993", "second \"quoted\"", false, "1700000001123000",
      "1700000001123456", "1700000001123456789", "1700000001123456" },
  }
  for _, spec in ipairs(rows) do
    local row = assert(sender:row(name))
    assert(row:symbol("sym", spec[1]))
    assert(row:double("price", spec[2]))
    assert(row:int64("qty", spec[3]))
    assert(row:string("note", spec[4]))
    assert(row:bool("active", spec[5]))
    -- row:date() is QWP-only; over ILP a DATE column takes a timestamp field.
    assert(row:timestamp_us("created", qdb.time.us(spec[6])))
    assert(row:timestamp("event_us", qdb.time.us(spec[7])))
    assert(row:timestamp_ns("event_ns", qdb.time.ns(spec[8])))
    assert(row:at(qdb.time.us(spec[9])))
    assert(row:send())
  end
  sender:close()

  wait_for_rows(name, #rows)

  local data = must_exec("select sym, price, qty::string, note, active, created, " ..
    "event_us, event_ns, ts from " .. name .. " order by ts").dataset
  local expected = {
    { "BTC-USD", 42000.25, "2", "first", true, "2023-11-14T22:13:20.123Z",
      "2023-11-14T22:13:20.123456Z", "2023-11-14T22:13:20.123456789Z",
      "2023-11-14T22:13:20.123456Z" },
    { "ETH-USD", 1800.5, "9007199254740993", "second \"quoted\"", false,
      "2023-11-14T22:13:21.123Z", "2023-11-14T22:13:21.123456Z",
      "2023-11-14T22:13:21.123456789Z", "2023-11-14T22:13:21.123456Z" },
  }
  assert_equal(#data, #expected, "rows read back")
  for i, row in ipairs(expected) do
    for column, value in ipairs(row) do
      assert_equal(data[i][column], value, "row " .. i .. " column " .. column)
    end
  end
end

----------------------------------------------------------------------
-- A batch: every row must arrive, not just the first
----------------------------------------------------------------------
local function test_batch()
  local name = create_table("batch", "sym SYMBOL, qty LONG, ts TIMESTAMP")
  local sender = new_sender()
  local buffer = assert(sender:buffer())

  local total = 250
  local function batch_ts(i)
    return qdb.time.from_unix(1700000000 + i % 60, i, "us")
  end
  for i = 1, total do
    local row = assert(buffer:row(name))
    assert(row:symbol("sym", "S" .. (i % 7)))
    assert(row:int64("qty", i))
    assert(row:at(batch_ts(i)))
  end
  assert_equal(buffer:row_count(), total, "buffered rows")
  assert(buffer:flush())
  assert_equal(buffer:row_count(), 0, "rows after flush")

  -- The buffer is reusable after a flush.
  local extra = assert(buffer:row(name))
  assert(extra:symbol("sym", "extra"))
  assert(extra:int64("qty", total + 1))
  assert(extra:at(qdb.time.from_unix(1700000000, total + 1, "us")))
  assert(buffer:flush())
  sender:close()

  wait_for_rows(name, total + 1)

  local data = must_exec("select qty, sym, ts from " .. name .. " order by qty").dataset
  assert_equal(#data, total + 1, "rows read back")
  for i = 1, total do
    assert_equal(data[i][1], i, "batch qty")
    assert_equal(data[i][2], "S" .. (i % 7), "batch sym")
    assert_equal(data[i][3], batch_ts(i):to_string(), "batch ts")
  end
  assert_equal(data[total + 1][2], "extra", "row sent after the first flush")
end

----------------------------------------------------------------------
-- Designated nanosecond timestamps keep all nine digits
----------------------------------------------------------------------
local function test_designated_nanos()
  local name = create_table("nanos", "qty LONG, ts TIMESTAMP_NS")
  local sender = new_sender()
  local row = assert(sender:row(name))
  assert(row:int64("qty", 1))
  assert(row:at(qdb.time.ns("1700000000123456789")))
  assert(row:send())
  row = assert(sender:row(name))
  assert(row:int64("qty", 2))
  assert(row:at(qdb.time.parse_rfc3339("2023-11-14T22:13:21.000000001Z")))
  assert(row:send())
  sender:close()

  wait_for_rows(name, 2)
  local data = must_exec("select ts from " .. name .. " order by ts").dataset
  assert_equal(data[1][1], "2023-11-14T22:13:20.123456789Z", "first designated ns")
  assert_equal(data[2][1], "2023-11-14T22:13:21.000000001Z", "second designated ns")
end

----------------------------------------------------------------------
-- Server rejection: reported, not retried behind the caller's back
----------------------------------------------------------------------
local function test_server_rejection()
  local name = create_table("reject", "qty LONG, ts TIMESTAMP")
  local sender = new_sender()

  local bad = assert(sender:row(name))
  assert(bad:string("qty", "not a number"))
  assert(bad:at(qdb.time.us(1700000000000000)))
  local ok, err = bad:send()
  assert(ok == nil, "the server must reject a string in a LONG column")
  assert_equal(err.code, "server_flush_error", "rejection error code: " .. tostring(err))
  assert_equal(err.in_doubt, false, "a rejected batch was definitely not stored")
  assert(err.message ~= "", "the server's reason must reach the caller")

  -- The rows stay queued until the caller decides; dropping them recovers.
  local buffer = assert(sender:buffer())
  assert_equal(buffer:row_count(), 1, "rows kept after a rejection")
  assert(buffer:clear())
  assert(bad:send() == nil, "a cleared row must not be sendable")

  local good = assert(sender:row(name))
  assert(good:int64("qty", 7))
  assert(good:at(qdb.time.us(1700000000000001)))
  assert(good:send())
  sender:close()

  wait_for_rows(name, 1)
  assert_equal(must_exec("select qty from " .. name).dataset[1][1], 7, "row after rejection")
end

----------------------------------------------------------------------
-- Run, always removing what this run created
----------------------------------------------------------------------
local tests = {
  { "all column types", test_all_types },
  { "batch", test_batch },
  { "designated nanoseconds", test_designated_nanos },
  { "server rejection", test_server_rejection },
}

local failures = 0
for _, test in ipairs(tests) do
  local ok, err = xpcall(test[2], debug.traceback)
  print((ok and "ok    " or "FAIL  ") .. test[1])
  if not ok then
    failures = failures + 1
    io.stderr:write(tostring(err) .. "\n")
  end
end

local dropped = drop_created()
if not dropped then failures = failures + 1 end

if failures > 0 then
  io.stderr:write("integration test failed\n")
  os.exit(1)
end
print("integration test passed")
