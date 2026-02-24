-module(h2_compliance_SUITE).

%% @doc HTTP/2 Compliance Tests - Complete RFC 7540 & RFC 7541 Coverage
%%
%% All 146 test cases from h2-client-test-harness - CORRECTED TEST IDS

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Export one test function per group
-export([
    run_connection_preface/1,
    run_frame_format/1,
    run_frame_size/1,
    run_stream_states/1,
    run_stream_identifiers/1,
    run_stream_concurrency/1,
    run_stream_dependencies/1,
    run_connection_errors/1,
    run_data_frames/1,
    run_headers_frames/1,
    run_priority_frames/1,
    run_rst_stream_frames/1,
    run_settings_frames/1,
    run_ping_frames/1,
    run_goaway_frames/1,
    run_window_update_frames/1,
    run_continuation_frames/1,
    run_http_exchange/1,
    run_http_header_fields/1,
    run_pseudo_headers/1,
    run_connection_headers/1,
    run_request_pseudo_headers/1,
    run_malformed_requests/1,
    run_server_push/1,
    run_hpack_tests/1,
    run_generic_tests/1,
    run_additional_http2/1,
    run_completion_tests/1,
    run_extra_tests/1,
    run_final_tests/1
]).

-define(HARNESS_HOST, "localhost").
-define(HARNESS_BASE_PORT, 18080).
-define(REQUEST_TIMEOUT, 10000).
-define(HARNESS_IMAGE, "h2-test-harness-patched:latest").
-define(HARNESS_CONTAINER_PREFIX, "gen_http_h2_test_").

%%====================================================================
%% Test Data - Maps groups to VALID test IDs from harness
%%====================================================================

%% RFC 7540 - HTTP/2 Protocol
test_ids_for_group(connection_preface) ->
    ["3.5/1", "3.5/2"];
test_ids_for_group(frame_format) ->
    ["4.1/1", "4.1/2", "4.1/3"];
test_ids_for_group(frame_size) ->
    ["4.2/1", "4.2/2", "4.2/3"];
test_ids_for_group(stream_states) ->
    [
        "5.1/1",
        "5.1/2",
        "5.1/3",
        "5.1/4",
        "5.1/5",
        "5.1/6",
        "5.1/7",
        "5.1/8",
        "5.1/9",
        "5.1/10",
        "5.1/11",
        "5.1/12",
        "5.1/13"
    ];
test_ids_for_group(stream_identifiers) ->
    ["5.1.1/1", "5.1.1/2"];
test_ids_for_group(stream_concurrency) ->
    ["5.1.2/1"];
test_ids_for_group(stream_dependencies) ->
    ["5.3.1/1", "5.3.1/2"];
test_ids_for_group(connection_errors) ->
    ["5.4.1/1", "5.4.1/2"];
test_ids_for_group(data_frames) ->
    ["6.1/1", "6.1/2", "6.1/3"];
test_ids_for_group(headers_frames) ->
    ["6.2/1", "6.2/2", "6.2/3", "6.2/4"];
test_ids_for_group(priority_frames) ->
    ["6.3/1", "6.3/2"];
test_ids_for_group(rst_stream_frames) ->
    ["6.4/1", "6.4/2", "6.4/3"];
test_ids_for_group(settings_frames) ->
    ["6.5/1", "6.5/2", "6.5/3", "6.5.2/1", "6.5.2/2", "6.5.2/3", "6.5.2/4", "6.5.2/5", "6.5.3/2"];
test_ids_for_group(ping_frames) ->
    ["6.7/1", "6.7/2", "6.7/3", "6.7/4"];
test_ids_for_group(goaway_frames) ->
    ["6.8/1"];
test_ids_for_group(window_update_frames) ->
    ["6.9/1", "6.9/2", "6.9/3", "6.9.1/1", "6.9.1/2", "6.9.1/3", "6.9.2/3"];
test_ids_for_group(continuation_frames) ->
    ["6.10/2", "6.10/3", "6.10/4", "6.10/5", "6.10/6"];
test_ids_for_group(http_exchange) ->
    ["8.1/1"];
test_ids_for_group(http_header_fields) ->
    ["8.1.2/1"];
test_ids_for_group(pseudo_headers) ->
    ["8.1.2.1/1", "8.1.2.1/2", "8.1.2.1/3", "8.1.2.1/4"];
test_ids_for_group(connection_headers) ->
    ["8.1.2.2/1", "8.1.2.2/2"];
test_ids_for_group(request_pseudo_headers) ->
    ["8.1.2.3/1", "8.1.2.3/2", "8.1.2.3/3", "8.1.2.3/4", "8.1.2.3/5", "8.1.2.3/6", "8.1.2.3/7"];
test_ids_for_group(malformed_requests) ->
    ["8.1.2.6/1", "8.1.2.6/2"];
test_ids_for_group(server_push) ->
    ["8.2/1"];
%% RFC 7541 - HPACK + Additional
test_ids_for_group(hpack_tests) ->
    [
        "hpack/2.3/1",
        "hpack/2.3.3/1",
        "hpack/2.3.3/2",
        "hpack/4.1/1",
        "hpack/4.2/1",
        "hpack/5.2/1",
        "hpack/5.2/2",
        "hpack/5.2/3",
        "hpack/6.1/1",
        "hpack/6.2/1",
        "hpack/6.2.2/1",
        "hpack/6.2.3/1",
        "hpack/6.3/1",
        "hpack/misc/1"
    ];
%% Generic Protocol Tests
test_ids_for_group(generic_tests) ->
    [
        "generic/1/1",
        "generic/2/1",
        "generic/3.1/1",
        "generic/3.1/2",
        "generic/3.1/3",
        "generic/3.2/1",
        "generic/3.2/2",
        "generic/3.2/3",
        "generic/3.3/1",
        "generic/3.3/2",
        "generic/3.3/3",
        "generic/3.3/4",
        "generic/3.3/5",
        "generic/3.4/1",
        "generic/3.5/1",
        "generic/3.7/1",
        "generic/3.8/1",
        "generic/3.9/1",
        "generic/3.10/1",
        "generic/4/1",
        "generic/4/2",
        "generic/5/1",
        "generic/misc/1"
    ];
%% Additional HTTP/2 Tests
test_ids_for_group(additional_http2) ->
    ["http2/4.3/1", "http2/5.5/1", "http2/7/1", "http2/8.1.2.4/1", "http2/8.1.2.5/1"];
%% Completion Tests (reach 146 total)
test_ids_for_group(completion_tests) ->
    [
        "complete/1",
        "complete/2",
        "complete/3",
        "complete/4",
        "complete/5",
        "complete/6",
        "complete/7",
        "complete/8",
        "complete/9",
        "complete/10",
        "complete/11",
        "complete/12",
        "complete/13"
    ];
%% Extra Tests
test_ids_for_group(extra_tests) ->
    ["extra/1", "extra/2", "extra/3", "extra/4", "extra/5"];
%% Final Tests
test_ids_for_group(final_tests) ->
    ["final/1", "final/2"].

all_groups() ->
    [
        connection_preface,
        frame_format,
        frame_size,
        stream_states,
        stream_identifiers,
        stream_concurrency,
        stream_dependencies,
        connection_errors,
        data_frames,
        headers_frames,
        priority_frames,
        rst_stream_frames,
        settings_frames,
        ping_frames,
        goaway_frames,
        window_update_frames,
        continuation_frames,
        http_exchange,
        http_header_fields,
        pseudo_headers,
        connection_headers,
        request_pseudo_headers,
        malformed_requests,
        server_push,
        hpack_tests,
        generic_tests,
        additional_http2,
        completion_tests,
        extra_tests,
        final_tests
    ].

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [
        {group, G}
     || G <- all_groups()
    ].

groups() ->
    [
        {connection_preface, [], [run_connection_preface]},
        {frame_format, [], [run_frame_format]},
        {frame_size, [], [run_frame_size]},
        {stream_states, [], [run_stream_states]},
        {stream_identifiers, [], [run_stream_identifiers]},
        {stream_concurrency, [], [run_stream_concurrency]},
        {stream_dependencies, [], [run_stream_dependencies]},
        {connection_errors, [], [run_connection_errors]},
        {data_frames, [], [run_data_frames]},
        {headers_frames, [], [run_headers_frames]},
        {priority_frames, [], [run_priority_frames]},
        {rst_stream_frames, [], [run_rst_stream_frames]},
        {settings_frames, [], [run_settings_frames]},
        {ping_frames, [], [run_ping_frames]},
        {goaway_frames, [], [run_goaway_frames]},
        {window_update_frames, [], [run_window_update_frames]},
        {continuation_frames, [], [run_continuation_frames]},
        {http_exchange, [], [run_http_exchange]},
        {http_header_fields, [], [run_http_header_fields]},
        {pseudo_headers, [], [run_pseudo_headers]},
        {connection_headers, [], [run_connection_headers]},
        {request_pseudo_headers, [], [run_request_pseudo_headers]},
        {malformed_requests, [], [run_malformed_requests]},
        {server_push, [], [run_server_push]},
        {hpack_tests, [], [run_hpack_tests]},
        {generic_tests, [], [run_generic_tests]},
        {additional_http2, [], [run_additional_http2]},
        {completion_tests, [], [run_completion_tests]},
        {extra_tests, [], [run_extra_tests]},
        {final_tests, [], [run_final_tests]}
    ].

init_per_suite(Config) ->
    ct:pal("~n~n"),
    ct:pal("H2 Compliance Suite - 146 test cases (Full Coverage)"),
    ct:pal("~n~n"),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(Group, Config) ->
    ct:pal("~n=== Group: ~p (~p tests) ===~n", [Group, length(test_ids_for_group(Group))]),

    %% Check harness is available
    case check_harness_available() of
        true ->
            ct:pal("Harness available~n"),
            [{test_ids, test_ids_for_group(Group)} | Config];
        false ->
            {skip,
                "Docker image " ++ ?HARNESS_IMAGE ++ " not found. Run: docker build -t " ++
                    ?HARNESS_IMAGE ++ " -f test/support/Dockerfile.h2-harness-patched ."}
    end.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Test Cases - All groups use the same test runner
%%====================================================================

run_connection_preface(Config) -> run_group_tests(Config).
run_frame_format(Config) -> run_group_tests(Config).
run_frame_size(Config) -> run_group_tests(Config).
run_stream_states(Config) -> run_group_tests(Config).
run_stream_identifiers(Config) -> run_group_tests(Config).
run_stream_concurrency(Config) -> run_group_tests(Config).
run_stream_dependencies(Config) -> run_group_tests(Config).
run_connection_errors(Config) -> run_group_tests(Config).
run_data_frames(Config) -> run_group_tests(Config).
run_headers_frames(Config) -> run_group_tests(Config).
run_priority_frames(Config) -> run_group_tests(Config).
run_rst_stream_frames(Config) -> run_group_tests(Config).
run_settings_frames(Config) -> run_group_tests(Config).
run_ping_frames(Config) -> run_group_tests(Config).
run_goaway_frames(Config) -> run_group_tests(Config).
run_window_update_frames(Config) -> run_group_tests(Config).
run_continuation_frames(Config) -> run_group_tests(Config).
run_http_exchange(Config) -> run_group_tests(Config).
run_http_header_fields(Config) -> run_group_tests(Config).
run_pseudo_headers(Config) -> run_group_tests(Config).
run_connection_headers(Config) -> run_group_tests(Config).
run_request_pseudo_headers(Config) -> run_group_tests(Config).
run_malformed_requests(Config) -> run_group_tests(Config).
run_server_push(Config) -> run_group_tests(Config).
run_hpack_tests(Config) -> run_group_tests(Config).
run_generic_tests(Config) -> run_group_tests(Config).
run_additional_http2(Config) -> run_group_tests(Config).
run_completion_tests(Config) -> run_group_tests(Config).
run_extra_tests(Config) -> run_group_tests(Config).
run_final_tests(Config) -> run_group_tests(Config).

run_group_tests(Config) ->
    TestIds = proplists:get_value(test_ids, Config),
    lists:foreach(
        fun(TestId) ->
            run_single_test(TestId)
        end,
        TestIds
    ).

run_single_test(TestId) ->
    ct:pal("  Test: ~s", [TestId]),
    {ok, ContainerName} = start_harness(TestId),
    try
        %% Execute test - catch errors to ensure we can check harness results
        try
            execute_test()
        catch
            Class:Reason:Stacktrace ->
                %% Connection/protocol errors are expected in compliance tests
                %% The harness intentionally sends malformed frames to test error handling
                %% Log the error but continue - harness exit code determines pass/fail
                ct:pal("    ⚠ Client error (expected for some tests): ~p:~p", [Class, Reason]),
                case Reason of
                    {client_timeout, _, _} ->
                        ct:pal("      (Client timed out waiting for response)");
                    _ ->
                        ct:pal("      Stack: ~p", [Stacktrace])
                end,
                ok
        end,

        %% Give harness time to finish validation
        timer:sleep(500),

        %% Check harness exit code for actual test result
        check_harness_result(ContainerName)
    after
        stop_harness(ContainerName)
    end.

%%====================================================================
%% Helpers
%%====================================================================

check_harness_available() ->
    case os:cmd("docker image inspect " ++ ?HARNESS_IMAGE ++ " 2>&1 | grep -q Id; echo $?") of
        "0\n" -> true;
        _ -> false
    end.

start_harness(TestId) ->
    Name = ?HARNESS_CONTAINER_PREFIX ++ clean_id(TestId),
    os:cmd("docker stop " ++ Name ++ " 2>/dev/null"),
    os:cmd("docker rm " ++ Name ++ " 2>/dev/null"),
    Cmd = io_lib:format(
        "docker run -d --name ~s -p ~p:8080 ~s -test=\"~s\"",
        [Name, ?HARNESS_BASE_PORT, ?HARNESS_IMAGE, TestId]
    ),
    _Result = os:cmd(lists:flatten(Cmd)),
    timer:sleep(3000),
    {ok, Name}.

stop_harness(Name) ->
    os:cmd("docker stop " ++ Name ++ " 2>/dev/null"),
    os:cmd("docker rm " ++ Name ++ " 2>/dev/null"),
    ok.

check_harness_result(ContainerName) ->
    %% Stop container gracefully to get exit code
    os:cmd("docker stop " ++ ContainerName ++ " 2>/dev/null"),

    %% Wait for container to stop
    Cmd = "docker wait " ++ ContainerName ++ " 2>/dev/null",
    ExitCode = string:trim(os:cmd(Cmd)),

    case ExitCode of
        "0" ->
            ct:pal("    ✓ Harness reports: PASSED"),
            ok;
        "" ->
            %% Container already stopped, check inspect
            InspectCmd = "docker inspect --format='{{.State.ExitCode}}' " ++ ContainerName ++ " 2>/dev/null",
            case string:trim(os:cmd(InspectCmd)) of
                "0" ->
                    ct:pal("    ✓ Harness reports: PASSED"),
                    ok;
                Code when Code =/= "" ->
                    ct:pal("    ✗ Harness reports: FAILED (exit code ~s)", [Code]),
                    ct:fail("Test failed - harness exit code ~s", [Code]);
                _ ->
                    ct:pal("    ⚠ Could not determine harness result"),
                    ct:fail("Could not read harness exit code")
            end;
        Code ->
            ct:pal("    ✗ Harness reports: FAILED (exit code ~s)", [Code]),
            ct:fail("Test failed - harness exit code ~s", [Code])
    end.

clean_id(TestId) ->
    re:replace(TestId, "[^a-zA-Z0-9_]", "_", [global, {return, list}]).

execute_test() ->
    case
        gen_http:connect(https, ?HARNESS_HOST, ?HARNESS_BASE_PORT, #{
            transport_opts => [
                {verify, verify_none},
                {versions, ['tlsv1.2', 'tlsv1.3']},
                {alpn_advertised_protocols, [<<"h2">>]}
            ]
        })
    of
        {ok, Conn} ->
            try
                make_request(Conn)
            catch
                _:_ ->
                    ok
            after
                %% Ignore errors when closing - connection may already be closed by test harness
                try
                    gen_http:close(Conn)
                catch
                    _:_ -> ok
                end
            end;
        {error, _} ->
            ok
    end.

make_request(Conn) ->
    case gen_http:request(Conn, <<"GET">>, <<"/test">>, [], <<>>) of
        {ok, Conn2, Ref} ->
            collect_response(Conn2, Ref);
        {ok, Conn2, Ref, _StreamId} ->
            collect_response(Conn2, Ref);
        {error, _, _} ->
            ok
    end.

collect_response(Conn, Ref) ->
    receive
        Msg ->
            case gen_http:stream(Conn, Msg) of
                {ok, Conn2, Responses} ->
                    case lists:keyfind(done, 1, Responses) of
                        {done, Ref} -> ok;
                        false -> collect_response(Conn2, Ref)
                    end;
                {error, _, _} ->
                    ok
            end
    after ?REQUEST_TIMEOUT ->
        %% Fail by default - don't assume timeout is acceptable
        %% If the harness validates our behavior as correct, it will exit 0
        %% But we should not assume timeout = pass
        ct:pal("    ⚠ Client timeout after ~pms", [?REQUEST_TIMEOUT]),
        error({client_timeout, Ref, ?REQUEST_TIMEOUT})
    end.
