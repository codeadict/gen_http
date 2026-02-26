-module(features_SUITE).

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
    % recv/3 - Passive mode tests
    recv_passive_get/1,
    recv_active_mode_badarg/1,

    % set_mode/2 - Mode switching tests
    set_mode_to_passive/1,
    set_mode_to_active/1,
    set_mode_noop/1,

    % controlling_process/2 tests
    controlling_process_transfer/1,

    % put_log/2 tests
    put_log_enable/1,
    put_log_disable/1,

    % Integration test
    combined_features/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [
        {group, passive_mode},
        {group, mode_switching},
        {group, process_control},
        {group, logging},
        {group, integration}
    ].

groups() ->
    [
        {passive_mode, [parallel], [
            recv_passive_get,
            recv_active_mode_badarg
        ]},
        {mode_switching, [parallel], [
            set_mode_to_passive,
            set_mode_to_active,
            set_mode_noop
        ]},
        {process_control, [sequence], [
            controlling_process_transfer
        ]},
        {logging, [parallel], [
            put_log_enable,
            put_log_disable
        ]},
        {integration, [sequence], [
            combined_features
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
%% Feature 1: recv/3 - Passive Mode Data Retrieval
%%====================================================================

recv_passive_get(Config) ->
    ct:pal("Testing recv/3 in passive mode"),
    Port = ?config(https_port, Config),
    {ok, Conn} = gen_http:connect(https, <<"127.0.0.1">>, Port, #{
        mode => passive,
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    {ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),

    Result = gen_http:recv(Conn2, 0, 5000),

    case Result of
        {ok, Conn3, Responses} when is_list(Responses) ->
            ?assert(
                lists:any(
                    fun
                        ({status, R, Status}) when R =:= Ref -> Status =:= 200;
                        (_) -> false
                    end,
                    Responses
                )
            ),
            {ok, _} = gen_http:close(Conn3),
            ok;
        {error, Conn3, _Reason, Responses} ->
            HasStatus = lists:any(
                fun
                    ({status, R, Status}) when R =:= Ref -> Status =:= 200;
                    (_) -> false
                end,
                Responses
            ),
            {ok, _} = gen_http:close(Conn3),
            ?assert(HasStatus)
    end.

recv_active_mode_badarg(Config) ->
    ct:pal("Testing recv/3 error on active mode"),
    Port = ?config(https_port, Config),
    {ok, Conn} = gen_http:connect(https, <<"127.0.0.1">>, Port, #{
        mode => active,
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    ?assertError(badarg, gen_http:recv(Conn, 0, 5000)),

    {ok, _} = gen_http:close(Conn),
    ok.

%%====================================================================
%% Feature 2: set_mode/2 - Dynamic Socket Mode Switching
%%====================================================================

set_mode_to_passive(Config) ->
    ct:pal("Testing set_mode/2 switch to passive"),
    Port = ?config(https_port, Config),
    {ok, Conn} = gen_http:connect(https, <<"127.0.0.1">>, Port, #{
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    Result = gen_http:set_mode(Conn, passive),
    ?assertMatch({ok, _}, Result),
    {ok, Conn2} = Result,

    {ok, Conn3, Ref} = gen_http:request(Conn2, <<"GET">>, <<"/get">>, [], <<>>),
    {ok, Conn4, Responses} = gen_http:recv(Conn3, 0, 5000),

    ?assert(
        lists:any(
            fun
                ({status, R, _}) when R =:= Ref -> true;
                (_) -> false
            end,
            Responses
        )
    ),

    {ok, _} = gen_http:close(Conn4),
    ok.

set_mode_to_active(Config) ->
    ct:pal("Testing set_mode/2 switch to active"),
    Port = ?config(https_port, Config),
    {ok, Conn} = gen_http:connect(https, <<"127.0.0.1">>, Port, #{
        mode => passive,
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    Result = gen_http:set_mode(Conn, active),
    ?assertMatch({ok, _}, Result),
    {ok, Conn2} = Result,

    ?assertError(badarg, gen_http:recv(Conn2, 0, 5000)),

    {ok, _} = gen_http:close(Conn2),
    ok.

set_mode_noop(Config) ->
    ct:pal("Testing set_mode/2 no-op when already in mode"),
    Port = ?config(https_port, Config),
    {ok, Conn} = gen_http:connect(https, <<"127.0.0.1">>, Port, #{
        mode => passive,
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    {ok, Conn2} = gen_http:set_mode(Conn, passive),

    {ok, Conn3, Ref} = gen_http:request(Conn2, <<"GET">>, <<"/get">>, [], <<>>),
    {ok, Conn4, Responses} = gen_http:recv(Conn3, 0, 5000),

    ?assert(
        lists:any(
            fun
                ({status, R, _}) when R =:= Ref -> true;
                (_) -> false
            end,
            Responses
        )
    ),

    {ok, _} = gen_http:close(Conn4),
    ok.

%%====================================================================
%% Feature 3: controlling_process/2 - Process Ownership Transfer
%%====================================================================

controlling_process_transfer(Config) ->
    ct:pal("Testing controlling_process/2 ownership transfer"),
    Port = ?config(https_port, Config),
    {ok, Conn} = gen_http:connect(https, <<"127.0.0.1">>, Port, #{
        mode => passive,
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    Parent = self(),
    Worker = spawn(fun() ->
        receive
            {conn, TransferredConn} ->
                {ok, Conn2, Ref} = gen_http:request(TransferredConn, <<"GET">>, <<"/get">>, [], <<>>),
                {ok, Conn3, Responses} = gen_http:recv(Conn2, 0, 5000),

                HasStatus = lists:any(
                    fun
                        ({status, R, _}) when R =:= Ref -> true;
                        (_) -> false
                    end,
                    Responses
                ),

                Parent ! {test_result, HasStatus},
                {ok, _} = gen_http:close(Conn3)
        end
    end),

    {ok, Conn2} = gen_http:controlling_process(Conn, Worker),

    Worker ! {conn, Conn2},

    receive
        {test_result, HasStatus} ->
            ?assert(HasStatus)
    after 10000 ->
        ?assert(false)
    end,
    ok.

%%====================================================================
%% Feature 4: put_log/2 - Dynamic Logging Control
%%====================================================================

put_log_enable(Config) ->
    ct:pal("Testing put_log/2 enable logging"),
    Port = ?config(https_port, Config),
    {ok, Conn} = gen_http:connect(https, <<"127.0.0.1">>, Port, #{
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    Result = gen_http:put_log(Conn, true),
    ?assertMatch({ok, _}, Result),
    {ok, Conn2} = Result,

    {ok, Conn3} = gen_http:set_mode(Conn2, passive),
    {ok, Conn4, Ref} = gen_http:request(Conn3, <<"GET">>, <<"/get">>, [], <<>>),
    {ok, Conn5, Responses} = gen_http:recv(Conn4, 0, 5000),

    ?assert(
        lists:any(
            fun
                ({status, R, _}) when R =:= Ref -> true;
                (_) -> false
            end,
            Responses
        )
    ),

    {ok, _} = gen_http:close(Conn5),
    ok.

put_log_disable(Config) ->
    ct:pal("Testing put_log/2 disable logging"),
    Port = ?config(https_port, Config),
    {ok, Conn} = gen_http:connect(https, <<"127.0.0.1">>, Port, #{
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    {ok, Conn2} = gen_http:put_log(Conn, true),
    Result = gen_http:put_log(Conn2, false),
    ?assertMatch({ok, _}, Result),
    {ok, Conn3} = Result,

    {ok, Conn4} = gen_http:set_mode(Conn3, passive),
    {ok, Conn5, Ref} = gen_http:request(Conn4, <<"GET">>, <<"/get">>, [], <<>>),
    {ok, Conn6, Responses} = gen_http:recv(Conn5, 0, 5000),

    ?assert(
        lists:any(
            fun
                ({status, R, _}) when R =:= Ref -> true;
                (_) -> false
            end,
            Responses
        )
    ),

    {ok, _} = gen_http:close(Conn6),
    ok.

%%====================================================================
%% Integration Tests - Feature Combinations
%%====================================================================

combined_features(Config) ->
    ct:pal("Testing combined features"),
    Port = ?config(https_port, Config),
    {ok, Conn} = gen_http:connect(https, <<"127.0.0.1">>, Port, #{
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),
    {ok, Conn2} = gen_http:put_log(Conn, true),
    {ok, Conn3} = gen_http:set_mode(Conn2, passive),

    Parent = self(),
    Worker = spawn(fun() ->
        receive
            {conn, C} ->
                {ok, C2, Ref} = gen_http:request(C, <<"GET">>, <<"/get">>, [], <<>>),
                {ok, C3, Responses} = gen_http:recv(C2, 0, 5000),
                HasStatus = lists:any(
                    fun
                        ({status, R, _}) when R =:= Ref -> true;
                        (_) -> false
                    end,
                    Responses
                ),
                Parent ! {result, HasStatus},
                {ok, _} = gen_http:close(C3)
        end
    end),

    {ok, Conn4} = gen_http:controlling_process(Conn3, Worker),
    Worker ! {conn, Conn4},

    receive
        {result, HasStatus} ->
            ?assert(HasStatus)
    after 10000 ->
        ?assert(false)
    end,
    ok.
