# Testing gen_http

This directory contains tests for the gen_http HTTP client library.

## Test Infrastructure

Tests run against local servers with zero outgoing network requests:

- **mock_server** (Erlang): HTTP/1.1 echo server that parses requests, routes by path, and echoes back JSON. Started in-process via `mock_server:start_http/0`.
- **nghttpx**: TLS/H2 reverse proxy that terminates TLS and speaks HTTP/2 to clients, forwarding to the mock server over plain TCP.

```
HTTP/1.1 tests ──→ mock_server (port A, plain TCP)
                         ↑
                         │ backend
HTTPS/H2 tests ──→ nghttpx (port B, TLS+ALPN) ───┘
```

## Requirements

- Erlang/OTP 27+
- `nghttpx` (from nghttp2) for SSL/H2/ALPN tests
- `openssl` for generating self-signed certificates

Install nghttpx on macOS:

```bash
brew install nghttp2
```

## Running Tests

```bash
# Run all unit tests
rebar3 eunit

# Run all Common Test integration tests
rebar3 ct

# Run a specific suite
rebar3 ct --suite=http1_SUITE
rebar3 ct --suite=ssl_SUITE
rebar3 ct --suite=http2_SUITE
rebar3 ct --suite=unified_SUITE
rebar3 ct --suite=features_SUITE

# Run property-based tests
rebar3 proper

# Run HTTP/2 compliance tests (excluded by default, requires separate Docker harness)
rebar3 ct --suite=h2_compliance_SUITE
```

Suites that need nghttpx skip gracefully if it's not installed.

## Test Server Endpoints

The mock server handles these routes:

| Path | Behavior |
|------|----------|
| `GET /get` | 200, JSON echo of method/path/args/headers |
| `POST /post` | 200, JSON echo including posted body |
| `GET /status/<code>` | Responds with `<code>` status |
| `GET /redirect/<n>` | 302 redirect chain down to `/get` |
| `GET /bytes/<n>` | 200 with n zero-bytes |
| `GET /stream-bytes/<n>` | 200, chunked transfer, n bytes total |
| `GET /response-headers?K=V` | 200 with K:V as response headers |
| `GET /delay/<n>` | Sleeps n seconds, then 200 |
| fallback | 200, empty body |

## Test Structure

- `mock_server.erl` - Two-mode mock: canned-response replay + HTTP echo server
- `test_helper.erl` - Common utilities: nghttpx lifecycle, cert generation, response collection
- `test/data/` - Canned HTTP response fixtures for protocol hardening tests
- `*_SUITE.erl` - Common Test suites:
  - `http1_SUITE.erl` - HTTP/1.1 protocol tests (mock_server only)
  - `ssl_SUITE.erl` - SSL/TLS and ALPN tests (mock_server + nghttpx)
  - `http2_SUITE.erl` - HTTP/2 protocol tests (nghttpx)
  - `unified_SUITE.erl` - Unified API tests (mock_server + nghttpx)
  - `features_SUITE.erl` - Feature tests: recv, set_mode, controlling_process, put_log (nghttpx)
  - `protocol_hardening_SUITE.erl` - Protocol limits and error detection (mock_server canned mode)
  - `error_path_SUITE.erl` - Error path coverage
  - `h2_compliance_SUITE.erl` - HTTP/2 RFC compliance (separate Docker harness, excluded by default)
- `prop_*.erl` - Property-based tests using PropEr
