# Getting Started

## Installation

Add `gen_http` to your `rebar.config` dependencies:

```erlang
{deps, [
    {gen_http, {git, "https://github.com/codeadict/gen_http.git", {branch, "main"}}}
]}.
```

Then fetch and compile:

```bash
rebar3 compile
```

## Your First Request

Connect to a server and send a GET request:

```erlang
{ok, Conn} = gen_http:connect(http, "httpbin.org", 80),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>).
```

`Ref` is a reference that tags all response messages for this request.
You need it to match responses when you have multiple requests in flight.

## Collecting the Response

By default, connections run in active mode. The socket delivers data as
Erlang messages to your process. You hand each message to `gen_http:stream/2`,
which parses it into structured response events:

```erlang
receive
    Msg ->
        {ok, Conn3, Responses} = gen_http:stream(Conn2, Msg)
end
```

`Responses` is a list of tuples. A complete response looks like:

```erlang
[
    {status, Ref, 200},
    {headers, Ref, [{<<"content-type">>, <<"application/json">>}, ...]},
    {data, Ref, <<"response body">>},
    {done, Ref}
]
```

The response might arrive across several messages, so keep calling
`stream/2` in a loop until you see `{done, Ref}`.

## A Complete Example

Putting it together with a collection loop:

```erlang
fetch(Scheme, Host, Port, Path) ->
    {ok, Conn} = gen_http:connect(Scheme, Host, Port),
    {ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, Path, [], <<>>),
    collect(Conn2, Ref, #{}).

collect(Conn, Ref, Acc) ->
    receive
        Msg ->
            case gen_http:stream(Conn, Msg) of
                {ok, Conn2, Responses} ->
                    case process_responses(Responses, Ref, Acc) of
                        {done, Result} ->
                            gen_http:close(Conn2),
                            Result;
                        {continue, Acc2} ->
                            collect(Conn2, Ref, Acc2)
                    end;
                {error, _Conn2, Reason, _Partial} ->
                    {error, Reason}
            end
    after 10000 ->
        gen_http:close(Conn),
        {error, timeout}
    end.

process_responses([], _Ref, Acc) ->
    {continue, Acc};
process_responses([{status, Ref, Status} | Rest], Ref, Acc) ->
    process_responses(Rest, Ref, Acc#{status => Status});
process_responses([{headers, Ref, Headers} | Rest], Ref, Acc) ->
    process_responses(Rest, Ref, Acc#{headers => Headers});
process_responses([{data, Ref, Chunk} | Rest], Ref, Acc) ->
    Body = maps:get(body, Acc, <<>>),
    process_responses(Rest, Ref, Acc#{body => <<Body/binary, Chunk/binary>>});
process_responses([{done, Ref} | _Rest], Ref, Acc) ->
    {done, Acc}.
```

## HTTPS and HTTP/2

HTTPS connections negotiate the protocol automatically via ALPN. If the
server supports HTTP/2, you get HTTP/2. The API stays the same:

```erlang
{ok, Conn} = gen_http:connect(https, "www.google.com", 443),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/">>, [], <<>>).
```

To force a specific protocol:

```erlang
%% HTTP/2 only
{ok, Conn} = gen_http:connect(https, "example.com", 443, #{protocols => [http2]}).

%% HTTP/1.1 only
{ok, Conn} = gen_http:connect(https, "example.com", 443, #{protocols => [http1]}).
```

## POST with a Body

```erlang
{ok, Conn} = gen_http:connect(https, "httpbin.org", 443),
Headers = [{<<"content-type">>, <<"application/json">>}],
Body = <<"{\"key\": \"value\"}">>,
{ok, Conn2, Ref} = gen_http:request(Conn, <<"POST">>, <<"/post">>, Headers, Body).
```

## Connection Reuse

Connections stay open. Send multiple requests on the same one:

```erlang
{ok, Conn} = gen_http:connect(http, "httpbin.org", 80),

{ok, Conn2, Ref1} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),
%% ... collect response for Ref1 ...

{ok, Conn3, Ref2} = gen_http:request(Conn2, <<"GET">>, <<"/headers">>, [], <<>>),
%% ... collect response for Ref2 ...

{ok, _} = gen_http:close(Conn3).
```

## Passive Mode

If you prefer blocking reads over message-based I/O:

```erlang
{ok, Conn} = gen_http:connect(http, "httpbin.org", 80, #{mode => passive}),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),
{ok, Conn3, Responses} = gen_http:recv(Conn2, 0, 5000).
```

See the [Active and Passive Modes](active-and-passive-modes.md) guide for when to pick which.

## Error Handling

Errors come back as tagged tuples in three categories:

```erlang
case gen_http:request(Conn, <<"GET">>, <<"/">>, [], <<>>) of
    {ok, Conn2, Ref} ->
        handle_success(Conn2, Ref);
    {error, Conn2, Reason} ->
        case gen_http:is_retriable_error(Reason) of
            true -> retry_with_new_connection();
            false -> {error, Reason}
        end
end
```

See the [Error Handling](error-handling.md) guide for the full breakdown.

## Closing Connections

Always close connections when done:

```erlang
{ok, _Conn} = gen_http:close(Conn).
```

## What's Next

- [Architecture](architecture.md) -- how `gen_http` works under the hood
- [Active and Passive Modes](active-and-passive-modes.md) -- choosing the right I/O mode
- [Error Handling](error-handling.md) -- dealing with failures and retries
- [SSL Certificates](ssl-certificates.md) -- TLS configuration and certificate verification
