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
%% Feature 1: recv/3 - Passive Mode Data Retrieval
%%====================================================================

recv_passive_get(_Config) ->
    ct:pal("Testing recv/3 in passive mode"),
    %% Connect in passive mode to local test server, force HTTP/1.1
    {https, Host, Port} = test_helper:https_server(),
    {ok, Conn} = gen_http:connect(https, list_to_binary(Host), Port, #{
        mode => passive,
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    %% Send GET request
    {ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),

    %% Receive response explicitly (0 = all available data)
    Result = gen_http:recv(Conn2, 0, 5000),

    %% Check if we got an error response or success
    case Result of
        {ok, Conn3, Responses} when is_list(Responses) ->
            %% Verify status response
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
            %% Connection might have closed, check if we got any responses
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

recv_active_mode_badarg(_Config) ->
    ct:pal("Testing recv/3 error on active mode"),
    %% Connect in active mode (default) to local test server, force HTTP/1.1
    {https, Host, Port} = test_helper:https_server(),
    {ok, Conn} = gen_http:connect(https, list_to_binary(Host), Port, #{
        mode => active,
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    %% Try to call recv/3 on active mode - should raise badarg
    ?assertError(badarg, gen_http:recv(Conn, 0, 5000)),

    %% Close connection
    {ok, _} = gen_http:close(Conn),
    ok.

%%====================================================================
%% Feature 2: set_mode/2 - Dynamic Socket Mode Switching
%%====================================================================

set_mode_to_passive(_Config) ->
    ct:pal("Testing set_mode/2 switch to passive"),
    %% Start in active mode (default), force HTTP/1.1
    {https, Host, Port} = test_helper:https_server(),
    {ok, Conn} = gen_http:connect(https, list_to_binary(Host), Port, #{
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    %% Switch to passive mode
    Result = gen_http:set_mode(Conn, passive),
    ?assertMatch({ok, _}, Result),
    {ok, Conn2} = Result,

    %% Should now be able to use recv/3
    {ok, Conn3, Ref} = gen_http:request(Conn2, <<"GET">>, <<"/get">>, [], <<>>),
    {ok, Conn4, Responses} = gen_http:recv(Conn3, 0, 5000),

    %% Verify we got status response
    ?assert(
        lists:any(
            fun
                ({status, R, _}) when R =:= Ref -> true;
                (_) -> false
            end,
            Responses
        )
    ),

    %% Close connection
    {ok, _} = gen_http:close(Conn4),
    ok.

set_mode_to_active(_Config) ->
    ct:pal("Testing set_mode/2 switch to active"),
    %% Start in passive mode, force HTTP/1.1
    {https, Host, Port} = test_helper:https_server(),
    {ok, Conn} = gen_http:connect(https, list_to_binary(Host), Port, #{
        mode => passive,
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    %% Switch to active mode
    Result = gen_http:set_mode(Conn, active),
    ?assertMatch({ok, _}, Result),
    {ok, Conn2} = Result,

    %% recv/3 should now fail with badarg
    ?assertError(badarg, gen_http:recv(Conn2, 0, 5000)),

    %% Close connection
    {ok, _} = gen_http:close(Conn2),
    ok.

set_mode_noop(_Config) ->
    ct:pal("Testing set_mode/2 no-op when already in mode"),
    %% Start in passive mode, force HTTP/1.1
    {https, Host, Port} = test_helper:https_server(),
    {ok, Conn} = gen_http:connect(https, list_to_binary(Host), Port, #{
        mode => passive,
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    %% Set to passive again (no-op)
    {ok, Conn2} = gen_http:set_mode(Conn, passive),

    %% Should still work with recv/3
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

controlling_process_transfer(_Config) ->
    ct:pal("Testing controlling_process/2 ownership transfer"),
    %% Create connection in this process, force HTTP/1.1
    {https, Host, Port} = test_helper:https_server(),
    {ok, Conn} = gen_http:connect(https, list_to_binary(Host), Port, #{
        mode => passive,
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    %% Spawn worker process
    Parent = self(),
    Worker = spawn(fun() ->
        receive
            {conn, TransferredConn} ->
                %% Try to use the connection
                {ok, Conn2, Ref} = gen_http:request(TransferredConn, <<"GET">>, <<"/get">>, [], <<>>),
                {ok, Conn3, Responses} = gen_http:recv(Conn2, 0, 5000),

                %% Verify status
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

    %% Transfer ownership to worker
    {ok, Conn2} = gen_http:controlling_process(Conn, Worker),

    %% Send connection to worker
    Worker ! {conn, Conn2},

    %% Wait for worker result
    receive
        {test_result, HasStatus} ->
            ?assert(HasStatus)
    after 10000 ->
        %% Timeout
        ?assert(false)
    end,
    ok.

%%====================================================================
%% Feature 4: put_log/2 - Dynamic Logging Control
%%====================================================================

put_log_enable(_Config) ->
    ct:pal("Testing put_log/2 enable logging"),
    {https, Host, Port} = test_helper:https_server(),
    {ok, Conn} = gen_http:connect(https, list_to_binary(Host), Port, #{
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    %% Enable logging
    Result = gen_http:put_log(Conn, true),
    ?assertMatch({ok, _}, Result),
    {ok, Conn2} = Result,

    %% Connection should still work normally
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

put_log_disable(_Config) ->
    ct:pal("Testing put_log/2 disable logging"),
    {https, Host, Port} = test_helper:https_server(),
    {ok, Conn} = gen_http:connect(https, list_to_binary(Host), Port, #{
        protocols => [http1],
        transport_opts => [{verify, verify_none}]
    }),

    %% Enable then disable logging
    {ok, Conn2} = gen_http:put_log(Conn, true),
    Result = gen_http:put_log(Conn2, false),
    ?assertMatch({ok, _}, Result),
    {ok, Conn3} = Result,

    %% Connection should still work normally
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

combined_features(_Config) ->
    ct:pal("Testing combined features"),
    %% Test combining multiple features:
    %% 1. Connect with logging enabled
    %% 2. Switch modes
    %% 3. Transfer ownership
    %% 4. Use recv in passive mode

    {https, Host, Port} = test_helper:https_server(),
    {ok, Conn} = gen_http:connect(https, list_to_binary(Host), Port, #{
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
