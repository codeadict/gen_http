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
    chunked_response/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [
        {group, basic_http},
        {group, response_types},
        {group, connection_mgmt},
        {group, headers_body}
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
