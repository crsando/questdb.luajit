local ffi = require "ffi"
local M = {}

local native_code_names = {
  [0] = "could_not_resolve_addr",
  [1] = "invalid_api_call",
  [2] = "socket_error",
  [3] = "invalid_utf8",
  [4] = "invalid_name",
  [5] = "invalid_timestamp",
  [6] = "auth_error",
  [7] = "tls_error",
  [8] = "http_not_supported",
  [9] = "server_flush_error",
  [10] = "config_error",
  [11] = "array_error",
  [12] = "protocol_version_error",
  [13] = "invalid_decimal",
  [14] = "server_rejection",
  [15] = "arrow_unsupported_column_kind",
  [16] = "arrow_ingest",
  [17] = "failover_retry",
  [18] = "role_mismatch",
  [19] = "connect_timeout",
  [20] = "handshake_error",
  [21] = "unsupported_server",
  [22] = "protocol_error",
  [23] = "invalid_bind",
  [24] = "server_schema_mismatch",
  [25] = "server_parse_error",
  [26] = "server_internal_error",
  [27] = "server_security_error",
  [28] = "limit_exceeded",
  [29] = "server_limit_exceeded",
  [30] = "cancelled",
  [31] = "failover_would_duplicate",
  [32] = "schema_drift",
  [33] = "no_schema",
  [34] = "arrow_export",
  [35] = "batch_too_large",
  [36] = "store_resend_required",
  [37] = "symbol_dict_full",
}

local Error = {}
Error.__index = Error

function Error:__tostring()
  local prefix = self.code and ("questdb " .. tostring(self.code)) or "questdb error"
  if self.message and self.message ~= "" then
    return prefix .. ": " .. self.message
  end
  return prefix
end

function M.local_error(code, message, details)
  local err = {
    code = code,
    message = message,
    native_code = nil,
    in_doubt = false,
  }
  if details then
    for k, v in pairs(details) do
      err[k] = v
    end
  end
  return setmetatable(err, Error)
end

function M.from_native(lib, ptr)
  return M.from_native_with_ffi(ffi, lib, ptr)
end

-- Kept separate from native.lua to avoid a module cycle. The caller passes
-- the ffi module once, then all native errors are copied before freeing C data.
function M.from_native_with_ffi(ffi, lib, ptr)
  if ptr == nil then
    return M.local_error("unknown", "native call failed without an error object")
  end

  local len = ffi.new("size_t[1]")
  local msg_ptr = lib.line_sender_error_msg(ptr, len)
  local message = ""
  if msg_ptr ~= nil and tonumber(len[0]) > 0 then
    message = ffi.string(msg_ptr, tonumber(len[0]))
  end
  local native_code = tonumber(lib.line_sender_error_get_code(ptr))
  local in_doubt = lib.line_sender_error_in_doubt(ptr) and true or false
  lib.line_sender_error_free(ptr)

  return setmetatable({
    code = native_code_names[native_code] or "native",
    message = message,
    native_code = native_code,
    in_doubt = in_doubt,
  }, Error)
end

function M.is_error(value)
  return type(value) == "table" and getmetatable(value) == Error
end

return M
