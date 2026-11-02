-- Upstream C ABI declarations for c-questdb-client commit 8ef0219 (7.0.0+2);
-- `make abi-check` compiles them against that commit's header. Keep this file
-- free of logic: `native.lua` is the only module that calls `ffi.cdef`, and it
-- does so exactly once per Lua state.
return [[
  typedef struct line_sender line_sender;
  typedef struct line_sender_buffer line_sender_buffer;
  typedef struct line_sender_error line_sender_error;

  typedef enum line_sender_error_code {
    line_sender_error_could_not_resolve_addr = 0,
    line_sender_error_invalid_api_call = 1,
    line_sender_error_socket_error = 2,
    line_sender_error_invalid_utf8 = 3,
    line_sender_error_invalid_name = 4,
    line_sender_error_invalid_timestamp = 5,
    line_sender_error_auth_error = 6,
    line_sender_error_tls_error = 7,
    line_sender_error_http_not_supported = 8,
    line_sender_error_server_flush_error = 9,
    line_sender_error_config_error = 10,
    line_sender_error_array_error = 11,
    line_sender_error_protocol_version_error = 12,
    line_sender_error_invalid_decimal = 13,
    line_sender_error_server_rejection = 14,
    line_sender_error_arrow_unsupported_column_kind = 15,
    line_sender_error_arrow_ingest = 16,
    line_sender_error_failover_retry = 17,
    line_sender_error_role_mismatch = 18,
    line_sender_error_connect_timeout = 19,
    line_sender_error_handshake_error = 20,
    line_sender_error_unsupported_server = 21,
    line_sender_error_protocol_error = 22,
    line_sender_error_invalid_bind = 23,
    line_sender_error_server_schema_mismatch = 24,
    line_sender_error_server_parse_error = 25,
    line_sender_error_server_internal_error = 26,
    line_sender_error_server_security_error = 27,
    line_sender_error_limit_exceeded = 28,
    line_sender_error_server_limit_exceeded = 29,
    line_sender_error_cancelled = 30,
    line_sender_error_failover_would_duplicate = 31,
    line_sender_error_schema_drift = 32,
    line_sender_error_no_schema = 33,
    line_sender_error_arrow_export = 34,
    line_sender_error_batch_too_large = 35,
    line_sender_error_store_resend_required = 36,
    line_sender_error_symbol_dict_full = 37,
  } line_sender_error_code;

  typedef enum line_sender_protocol_version {
    line_sender_protocol_version_1 = 1,
    line_sender_protocol_version_2 = 2,
    line_sender_protocol_version_3 = 3,
  } line_sender_protocol_version;

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
  line_sender_buffer *line_sender_buffer_new(line_sender_protocol_version version);
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

  line_sender_error_code line_sender_error_get_code(const line_sender_error *error);
  const char *line_sender_error_msg(
    const line_sender_error *error, size_t *len_out);
  bool line_sender_error_in_doubt(const line_sender_error *error);
  void line_sender_error_free(line_sender_error *error);
]]
