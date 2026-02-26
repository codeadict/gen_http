-module(http1_SUITE).

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
    % Basic HTTP tests
    simple_get/1,
    simple_post/1,
    post_with_json_body/1,
    get_with_query_params/1,

    % Response types
    status_404/1,
    status_redirect/1,
    large_response_body/1,

    % Connection management
    connection_reuse/1,
    pipelining/1,

    % Headers and body
    response_headers/1,
    chunked_response/1,

    % Informational responses
    informational_100_continue/1,
    informational_103_early_hints/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [
        {group, basic_http},
        {group, response_types},
        {group, connection_mgmt},
        {group, headers_body},
        {group, informational_responses}
    ].

groups() ->
    [
        {basic_http, [parallel], [
            simple_get,
            simple_post,
            post_with_json_body,
            get_with_query_params
        ]},
        {response_types, [parallel], [
            status_404,
            status_redirect,
            large_response_body
        ]},
        {connection_mgmt, [sequence], [
            connection_reuse,
            pipelining
        ]},
        {headers_body, [parallel], [
            response_headers,
            chunked_response
        ]},
        {informational_responses, [sequence], [
            informational_100_continue,
            informational_103_early_hints
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
%% Test Cases
%%====================================================================

simple_get(_Config) ->
    ct:pal("Testing simple GET request"),
    {http, Host, Port} = test_helper:http_server(),

    {ok, Conn} = gen_http_h1:connect(http, Host, Port),
    ?assert(gen_http_h1:is_open(Conn)),

    Headers = [{<<"user-agent">>, <<"gen_http_test/1.0">>}],
    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/get">>, Headers, <<>>),

    %% Collect response
    {Conn3, Response} = test_helper:collect_response(Conn2, Ref, 5000),
    ?assertMatch(#{status := 200}, Response),
    ?assert(maps:is_key(headers, Response)),
    ?assert(maps:is_key(body, Response)),

    {ok, _} = gen_http_h1:close(Conn3),
    ok.

simple_post(_Config) ->
    ct:pal("Testing simple POST request"),
    {http, Host, Port} = test_helper:http_server(),

    {ok, Conn} = gen_http_h1:connect(http, Host, Port),

    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"user-agent">>, <<"gen_http_test/1.0">>}
    ],
    Body = <<"{\"test\": \"data\", \"number\": 42}">>,

    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"POST">>, <<"/post">>, Headers, Body),

    {Conn3, Response} = test_helper:collect_response(Conn2, Ref, 5000),
    ?assertMatch(#{status := 200}, Response),

    %% httpbin echoes back the posted data
    ResponseBody = maps:get(body, Response),
    ?assert(binary:match(ResponseBody, <<"test">>) =/= nomatch),
    ?assert(binary:match(ResponseBody, <<"42">>) =/= nomatch),

    {ok, _} = gen_http_h1:close(Conn3),
    ok.

post_with_json_body(_Config) ->
    ct:pal("Testing POST with JSON body"),
    {http, Host, Port} = test_helper:http_server(),

    {ok, Conn} = gen_http_h1:connect(http, Host, Port),

    Headers = [{<<"content-type">>, <<"application/json">>}],
    Body = <<"{\"key\": \"value\"}">>,

    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"POST">>, <<"/post">>, Headers, Body),

    {Conn3, Response} = test_helper:collect_response(Conn2, Ref, 5000),
    ?assertMatch(#{status := 200}, Response),

    {ok, _} = gen_http_h1:close(Conn3),
    ok.

get_with_query_params(_Config) ->
    ct:pal("Testing GET with query params"),
    {http, Host, Port} = test_helper:http_server(),

    {ok, Conn} = gen_http_h1:connect(http, Host, Port),

    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/get?foo=bar&baz=qux">>, [], <<>>),

    {Conn3, Response} = test_helper:collect_response(Conn2, Ref, 5000),
    ?assertMatch(#{status := 200}, Response),

    ResponseBody = maps:get(body, Response),
    ?assert(binary:match(ResponseBody, <<"foo">>) =/= nomatch),

    {ok, _} = gen_http_h1:close(Conn3),
    ok.

status_404(_Config) ->
    ct:pal("Testing 404 response"),
    {http, Host, Port} = test_helper:http_server(),

    {ok, Conn} = gen_http_h1:connect(http, Host, Port),

    Headers = [{<<"user-agent">>, <<"gen_http_test/1.0">>}],
    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/status/404">>, Headers, <<>>),

    {Conn3, Response} = test_helper:collect_response(Conn2, Ref, 5000),
    ?assertMatch(#{status := 404}, Response),

    {ok, _} = gen_http_h1:close(Conn3),
    ok.

status_redirect(_Config) ->
    ct:pal("Testing redirect response"),
    {http, Host, Port} = test_helper:http_server(),

    {ok, Conn} = gen_http_h1:connect(http, Host, Port),

    Headers = [{<<"user-agent">>, <<"gen_http_test/1.0">>}],
    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/redirect/1">>, Headers, <<>>),

    {Conn3, Response} = test_helper:collect_response(Conn2, Ref, 5000),
    ?assertMatch(#{status := 302}, Response),

    %% Should have Location header
    Headers2 = maps:get(headers, Response),
    ?assert(lists:keyfind(<<"location">>, 1, Headers2) =/= false),

    {ok, _} = gen_http_h1:close(Conn3),
    ok.

large_response_body(_Config) ->
    ct:pal("Testing large response body"),
    {http, Host, Port} = test_helper:http_server(),

    {ok, Conn} = gen_http_h1:connect(http, Host, Port),

    %% Request 10KB of data
    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/bytes/10240">>, [], <<>>),

    {Conn3, Response} = test_helper:collect_response(Conn2, Ref, 10000),
    ?assertMatch(#{status := 200}, Response),

    Body = maps:get(body, Response),
    ?assertEqual(10240, byte_size(Body)),

    {ok, _} = gen_http_h1:close(Conn3),
    ok.

connection_reuse(_Config) ->
    ct:pal("Testing connection reuse"),
    {http, Host, Port} = test_helper:http_server(),

    {ok, Conn} = gen_http_h1:connect(http, Host, Port),

    %% First request
    {ok, Conn2, Ref1} = gen_http_h1:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),
    {Conn3, Response1} = test_helper:collect_response(Conn2, Ref1, 5000),
    ?assertMatch(#{status := 200}, Response1),
    ?assert(gen_http_h1:is_open(Conn3)),

    %% Second request on same connection
    {ok, Conn4, Ref2} = gen_http_h1:request(Conn3, <<"GET">>, <<"/get">>, [], <<>>),
    {Conn5, Response2} = test_helper:collect_response(Conn4, Ref2, 5000),
    ?assertMatch(#{status := 200}, Response2),

    {ok, _} = gen_http_h1:close(Conn5),
    ok.

pipelining(_Config) ->
    ct:pal("Testing pipelining"),
    {http, Host, Port} = test_helper:http_server(),

    {ok, Conn} = gen_http_h1:connect(http, Host, Port),

    %% Send two requests without waiting for responses
    {ok, Conn2, Ref1} = gen_http_h1:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),
    {ok, Conn3, Ref2} = gen_http_h1:request(Conn2, <<"GET">>, <<"/get">>, [], <<>>),

    %% Collect responses in order (HTTP/1.1 requires ordered responses)
    {Conn4, Resp1} = test_helper:collect_response(Conn3, Ref1, 10000),
    ?assertMatch(#{status := 200}, Resp1),

    {Conn5, Resp2} = test_helper:collect_response(Conn4, Ref2, 10000),
    ?assertMatch(#{status := 200}, Resp2),

    {ok, _} = gen_http_h1:close(Conn5),
    ok.

response_headers(_Config) ->
    ct:pal("Testing response headers"),
    {http, Host, Port} = test_helper:http_server(),

    {ok, Conn} = gen_http_h1:connect(http, Host, Port),

    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/response-headers?Foo=Bar&Baz=Qux">>, [], <<>>),

    {Conn3, Response} = test_helper:collect_response(Conn2, Ref, 5000),
    ?assertMatch(#{status := 200}, Response),

    Headers = maps:get(headers, Response),
    ?assert(
        lists:keyfind(<<"foo">>, 1, Headers) =/= false orelse
            lists:keyfind(<<"Foo">>, 1, Headers) =/= false
    ),

    {ok, _} = gen_http_h1:close(Conn3),
    ok.

chunked_response(_Config) ->
    ct:pal("Testing chunked response"),
    {http, Host, Port} = test_helper:http_server(),

    {ok, Conn} = gen_http_h1:connect(http, Host, Port),

    %% /stream-bytes streams the response in chunks
    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/stream-bytes/1024">>, [], <<>>),

    {Conn3, Response} = test_helper:collect_response(Conn2, Ref, 5000),
    ?assertMatch(#{status := 200}, Response),

    Body = maps:get(body, Response),
    ?assertEqual(1024, byte_size(Body)),

    {ok, _} = gen_http_h1:close(Conn3),
    ok.

%%====================================================================
%% Informational Responses (1xx)
%%====================================================================

%% @doc Test 100 Continue informational response
informational_100_continue(_Config) ->
    ct:pal("Testing 100 Continue"),

    {ok, ListenSocket} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(ListenSocket),

    spawn_link(fun() ->
        {ok, Socket} = gen_tcp:accept(ListenSocket),
        {ok, _} = gen_tcp:recv(Socket, 0, 5000),
        ok = gen_tcp:send(Socket, <<"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK">>),
        gen_tcp:close(Socket)
    end),

    {ok, Conn} = gen_http_h1:connect(http, "localhost", Port, #{mode => passive}),
    {ok, Conn2, _Ref} = gen_http_h1:request(
        Conn, <<"POST">>, <<"/">>, [{<<"expect">>, <<"100-continue">>}], <<"data">>
    ),

    {ok, Conn3, Responses} = gen_http_h1:recv(Conn2, 0, 5000),

    Statuses = [S || {status, _, S} <- Responses],
    ?assertEqual([100, 200], Statuses),

    gen_http_h1:close(Conn3),

    gen_http_h1:close(Conn3),
    gen_tcp:close(ListenSocket),
    ok.

%% @doc Test 103 Early Hints informational response
informational_103_early_hints(_Config) ->
    ct:pal("Testing 103 Early Hints"),

    {ok, ListenSocket} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(ListenSocket),

    spawn_link(fun() ->
        {ok, Socket} = gen_tcp:accept(ListenSocket),
        {ok, _} = gen_tcp:recv(Socket, 0, 5000),
        ok = gen_tcp:send(
            Socket,
            <<"HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK">>
        ),
        gen_tcp:close(Socket)
    end),

    {ok, Conn} = gen_http_h1:connect(http, "localhost", Port, #{mode => passive}),
    {ok, Conn2, Ref} = gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>),

    {ok, Conn3, Responses} = gen_http_h1:recv(Conn2, 0, 5000),

    Statuses = [S || {status, _, S} <- Responses],
    ?assertEqual([103, 200], Statuses),

    %% Verify Link header in 103 response
    Headers103 = [H || {headers, R, H} <- Responses, R =:= Ref, lists:keymember(<<"link">>, 1, H)],
    ?assertMatch([_], Headers103),

    gen_http_h1:close(Conn3),
    gen_tcp:close(ListenSocket),
    ok.
