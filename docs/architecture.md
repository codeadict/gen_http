# Architecture

## No Processes

`gen_http` doesn't spawn processes. The connection is a plain Erlang data
structure -- a record -- that you pass between function calls. Each call
returns an updated connection alongside whatever results it produced.

```erlang
{ok, Conn} = gen_http:connect(https, "example.com", 443),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
{ok, Conn3, Responses} = gen_http:recv(Conn2, 0, 5000).
```

This pattern should feel familiar if you've worked with ETS or `:queue` --
you're threading state through a series of transformations.

The upside: you control scheduling. There's no hidden mailbox, no
gen_server overhead, no process-to-process message copies. The connection
lives in whatever process you put it in, and that process decides when to
read from the socket.

## Connection State

Internally, the connection record holds:

- **Socket** -- the TCP or SSL socket
- **Transport module** -- `gen_http_tcp` or `gen_http_ssl`
- **Parser state** -- buffered data, current parse position
- **Request tracking** -- which requests are in flight, their refs
- **Protocol-specific state** -- HTTP/2 streams, HPACK contexts, flow control windows

You don't access these fields directly. The public API in `gen_http`,
`gen_http_h1`, and `gen_http_h2` handles all the bookkeeping.

## Module Layout

```
gen_http              -- Unified API (protocol-agnostic)
gen_http_h1           -- HTTP/1.1 state machine
gen_http_h2           -- HTTP/2 state machine
gen_http_transport    -- Transport behaviour
gen_http_tcp          -- TCP transport
gen_http_ssl          -- SSL/TLS transport
gen_http_parser_h1    -- HTTP/1.1 wire format parser
gen_http_parser_h2    -- HTTP/2 frame parser
gen_http_parser_hpack -- HPACK header compression
gen_http_parser_huffman -- Huffman coding for HPACK
```

`gen_http` sits on top as the unified entry point. It inspects the
connection record's tag (`gen_http_h1_conn` or `gen_http_h2_conn`) and
dispatches to the right protocol module. When you call
`gen_http:request/5`, it figures out whether you're on HTTP/1.1 or
HTTP/2 and calls the right implementation.

You can also call `gen_http_h1` or `gen_http_h2` directly if you need
protocol-specific features like HTTP/2 window sizes or body streaming.

## Protocol Negotiation

For `http` scheme connections, gen_http always uses HTTP/1.1 -- there's
no upgrade mechanism.

For `https`, protocol negotiation happens during the TLS handshake via
ALPN (Application-Layer Protocol Negotiation). The client advertises
which protocols it supports, and the server picks one.

```
Client                          Server
  |-- TLS ClientHello ----------->|
  |   ALPN: [h2, http/1.1]       |
  |                               |
  |<- TLS ServerHello ------------|
  |   ALPN: h2                    |
  |                               |
  |   (HTTP/2 connection)         |
```

If the server picks `h2`, gen_http creates an HTTP/2 connection and
sends the connection preface. If it picks `http/1.1` (or doesn't support
ALPN), you get HTTP/1.1.

## Response Events

Both HTTP/1.1 and HTTP/2 produce the same response event types:

| Event | Shape | Meaning |
|-------|-------|---------|
| Status | `{status, Ref, StatusCode}` | HTTP status code (200, 404, ...) |
| Headers | `{headers, Ref, [{Name, Value}]}` | Response headers |
| Data | `{data, Ref, Binary}` | Body chunk |
| Done | `{done, Ref}` | Response complete |
| Error | `{error, Ref, Reason}` | Stream-level error |

HTTP/2 responses arrive with `Ref` matching the request, so you can
multiplex several requests and demux responses by ref. HTTP/1.1
responses arrive in order (pipelining).

## Wrapping in a Process

Since gen_http is process-less, you'll often wrap it in a GenServer or
similar for production use. A typical pattern:

```erlang
-module(http_worker).
-behaviour(gen_server).

init([Scheme, Host, Port]) ->
    {ok, Conn} = gen_http:connect(Scheme, Host, Port),
    {ok, #{conn => Conn, pending => #{}}}.

handle_call({request, Method, Path, Headers, Body}, From, State) ->
    #{conn := Conn, pending := Pending} = State,
    {ok, Conn2, Ref} = gen_http:request(Conn, Method, Path, Headers, Body),
    {noreply, State#{conn := Conn2, pending := Pending#{Ref => From}}}.

handle_info(Msg, #{conn := Conn} = State) ->
    case gen_http:stream(Conn, Msg) of
        {ok, Conn2, Responses} ->
            State2 = handle_responses(Responses, State#{conn := Conn2}),
            {noreply, State2};
        {error, Conn2, _Reason, _Partial} ->
            {noreply, State#{conn := Conn2}}
    end.
```

This gives you a supervised connection with request queuing, while
gen_http handles the protocol details.
