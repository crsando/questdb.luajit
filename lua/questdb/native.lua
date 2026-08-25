local ffi = require "ffi"

-- Keep this declaration set deliberately small. It is the ABI boundary used
-- by the row-oriented MVP; the authoritative definitions live in the
-- installed c-questdb-client headers.
ffi.cdef [[
  typedef struct line_sender line_sender;
  typedef struct line_sender_buffer line_sender_buffer;
  typedef struct line_sender_error line_sender_error;

  typedef struct line_sender_utf8 {
    size_t len;
    const char *buf;
  } line_sender_utf8;

  typedef struct line_sender_table_name {
    size_t len;
    const char *buf;
  } line_sender_table_name;

  typedef struct line_sender_column_name {
    size_t len;
    const char *buf;
  } line_sender_column_name;

  typedef struct line_sender_buffer_view {
    size_t len;
    const uint8_t *buf;
  } line_sender_buffer_view;

  bool line_sender_utf8_init(
    line_sender_utf8 *str, size_t len, const char *buf,
    line_sender_error **err_out);
  bool line_sender_table_name_init(
    line_sender_table_name *name, size_t len, const char *buf,
    line_sender_error **err_out);
  bool line_sender_column_name_init(
    line_sender_column_name *name, size_t len, const char *buf,
    line_sender_error **err_out);

  line_sender *line_sender_from_conf(
    line_sender_utf8 config, line_sender_error **err_out);
  void line_sender_close(line_sender *sender);
  bool line_sender_must_close(const line_sender *sender);

  line_sender_buffer *line_sender_buffer_new_for_sender(
    const line_sender *sender);
  line_sender_buffer *line_sender_buffer_new(int version);
  void line_sender_buffer_free(line_sender_buffer *buffer);
  void line_sender_buffer_clear(line_sender_buffer *buffer);
  bool line_sender_buffer_reserve(
    line_sender_buffer *buffer, size_t additional,
    line_sender_error **err_out);
  size_t line_sender_buffer_size(const line_sender_buffer *buffer);
  size_t line_sender_buffer_row_count(const line_sender_buffer *buffer);

  bool line_sender_buffer_table(
    line_sender_buffer *buffer, line_sender_table_name name,
    line_sender_error **err_out);
  bool line_sender_buffer_symbol(
    line_sender_buffer *buffer, line_sender_column_name name,
    line_sender_utf8 value, line_sender_error **err_out);
  bool line_sender_buffer_column_bool(
    line_sender_buffer *buffer, line_sender_column_name name, bool value,
    line_sender_error **err_out);
  bool line_sender_buffer_column_i64(
    line_sender_buffer *buffer, line_sender_column_name name, int64_t value,
    line_sender_error **err_out);
  bool line_sender_buffer_column_f64(
    line_sender_buffer *buffer, line_sender_column_name name, double value,
    line_sender_error **err_out);
  bool line_sender_buffer_column_str(
    line_sender_buffer *buffer, line_sender_column_name name,
    line_sender_utf8 value, line_sender_error **err_out);
  bool line_sender_buffer_column_date(
    line_sender_buffer *buffer, line_sender_column_name name, int64_t millis,
    line_sender_error **err_out);
  bool line_sender_buffer_column_ts_micros(
    line_sender_buffer *buffer, line_sender_column_name name, int64_t micros,
    line_sender_error **err_out);
  bool line_sender_buffer_column_ts_nanos(
    line_sender_buffer *buffer, line_sender_column_name name, int64_t nanos,
    line_sender_error **err_out);

  bool line_sender_buffer_at_micros(
    line_sender_buffer *buffer, int64_t epoch_micros,
    line_sender_error **err_out);
  bool line_sender_buffer_at_nanos(
    line_sender_buffer *buffer, int64_t epoch_nanos,
    line_sender_error **err_out);
  bool line_sender_buffer_at_now(
    line_sender_buffer *buffer, line_sender_error **err_out);

  bool line_sender_flush(
    line_sender *sender, line_sender_buffer *buffer,
    line_sender_error **err_out);

  int64_t line_sender_now_micros(void);
  int64_t line_sender_now_nanos(void);

  int line_sender_error_get_code(const line_sender_error *error);
  const char *line_sender_error_msg(
    const line_sender_error *error, size_t *len_out);
  bool line_sender_error_in_doubt(const line_sender_error *error);
  void line_sender_error_free(line_sender_error *error);
]]

local M = {
  ffi = ffi,
}

local loaded = {}

local function add_candidate(out, seen, value)
  if value and value ~= "" and not seen[value] then
    seen[value] = true
    out[#out + 1] = value
  end
end

function M.load(path)
  local requested = path
    or os.getenv("QUESTDB_CLIENT_LIB")
    or os.getenv("QUESTDB_CLIENT_LIBRARY")

  local candidates = {}
  local seen = {}
  add_candidate(candidates, seen, requested)
  add_candidate(candidates, seen, "questdb_client")
  add_candidate(candidates, seen, "libquestdb_client.so")
  add_candidate(candidates, seen, "/usr/local/lib/libquestdb_client.so")

  local failures = {}
  for _, name in ipairs(candidates) do
    if loaded[name] then
      return loaded[name]
    end

    local ok, lib = pcall(ffi.load, name)
    if ok then
      loaded[name] = lib
      return lib
    end
    failures[#failures + 1] = name .. ": " .. tostring(lib)
  end

  error("unable to load c-questdb-client shared library:\n  " ..
    table.concat(failures, "\n  "), 2)
end

return M
