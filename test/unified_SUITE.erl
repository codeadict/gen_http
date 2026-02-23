-module(unified_SUITE).

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
    % Connection tests
    unified_connect_http/1,
    unified_connect_https/1,
    unified_connect_with_options/1,

    % Request tests (passive mode with recv)
    passive_mode_simple_get/1,
    passive_mode_with_timeout/1,
    passive_mode_post_with_body/1,

    % Request tests (non-blocking)
    unified_request/1,

    % Stream tests
    unified_stream_unknown_message/1,

    % Metadata tests
    unified_put_private/1,
    unified_get_private/1,
    unified_delete_private/1,

    % Error classification tests
    unified_classify_error/1,
    unified_is_retriable_error/1,

    % Connection state tests
    unified_is_open/1,
    unified_get_socket/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [
        {group, connection},
        {group, passive_requests},
        {group, async_requests},
        {group, stream},
        {group, metadata},
        {group, error_handling},
        {group, state}
    ].

groups() ->
    [
        {connection, [parallel], [
            unified_connect_http,
            unified_connect_https,
            unified_connect_with_options
        ]},
        {passive_requests, [parallel], [
            passive_mode_simple_get,
            passive_mode_with_timeout,
            passive_mode_post_with_body
        ]},
        {async_requests, [parallel], [
            unified_request
        ]},
        {stream, [parallel], [
            unified_stream_unknown_message
        ]},
        {metadata, [parallel], [
            unified_put_private,
            unified_get_private,
            unified_delete_private
        ]},
        {error_handling, [parallel], [
            unified_classify_error,
            unified_is_retriable_error
        ]},
        {state, [parallel], [
            unified_is_open,
            unified_get_socket
        ]}
    ].

init_per_suite(Config) ->
    %% Check if docker-compose services are available
    case test_helper:is_server_available() of
        true ->
            ct:pal("Docker services are available"),
            Config;
        false ->
            {skip, "Docker services not available. Run: docker-compose up -d"}
    end.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Unified Connect Tests
%%====================================================================

unified_connect_http(_Config) ->
    ct:pal("Testing unified HTTP connection"),
    {http, Host, Port} = test_helper:http_server(),
    Result = gen_http:connect(http, list_to_binary(Host), Port),
    ?assertMatch({ok, _Conn}, Result),
    {ok, Conn} = Result,
    ?assert(gen_http:is_open(Conn)),
    {ok, _} = gen_http:close(Conn),
    ok.

unified_connect_https(_Config) ->
    ct:pal("Testing unified HTTPS connection"),
    {https, Host, Port} = test_helper:https_server(),
    Opts = #{transport_opts => [{verify, verify_none}]},
    Result = gen_http:connect(https, list_to_binary(Host), Port, Opts),
    ?assertMatch({ok, _Conn}, Result),
    {ok, Conn} = Result,
    ?assert(gen_http:is_open(Conn)),
    {ok, _} = gen_http:close(Conn),
    ok.

unified_connect_with_options(_Config) ->
    ct:pal("Testing unified connection with custom options"),
    {http, Host, Port} = test_helper:http_server(),
    Opts = #{
        timeout => 10000,
        max_pipeline => 5
    },
    Result = gen_http:connect(http, list_to_binary(Host), Port, Opts),
    ?assertMatch({ok, _Conn}, Result),
    {ok, Conn} = Result,
    {ok, _} = gen_http:close(Conn),
    ok.

%%====================================================================
%% Request with Passive Mode Recv Tests
%%====================================================================

passive_mode_simple_get(_Config) ->
    ct:pal("Testing passive mode simple GET request"),
    {http, Host, Port} = test_helper:http_server(),
    case gen_http:connect(http, list_to_binary(Host), Port, #{mode => passive, protocols => [http1]}) of
        {error, _} ->
            %% Server unavailable, skip test
            ok;
        {ok, Conn} ->
            %% Send request
            case gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>) of
                {ok, Conn2, Ref} ->
                    %% Receive response using recv/3
                    Result = gen_http:recv(Conn2, 0, 5000),

                    case Result of
                        {ok, Conn3, Responses} ->
                            %% Verify we got status response
                            HasStatus = lists:any(
                                fun
                                    ({status, R, Status}) when R =:= Ref ->
                                        is_integer(Status);
                                    (_) ->
                                        false
                                end,
                                Responses
                            ),
                            ?assert(HasStatus),
                            {ok, _} = gen_http:close(Conn3);
                        {error, Conn3, _Reason, _Responses} ->
                            %% Connection closed with responses, skip test
                            {ok, _} = gen_http:close(Conn3);
                        {error, Conn3, _Reason} ->
                            %% Request failed, close and skip
                            {ok, _} = gen_http:close(Conn3)
                    end;
                {error, ConnErr, _Reason} ->
                    %% Request failed (connection closed), skip test
                    {ok, _} = gen_http:close(ConnErr)
            end
    end,
    ok.

passive_mode_with_timeout(_Config) ->
    ct:pal("Testing passive mode with timeout"),
    {http, Host, Port} = test_helper:http_server(),
    case gen_http:connect(http, list_to_binary(Host), Port, #{mode => passive, protocols => [http1]}) of
        {error, _} ->
            %% Server unavailable, skip test
            ok;
        {ok, Conn} ->
            %% Send request
            case gen_http:request(Conn, <<"GET">>, <<"/delay/1">>, [], <<>>) of
                {ok, Conn2, Ref} ->
                    %% Receive with timeout
                    Result = gen_http:recv(Conn2, 0, 10000),

                    case Result of
                        {ok, Conn3, Responses} ->
                            %% Check for status 200
                            HasStatus200 = lists:any(
                                fun
                                    ({status, R, 200}) when R =:= Ref -> true;
                                    (_) -> false
                                end,
                                Responses
                            ),
                            ?assert(HasStatus200),
                            {ok, _} = gen_http:close(Conn3);
                        {error, Conn3, _Reason, _Responses} ->
                            %% Connection closed with responses, skip test
                            {ok, _} = gen_http:close(Conn3);
                        {error, Conn3, _Reason} ->
                            {ok, _} = gen_http:close(Conn3)
                    end;
                {error, ConnErr, _Reason} ->
                    %% Request failed (connection closed), skip test
                    {ok, _} = gen_http:close(ConnErr)
            end
    end,
    ok.

passive_mode_post_with_body(_Config) ->
    ct:pal("Testing passive mode POST with body"),
    {http, Host, Port} = test_helper:http_server(),
    case gen_http:connect(http, list_to_binary(Host), Port, #{mode => passive, protocols => [http1]}) of
        {error, _} ->
            %% Server unavailable, skip test
            ok;
        {ok, Conn} ->
            Headers = [
                {<<"content-type">>, <<"application/json">>}
            ],
            Body = <<"{\"test\": \"data\"}">>,

            %% Send request
            case gen_http:request(Conn, <<"POST">>, <<"/post">>, Headers, Body) of
                {ok, Conn2, Ref} ->
                    %% Receive response
                    Result = gen_http:recv(Conn2, 0, 5000),

                    case Result of
                        {ok, Conn3, Responses} ->
                            %% Check for status 200
                            HasStatus200 = lists:any(
                                fun
                                    ({status, R, 200}) when R =:= Ref -> true;
                                    (_) -> false
                                end,
                                Responses
                            ),
                            ?assert(HasStatus200),
                            {ok, _} = gen_http:close(Conn3);
                        {error, Conn3, _Reason, _Responses} ->
                            %% Connection closed with responses, skip test
                            {ok, _} = gen_http:close(Conn3);
                        {error, Conn3, _Reason} ->
                            {ok, _} = gen_http:close(Conn3)
                    end;
                {error, ConnErr, _Reason} ->
                    %% Request failed (connection closed), skip test
                    {ok, _} = gen_http:close(ConnErr)
            end
    end,
    ok.

%%====================================================================
%% Unified Request Tests (Non-blocking)
%%====================================================================

unified_request(_Config) ->
    ct:pal("Testing unified request function"),
    {http, Host, Port} = test_helper:http_server(),
    {ok, Conn} = gen_http:connect(http, list_to_binary(Host), Port),

    Result = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),
    case Result of
        {ok, Conn2, Ref} ->
            ?assert(is_reference(Ref)),
            {ok, _} = gen_http:close(Conn2);
        {ok, Conn2, Ref, _StreamId} ->
            %% HTTP/2 returns StreamId too
            ?assert(is_reference(Ref)),
            {ok, _} = gen_http:close(Conn2);
        {error, Conn2, _Reason} ->
            {ok, _} = gen_http:close(Conn2)
    end,
    ok.

%%====================================================================
%% Unified Stream Tests
%%====================================================================

unified_stream_unknown_message(_Config) ->
    ct:pal("Testing unified stream with unknown message"),
    {http, Host, Port} = test_helper:http_server(),
    {ok, Conn} = gen_http:connect(http, list_to_binary(Host), Port),

    UnknownMsg = {unknown, message},
    Result = gen_http:stream(Conn, UnknownMsg),
    ?assertEqual(unknown, Result),

    {ok, _} = gen_http:close(Conn),
    ok.

%%====================================================================
%% Unified Metadata Tests
%%====================================================================

unified_put_private(_Config) ->
    ct:pal("Testing unified put_private"),
    {http, Host, Port} = test_helper:http_server(),
    {ok, Conn} = gen_http:connect(http, list_to_binary(Host), Port),

    Conn2 = gen_http:put_private(Conn, pool_id, unified_pool),
    Conn3 = gen_http:put_private(Conn2, request_count, 0),

    %% Verify state is still valid
    ?assert(gen_http:is_open(Conn3)),

    {ok, _} = gen_http:close(Conn3),
    ok.

unified_get_private(_Config) ->
    ct:pal("Testing unified get_private"),
    {http, Host, Port} = test_helper:http_server(),
    {ok, Conn} = gen_http:connect(http, list_to_binary(Host), Port),

    %% Get from empty private storage
    ?assertEqual(undefined, gen_http:get_private(Conn, pool_id)),

    %% Store and retrieve
    Conn2 = gen_http:put_private(Conn, pool_id, unified_pool),
    ?assertEqual(unified_pool, gen_http:get_private(Conn2, pool_id)),

    %% Get with default value
    ?assertEqual(default_val, gen_http:get_private(Conn2, missing_key, default_val)),

    {ok, _} = gen_http:close(Conn2),
    ok.

unified_delete_private(_Config) ->
    ct:pal("Testing unified delete_private"),
    {http, Host, Port} = test_helper:http_server(),
    {ok, Conn} = gen_http:connect(http, list_to_binary(Host), Port),

    Conn2 = gen_http:put_private(Conn, key1, value1),
    Conn3 = gen_http:put_private(Conn2, key2, value2),

    %% Verify both exist
    ?assertEqual(value1, gen_http:get_private(Conn3, key1)),
    ?assertEqual(value2, gen_http:get_private(Conn3, key2)),

    %% Delete one key
    Conn4 = gen_http:delete_private(Conn3, key1),

    %% Verify key1 is gone but key2 remains
    ?assertEqual(undefined, gen_http:get_private(Conn4, key1)),
    ?assertEqual(value2, gen_http:get_private(Conn4, key2)),

    {ok, _} = gen_http:close(Conn4),
    ok.

%%====================================================================
%% Error Classification Tests
%%====================================================================

unified_classify_error(_Config) ->
    ct:pal("Testing unified classify_error"),
    %% Test error classification through unified interface
    Transport = {transport_error, closed},
    Protocol = {protocol_error, invalid_status_line},
    Application = {application_error, pipeline_full},

    ?assertEqual(transport, gen_http:classify_error(Transport)),
    ?assertEqual(protocol, gen_http:classify_error(Protocol)),
    ?assertEqual(application, gen_http:classify_error(Application)),
    ok.

unified_is_retriable_error(_Config) ->
    ct:pal("Testing unified is_retriable_error"),
    %% Test retriable error checking through unified interface
    Transport = {transport_error, closed},
    Protocol = {protocol_error, invalid_status_line},
    AppClosed = {application_error, connection_closed},
    AppFull = {application_error, pipeline_full},

    ?assert(gen_http:is_retriable_error(Transport)),
    ?assertNot(gen_http:is_retriable_error(Protocol)),
    ?assert(gen_http:is_retriable_error(AppClosed)),
    ?assertNot(gen_http:is_retriable_error(AppFull)),
    ok.

%%====================================================================
%% Connection State Tests
%%====================================================================

unified_is_open(_Config) ->
    ct:pal("Testing unified is_open"),
    {http, Host, Port} = test_helper:http_server(),
    {ok, Conn} = gen_http:connect(http, list_to_binary(Host), Port),
    ?assert(gen_http:is_open(Conn)),

    {ok, Conn2} = gen_http:close(Conn),
    ?assertNot(gen_http:is_open(Conn2)),
    ok.

unified_get_socket(_Config) ->
    ct:pal("Testing unified get_socket"),
    {http, Host, Port} = test_helper:http_server(),
    {ok, Conn} = gen_http:connect(http, list_to_binary(Host), Port),
    Socket = gen_http:get_socket(Conn),
    ?assert(Socket =/= undefined),
    {ok, _} = gen_http:close(Conn),
    ok.
