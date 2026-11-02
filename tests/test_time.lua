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

-- 2^53 itself is not safe: 2^53 + 1 rounds to it before the check can see it.
assert_equal(time.us(9007199254740991):raw(), time.us("9007199254740991"):raw())
assert_equal(time.us(-9007199254740991):raw(), time.us("-9007199254740991"):raw())
assert_error(function() time.us(2^53) end, "2^53 must be rejected")
assert_error(function() time.us(-2^53) end, "-2^53 must be rejected")
assert_error(function() time.us(9007199254740993) end, "2^53 + 1 must be rejected")
assert_error(function() time.us(1.5) end, "fractions must be rejected")
assert_error(function() time.us(0/0) end, "NaN must be rejected")
assert_error(function() time.us(1/0) end, "infinity must be rejected")

-- Each input form reaches the same value.
local from_cdata = time.ns(ns:raw())
assert_equal(from_cdata:raw(), ns:raw())
assert_equal(time.from_unix(1700000000, 123456789, "ns"):raw(), ns:raw())
assert_equal(time.parse_rfc3339("2023-11-14T22:13:20.123456789Z"):raw(), ns:raw())

-- The whole int64 nanosecond range is reachable from every constructor.
local NS_MIN, NS_MAX = "-9223372036854775808", "9223372036854775807"
assert_equal(tostring(time.parse_rfc3339("1677-09-21T00:12:43.145224192Z"):raw()),
  NS_MIN .. "LL")
assert_equal(tostring(time.parse_rfc3339("2262-04-11T23:47:16.854775807Z"):raw()),
  NS_MAX .. "LL")
assert_equal(tostring(time.from_unix(-9223372037, 145224192, "ns"):raw()), NS_MIN .. "LL")
assert_equal(tostring(time.from_unix(9223372036, 854775807, "ns"):raw()), NS_MAX .. "LL")
assert_error(function() time.parse_rfc3339("1677-09-21T00:12:43.145224191Z") end,
  "one below the nanosecond range must be rejected")
assert_error(function() time.parse_rfc3339("2262-04-11T23:47:16.854775808Z") end,
  "one above the nanosecond range must be rejected")
assert_error(function() time.from_unix(-9223372037, 145224191, "ns") end,
  "one below the nanosecond range must be rejected")
assert_error(function() time.from_unix(9223372036, 854775808, "ns") end,
  "one above the nanosecond range must be rejected")

-- The target unit decides the range, not an intermediate nanosecond value.
assert_equal(time.parse_rfc3339("2500-01-01T00:00:00Z", { unit = "us" }):raw(),
  time.from_unix(16725225600, 0, "us"):raw())
assert_equal(time.parse_rfc3339("2500-01-01T00:00:00.123Z", { unit = "ms" }):to_string(),
  "2500-01-01T00:00:00.123Z")
assert_equal(time.parse_rfc3339("1500-01-01T00:00:00.5Z", { unit = "us" }):to_string(),
  "1500-01-01T00:00:00.500000Z")
assert_error(function() time.parse_rfc3339("2500-01-01T00:00:00Z") end,
  "2500 does not fit nanoseconds")

-- Fractions reduce the same way as the equivalent to_us()/to_ms() conversion,
-- including across the epoch and when rounding carries into the next second.
local reduction_inputs = {
  "1970-01-01T00:00:00.000000500Z",
  "1970-01-01T00:00:00.000000499Z",
  "1970-01-01T00:00:00.000000501Z",
  "1970-01-01T00:00:00.999999500Z",
  "1969-12-31T23:59:59.999999500Z",
  "1969-12-31T23:59:59.999999499Z",
  "1969-12-31T23:59:59.999999501Z",
  "1969-12-31T23:59:59.000000500Z",
  "1969-12-31T23:59:59.999999999Z",
  "2024-02-29T12:34:56.123456789+08:00",
  "1900-06-15T01:02:03.999999999-05:00",
}
for _, text in ipairs(reduction_inputs) do
  local exact = time.parse_rfc3339(text)
  for _, mode in ipairs({ "truncate", "floor", "round" }) do
    assert_equal(time.parse_rfc3339(text, { unit = "us", precision = mode }):raw(),
      exact:to_us { mode = mode }:raw(), text .. " us/" .. mode)
    assert_equal(time.parse_rfc3339(text, { unit = "ms", precision = mode }):raw(),
      exact:to_ms { mode = mode }:raw(), text .. " ms/" .. mode)
  end
  assert_error(function() time.parse_rfc3339(text, { unit = "us" }) end,
    "exact parsing must reject a remainder: " .. text)
end
assert_equal(time.parse_rfc3339("1970-01-01T00:00:00.9999995Z",
  { unit = "us", precision = "round" }):raw(), 1000000)
assert_equal(time.parse_rfc3339("1970-01-01T00:00:00.123Z", { unit = "ms" }):raw(), 123)
assert_error(function()
  time.parse_rfc3339("1970-01-01T00:00:00.1234Z", { unit = "ms", precision = "bogus" })
end, "unknown precision modes must be rejected")
assert_error(function() time.parse_rfc3339("1970-01-01T00:00:00Z", { unit = "s" }) end,
  "unknown units must be rejected")

-- Invalid dates and offsets.
for _, text in ipairs({
  "2023-02-29T00:00:00Z", "2024-13-01T00:00:00Z", "2024-01-01T24:00:00Z",
  "2024-01-01T00:00:00", "2024-01-01T00:00:00+24:00", "2024-01-01T00:00:00.1234567890Z",
  "1700000000", "",
}) do
  assert_error(function() time.parse_rfc3339(text) end, "must be rejected: " .. text)
end

-- Unit conversions check for overflow in both directions.
assert_error(function() time.ms(NS_MAX):to_us() end, "ms -> us must detect overflow")
assert_error(function() time.us(NS_MIN):to_ns() end, "us -> ns must detect overflow")
assert_equal(time.ms(1):to_ns():raw(), 1000000)
assert_equal(time.ns(NS_MIN):to_us { mode = "floor" }:raw(),
  time.us("-9223372036854776"):raw())

-- Timestamps are immutable values.
local fixed = time.ns("1000")
assert_error(function() fixed._value = 5000 end, "internal state must not be writable")
assert_error(function() fixed._unit = 1 end, "internal state must not be writable")
assert_error(function() fixed.extra = true end, "new fields must be rejected")
assert_equal(fixed:raw(), 1000)
assert_equal(fixed:unit(), "ns")

assert(time.is_timestamp(fixed))
assert(not time.is_timestamp({}))
assert(not time.is_timestamp(1))
assert(not time.is_timestamp(nil))
assert(not time.is_timestamp(fixed:raw()))
assert(fixed == time.ns(1000))
assert(fixed ~= time.ns(1001))
assert(fixed ~= time.us(1000), "the same integer in another unit is a different value")
assert(fixed ~= nil)
assert(fixed ~= "1000")
assert_equal(tostring(time.us(0)), "1970-01-01T00:00:00.000000Z")
assert_equal(time.us(0):to_string { trim = true }, "1970-01-01T00:00:00Z")
assert_equal(time.us(1700000000123456):to_number(), 1700000000123456)
assert_error(function() time.ns(NS_MAX):to_number() end,
  "to_number must reject a value a double cannot hold")

print("time tests passed")
