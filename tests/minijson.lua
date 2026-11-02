-- Just enough JSON to read QuestDB's /exec responses in the integration test.
-- Numbers become Lua numbers, so callers compare large integers as strings.

local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local ESCAPES = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local decode_value

local function skip_space(text, pos)
  return text:find("%S", pos) or #text + 1
end

local function fail(pos, what)
  error("invalid JSON at byte " .. pos .. ": " .. what, 0)
end

local function decode_string(text, pos)
  local parts = {}
  local i = pos + 1
  while true do
    local stop = text:find('["\\]', i)
    if not stop then fail(pos, "unterminated string") end
    parts[#parts + 1] = text:sub(i, stop - 1)
    if text:sub(stop, stop) == '"' then
      return table.concat(parts), stop + 1
    end
    local escape = text:sub(stop + 1, stop + 1)
    if escape == "u" then
      -- Tests only write ASCII text; keep anything else visibly unconverted.
      parts[#parts + 1] = "\\u" .. text:sub(stop + 2, stop + 5)
      i = stop + 6
    else
      if not ESCAPES[escape] then fail(stop, "bad escape") end
      parts[#parts + 1] = ESCAPES[escape]
      i = stop + 2
    end
  end
end

local function decode_array(text, pos)
  local out = {}
  local i = skip_space(text, pos + 1)
  if text:sub(i, i) == "]" then return out, i + 1 end
  while true do
    out[#out + 1], i = decode_value(text, i)
    i = skip_space(text, i)
    local c = text:sub(i, i)
    if c == "]" then return out, i + 1 end
    if c ~= "," then fail(i, "expected , or ]") end
    i = skip_space(text, i + 1)
  end
end

local function decode_object(text, pos)
  local out = {}
  local i = skip_space(text, pos + 1)
  if text:sub(i, i) == "}" then return out, i + 1 end
  while true do
    if text:sub(i, i) ~= '"' then fail(i, "expected a key") end
    local key
    key, i = decode_string(text, i)
    i = skip_space(text, i)
    if text:sub(i, i) ~= ":" then fail(i, "expected :") end
    out[key], i = decode_value(text, skip_space(text, i + 1))
    i = skip_space(text, i)
    local c = text:sub(i, i)
    if c == "}" then return out, i + 1 end
    if c ~= "," then fail(i, "expected , or }") end
    i = skip_space(text, i + 1)
  end
end

decode_value = function(text, pos)
  local c = text:sub(pos, pos)
  if c == '"' then return decode_string(text, pos) end
  if c == "[" then return decode_array(text, pos) end
  if c == "{" then return decode_object(text, pos) end
  if text:sub(pos, pos + 3) == "true" then return true, pos + 4 end
  if text:sub(pos, pos + 4) == "false" then return false, pos + 5 end
  if text:sub(pos, pos + 3) == "null" then return M.null, pos + 4 end
  local number = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
  if not number or not tonumber(number) then fail(pos, "unexpected value") end
  return tonumber(number), pos + #number
end

function M.decode(text)
  local value, pos = decode_value(text, skip_space(text, 1))
  pos = skip_space(text, pos)
  if pos <= #text then fail(pos, "trailing data") end
  return value
end

return M
