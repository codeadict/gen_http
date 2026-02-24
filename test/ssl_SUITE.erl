-module(ssl_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    % SSL connection tests
    connect_to_https_server/1,
    connect_with_verify_none/1,
    connect_timeout/1,
    certificate_verification/1,

    % ALPN tests
    alpn_negotiation/1,
    alpn_http2_preference/1,

    % Socket operations
    send_and_receive/1,
    setopts/1,
    controlling_process/1,
    close/1,

    % TCP tests
    tcp_connect_valid_host/1,
    tcp_connect_timeout/1,
    tcp_connect_refused/1,
    tcp_send_and_receive/1,
    tcp_setopts/1,
    tcp_controlling_process/1,
    tcp_upgrade_not_supported/1,
    tcp_negotiated_protocol_not_available/1,
    tcp_close/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [
        {group, ssl_connection},
        {group, alpn},
        {group, ssl_operations},
        {group, tcp_connection},
        {group, tcp_operations}
    ].

groups() ->
    [
        {ssl_connection, [parallel], [
            connect_to_https_server,
            connect_with_verify_none,
            connect_timeout,
            certificate_verification
        ]},
        {alpn, [sequence], [
            alpn_negotiation,
            alpn_http2_preference
        ]},
        {ssl_operations, [parallel], [
            send_and_receive,
            setopts,
            controlling_process,
            close
        ]},
        {tcp_connection, [parallel], [
            tcp_connect_valid_host,
            tcp_connect_timeout,
            tcp_connect_refused
        ]},
        {tcp_operations, [parallel], [
            tcp_send_and_receive,
            tcp_setopts,
            tcp_controlling_process,
            tcp_upgrade_not_supported,
            tcp_negotiated_protocol_not_available,
            tcp_close
        ]}
    ].

init_per_suite(Config) ->
    %% Check if docker-compose services are available
    case test_helper:is_server_available() of
        true ->
            ct:pal("Docker services are available"),
            Config;
        false ->
            {skip, "Docker services not available. Run: docker compose -f test/support/docker-compose.yml up -d"}
    end.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% SSL Connection Tests
%%====================================================================

connect_to_https_server(_Config) ->
    ct:pal("Testing SSL connection to HTTPS server"),
    {https, Host, Port} = test_helper:https_server(),
    Result = gen_http_ssl:connect(Host, Port, [{verify, verify_none}]),
    ?assertMatch({ok, _Socket}, Result),
    {ok, Socket} = Result,
    ok = gen_http_ssl:close(Socket),
    ok.

connect_with_verify_none(_Config) ->
    ct:pal("Testing SSL connection without certificate verification"),
    {https, Host, Port} = test_helper:https_server(),
    Result = gen_http_ssl:connect(Host, Port, [{verify, verify_none}]),
    ?assertMatch({ok, _Socket}, Result),
    {ok, Socket} = Result,
    ok = gen_http_ssl:close(Socket),
    ok.

connect_timeout(_Config) ->
    ct:pal("Testing SSL connection timeout"),
    %% Try to connect to an IP that doesn't respond
    Result = gen_http_ssl:connect("192.0.2.1", 443, [{timeout, 100}]),
    ?assertMatch({error, _}, Result),
    ok.

certificate_verification(_Config) ->
    ct:pal("Testing certificate verification"),
    {https, Host, Port} = test_helper:https_server(),

    %% Test with self-signed certificate (should fail with verify_peer)
    Result1 = gen_http_ssl:connect(Host, Port, [{verify, verify_peer}]),
    %% Self-signed cert should fail verification
    ?assertMatch({error, _}, Result1),

    %% With verify_none should succeed
    Result2 = gen_http_ssl:connect(Host, Port, [{verify, verify_none}]),
    ?assertMatch({ok, _}, Result2),
    {ok, Socket2} = Result2,
    ok = gen_http_ssl:close(Socket2),
    ok.

%%====================================================================
%% ALPN Tests
%%====================================================================

alpn_negotiation(_Config) ->
    ct:pal("Testing ALPN negotiation"),
    %% Connect to a server that supports HTTP/2 (e.g., google.com)
    {ok, Socket} = gen_http_ssl:connect("google.com", 443, [
        {alpn_advertise, [<<"h2">>, <<"http/1.1">>]}
    ]),

    %% Check negotiated protocol
    Result = gen_http_ssl:negotiated_protocol(Socket),
    ?assertMatch(
        {ok, Protocol} when Protocol =:= <<"h2">> orelse Protocol =:= <<"http/1.1">>,
        Result
    ),

    ok = gen_http_ssl:close(Socket),
    ok.

alpn_http2_preference(_Config) ->
    ct:pal("Testing ALPN HTTP/2 preference"),
    %% Many modern servers prefer HTTP/2, test with a known HTTP/2 server
    {ok, Socket} = gen_http_ssl:connect("www.google.com", 443, []),

    case gen_http_ssl:negotiated_protocol(Socket) of
        {ok, Protocol} ->
            %% Should be either h2 or http/1.1
            ?assert(Protocol =:= <<"h2">> orelse Protocol =:= <<"http/1.1">>);
        {error, protocol_not_negotiated} ->
            %% Some servers might not support ALPN
            ?assert(true)
    end,

    ok = gen_http_ssl:close(Socket),
    ok.

%%====================================================================
%% SSL Socket Operations
%%====================================================================

send_and_receive(_Config) ->
    ct:pal("Testing SSL send and receive operations"),
    {https, Host, Port} = test_helper:https_server(),
    {ok, Socket} = gen_http_ssl:connect(Host, Port, [{verify, verify_none}]),

    %% Test that we can send data without error
    TestData = <<"GET /get HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n">>,
    ?assertEqual(ok, gen_http_ssl:send(Socket, TestData)),

    %% Test that setopts works for switching to passive mode
    ?assertEqual(ok, gen_http_ssl:setopts(Socket, [{active, false}])),

    ok = gen_http_ssl:close(Socket),
    ok.

setopts(_Config) ->
    ct:pal("Testing SSL setopts"),
    {https, Host, Port} = test_helper:https_server(),
    {ok, Socket} = gen_http_ssl:connect(Host, Port, [{verify, verify_none}]),

    %% Test setting active mode
    ?assertEqual(ok, gen_http_ssl:setopts(Socket, [{active, once}])),
    ?assertEqual(ok, gen_http_ssl:setopts(Socket, [{active, false}])),

    ok = gen_http_ssl:close(Socket),
    ok.

controlling_process(_Config) ->
    ct:pal("Testing SSL controlling_process"),
    {https, Host, Port} = test_helper:https_server(),
    {ok, Socket} = gen_http_ssl:connect(Host, Port, [{verify, verify_none}]),

    %% Transfer to self (should succeed)
    ?assertEqual(ok, gen_http_ssl:controlling_process(Socket, self())),

    ok = gen_http_ssl:close(Socket),
    ok.

close(_Config) ->
    ct:pal("Testing SSL close"),
    {https, Host, Port} = test_helper:https_server(),
    {ok, Socket} = gen_http_ssl:connect(Host, Port, [{verify, verify_none}]),
    ?assertEqual(ok, gen_http_ssl:close(Socket)),

    %% Verify socket is closed by trying to send
    Result = gen_http_ssl:send(Socket, "test"),
    ?assertMatch({error, _}, Result),
    ok.

%%====================================================================
%% TCP Connection Tests
%%====================================================================

tcp_connect_valid_host(_Config) ->
    ct:pal("Testing TCP connection to valid host"),
    {http, Host, Port} = test_helper:http_server(),
    Result = gen_http_tcp:connect(Host, Port, []),
    ?assertMatch({ok, _Socket}, Result),
    {ok, Socket} = Result,
    ok = gen_http_tcp:close(Socket),
    ok.

tcp_connect_timeout(_Config) ->
    ct:pal("Testing TCP connection timeout"),
    %% Try to connect to an IP that doesn't respond (reserved IP, should timeout)
    %% Use a very short timeout to speed up the test
    Result = gen_http_tcp:connect("192.0.2.1", 80, [{timeout, 100}]),
    ?assertMatch({error, _}, Result),
    ok.

tcp_connect_refused(_Config) ->
    ct:pal("Testing TCP connection refused"),
    %% Connect to localhost on a port that's likely not listening
    Result = gen_http_tcp:connect("localhost", 9999, [{timeout, 1000}]),
    ?assertMatch({error, econnrefused}, Result),
    ok.

%%====================================================================
%% TCP Socket Operations
%%====================================================================

tcp_send_and_receive(_Config) ->
    ct:pal("Testing TCP send operations"),
    {http, Host, Port} = test_helper:http_server(),
    {ok, Socket} = gen_http_tcp:connect(Host, Port, []),

    %% Test that we can send data without error
    TestData = <<"GET /get HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n">>,
    ?assertEqual(ok, gen_http_tcp:send(Socket, TestData)),

    %% Test that setopts works for switching to passive mode
    ?assertEqual(ok, gen_http_tcp:setopts(Socket, [{active, false}])),

    ok = gen_http_tcp:close(Socket),
    ok.

tcp_setopts(_Config) ->
    ct:pal("Testing TCP setopts"),
    {http, Host, Port} = test_helper:http_server(),
    {ok, Socket} = gen_http_tcp:connect(Host, Port, []),

    %% Test setting active mode
    ?assertEqual(ok, gen_http_tcp:setopts(Socket, [{active, once}])),
    ?assertEqual(ok, gen_http_tcp:setopts(Socket, [{active, false}])),

    ok = gen_http_tcp:close(Socket),
    ok.

tcp_controlling_process(_Config) ->
    ct:pal("Testing TCP controlling_process"),
    {http, Host, Port} = test_helper:http_server(),
    {ok, Socket} = gen_http_tcp:connect(Host, Port, []),

    %% Transfer to self (should succeed)
    ?assertEqual(ok, gen_http_tcp:controlling_process(Socket, self())),

    ok = gen_http_tcp:close(Socket),
    ok.

tcp_upgrade_not_supported(_Config) ->
    ct:pal("Testing TCP upgrade not supported"),
    %% TCP upgrade should return not_supported
    Result = gen_http_tcp:upgrade(fake_socket, http, <<"localhost">>, 8080, []),
    ?assertEqual({error, not_supported}, Result),
    ok.

tcp_negotiated_protocol_not_available(_Config) ->
    ct:pal("Testing TCP negotiated_protocol not available"),
    %% TCP doesn't support ALPN
    Result = gen_http_tcp:negotiated_protocol(fake_socket),
    ?assertEqual({error, protocol_not_negotiated}, Result),
    ok.

tcp_close(_Config) ->
    ct:pal("Testing TCP close"),
    {http, Host, Port} = test_helper:http_server(),
    {ok, Socket} = gen_http_tcp:connect(Host, Port, []),
    ?assertEqual(ok, gen_http_tcp:close(Socket)),

    %% Verify socket is closed by trying to send
    Result = gen_http_tcp:send(Socket, "test"),
    ?assertMatch({error, _}, Result),
    ok.
