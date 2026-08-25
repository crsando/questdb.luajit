local ffi = require "ffi"
local native = require "questdb.native"

local M = {}
local Timestamp = {}
Timestamp.__index = Timestamp

local ZERO = ffi.new("int64_t", 0)
local ONE = ffi.new("int64_t", 1)
local MAX_I64 = nil
local MIN_I64 = nil

local function parse_u64_digits(digits)
  local value = ffi.new("uint64_t", 0)
  for i = 1, #digits do
    value = value * 10 + (digits:byte(i) - 48)
  end
  return value
end

MAX_I64 = ffi.cast("int64_t", parse_u64_digits("9223372036854775807"))
MIN_I64 = ffi.cast("int64_t", parse_u64_digits("9223372036854775808"))

local MAX_SAFE_NUMBER = 9007199254740992 -- 2^53; inclusive

local units = {
  ms = {
    scale = parse_u64_digits("1000"),
    per_day = parse_u64_digits("86400000"),
    digits = 3,
  },
  us = {
    scale = parse_u64_digits("1000000"),
    per_day = parse_u64_digits("86400000000"),
    digits = 6,
  },
  ns = {
    scale = parse_u64_digits("1000000000"),
    per_day = parse_u64_digits("86400000000000"),
    digits = 9,
  },
}

for _, spec in pairs(units) do
  spec.scale = ffi.cast("int64_t", spec.scale)
  spec.per_day = ffi.cast("int64_t", spec.per_day)
end

local function fail(message, level)
  error("questdb time: " .. message, (level or 1) + 1)
end

local function decimal_string(value)
  local text = tostring(value)
  local digits = text:match("^([+-]?%d+)")
  if not digits then
    fail("invalid integer cdata: " .. text, 3)
  end
  return digits
end

local function strip_leading_zeroes(text)
  local sign = ""
  if text:sub(1, 1) == "+" or text:sub(1, 1) == "-" then
    sign = text:sub(1, 1)
    text = text:sub(2)
  end
  text = text:gsub("^0+", "")
  if text == "" then text = "0" end
  return sign, text
end

local function compare_digits(a, b)
  a = a:gsub("^0+", "")
  b = b:gsub("^0+", "")
  if a == "" then a = "0" end
  if b == "" then b = "0" end
  if #a ~= #b then return #a < #b and -1 or 1 end
  if a == b then return 0 end
  return a < b and -1 or 1
end

local function parse_integer(value)
  local kind = type(value)
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge or
        value % 1 ~= 0 or math.abs(value) > MAX_SAFE_NUMBER then
      fail("Lua number is not a safe integer; use a decimal string or int64_t cdata", 3)
    end
    return ffi.new("int64_t", value)
  end

  if ffi.istype("int64_t", value) then
    return ffi.cast("int64_t", value)
  end

  if ffi.istype("uint64_t", value) then
    value = decimal_string(value)
  elseif kind == "string" then
    value = value
  else
    fail("expected integer number, decimal string, or int64_t cdata", 3)
  end

  if not value:match("^[+-]?%d+$") then
    fail("invalid decimal integer: " .. tostring(value), 3)
  end
  local sign, digits = strip_leading_zeroes(value)
  local limit = sign == "-" and "9223372036854775808" or "9223372036854775807"
  if compare_digits(digits, limit) > 0 then
    fail("integer outside signed int64 range: " .. value, 3)
  end
  local magnitude = parse_u64_digits(digits)
  if sign == "-" then
    if digits == "9223372036854775808" then
      return ffi.cast("int64_t", magnitude)
    end
    return -ffi.cast("int64_t", magnitude)
  end
  return ffi.cast("int64_t", magnitude)
end

local function unit_spec(unit)
  local spec = units[unit]
  if not spec then fail("unsupported unit: " .. tostring(unit), 3) end
  return spec
end

local function checked_mul(value, factor)
  if value > ZERO and value > MAX_I64 / factor then
    fail("timestamp conversion overflow", 4)
  end
  if value < ZERO and value < MIN_I64 / factor then
    fail("timestamp conversion overflow", 4)
  end
  return value * factor
end

local function checked_add(a, b)
  if b > ZERO and a > MAX_I64 - b then fail("timestamp conversion overflow", 4) end
  if b < ZERO and a < MIN_I64 - b then fail("timestamp conversion overflow", 4) end
  return a + b
end

local function floor_div(value, divisor)
  local quotient = value / divisor
  local remainder = value % divisor
  if remainder < ZERO then
    quotient = quotient - ONE
    remainder = remainder + divisor
  end
  return quotient, remainder
end

local function days_from_civil(year, month, day)
  year = year - (month <= 2 and 1 or 0)
  local era = math.floor(year / 400)
  local yoe = year - era * 400
  local month_prime = month + (month > 2 and -3 or 9)
  local doy = math.floor((153 * month_prime + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(days)
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) +
    math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local year = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local month_prime = math.floor((5 * doy + 2) / 153)
  local day = doy - math.floor((153 * month_prime + 2) / 5) + 1
  local month = month_prime + (month_prime < 10 and 3 or -9)
  year = year + (month <= 2 and 1 or 0)
  return year, month, day
end

local function format_year(year)
  if year >= 0 then return string.format("%04d", year) end
  return "-" .. string.format("%04d", -year)
end

local function format_timestamp(self, options)
  options = options or {}
  local spec = unit_spec(self._unit)
  local days, day_remainder = floor_div(self._value, spec.per_day)
  local seconds = day_remainder / spec.scale
  local fraction = day_remainder % spec.scale
  local day_number = tonumber(days)
  local second_number = tonumber(seconds)
  local fraction_number = tonumber(fraction)
  local year, month, day = civil_from_days(day_number)
  local hour = math.floor(second_number / 3600)
  local minute = math.floor((second_number % 3600) / 60)
  local second = second_number % 60
  local fraction_text = string.format("%0" .. spec.digits .. "d", fraction_number)
  if options.trim then
    fraction_text = fraction_text:gsub("0+$", "")
  end
  local suffix = fraction_text ~= "" and ("." .. fraction_text) or ""
  return string.format("%s-%02d-%02dT%02d:%02d:%02d%sZ",
    format_year(year), month, day, hour, minute, second, suffix)
end

local function convert(self, target, options)
  local source = self._unit
  if source == target then return self end
  local source_spec = unit_spec(source)
  local target_spec = unit_spec(target)
  options = options or {}

  if target_spec.scale > source_spec.scale then
    local factor = target_spec.scale / source_spec.scale
    return setmetatable({
      _unit = target,
      _value = checked_mul(self._value, factor),
    }, Timestamp)
  end

  local factor = source_spec.scale / target_spec.scale
  local quotient = self._value / factor
  local remainder = self._value % factor
  if remainder ~= ZERO then
    local mode = options.mode or "exact"
    if mode == "exact" then
      fail("cannot convert " .. source .. " to " .. target .. " without precision loss", 3)
    elseif mode == "floor" then
      if self._value < ZERO then quotient = quotient - ONE end
    elseif mode == "round" then
      local magnitude = remainder < ZERO and -remainder or remainder
      if magnitude * 2 >= factor then
        quotient = quotient + (self._value < ZERO and -ONE or ONE)
      end
    elseif mode ~= "truncate" then
      fail("unknown precision mode: " .. tostring(mode), 3)
    end
  end
  return setmetatable({ _unit = target, _value = quotient }, Timestamp)
end

function Timestamp:unit()
  return self._unit
end

function Timestamp:raw()
  return self._value
end

function Timestamp:to_number()
  local text = decimal_string(self._value)
  local _, digits = strip_leading_zeroes(text)
  if #digits > 16 or (#digits == 16 and compare_digits(digits, "9007199254740992") > 0) then
    fail("timestamp does not fit an exact Lua number; use :raw()", 2)
  end
  return tonumber(text)
end

function Timestamp:to_string(options)
  return format_timestamp(self, options)
end

function Timestamp:to_ms(options) return convert(self, "ms", options) end
function Timestamp:to_us(options) return convert(self, "us", options) end
function Timestamp:to_ns(options) return convert(self, "ns", options) end

function Timestamp:__tostring()
  return self:to_string()
end

function Timestamp:__eq(other)
  return type(other) == "table" and self._unit == other._unit and
    self._value == other._value
end

local function new_timestamp(unit, value)
  unit_spec(unit)
  return setmetatable({ _unit = unit, _value = parse_integer(value) }, Timestamp)
end

function M.ms(value) return new_timestamp("ms", value) end
function M.us(value) return new_timestamp("us", value) end
function M.ns(value) return new_timestamp("ns", value) end

function M.from_unix(seconds, fraction, unit)
  unit = unit or "ns"
  local spec = unit_spec(unit)
  seconds = parse_integer(seconds)
  if type(fraction) ~= "number" or fraction % 1 ~= 0 or
      fraction < 0 or fraction >= tonumber(spec.scale) then
    fail("fraction must be an integer in [0, units_per_second)", 2)
  end
  local whole = checked_mul(seconds, spec.scale)
  return new_timestamp(unit, checked_add(whole, ffi.new("int64_t", fraction)))
end

function M.parse_rfc3339(text, options)
  if type(text) ~= "string" then fail("RFC3339 value must be a string", 2) end
  options = options or {}
  local base, zone = text:match("^(.*)([Zz])$")
  if not base then base, zone = text:match("^(.*)([+-]%d%d:%d%d)$") end
  if not base then fail("invalid RFC3339 timezone suffix", 2) end

  local year, month, day, hour, minute, second, fraction = base:match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d):(%d%d)(%.%d+)$")
  if not year then
    year, month, day, hour, minute, second = base:match(
      "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d):(%d%d)$")
  end
  if not year then fail("invalid RFC3339 date/time", 2) end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
  if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or
      minute > 59 or second > 59 then
    fail("invalid RFC3339 date/time fields", 2)
  end
  local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
  local month_days = {31, leap and 29 or 28, 31, 30, 31, 30,
    31, 31, 30, 31, 30, 31}
  if day > month_days[month] then fail("invalid RFC3339 calendar date", 2) end

  local offset_seconds = 0
  if zone ~= "Z" and zone ~= "z" then
    local sign, offset_hour, offset_minute = zone:match("^([+-])(%d%d):(%d%d)$")
    offset_hour, offset_minute = tonumber(offset_hour), tonumber(offset_minute)
    if offset_hour > 23 or offset_minute > 59 then fail("invalid timezone offset", 2) end
    offset_seconds = (offset_hour * 60 + offset_minute) * 60
    if sign == "+" then offset_seconds = offset_seconds else offset_seconds = -offset_seconds end
  end

  local fraction_digits = fraction and fraction:sub(2) or ""
  if #fraction_digits > 9 then fail("RFC3339 precision exceeds nanoseconds", 2) end
  local nanos = tonumber((fraction_digits .. "000000000"):sub(1, 9)) or 0
  local seconds_value = days_from_civil(year, month, day) * 86400 +
    hour * 3600 + minute * 60 + second - offset_seconds
  local parsed = M.from_unix(seconds_value, nanos, "ns")
  local target = options.unit or "ns"
  if target ~= "ns" then
    return convert(parsed, target, { mode = options.precision or "exact" })
  end
  return parsed
end

function M.now_ms()
  return M.ms(native.load().line_sender_now_micros() / 1000)
end

function M.now_us()
  return M.us(native.load().line_sender_now_micros())
end

function M.now_ns()
  return M.ns(native.load().line_sender_now_nanos())
end

function M.is_timestamp(value)
  return type(value) == "table" and getmetatable(value) == Timestamp
end

M.Timestamp = Timestamp
M.units = { "ms", "us", "ns" }

return M
