# Error Handling

gen_http returns structured error tuples that tell you what went wrong
and whether you should retry.

## Error Categories

Every error from gen_http is wrapped in one of three categories:

```erlang
{transport_error, Reason}     %% network/socket level
{protocol_error, Reason}      %% HTTP protocol violation
{application_error, Reason}   %% policy or state violation
```

### Transport Errors

Network problems. The server is unreachable, the connection dropped,
DNS failed, TLS handshake broke.

```erlang
{transport_error, closed}
{transport_error, timeout}
{transport_error, econnrefused}
{transport_error, econnreset}
{transport_error, ehostunreach}
{transport_error, nxdomain}
{transport_error, {ssl_error, Reason}}
{transport_error, {send_failed, Reason}}
```

These are usually retriable. Reconnect and try again.

### Protocol Errors

The server sent something that violates HTTP/1.1 or HTTP/2 rules.
Malformed status lines, bad frame sizes, HPACK decode failures.

```erlang
%% HTTP/1.1
{protocol_error, invalid_status_line}
{protocol_error, invalid_header}
{protocol_error, invalid_chunk_size}
{protocol_error, too_many_headers}

%% HTTP/2
{protocol_error, {frame_size_error, Size}}
{protocol_error, {goaway, ErrorCode}}
{protocol_error, {rst_stream, ErrorCode}}
{protocol_error, max_concurrent_streams_exceeded}
```

Don't retry these on the same connection. The connection state is
probably corrupted. Close it and open a new one if you want to retry.

One exception: `{rst_stream, refused_stream}` means the server rejected
the stream before processing it (RFC 9113 Section 8.7). Safe to retry
on a new connection.

### Application Errors

Your code did something the library doesn't allow, or the connection
hit a state where the operation doesn't make sense.

```erlang
{application_error, connection_closed}
{application_error, pipeline_full}
{application_error, {invalid_request_ref, Ref}}
{application_error, unexpected_close}
{application_error, {incomplete_body, Got, Expected}}
```

`connection_closed` and `unexpected_close` are retriable with a new
connection. The others point to bugs in caller code.

## Retryable or Not

`gen_http:is_retriable_error/1` tells you:

```erlang
case gen_http:request(Conn, <<"GET">>, <<"/">>, [], <<>>) of
    {ok, Conn2, Ref} ->
        {ok, Conn2, Ref};
    {error, _Conn2, Reason} ->
        case gen_http:is_retriable_error(Reason) of
            true ->
                %% reconnect and try again
                {ok, NewConn} = gen_http:connect(https, Host, 443),
                gen_http:request(NewConn, <<"GET">>, <<"/">>, [], <<>>);
            false ->
                {error, Reason}
        end
end
```

The rules:

| Category | Retriable? |
|----------|-----------|
| Transport errors | Yes |
| Protocol errors | No (except `refused_stream`) |
| `connection_closed`, `unexpected_close` | Yes (new connection) |
| `pipeline_full`, `invalid_request_ref` | No |

## Classifying Errors

If you want the category as an atom:

```erlang
case gen_http:classify_error(Reason) of
    transport -> log_and_retry();
    protocol -> log_and_alert();
    application -> handle_bug()
end
```

## Error Shapes in Different Contexts

### connect/3,4

```erlang
{error, {transport_error, Reason}}
```

Connection failures are always transport errors.

### request/5

```erlang
{error, Conn, {transport_error, Reason}}
{error, Conn, {application_error, Reason}}
```

The connection is returned so you can inspect or close it.

### stream/2 and recv/3

```erlang
{error, Conn, Reason, PartialResponses}   %% stream/2
{error, Conn, Reason}                      %% recv/3
```

`stream/2` includes partial responses that were parsed before the error
hit. You might get a status and headers but no body, for instance.

## Pattern Matching

The tagged tuple structure makes pattern matching direct:

```erlang
case Result of
    {error, _, {transport_error, closed}} ->
        reconnect();
    {error, _, {protocol_error, {goaway, _}}} ->
        %% server is shutting down
        reconnect();
    {error, _, {application_error, pipeline_full}} ->
        %% slow down
        timer:sleep(100),
        retry();
    {error, _, Reason} ->
        {error, Reason}
end
```
