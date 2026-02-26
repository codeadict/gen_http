-module(protocol_hardening_SUITE).

%% Integration tests for HTTP/1.1 protocol hardening.
%%
%% Sends crafted wire-level responses through a real TCP connection
%% to verify that protocol limits and error detection work end-to-end.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    %% Header limits
    too_many_headers_rejected/1,
    conflicting_content_length_rejected/1,
    headers_under_limit_accepted/1,

    %% Body parsing
    chunk_size_overflow_rejected/1,
    chunked_with_trailers/1,
    chunked_no_trailers/1,
    valid_chunked_response/1,

    %% Connection health
    is_alive_returns_false_after_server_close/1,
    is_alive_returns_true_on_idle_conn/1,

    %% Close detection
    partial_content_length_reports_incomplete/1,
    incomplete_chunked_reports_error/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [
        {group, header_limits},
        {group, body_parsing},
        {group, connection_health},
        {group, close_detection}
    ].

groups() ->
    [
        {header_limits, [sequence], [
            too_many_headers_rejected,
            conflicting_content_length_rejected,
            headers_under_limit_accepted
        ]},
        {body_parsing, [sequence], [
            chunk_size_overflow_rejected,
            chunked_with_trailers,
            chunked_no_trailers,
            valid_chunked_response
        ]},
        {connection_health, [sequence], [
            is_alive_returns_false_after_server_close,
            is_alive_returns_true_on_idle_conn
        ]},
        {close_detection, [sequence], [
            partial_content_length_reports_incomplete,
            incomplete_chunked_reports_error
        ]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

%%====================================================================
%% Helpers
%%====================================================================

data_dir() ->
    %% __FILE__ resolves to this module's source path at compile time.
    %% Walk up to the test/ directory and into data/.
    TestDir = filename:dirname(?FILE),
    filename:join(TestDir, "data").

read_fixture(Filename) ->
    Path = filename:join(data_dir(), Filename),
    {ok, Bin} = file:read_file(Path),
    Bin.

%%====================================================================
%% Header Limits
%%====================================================================

too_many_headers_rejected(_Config) ->
    Response = read_fixture("too_many_headers.txt"),
    {ok, Server, Port} = mock_server:start(Response),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
    {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
    Result = gen_http_h1:recv(Conn2, 0, 5000),
    ?assertMatch({error, _, {protocol_error, too_many_headers}, _}, Result),
    mock_server:stop(Server).

conflicting_content_length_rejected(_Config) ->
    Response = read_fixture("conflicting_content_length.txt"),
    {ok, Server, Port} = mock_server:start(Response),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
    {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
    Result = gen_http_h1:recv(Conn2, 0, 5000),
    ?assertMatch({error, _, {protocol_error, conflicting_content_length}, _}, Result),
    mock_server:stop(Server).

headers_under_limit_accepted(_Config) ->
    Response = read_fixture("valid_200.txt"),
    {ok, Server, Port} = mock_server:start(Response),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
    {Conn3, Responses} = test_helper:recv_all(Conn2, 5000),
    Statuses = [S || {status, R, S} <- Responses, R =:= Ref],
    ?assertEqual([200], Statuses),
    Bodies = [B || {data, R, B} <- Responses, R =:= Ref],
    ?assertEqual([<<"hello">>], Bodies),
    gen_http_h1:close(Conn3),
    mock_server:stop(Server).

%%====================================================================
%% Body Parsing
%%====================================================================

chunk_size_overflow_rejected(_Config) ->
    Response = read_fixture("chunk_size_overflow.txt"),
    {ok, Server, Port} = mock_server:start(Response),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
    {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
    Result = gen_http_h1:recv(Conn2, 0, 5000),
    ?assertMatch({error, _, {protocol_error, chunk_size_overflow}, _}, Result),
    mock_server:stop(Server).

chunked_with_trailers(_Config) ->
    Response = read_fixture("chunked_with_trailers.txt"),
    {ok, Server, Port} = mock_server:start(Response),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
    {Conn3, Responses} = test_helper:recv_all(Conn2, 5000),
    %% Should have: status, headers, data, trailers, done
    HasTrailers = lists:any(
        fun
            ({trailers, R, _}) when R =:= Ref -> true;
            (_) -> false
        end,
        Responses
    ),
    ?assert(HasTrailers),
    TrailerHeaders = [H || {trailers, R, H} <- Responses, R =:= Ref],
    ?assertMatch([[{<<"x-checksum">>, <<"abc123">>}]], TrailerHeaders),
    gen_http_h1:close(Conn3),
    mock_server:stop(Server).

chunked_no_trailers(_Config) ->
    Response = read_fixture("chunked_no_trailers.txt"),
    {ok, Server, Port} = mock_server:start(Response),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
    {Conn3, Responses} = test_helper:recv_all(Conn2, 5000),
    %% No trailers expected
    HasTrailers = lists:any(
        fun
            ({trailers, R, _}) when R =:= Ref -> true;
            (_) -> false
        end,
        Responses
    ),
    ?assertNot(HasTrailers),
    Bodies = [B || {data, R, B} <- Responses, R =:= Ref],
    ?assertEqual([<<"hello">>], Bodies),
    gen_http_h1:close(Conn3),
    mock_server:stop(Server).

valid_chunked_response(_Config) ->
    Response = read_fixture("valid_chunked.txt"),
    {ok, Server, Port} = mock_server:start(Response),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
    {Conn3, Responses} = test_helper:recv_all(Conn2, 5000),
    Statuses = [S || {status, R, S} <- Responses, R =:= Ref],
    ?assertEqual([200], Statuses),
    HasDone = lists:any(
        fun
            ({done, R}) when R =:= Ref -> true;
            (_) -> false
        end,
        Responses
    ),
    ?assert(HasDone),
    gen_http_h1:close(Conn3),
    mock_server:stop(Server).

%%====================================================================
%% Connection Health
%%====================================================================

is_alive_returns_false_after_server_close(_Config) ->
    Response = read_fixture("valid_200.txt"),
    {ok, Server, Port} = mock_server:start(Response),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
    {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
    {Conn3, _} = test_helper:recv_all(Conn2, 5000),
    %% Server closed after sending. Give TCP FIN time to propagate.
    timer:sleep(50),
    mock_server:stop(Server),
    ?assertNot(gen_http_h1:is_alive(Conn3)).

is_alive_returns_true_on_idle_conn(_Config) ->
    %% Use linger so server keeps connection open
    Response = read_fixture("valid_200.txt"),
    {ok, Server, Port} = mock_server:start(Response, #{linger => true}),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
    {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
    {Conn3, _} = test_helper:recv_all(Conn2, 5000),
    ?assert(gen_http_h1:is_alive(Conn3)),
    gen_http_h1:close(Conn3),
    mock_server:stop(Server).

%%====================================================================
%% Close Detection
%%====================================================================

partial_content_length_reports_incomplete(_Config) ->
    Response = read_fixture("partial_body.txt"),
    {ok, Server, Port} = mock_server:start(Response),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
    {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
    %% First recv gets partial data
    Result1 = gen_http_h1:recv(Conn2, 0, 5000),
    case Result1 of
        {ok, Conn3, _Partial} ->
            %% Server closed; next recv should report incomplete body or closed
            Result2 = gen_http_h1:recv(Conn3, 0, 2000),
            case Result2 of
                {error, _, {application_error, {incomplete_body, _, _}}, _} -> ok;
                {error, _, {application_error, connection_closed}, _} -> ok;
                {error, _, {transport_error, closed}, _} -> ok
            end;
        {error, _, {application_error, {incomplete_body, _, _}}, _} ->
            ok;
        {error, _, {application_error, connection_closed}, _} ->
            ok;
        {error, _, {transport_error, closed}, _} ->
            ok
    end,
    mock_server:stop(Server).

incomplete_chunked_reports_error(_Config) ->
    %% Chunked response that ends abruptly after the chunk size line
    Incomplete = <<"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhel">>,
    {ok, Server, Port} = mock_server:start(Incomplete),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", Port, #{mode => passive}),
    {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),
    %% First recv gets partial chunked data
    Result1 = gen_http_h1:recv(Conn2, 0, 5000),
    case Result1 of
        {ok, Conn3, _Partial} ->
            Result2 = gen_http_h1:recv(Conn3, 0, 2000),
            case Result2 of
                {error, _, {application_error, incomplete_chunked_body}, _} -> ok;
                {error, _, {application_error, connection_closed}, _} -> ok;
                {error, _, {transport_error, closed}, _} -> ok
            end;
        {error, _, {application_error, incomplete_chunked_body}, _} ->
            ok;
        {error, _, {application_error, connection_closed}, _} ->
            ok;
        {error, _, {transport_error, closed}, _} ->
            ok
    end,
    mock_server:stop(Server).
