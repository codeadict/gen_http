# Testing gen_http

This directory contains tests for the gen_http HTTP client library.

## Test Infrastructure

Tests run against local servers with zero outgoing network requests:

- **mock_server** (Erlang): HTTP/1.1 echo server that parses requests, routes by path, and echoes back JSON. Started in-process via `mock_server:start_http/0`.
- **nghttpx**: TLS/H2 reverse proxy that terminates TLS and speaks HTTP/2 to clients, forwarding to the mock server over plain TCP.

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
