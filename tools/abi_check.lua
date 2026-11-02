-- Generates a C translation unit that holds the Lua view of the ABI against the
-- upstream header. It only has to compile: a wrong signature is a conflicting
-- declaration, a wrong struct layout or error code fails a static assertion.
--
--   luajit tools/abi_check.lua > build/abi_check.c
--   cc -std=c11 -fsyntax-only -I<upstream>/include build/abi_check.c

local cdef = require "questdb.cdef"
local errors = require "questdb.error"

local out = {
  "#include <stddef.h>",
  "#include <questdb/ingress/line_sender.h>",
  "",
}

local function emit(line) out[#out + 1] = line end

local function static_assert(condition)
  emit("_Static_assert(" .. condition .. ", \"" .. condition:gsub('"', "'") .. "\");")
end

local declarations = cdef

-- Structs: rebuild each under another name and compare the layouts.
declarations = declarations:gsub("typedef%s+struct%s+[%w_]+%s*(%b{})%s*([%w_]+)%s*;",
  function(body, name)
    local shadow = "struct cdef_" .. name
    emit(shadow .. " " .. body .. ";")
    static_assert("sizeof(" .. shadow .. ") == sizeof(" .. name .. ")")
    for field in body:gmatch("([%w_]+)%s*;") do
      static_assert("offsetof(" .. shadow .. ", " .. field .. ") == offsetof(" .. name ..
        ", " .. field .. ")")
    end
    return ""
  end)

-- Enums: every enumerator must carry the header's value.
declarations = declarations:gsub("typedef%s+enum%s+[%w_]+%s*(%b{})%s*[%w_]+%s*;",
  function(body)
    for name, value in body:gmatch("([%w_]+)%s*=%s*(%d+)") do
      static_assert(name .. " == " .. value)
    end
    return ""
  end)

-- error.lua maps native codes to names, so it has to agree as well.
for code, name in pairs(errors.native_code_names) do
  static_assert("line_sender_error_" .. name .. " == " .. code)
end

-- Opaque handles are declared by the header already.
declarations = declarations:gsub("typedef%s+struct%s+[%w_]+%s+[%w_]+%s*;", "")

-- What is left are function prototypes, which conflict if they disagree.
emit("")
emit(declarations)

io.write(table.concat(out, "\n"), "\n")
