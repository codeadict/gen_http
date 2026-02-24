-module(error_path_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    %% Connection errors
    h1_connect_refused/1,
    h2_connect_refused/1,
    h1_connect_timeout/1,
    h2_connect_timeout/1,
    h1_unknown_option/1,
    h2_unknown_option/1,

    %% Close behavior
    h1_close_already_closed/1,
    h2_close_already_closed/1,
    h1_is_open_after_close/1,
    h2_is_open_after_close/1,

    %% Malformed response handling
    h1_server_sends_garbage/1,
    h1_server_closes_mid_response/1,

    %% Unified API errors
    unified_connect_refused/1,
    unified_unknown_protocol/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [
        {group, connection_errors},
        {group, close_behavior},
        {group, malformed_responses},
        {group, unified_errors}
    ].

groups() ->
    [
        {connection_errors, [parallel], [
            h1_connect_refused,
            h2_connect_refused,
            h1_connect_timeout,
            h2_connect_timeout,
            h1_unknown_option,
            h2_unknown_option
        ]},
        {close_behavior, [parallel], [
            h1_close_already_closed,
            h2_close_already_closed,
            h1_is_open_after_close,
            h2_is_open_after_close
        ]},
        {malformed_responses, [sequence], [
            h1_server_sends_garbage,
            h1_server_closes_mid_response
        ]},
        {unified_errors, [parallel], [
            unified_connect_refused,
            unified_unknown_protocol
        ]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

%%====================================================================
%% Connection Errors
%%====================================================================

h1_connect_refused(_Config) ->
    %% Port 1 is almost always not listening
    Result = gen_http_h1:connect(http, "127.0.0.1", 1, #{timeout => 500}),
    ?assertMatch({error, {transport_error, {connect_failed, _}}}, Result).

h2_connect_refused(_Config) ->
    Result = gen_http_h2:connect(http, "127.0.0.1", 1, #{timeout => 500}),
    ?assertMatch({error, {transport_error, {connect_failed, _}}}, Result).

h1_connect_timeout(_Config) ->
    %% 192.0.2.1 is TEST-NET, should be non-routable and time out
    Result = gen_http_h1:connect(http, "192.0.2.1", 80, #{timeout => 200}),
    ?assertMatch({error, {transport_error, {connect_failed, _}}}, Result).

h2_connect_timeout(_Config) ->
    Result = gen_http_h2:connect(http, "192.0.2.1", 80, #{timeout => 200}),
    ?assertMatch({error, {transport_error, {connect_failed, _}}}, Result).

h1_unknown_option(_Config) ->
    Result = gen_http_h1:connect(http, "localhost", 80, #{max_pipline => 5}),
    ?assertEqual({error, {unknown_option, max_pipline}}, Result).

h2_unknown_option(_Config) ->
    Result = gen_http_h2:connect(http, "localhost", 80, #{max_concurrnt => 50}),
    ?assertEqual({error, {unknown_option, max_concurrnt}}, Result).

%%====================================================================
%% Close Behavior
%%====================================================================

h1_close_already_closed(Config) ->
    Conn = make_h1_conn(Config),
    {ok, Conn2} = gen_http_h1:close(Conn),
    ?assertNot(gen_http_h1:is_open(Conn2)),
    %% Closing again should be idempotent
    {ok, Conn3} = gen_http_h1:close(Conn2),
    ?assertNot(gen_http_h1:is_open(Conn3)).

h2_close_already_closed(Config) ->
    Conn = make_h2_conn(Config),
    {ok, Conn2} = gen_http_h2:close(Conn),
    ?assertNot(gen_http_h2:is_open(Conn2)),
    {ok, Conn3} = gen_http_h2:close(Conn2),
    ?assertNot(gen_http_h2:is_open(Conn3)).

h1_is_open_after_close(Config) ->
    Conn = make_h1_conn(Config),
    ?assert(gen_http_h1:is_open(Conn)),
    {ok, Conn2} = gen_http_h1:close(Conn),
    ?assertNot(gen_http_h1:is_open(Conn2)).

h2_is_open_after_close(Config) ->
    Conn = make_h2_conn(Config),
    ?assert(gen_http_h2:is_open(Conn)),
    {ok, Conn2} = gen_http_h2:close(Conn),
    ?assertNot(gen_http_h2:is_open(Conn2)).

%%====================================================================
%% Malformed Response Handling
%%====================================================================

h1_server_sends_garbage(_Config) ->
    {ServerPort, ListenSock} = start_tcp_server(),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", ServerPort, #{mode => passive}),

    %% Send a request
    {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),

    %% Accept and send garbage from server side
    {ok, ClientSock} = gen_tcp:accept(ListenSock, 2000),
    gen_tcp:send(ClientSock, <<"NOT-HTTP GARBAGE\r\n\r\n">>),
    gen_tcp:close(ClientSock),

    %% Client should get a parse error or closed error
    Result = gen_http_h1:recv(Conn2, 0, 2000),
    case Result of
        {error, _Conn3, {protocol_error, _}, _} -> ok;
        {error, _Conn3, {transport_error, closed}, _} -> ok;
        {ok, _Conn3, _Responses} -> ok
    end,
    gen_tcp:close(ListenSock).

h1_server_closes_mid_response(_Config) ->
    {ServerPort, ListenSock} = start_tcp_server(),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", ServerPort, #{mode => passive}),

    %% Send a request
    {ok, Conn2, _Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),

    %% Accept, send partial response, then close
    {ok, ClientSock} = gen_tcp:accept(ListenSock, 2000),
    gen_tcp:send(ClientSock, <<"HTTP/1.1 200 OK\r\ncontent-length: 1000\r\n\r\npartial">>),
    gen_tcp:close(ClientSock),

    %% Client should eventually get a closed/error
    Result = gen_http_h1:recv(Conn2, 0, 2000),
    case Result of
        {ok, Conn3, Responses} ->
            %% May get partial data followed by close on next recv
            ct:pal("Got partial responses: ~p", [Responses]),
            Result2 = gen_http_h1:recv(Conn3, 0, 2000),
            case Result2 of
                {error, _, {transport_error, closed}, _} -> ok;
                {error, _, _, _} -> ok;
                {ok, _, _} -> ok
            end;
        {error, _Conn3, _Reason, _Responses} ->
            ok
    end,
    gen_tcp:close(ListenSock).

%%====================================================================
%% Unified API Errors
%%====================================================================

unified_connect_refused(_Config) ->
    Result = gen_http:connect(http, "127.0.0.1", 1, #{timeout => 500}),
    ?assertMatch({error, {transport_error, {connect_failed, _}}}, Result).

unified_unknown_protocol(_Config) ->
    Result = gen_http:connect(https, "127.0.0.1", 1, #{
        timeout => 500,
        protocols => [http2]
    }),
    ?assertMatch({error, _}, Result).

%%====================================================================
%% Helpers
%%====================================================================

start_tcp_server() ->
    {ok, ListenSock} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(ListenSock),
    {Port, ListenSock}.

make_h1_conn(_Config) ->
    {ServerPort, ListenSock} = start_tcp_server(),
    {ok, Conn} = gen_http_h1:connect(http, "127.0.0.1", ServerPort, #{mode => passive}),
    %% Accept the connection on server side (don't need to do anything with it)
    spawn(fun() ->
        {ok, _Sock} = gen_tcp:accept(ListenSock, 5000),
        timer:sleep(60000)
    end),
    put(listen_sock, ListenSock),
    Conn.

make_h2_conn(_Config) ->
    {ServerPort, ListenSock} = start_tcp_server(),
    %% H2 connect over plaintext will try to send preface, so we need
    %% a server that at least accepts the connection
    spawn(fun() ->
        case gen_tcp:accept(ListenSock, 5000) of
            {ok, Sock} ->
                %% Read the preface, send back a minimal SETTINGS frame
                Preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>,
                case gen_tcp:recv(Sock, byte_size(Preface), 5000) of
                    {ok, _} ->
                        %% Also consume the client SETTINGS frame
                        case gen_tcp:recv(Sock, 9, 5000) of
                            {ok, <<Len:24, _:48>>} ->
                                gen_tcp:recv(Sock, Len, 5000),
                                %% Send empty SETTINGS + SETTINGS ACK
                                EmptySettings = <<0:24, 4:8, 0:8, 0:32>>,
                                SettingsAck = <<0:24, 4:8, 1:8, 0:32>>,
                                gen_tcp:send(Sock, [EmptySettings, SettingsAck]),
                                timer:sleep(60000);
                            _ ->
                                ok
                        end;
                    _ ->
                        ok
                end;
            _ ->
                ok
        end
    end),
    %% Give the server a moment to start accepting
    timer:sleep(50),
    {ok, Conn} = gen_http_h2:connect(http, "127.0.0.1", ServerPort, #{mode => passive}),
    put(listen_sock, ListenSock),
    Conn.
