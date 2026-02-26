-module(prop_gen_http_h1_limits).

%% PropEr tests for HTTP/1.1 protocol hardening limits.
%%
%% Tests header count limits, chunk size hex length, and chunk size
%% value boundaries by sending crafted responses through a real TCP
%% connection via mock_server.

-include_lib("proper/include/proper.hrl").

%%--------------------------------------------------------------------
%% Header count: count > max_header_count triggers error
%%--------------------------------------------------------------------

prop_header_count_limit() ->
    ?FORALL(
        {HeaderCount, MaxCount},
        {range(1, 150), range(10, 100)},
        begin
            Headers = [
                iolist_to_binary(
                    io_lib:format("x-h-~B: v~B\r\n", [I, I])
                )
             || I <- lists:seq(1, HeaderCount)
            ],
            Response = iolist_to_binary([
                <<"HTTP/1.1 200 OK\r\n">>,
                Headers,
                <<"content-length: 2\r\n">>,
                <<"\r\nok">>
            ]),
            {ok, Server, Port} = mock_server:start(Response),
            {ok, Conn} = gen_http_h1:connect(
                http,
                "127.0.0.1",
                Port,
                #{mode => passive, max_header_count => MaxCount}
            ),
            {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
            Result = recv_until_done_or_error(Conn2),
            mock_server:stop(Server),
            %% +1 for content-length header we appended
            TotalHeaders = HeaderCount + 1,
            case TotalHeaders > MaxCount of
                true ->
                    is_too_many_headers(Result);
                false ->
                    not is_too_many_headers(Result)
            end
        end
    ).

%%--------------------------------------------------------------------
%% Chunk hex length: hex strings > 16 chars always rejected
%%--------------------------------------------------------------------

prop_chunk_size_hex_length() ->
    ?FORALL(
        HexLen,
        range(1, 24),
        begin
            %% Use '0' padding with a small value so short hex strings
            %% don't accidentally overflow by value. e.g. "00000000A" = 10.
            HexStr = list_to_binary(
                lists:duplicate(max(0, HexLen - 1), $0) ++ [$A]
            ),
            Response = iolist_to_binary([
                <<"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n">>,
                HexStr,
                <<"\r\ndata\r\n">>
            ]),
            {ok, Server, Port} = mock_server:start(Response),
            {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
            {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
            Result = recv_until_done_or_error(Conn2),
            mock_server:stop(Server),
            case HexLen > 16 of
                true ->
                    is_chunk_overflow(Result);
                false ->
                    %% Value is always 10 (0xA), so no value overflow
                    not is_chunk_overflow(Result)
            end
        end
    ).

%%--------------------------------------------------------------------
%% Chunk size value: values > 2^31-1 rejected even if hex length <= 16
%%--------------------------------------------------------------------

prop_chunk_size_value_range() ->
    ?FORALL(
        Size,
        oneof([range(1, 100), range(2147483640, 2147483660)]),
        begin
            HexStr = list_to_binary(integer_to_list(Size, 16)),
            %% Build a chunked response with this size.
            %% The server will close before sending the body data,
            %% so either chunk_size_overflow fires or we get a partial read.
            Response = iolist_to_binary([
                <<"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n">>,
                HexStr,
                <<"\r\n">>
            ]),
            {ok, Server, Port} = mock_server:start(Response),
            {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
            {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
            Result = recv_until_done_or_error(Conn2),
            mock_server:stop(Server),
            case Size > 2147483647 of
                true ->
                    is_chunk_overflow(Result);
                false ->
                    %% Should not be a chunk_size_overflow error.
                    %% May be incomplete_chunked_body, closed, etc.
                    not is_chunk_overflow(Result)
            end
        end
    ).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

recv_until_done_or_error(Conn) ->
    recv_until_done_or_error(Conn, []).

recv_until_done_or_error(Conn, Acc) ->
    case gen_http_h1:recv(Conn, 0, 3000) of
        {ok, Conn2, Responses} ->
            NewAcc = Acc ++ Responses,
            case
                lists:any(
                    fun
                        ({done, _}) -> true;
                        (_) -> false
                    end,
                    Responses
                )
            of
                true -> {ok, NewAcc};
                false -> recv_until_done_or_error(Conn2, NewAcc)
            end;
        {error, _Conn2, Reason, Responses} ->
            {error, Reason, Acc ++ Responses};
        {error, _Conn2, Reason} ->
            {error, Reason, Acc}
    end.

is_too_many_headers({error, {protocol_error, too_many_headers}, _}) -> true;
is_too_many_headers(_) -> false.

is_chunk_overflow({error, {protocol_error, chunk_size_overflow}, _}) -> true;
is_chunk_overflow(_) -> false.
