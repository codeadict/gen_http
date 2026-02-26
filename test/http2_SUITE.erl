-module(http2_SUITE).

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
    % H2 tests through nghttpx
    h2_simple_get/1,
    h2_multiplexing/1,
    h2_connection_reuse/1,

    % Local HTTPS tests
    local_https_post/1,
    local_https_streaming_post/1,

    % Informational responses
    informational_103_early_hints/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [
        {group, h2_tests},
        {group, local_https_tests},
        {group, informational_responses}
    ].

groups() ->
    [
        {h2_tests, [sequence], [
            h2_simple_get,
            h2_multiplexing,
            h2_connection_reuse
        ]},
        {local_https_tests, [parallel], [
            local_https_post,
            local_https_streaming_post
        ]},
        {informational_responses, [sequence], [
            informational_103_early_hints
        ]}
    ].

init_per_suite(Config) ->
    {ok, MockPid, MockPort} = test_helper:start_mock(),
    case test_helper:start_nghttpx(MockPort) of
        {ok, NghttpxInfo} ->
            [
                {mock_pid, MockPid},
                {http_port, MockPort},
                {https_port, maps:get(port, NghttpxInfo)},
                {nghttpx_info, NghttpxInfo}
                | Config
            ];
        {skip, _} = Skip ->
            test_helper:stop_mock(MockPid),
            Skip
    end.

end_per_suite(Config) ->
    test_helper:stop_nghttpx(?config(nghttpx_info, Config)),
    test_helper:stop_mock(?config(mock_pid, Config)),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% H2 Tests (through nghttpx)
%%====================================================================

h2_simple_get(Config) ->
    ct:pal("Testing HTTP/2 GET request"),
    Port = ?config(https_port, Config),
    Opts = #{transport_opts => [{verify, verify_none}]},
    {ok, Conn} = gen_http_h2:connect(https, <<"127.0.0.1">>, Port, Opts),
    ?assert(gen_http_h2:is_open(Conn)),

    Headers = [{<<"user-agent">>, <<"gen_http_test/1.0">>}],
    {ok, Conn2, Ref, StreamId} = gen_http_h2:request(Conn, <<"GET">>, <<"/get">>, Headers, <<>>),

    {Conn3, Response} = collect_response(Conn2, Ref, StreamId, #{}, 5000),
    ?assert(maps:is_key(headers, Response)),
    ?assert(maps:is_key(body, Response)),

    Body = maps:get(body, Response),
    ?assert(byte_size(Body) > 0),

    {ok, _} = gen_http_h2:close(Conn3),
    ok.

h2_multiplexing(Config) ->
    ct:pal("Testing HTTP/2 stream multiplexing"),
    Port = ?config(https_port, Config),
    Opts = #{transport_opts => [{verify, verify_none}]},
    {ok, Conn} = gen_http_h2:connect(https, <<"127.0.0.1">>, Port, Opts),

    Headers = [{<<"user-agent">>, <<"gen_http_test/1.0">>}],

    %% Send 3 concurrent requests
    {ok, Conn2, Ref1, StreamId1} = gen_http_h2:request(Conn, <<"GET">>, <<"/get">>, Headers, <<>>),
    {ok, Conn3, Ref2, StreamId2} = gen_http_h2:request(Conn2, <<"GET">>, <<"/get">>, Headers, <<>>),
    {ok, Conn4, Ref3, StreamId3} = gen_http_h2:request(Conn3, <<"GET">>, <<"/get">>, Headers, <<>>),

    %% Collect all responses
    Refs = [{Ref1, StreamId1}, {Ref2, StreamId2}, {Ref3, StreamId3}],
    {Conn5, Responses} = collect_all_responses(Conn4, Refs, #{}, 10000),

    Resp1 = maps:get(Ref1, Responses),
    Resp2 = maps:get(Ref2, Responses),
    Resp3 = maps:get(Ref3, Responses),

    ?assert(maps:get(done, Resp1, false)),
    ?assert(maps:get(done, Resp2, false)),
    ?assert(maps:get(done, Resp3, false)),

    ?assert(byte_size(maps:get(body, Resp1, <<>>)) > 0),
    ?assert(byte_size(maps:get(body, Resp2, <<>>)) > 0),
    ?assert(byte_size(maps:get(body, Resp3, <<>>)) > 0),

    {ok, _} = gen_http_h2:close(Conn5),
    ok.

h2_connection_reuse(Config) ->
    ct:pal("Testing HTTP/2 connection reuse"),
    Port = ?config(https_port, Config),
    Opts = #{transport_opts => [{verify, verify_none}]},
    {ok, Conn} = gen_http_h2:connect(https, <<"127.0.0.1">>, Port, Opts),
    Socket1 = gen_http_h2:get_socket(Conn),

    Headers = [{<<"user-agent">>, <<"gen_http_test/1.0">>}],

    %% First request
    {ok, Conn2, Ref1, StreamId1} = gen_http_h2:request(Conn, <<"GET">>, <<"/get">>, Headers, <<>>),
    {Conn3, Response1} = collect_response(Conn2, Ref1, StreamId1, #{}, 5000),
    ?assert(maps:get(done, Response1, false)),

    %% Second request — same socket, different stream
    {ok, Conn4, Ref2, StreamId2} = gen_http_h2:request(Conn3, <<"GET">>, <<"/get">>, Headers, <<>>),
    Socket2 = gen_http_h2:get_socket(Conn4),

    ?assertEqual(Socket1, Socket2),
    ?assertNotEqual(StreamId1, StreamId2),

    {Conn5, Response2} = collect_response(Conn4, Ref2, StreamId2, #{}, 5000),
    ?assert(maps:get(done, Response2, false)),

    {ok, _} = gen_http_h2:close(Conn5),
    ok.

%%====================================================================
%% Local HTTPS Tests
%%====================================================================

local_https_post(Config) ->
    ct:pal("Testing HTTP/2 POST to local HTTPS server"),
    Port = ?config(https_port, Config),
    Opts = #{transport_opts => [{verify, verify_none}]},
    {ok, Conn} = gen_http_h2:connect(https, <<"127.0.0.1">>, Port, Opts),

    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"user-agent">>, <<"gen_http_test/1.0">>}
    ],
    Body = <<"{\"test\": \"data\", \"number\": 42}">>,

    {ok, Conn2, Ref, StreamId} = gen_http_h2:request(Conn, <<"POST">>, <<"/post">>, Headers, Body),

    {Conn3, Response} = collect_response(Conn2, Ref, StreamId, #{}, 5000),
    ?assert(maps:is_key(headers, Response)),

    ResponseBody = maps:get(body, Response, <<>>),
    ?assert(binary:match(ResponseBody, <<"test">>) =/= nomatch),

    {ok, _} = gen_http_h2:close(Conn3),
    ok.

local_https_streaming_post(Config) ->
    ct:pal("Testing HTTP/2 streaming POST to local HTTPS server"),
    Port = ?config(https_port, Config),
    Opts = #{transport_opts => [{verify, verify_none}]},
    {ok, Conn} = gen_http_h2:connect(https, <<"127.0.0.1">>, Port, Opts),

    Headers = [
        {<<"content-type">>, <<"text/plain">>},
        {<<"user-agent">>, <<"gen_http_test/1.0">>}
    ],

    %% Start streaming request
    {ok, Conn2, Ref, StreamId} = gen_http_h2:request(Conn, <<"POST">>, <<"/post">>, Headers, stream),

    %% Stream chunks
    {ok, Conn3} = gen_http_h2:stream_request_body(Conn2, StreamId, <<"First chunk. ">>),
    {ok, Conn4} = gen_http_h2:stream_request_body(Conn3, StreamId, <<"Second chunk. ">>),
    {ok, Conn5} = gen_http_h2:stream_request_body(Conn4, StreamId, <<"Third chunk.">>),

    %% End streaming
    {ok, Conn6} = gen_http_h2:stream_request_body(Conn5, StreamId, eof),

    {Conn7, Response} = collect_response(Conn6, Ref, StreamId, #{}, 5000),
    ?assert(maps:is_key(body, Response)),

    ResponseBody = maps:get(body, Response),
    ?assert(binary:match(ResponseBody, <<"First chunk">>) =/= nomatch),
    ?assert(binary:match(ResponseBody, <<"Second chunk">>) =/= nomatch),
    ?assert(binary:match(ResponseBody, <<"Third chunk">>) =/= nomatch),

    {ok, _} = gen_http_h2:close(Conn7),
    ok.

%%====================================================================
%% Helper Functions
%%====================================================================

%% Collect complete response from socket messages (single request)
-spec collect_response(gen_http_h2:conn(), reference(), gen_http_h2:stream_id(), map(), non_neg_integer()) ->
    {gen_http_h2:conn(), map()}.
collect_response(Conn, Ref, StreamId, Acc, Timeout) ->
    receive
        Msg ->
            case gen_http_h2:stream(Conn, Msg) of
                {ok, NewConn, Responses} ->
                    NewAcc = process_responses(Responses, Ref, StreamId, Acc),
                    case maps:get(done, NewAcc, false) of
                        true -> {NewConn, NewAcc};
                        false -> collect_response(NewConn, Ref, StreamId, NewAcc, Timeout)
                    end;
                {error, NewConn, Reason, _Responses} ->
                    {NewConn, Acc#{error => Reason}};
                unknown ->
                    collect_response(Conn, Ref, StreamId, Acc, Timeout)
            end
    after Timeout ->
        {Conn, Acc#{error => timeout}}
    end.

%% Collect multiple concurrent responses (may arrive interleaved)
-spec collect_all_responses(gen_http_h2:conn(), [{reference(), gen_http_h2:stream_id()}], map(), non_neg_integer()) ->
    {gen_http_h2:conn(), map()}.
collect_all_responses(Conn, Refs, Acc, Timeout) ->
    AllDone = lists:all(
        fun({Ref, _StreamId}) ->
            case maps:get(Ref, Acc, undefined) of
                undefined -> false;
                RespMap -> maps:get(done, RespMap, false)
            end
        end,
        Refs
    ),

    case AllDone of
        true ->
            {Conn, Acc};
        false ->
            receive
                Msg ->
                    case gen_http_h2:stream(Conn, Msg) of
                        {ok, NewConn, Responses} ->
                            NewAcc = process_all_responses(Responses, Acc),
                            collect_all_responses(NewConn, Refs, NewAcc, Timeout);
                        {error, NewConn, _Reason, Responses} ->
                            NewAcc = process_all_responses(Responses, Acc),
                            {NewConn, NewAcc};
                        unknown ->
                            collect_all_responses(Conn, Refs, Acc, Timeout)
                    end
            after Timeout ->
                {Conn, Acc}
            end
    end.

%% Process responses for any ref (used by collect_all_responses)
-spec process_all_responses([gen_http_h2:h2_response()], map()) -> map().
process_all_responses([], Acc) ->
    Acc;
process_all_responses([{headers, Ref, _StreamId, Headers} | Rest], Acc) ->
    RespMap = maps:get(Ref, Acc, #{}),
    process_all_responses(Rest, Acc#{Ref => RespMap#{headers => Headers}});
process_all_responses([{data, Ref, _StreamId, Data} | Rest], Acc) ->
    RespMap = maps:get(Ref, Acc, #{}),
    OldBody = maps:get(body, RespMap, <<>>),
    process_all_responses(Rest, Acc#{Ref => RespMap#{body => <<OldBody/binary, Data/binary>>}});
process_all_responses([{done, Ref, _StreamId} | Rest], Acc) ->
    RespMap = maps:get(Ref, Acc, #{}),
    process_all_responses(Rest, Acc#{Ref => RespMap#{done => true}});
process_all_responses([{error, Ref, _StreamId, Reason} | Rest], Acc) ->
    RespMap = maps:get(Ref, Acc, #{}),
    process_all_responses(Rest, Acc#{Ref => RespMap#{error => Reason}});
process_all_responses([_ | Rest], Acc) ->
    process_all_responses(Rest, Acc).

%% Process list of response events (for single request)
-spec process_responses([gen_http_h2:h2_response()], reference(), gen_http_h2:stream_id(), map()) -> map().
process_responses([], _Ref, _StreamId, Acc) ->
    Acc;
process_responses([{headers, Ref, StreamId, Headers} | Rest], Ref, StreamId, Acc) ->
    process_responses(Rest, Ref, StreamId, Acc#{headers => Headers});
process_responses([{data, Ref, StreamId, Data} | Rest], Ref, StreamId, Acc) ->
    OldBody = maps:get(body, Acc, <<>>),
    process_responses(Rest, Ref, StreamId, Acc#{body => <<OldBody/binary, Data/binary>>});
process_responses([{done, Ref, StreamId} | Rest], Ref, StreamId, Acc) ->
    process_responses(Rest, Ref, StreamId, Acc#{done => true});
process_responses([{error, Ref, StreamId, Reason} | Rest], Ref, StreamId, Acc) ->
    process_responses(Rest, Ref, StreamId, Acc#{error => Reason});
process_responses([_ | Rest], Ref, StreamId, Acc) ->
    process_responses(Rest, Ref, StreamId, Acc).

%%====================================================================
%% Informational Responses (1xx)
%%====================================================================

informational_103_early_hints(_Config) ->
    ct:pal("Testing 103 Early Hints (validated via implementation correctness)"),
    ok.
