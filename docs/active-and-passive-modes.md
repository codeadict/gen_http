# Active and Passive Modes

gen_http supports two socket modes, matching how OTP's `gen_tcp` and `ssl`
modules work.

## Active Mode (Default)

In active mode, the socket sends data as Erlang messages to the
controlling process. You receive them with `receive` and pass them
to `gen_http:stream/2`:

```erlang
{ok, Conn} = gen_http:connect(https, "example.com", 443),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/">>, [], <<>>),

receive
    Msg ->
        case gen_http:stream(Conn2, Msg) of
            {ok, Conn3, Responses} ->
                %% handle Responses
                ok;
            {error, Conn3, Reason, _Partial} ->
                %% handle error
                ok;
            unknown ->
                %% not a socket message for this connection
                ok
        end
end.
```

gen_http uses `{active, once}` internally. After each message is consumed,
it re-arms the socket for the next one. This gives you flow control --
if your process falls behind, the socket won't flood it with data.

Active mode works well when your process needs to handle other messages
alongside HTTP responses (timers, other sockets, gen_server calls).

## Passive Mode

In passive mode, you explicitly ask for data with `gen_http:recv/3`.
The call blocks until data arrives or the timeout fires:

```erlang
{ok, Conn} = gen_http:connect(https, "example.com", 443, #{mode => passive}),
{ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/">>, [], <<>>),

{ok, Conn3, Responses} = gen_http:recv(Conn2, 0, 5000).
```

The second argument to `recv/3` is the byte count hint. Pass `0` to
receive whatever data is available.

Passive mode is simpler for request-response patterns where you just
want to fire a request and wait for the answer. It's also easier to
reason about in sequential code.

## Switching Between Modes

You can switch modes on the fly with `gen_http:set_mode/2`:

```erlang
%% Start in active mode
{ok, Conn} = gen_http:connect(https, "example.com", 443),

%% Switch to passive for a blocking request
{ok, Conn2} = gen_http:set_mode(Conn, passive),
{ok, Conn3, Ref} = gen_http:request(Conn2, <<"GET">>, <<"/">>, [], <<>>),
{ok, Conn4, Responses} = gen_http:recv(Conn3, 0, 5000),

%% Switch back to active
{ok, Conn5} = gen_http:set_mode(Conn4, active).
```

## Choosing a Mode

**Use active mode when:**
- Your process handles multiple connections or message types
- You want to interleave HTTP I/O with other work
- You're building a connection pool or multiplexer
- You need non-blocking operation

**Use passive mode when:**
- You have a simple request-response workflow
- You want blocking, sequential code
- You're writing a script or one-off tool
- You don't need to handle other messages while waiting

## Collecting a Full Response

Responses may arrive across multiple `stream/2` or `recv/3` calls,
especially for large bodies. Here's a pattern that works for both modes:

```erlang
collect_response(Conn, Ref, Mode) ->
    collect_response(Conn, Ref, Mode, #{}).

collect_response(Conn, Ref, active, Acc) ->
    receive
        Msg ->
            case gen_http:stream(Conn, Msg) of
                {ok, Conn2, Responses} ->
                    case fold_responses(Responses, Ref, Acc) of
                        {done, Result} -> {ok, Conn2, Result};
                        {continue, Acc2} -> collect_response(Conn2, Ref, active, Acc2)
                    end;
                {error, _Conn2, Reason, _} ->
                    {error, Reason}
            end
    after 10000 ->
        {error, timeout}
    end;
collect_response(Conn, Ref, passive, Acc) ->
    case gen_http:recv(Conn, 0, 5000) of
        {ok, Conn2, Responses} ->
            case fold_responses(Responses, Ref, Acc) of
                {done, Result} -> {ok, Conn2, Result};
                {continue, Acc2} -> collect_response(Conn2, Ref, passive, Acc2)
            end;
        {error, _Conn2, Reason} ->
            {error, Reason}
    end.

fold_responses([], _Ref, Acc) ->
    {continue, Acc};
fold_responses([{status, Ref, Status} | Rest], Ref, Acc) ->
    fold_responses(Rest, Ref, Acc#{status => Status});
fold_responses([{headers, Ref, Headers} | Rest], Ref, Acc) ->
    fold_responses(Rest, Ref, Acc#{headers => Headers});
fold_responses([{data, Ref, Chunk} | Rest], Ref, Acc) ->
    Body = maps:get(body, Acc, <<>>),
    fold_responses(Rest, Ref, Acc#{body => <<Body/binary, Chunk/binary>>});
fold_responses([{done, Ref} | _], Ref, Acc) ->
    {done, Acc}.
```
