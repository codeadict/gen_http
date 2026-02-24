# gen_http

[![CI](https://github.com/codeadict/gen_http/actions/workflows/ci.yml/badge.svg)](https://github.com/codeadict/gen_http/actions/workflows/ci.yml)
[![HTTP/2 Compliance](https://github.com/codeadict/gen_http/actions/workflows/h2-compliance.yml/badge.svg)](https://github.com/codeadict/gen_http/actions/workflows/h2-compliance.yml)
[![RFC 7540](https://img.shields.io/badge/RFC%207540-compliant-brightgreen)](https://datatracker.ietf.org/doc/html/rfc7540)
[![RFC 7541](https://img.shields.io/badge/RFC%207541-compliant-brightgreen)](https://datatracker.ietf.org/doc/html/rfc7541)

A minimal, low-level HTTP client for Erlang.

HTTP/1.1 and HTTP/2 support. Pure Erlang. Zero dependencies.

## Why?

- **Fast**: Optimized for performance with inline compilation and buffer tuning
- **Simple**: Small API surface, easy to understand
- **Correct**: Proper HTTP/1.1 and HTTP/2 protocol handling
- **Flexible**: Works with both protocols transparently

Built to replace `httpc` with better performance and cleaner code.

## HTTP/2 Compliance

**156 compliance tests** covering RFC 7540 (HTTP/2) and RFC 7541 (HPACK)

- Complete frame type validation (DATA, HEADERS, SETTINGS, PING, etc.)
- Stream state machine verification
- Flow control and priority handling
- HPACK compression/decompression
- All error conditions tested

Tested against [h2-client-test-harness](https://github.com/nomadlabsinc/h2-client-test-harness) with **100% pass rate**.

## Quick Start

```erlang
%% HTTP/1.1
{ok, Conn} = gen_http:connect(http, "httpbin.org", 80),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),

%% Collect response in active mode (default)
receive
    Msg ->
        case gen_http:stream(Conn2, Msg) of
            {ok, Conn3, [{status, Ref, 200}, {headers, Ref, Headers}, {data, Ref, Body}, {done, Ref}]} ->
                io:format("Body: ~s~n", [Body])
        end
end.

%% HTTP/2 (automatic via ALPN)
{ok, Conn} = gen_http:connect(https, "google.com", 443),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
%% Same API, different protocol
```

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {gen_http, {git, "https://github.com/codeadict/gen_http.git", {branch, "main"}}}
]}.
```

## Examples

### Simple GET Request

```erlang
{ok, Conn} = gen_http:connect(http, "httpbin.org", 80),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),

%% Active mode - receive messages
receive Msg ->
    {ok, Conn3, Responses} = gen_http:stream(Conn2, Msg),
    io:format("Responses: ~p~n", [Responses])
end.
```

### POST with Body

```erlang
{ok, Conn} = gen_http:connect(http, "httpbin.org", 80),

Headers = [{<<"content-type">>, <<"application/json">>}],
Body = <<"{\"hello\": \"world\"}">>,

{ok, Conn2, Ref} = gen_http:request(Conn, <<"POST">>, <<"/post">>, Headers, Body).
```

### HTTPS with HTTP/2

```erlang
%% ALPN automatically negotiates HTTP/2 if available
{ok, Conn} = gen_http:connect(https, "www.google.com", 443),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/">>, [], <<>>).
```

### Passive Mode (Blocking)

```erlang
{ok, Conn} = gen_http:connect(http, "httpbin.org", 80, #{mode => passive}),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),

%% Blocking receive
{ok, Conn3, Responses} = gen_http:recv(Conn2, 0, 5000),
io:format("Responses: ~p~n", [Responses]).
```

### Connection Reuse

```erlang
{ok, Conn} = gen_http:connect(http, "httpbin.org", 80),

%% First request
{ok, Conn2, Ref1} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),
%% ... handle response ...

%% Second request on same connection
{ok, Conn3, Ref2} = gen_http:request(Conn2, <<"GET">>, <<"/headers">>, [], <<>>),
%% ... handle response ...

{ok, _} = gen_http:close(Conn3).
```

### Error Handling

```erlang
case gen_http:connect(http, "example.com", 80) of
    {ok, Conn} ->
        case gen_http:request(Conn, <<"GET">>, <<"/">>, [], <<>>) of
            {ok, Conn2, Ref} ->
                handle_success(Conn2, Ref);
            {error, Conn2, Reason} ->
                %% Structured errors: {transport_error, _}, {protocol_error, _}, {application_error, _}
                case gen_http:is_retriable_error(Reason) of
                    true -> retry_request();
                    false -> handle_permanent_error(Reason)
                end
        end;
    {error, Reason} ->
        io:format("Connection failed: ~p~n", [Reason])
end.
```

## Testing

```bash
# Start test infrastructure
docker compose -f test/support/docker-compose.yml up -d

# Run all tests
rebar3 test

# Run specific test types
rebar3 eunit           # Unit tests (fast, no docker)
rebar3 ct              # Integration tests (requires docker)
rebar3 proper          # Property-based tests

# HTTP/2 compliance tests (excluded by default - slow, requires special setup)
rebar3 ct --suite=h2_compliance_SUITE
```

## Project Status

Early development. API may change.

## Inspiration

- [Mint](https://github.com/elixir-mint/mint) - HTTP client for Elixir
- [httpcore](https://github.com/encode/httpcore) - Minimal HTTP client for Python
- [gun](https://github.com/ninenines/gun) - HTTP client for Erlang

## License

Apache 2.0
