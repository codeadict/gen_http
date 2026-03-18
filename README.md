# gen_http

[![CI](https://github.com/codeadict/gen_http/actions/workflows/ci.yml/badge.svg)](https://github.com/codeadict/gen_http/actions/workflows/ci.yml)
[![codecov](https://codecov.io/github/codeadict/gen_http/graph/badge.svg?token=Y07BA8DQ6T)](https://codecov.io/github/codeadict/gen_http)
[![HTTP/2 Compliance](https://github.com/codeadict/gen_http/actions/workflows/h2-compliance.yml/badge.svg)](https://github.com/codeadict/gen_http/actions/workflows/h2-compliance.yml)
[![RFC 7540](https://img.shields.io/badge/RFC%207540-compliant-brightgreen)](https://datatracker.ietf.org/doc/html/rfc7540)
[![RFC 7541](https://img.shields.io/badge/RFC%207541-compliant-brightgreen)](https://datatracker.ietf.org/doc/html/rfc7541)

A minimal, low-level HTTP client for Erlang.

HTTP/1.1 and HTTP/2 support. Pure Erlang. Zero dependencies.

## Why?

Fast. Small API. Proper HTTP/1.1 and HTTP/2 support. Works with both protocols transparently.

## Quick Start

Add to your `rebar.config`:

```erlang
{deps, [
    {gen_http, {git, "https://github.com/codeadict/gen_http.git", {branch, "main"}}}
]}.
```

Send a request:

```erlang
{ok, Conn} = gen_http:connect(http, "httpbin.org", 80),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),

receive
    Msg ->
        case gen_http:stream(Conn2, Msg) of
            {ok, Conn3, [{status, Ref, 200}, {headers, Ref, Headers}, {data, Ref, Body}, {done, Ref}]} ->
                io:format("Body: ~s~n", [Body])
        end
end.
```

HTTPS with automatic HTTP/2 negotiation:

```erlang
{ok, Conn} = gen_http:connect(https, "www.google.com", 443),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/">>, [], <<>>).
%% Same API, different protocol
```

See the [Getting Started](docs/getting-started.md) guide for POST requests, passive mode, response collection loops, and more.

## HTTP/2 Compliance

**156 tests** covering RFC 7540 (HTTP/2) and RFC 7541 (HPACK). All frame types, stream states, flow control, priority handling, HPACK compression, and error conditions.

Tested against [h2-client-test-harness](https://github.com/nomadlabsinc/h2-client-test-harness). **100% pass rate**.

## Documentation

- [Getting Started](docs/getting-started.md) -- installation, first request, collecting responses
- [Architecture](docs/architecture.md) -- process-less design, module layout, protocol negotiation
- [Active and Passive Modes](docs/active-and-passive-modes.md) -- choosing the right I/O model
- [Error Handling](docs/error-handling.md) -- structured errors, retries, pattern matching
- [SSL Certificates](docs/ssl-certificates.md) -- TLS config, custom CAs, ALPN

## Testing

SSL/H2/ALPN tests need `nghttpx` (from nghttp2). Install on macOS with `brew install nghttp2`. Suites that need it skip gracefully if it's not installed.

```bash
# Run all tests
rebar3 test

# Run specific test types
rebar3 eunit           # Unit tests
rebar3 ct              # Integration tests
rebar3 proper          # Property-based tests

# HTTP/2 compliance tests (excluded by default, requires separate Docker harness)
rebar3 ct --suite=h2_compliance_SUITE
```

## Project Status

Early development. API may change.

## License

Apache 2.0
