-module(mock_server).

%% Two operating modes:
%%
%% 1. Canned-response mode (start/1,2): accepts a connection, reads
%%    the request (discards it), replays a fixed binary, then closes.
%%    Used by protocol_hardening_SUITE and property tests.
%%
%% 2. HTTP echo mode (start_http/0): a keep-alive HTTP/1.1 server
%%    that parses requests with {packet, http_bin}, routes by path,
%%    and echoes back JSON. Replaces the httpbin Docker container.

-export([
    start/1,
    start/2,
    start_http/0,
    stop/1
]).

%%====================================================================
%% Canned-response mode (unchanged API)
%%====================================================================

-spec start(binary() | [binary()]) -> {ok, pid(), inet:port_number()}.
start(Response) ->
    start(Response, #{}).

-spec start(binary() | [binary()], map()) -> {ok, pid(), inet:port_number()}.
start(Response, Opts) ->
    Parent = self(),
    Pid = spawn_link(fun() -> init(Parent, Response, Opts) end),
    receive
        {Pid, {ok, Port}} -> {ok, Pid, Port};
        {Pid, {error, Reason}} -> error(Reason)
    after 5000 ->
        error(mock_server_start_timeout)
    end.

-spec stop(pid()) -> ok.
stop(Pid) ->
    Ref = monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 ->
        demonitor(Ref, [flush]),
        exit(Pid, kill),
        ok
    end.

%%====================================================================
%% HTTP echo mode
%%====================================================================

-spec start_http() -> {ok, pid(), inet:port_number()}.
start_http() ->
    Parent = self(),
    Pid = spawn_link(fun() -> http_init(Parent) end),
    receive
        {Pid, {ok, Port}} -> {ok, Pid, Port};
        {Pid, {error, Reason}} -> error(Reason)
    after 5000 ->
        error(mock_server_start_timeout)
    end.

%%====================================================================
%% Canned-response internals
%%====================================================================

init(Parent, Response, Opts) ->
    {ok, LSock} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(LSock),
    Parent ! {self(), {ok, Port}},
    AcceptCount = maps:get(accept_count, Opts, 1),
    accept_loop(LSock, Response, Opts, AcceptCount),
    gen_tcp:close(LSock),
    wait_for_stop().

accept_loop(_LSock, _Response, _Opts, 0) ->
    ok;
accept_loop(LSock, Response, Opts, Remaining) ->
    case gen_tcp:accept(LSock, 5000) of
        {ok, Sock} ->
            consume_request(Sock),
            Delay = maps:get(delay, Opts, 0),
            delay(Delay),
            send_response(Sock, Response, Opts),
            Linger = maps:get(linger, Opts, false),
            case Linger of
                true -> ok;
                false -> gen_tcp:close(Sock)
            end,
            accept_loop(LSock, Response, Opts, Remaining - 1);
        {error, _} ->
            ok
    end.

consume_request(Sock) ->
    %% Read whatever the client sent. We don't parse it.
    gen_tcp:recv(Sock, 0, 2000),
    ok.

send_response(Sock, Response, Opts) when is_binary(Response) ->
    ChunkSize = maps:get(chunk_size, Opts, 0),
    case ChunkSize > 0 of
        true ->
            send_chunked(Sock, Response, ChunkSize, Opts);
        false ->
            gen_tcp:send(Sock, Response)
    end;
send_response(Sock, [First | Rest], Opts) ->
    send_response(Sock, First, Opts),
    ChunkDelay = maps:get(chunk_delay, Opts, 0),
    lists:foreach(
        fun(Part) ->
            delay(ChunkDelay),
            gen_tcp:send(Sock, Part)
        end,
        Rest
    );
send_response(_Sock, [], _Opts) ->
    ok.

send_chunked(Sock, Data, ChunkSize, Opts) ->
    ChunkDelay = maps:get(chunk_delay, Opts, 0),
    send_chunked_loop(Sock, Data, ChunkSize, ChunkDelay).

send_chunked_loop(_Sock, <<>>, _ChunkSize, _Delay) ->
    ok;
send_chunked_loop(Sock, Data, ChunkSize, Delay) ->
    Size = min(ChunkSize, byte_size(Data)),
    <<Chunk:Size/binary, Rest/binary>> = Data,
    gen_tcp:send(Sock, Chunk),
    case byte_size(Rest) > 0 of
        true ->
            delay(Delay),
            send_chunked_loop(Sock, Rest, ChunkSize, Delay);
        false ->
            ok
    end.

%%====================================================================
%% HTTP echo internals
%%====================================================================

-record(http_req, {
    method = <<"GET">> :: binary(),
    path = <<"/">> :: binary(),
    query = <<>> :: binary(),
    headers = [] :: [{binary(), binary()}],
    body = <<>> :: binary()
}).

http_init(Parent) ->
    process_flag(trap_exit, true),
    {ok, LSock} = gen_tcp:listen(0, [
        binary,
        {active, false},
        {reuseaddr, true},
        {backlog, 128},
        {packet, http_bin},
        {nodelay, true}
    ]),
    {ok, Port} = inet:port(LSock),
    Parent ! {self(), {ok, Port}},
    http_accept_loop(LSock).

http_accept_loop(LSock) ->
    case gen_tcp:accept(LSock, 1000) of
        {ok, Sock} ->
            Handler = spawn(fun() ->
                receive
                    {ready, S} -> http_connection_loop(S)
                end
            end),
            gen_tcp:controlling_process(Sock, Handler),
            Handler ! {ready, Sock},
            http_accept_loop(LSock);
        {error, timeout} ->
            case check_stop() of
                stop -> gen_tcp:close(LSock);
                continue -> http_accept_loop(LSock)
            end;
        {error, closed} ->
            ok
    end.

check_stop() ->
    receive
        stop -> stop
    after 0 ->
        continue
    end.

http_connection_loop(Sock) ->
    case http_read_request(Sock) of
        {ok, Req} ->
            http_handle(Sock, Req),
            case http_should_close(Req) of
                true -> gen_tcp:close(Sock);
                false -> http_connection_loop(Sock)
            end;
        {error, _} ->
            gen_tcp:close(Sock)
    end.

http_read_request(Sock) ->
    case gen_tcp:recv(Sock, 0, 30000) of
        {ok, {http_request, Method, {abs_path, RawPath}, _Vsn}} ->
            {Path, Query} = http_split_path(RawPath),
            http_read_headers(Sock, #http_req{
                method = http_method_bin(Method),
                path = Path,
                query = Query
            });
        {ok, {http_error, _}} ->
            {error, bad_request};
        {error, Reason} ->
            {error, Reason}
    end.

http_read_headers(Sock, Req) ->
    case gen_tcp:recv(Sock, 0, 30000) of
        {ok, {http_header, _, Name, _, Value}} ->
            Key = http_header_key(Name),
            http_read_headers(Sock, Req#http_req{
                headers = [{Key, Value} | Req#http_req.headers]
            });
        {ok, http_eoh} ->
            http_read_body(Sock, Req);
        {error, Reason} ->
            {error, Reason}
    end.

http_read_body(Sock, Req) ->
    case http_is_chunked(Req#http_req.headers) of
        true ->
            inet:setopts(Sock, [{packet, raw}]),
            case http_read_chunked_body(Sock, []) of
                {ok, Body} ->
                    inet:setopts(Sock, [{packet, http_bin}]),
                    {ok, Req#http_req{body = Body}};
                {error, Reason} ->
                    {error, Reason}
            end;
        false ->
            CL = http_content_length(Req#http_req.headers),
            case CL of
                0 ->
                    {ok, Req};
                N when N > 0 ->
                    inet:setopts(Sock, [{packet, raw}]),
                    case gen_tcp:recv(Sock, N, 30000) of
                        {ok, Body} ->
                            inet:setopts(Sock, [{packet, http_bin}]),
                            {ok, Req#http_req{body = Body}};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
    end.

http_read_chunked_body(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 30000) of
        {ok, Data} ->
            case http_parse_chunks(Data, Acc) of
                {done, Body} -> {ok, Body};
                {more, NewAcc, <<>>} -> http_read_chunked_body(Sock, NewAcc);
                {more, NewAcc, Rest} -> http_parse_more_chunks(Sock, NewAcc, Rest)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

http_parse_more_chunks(Sock, Acc, Buf) ->
    case http_parse_chunks(Buf, Acc) of
        {done, Body} ->
            {ok, Body};
        {more, NewAcc, <<>>} ->
            http_read_chunked_body(Sock, NewAcc);
        {more, NewAcc, Rest} ->
            case gen_tcp:recv(Sock, 0, 30000) of
                {ok, More} -> http_parse_more_chunks(Sock, NewAcc, <<Rest/binary, More/binary>>);
                {error, Reason} -> {error, Reason}
            end
    end.

http_parse_chunks(Bin, Acc) ->
    case binary:split(Bin, <<"\r\n">>) of
        [SizeLine, Rest] ->
            Size = binary_to_integer(string:trim(SizeLine), 16),
            case Size of
                0 ->
                    {done, iolist_to_binary(lists:reverse(Acc))};
                _ ->
                    case Rest of
                        <<Chunk:Size/binary, "\r\n", Remaining/binary>> ->
                            http_parse_chunks(Remaining, [Chunk | Acc]);
                        <<Chunk:Size/binary, "\r\n">> ->
                            {more, [Chunk | Acc], <<>>};
                        _ when byte_size(Rest) >= Size ->
                            <<Chunk:Size/binary, _/binary>> = Rest,
                            {more, [Chunk | Acc], <<>>};
                        _ ->
                            {more, Acc, Bin}
                    end
            end;
        [_Incomplete] ->
            {more, Acc, Bin}
    end.

%%--------------------------------------------------------------------
%% HTTP routing
%%--------------------------------------------------------------------

http_handle(Sock, Req) ->
    inet:setopts(Sock, [{packet, raw}]),
    http_route(Sock, Req#http_req.method, Req#http_req.path, Req),
    inet:setopts(Sock, [{packet, http_bin}]).

http_route(Sock, <<"GET">>, <<"/get">>, Req) ->
    http_echo_json(Sock, Req);
http_route(Sock, <<"POST">>, <<"/post">>, Req) ->
    http_echo_json(Sock, Req);
http_route(Sock, <<"GET">>, <<"/status/", CodeBin/binary>>, _Req) ->
    Code = binary_to_integer(CodeBin),
    http_send(Sock, Code, [], <<>>);
http_route(Sock, <<"GET">>, <<"/redirect/", NBin/binary>>, _Req) ->
    N = binary_to_integer(NBin),
    Location =
        case N of
            1 -> <<"/get">>;
            _ -> <<"/redirect/", (integer_to_binary(N - 1))/binary>>
        end,
    http_send(Sock, 302, [{<<"location">>, Location}], <<>>);
http_route(Sock, <<"GET">>, <<"/bytes/", NBin/binary>>, _Req) ->
    N = binary_to_integer(NBin),
    Body = binary:copy(<<0>>, N),
    http_send(Sock, 200, [{<<"content-type">>, <<"application/octet-stream">>}], Body);
http_route(Sock, <<"GET">>, <<"/stream-bytes/", NBin/binary>>, _Req) ->
    N = binary_to_integer(NBin),
    http_send_chunked_bytes(Sock, N);
http_route(Sock, <<"GET">>, <<"/response-headers">>, Req) ->
    Extra = http_parse_query(Req#http_req.query),
    http_send(Sock, 200, Extra, <<"{}">>);
http_route(Sock, <<"GET">>, <<"/delay/", NBin/binary>>, Req) ->
    Secs = binary_to_integer(NBin),
    timer:sleep(Secs * 1000),
    http_echo_json(Sock, Req);
http_route(Sock, _Method, _Path, _Req) ->
    http_send(Sock, 200, [], <<>>).

%%--------------------------------------------------------------------
%% HTTP response helpers
%%--------------------------------------------------------------------

http_echo_json(Sock, #http_req{method = M, path = P, query = Q, headers = H, body = B}) ->
    Args =
        case Q of
            <<>> -> <<"{}">>;
            _ -> http_query_to_json(Q)
        end,
    Hdrs = http_headers_to_json(H),
    Json = iolist_to_binary([
        <<"{\"method\":\"">>,
        M,
        <<"\",\"path\":\"">>,
        P,
        <<"\",\"args\":">>,
        Args,
        <<",\"data\":\"">>,
        http_escape(B),
        <<"\",\"headers\":">>,
        Hdrs,
        <<"}">>
    ]),
    http_send(Sock, 200, [{<<"content-type">>, <<"application/json">>}], Json).

http_send(Sock, Code, Extra, Body) ->
    Status = [<<"HTTP/1.1 ">>, integer_to_binary(Code), <<" ">>, http_reason(Code), <<"\r\n">>],
    Base = [
        <<"content-length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n">>,
        <<"connection: keep-alive\r\n">>
    ],
    ExtraLines = [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- Extra],
    gen_tcp:send(Sock, [Status, Base, ExtraLines, <<"\r\n">>, Body]).

http_send_chunked_bytes(Sock, Total) ->
    Header = [
        <<"HTTP/1.1 200 OK\r\n">>,
        <<"transfer-encoding: chunked\r\n">>,
        <<"connection: keep-alive\r\n">>,
        <<"\r\n">>
    ],
    ok = gen_tcp:send(Sock, Header),
    http_write_chunks(Sock, Total),
    ok = gen_tcp:send(Sock, <<"0\r\n\r\n">>).

http_write_chunks(_Sock, N) when N =< 0 -> ok;
http_write_chunks(Sock, N) ->
    Sz = min(256, N),
    Hex = list_to_binary(integer_to_list(Sz, 16)),
    ok = gen_tcp:send(Sock, [Hex, <<"\r\n">>, binary:copy(<<0>>, Sz), <<"\r\n">>]),
    http_write_chunks(Sock, N - Sz).

%%====================================================================
%% Shared helpers
%%====================================================================

wait_for_stop() ->
    receive
        stop -> ok
    after 60000 ->
        ok
    end.

delay(0) -> ok;
delay(Ms) -> timer:sleep(Ms).

%%--------------------------------------------------------------------
%% HTTP-mode utilities
%%--------------------------------------------------------------------

http_method_bin('GET') -> <<"GET">>;
http_method_bin('POST') -> <<"POST">>;
http_method_bin('PUT') -> <<"PUT">>;
http_method_bin('DELETE') -> <<"DELETE">>;
http_method_bin('HEAD') -> <<"HEAD">>;
http_method_bin('OPTIONS') -> <<"OPTIONS">>;
http_method_bin('PATCH') -> <<"PATCH">>;
http_method_bin(Bin) when is_binary(Bin) -> Bin.

http_header_key(Atom) when is_atom(Atom) ->
    list_to_binary(string:lowercase(atom_to_list(Atom)));
http_header_key(Bin) when is_binary(Bin) ->
    string:lowercase(Bin).

http_split_path(RawPath) ->
    case binary:split(RawPath, <<"?">>) of
        [Path] -> {Path, <<>>};
        [Path, Query] -> {Path, Query}
    end.

http_content_length(Headers) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, Val} -> binary_to_integer(Val);
        false -> 0
    end.

http_is_chunked(Headers) ->
    case lists:keyfind(<<"transfer-encoding">>, 1, Headers) of
        {_, Val} -> binary:match(Val, <<"chunked">>) =/= nomatch;
        false -> false
    end.

http_should_close(#http_req{headers = Hdrs}) ->
    case lists:keyfind(<<"connection">>, 1, Hdrs) of
        {_, <<"close">>} -> true;
        _ -> false
    end.

http_parse_query(<<>>) ->
    [];
http_parse_query(Query) ->
    Pairs = binary:split(Query, <<"&">>, [global]),
    lists:filtermap(
        fun(Pair) ->
            case binary:split(Pair, <<"=">>) of
                [Key, Val] -> {true, {Key, Val}};
                _ -> false
            end
        end,
        Pairs
    ).

http_reason(200) -> <<"OK">>;
http_reason(302) -> <<"Found">>;
http_reason(404) -> <<"Not Found">>;
http_reason(Code) -> integer_to_binary(Code).

http_escape(Bin) ->
    binary:replace(
        binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
        <<"\"">>,
        <<"\\\"">>,
        [global]
    ).

http_headers_to_json(Hdrs) ->
    Pairs = [[<<"\"">>, K, <<"\":\"">>, http_escape(V), <<"\"">>] || {K, V} <- Hdrs],
    [<<"{">>, lists:join(<<",">>, Pairs), <<"}">>].

http_query_to_json(Query) ->
    Pairs = http_parse_query(Query),
    Js = [[<<"\"">>, K, <<"\":\"">>, http_escape(V), <<"\"">>] || {K, V} <- Pairs],
    [<<"{">>, lists:join(<<",">>, Js), <<"}">>].
