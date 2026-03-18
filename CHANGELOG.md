# Changelog

All notable changes to this project will be documented in this file.

## 0.1.0 (2025-03-18)

Initial release.

### Added

- **Unified API** - `gen_http` module works with both HTTP/1.1 and HTTP/2
  connections through a single interface. Protocol selection is automatic
  via ALPN for HTTPS, HTTP/1.1 for plain HTTP.

- **HTTP/1.1 state machine** (`gen_http_h1`) - Request pipelining, keep-alive,
  chunked transfer encoding, body streaming for requests and responses.

- **HTTP/2 state machine** (`gen_http_h2`) - Stream multiplexing, connection
  and stream level flow control, settings negotiation, GOAWAY handling,
  server push support. RFC 9113 compliant.

- **HPACK header compression** (`gen_http_parser_hpack`) - Static and dynamic
  tables with Huffman coding. Pure data structure, no process state.
  RFC 7541 compliant.

- **Active and passive socket modes** - Active mode delivers data as Erlang
  messages via `stream/2`. Passive mode uses blocking `recv/3`. Switch
  between them at any time with `set_mode/2`.

- **Structured error types** - Errors are tagged as `{transport_error, _}`,
  `{protocol_error, _}`, or `{application_error, _}`. Use
  `is_retriable_error/1` to decide whether to retry.

- **Connection metadata** - `put_private/3`, `get_private/2,3`,
  `delete_private/2` for attaching pool IDs, metrics, or tags to
  connections.

- **Transport abstraction** - `gen_http_transport` behaviour with TCP
  (`gen_http_tcp`) and SSL/TLS (`gen_http_ssl`) implementations.
  TLS certificate verification enabled by default.

- **Zero dependencies** - Only OTP stdlib (kernel, stdlib, crypto,
  public_key, ssl). Targets OTP 25+.
