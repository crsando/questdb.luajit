local time = require "questdb.time"

local function assert_equal(actual, expected, message)
  assert(actual == expected, (message or "values differ") ..
    ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
end

local function assert_error(fn, message)
  local ok = pcall(fn)
  assert(not ok, message or "expected an error")
end

assert_equal(time.ms(0):to_string(), "1970-01-01T00:00:00.000Z")
assert_equal(time.us(0):to_string(), "1970-01-01T00:00:00.000000Z")
assert_equal(time.ns(-1):to_string(), "1969-12-31T23:59:59.999999999Z")

local ns = time.ns("1700000000123456789")
assert_equal(tostring(ns:raw()), "1700000000123456789LL")
assert_equal(ns:to_string(), "2023-11-14T22:13:20.123456789Z")
assert_error(function() time.ns(1700000000123456789) end,
  "unsafe Lua number must be rejected")

assert_equal(time.parse_rfc3339("1970-01-01T08:00:00+08:00"):raw(), 0)
assert_equal(time.parse_rfc3339("2024-02-29T12:34:56.123456Z"):to_string(),
  "2024-02-29T12:34:56.123456000Z")
assert_equal(time.parse_rfc3339("2024-02-29T12:34:56.123456789+08:00"):to_string(),
  "2024-02-29T04:34:56.123456789Z")

assert_error(function() ns:to_us() end,
  "exact down-conversion must reject a remainder")
assert_equal(ns:to_us { mode = "truncate" }:raw(), 1700000000123456)
assert_equal(time.ns("-1500"):to_us { mode = "truncate" }:raw(), -1)
assert_equal(time.ns("-1500"):to_us { mode = "floor" }:raw(), -2)
assert_equal(time.ns("1500"):to_us { mode = "round" }:raw(), 2)
assert_equal(time.ns("-1500"):to_us { mode = "round" }:raw(), -2)

assert_equal(time.ns("9223372036854775807"):to_string(),
  "2262-04-11T23:47:16.854775807Z")
assert_equal(time.ns("-9223372036854775808"):to_string(),
  "1677-09-21T00:12:43.145224192Z")
assert_error(function() time.ns("9223372036854775808") end,
  "int64 overflow must be rejected")

print("time tests passed")
