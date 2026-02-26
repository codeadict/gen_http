-module(test_helper).

%% Common test utilities for gen_http tests.
%%
%% Provides helpers for starting the local mock HTTP server,
%% managing nghttpx as a TLS/H2 proxy, and collecting responses.

-export([
    start_mock/0,
    stop_mock/1,
    ensure_nghttpx/0,
    start_nghttpx/1,
    stop_nghttpx/1,
    generate_certs/1,
    find_free_port/0,
    collect_response/3,
    recv_all/2
]).

%%====================================================================
%% Mock HTTP server (delegates to mock_server:start_http/0)
%%====================================================================

-spec start_mock() -> {ok, pid(), inet:port_number()}.
start_mock() ->
    mock_server:start_http().

-spec stop_mock(pid()) -> ok.
stop_mock(Pid) ->
    mock_server:stop(Pid).

%%====================================================================
%% nghttpx TLS/H2 proxy management
%%====================================================================

-type nghttpx_info() :: #{
    port := inet:port_number(),
    os_pid := string(),
    cert_dir := string()
}.

-spec ensure_nghttpx() -> ok | {skip, string()}.
ensure_nghttpx() ->
    case os:find_executable("nghttpx") of
        false -> {skip, "nghttpx not found in PATH"};
        _ -> ok
    end.

-spec start_nghttpx(inet:port_number()) -> {ok, nghttpx_info()} | {skip, string()}.
start_nghttpx(BackendPort) ->
    case ensure_nghttpx() of
        {skip, _} = Skip ->
            Skip;
        ok ->
            TmpDir = make_tmp_dir(),
            {CertFile, KeyFile} = generate_certs(TmpDir),
            FrontendPort = find_free_port(),
            ConfigFile = filename:join(TmpDir, "nghttpx.conf"),
            Config = io_lib:format(
                "frontend=*,~B;tls\n"
                "backend=127.0.0.1,~B\n"
                "private-key-file=~s\n"
                "certificate-file=~s\n"
                "workers=1\n",
                [FrontendPort, BackendPort, KeyFile, CertFile]
            ),
            ok = file:write_file(ConfigFile, Config),
            Exe = os:find_executable("nghttpx"),
            PortRef = open_port(
                {spawn_executable, Exe},
                [
                    {args, ["--conf=" ++ ConfigFile]},
                    stderr_to_stdout,
                    binary,
                    exit_status
                ]
            ),
            %% Give nghttpx time to bind the port
            wait_for_port(FrontendPort, 50, 100),
            %% Read the OS PID so we can kill it later
            OsPid = read_os_pid(PortRef),
            {ok, #{
                port => FrontendPort,
                os_pid => OsPid,
                cert_dir => TmpDir,
                port_ref => PortRef
            }}
    end.

-spec stop_nghttpx(nghttpx_info()) -> ok.
stop_nghttpx(#{os_pid := OsPid, cert_dir := Dir, port_ref := PortRef}) ->
    %% Kill the nghttpx process
    _ = os:cmd("kill " ++ OsPid),
    %% Drain any remaining port messages
    drain_port(PortRef),
    %% Clean up temp dir
    _ = os:cmd("rm -rf " ++ Dir),
    ok.

%%====================================================================
%% Certificate generation
%%====================================================================

-spec generate_certs(string()) -> {CertFile :: string(), KeyFile :: string()}.
generate_certs(Dir) ->
    CertFile = filename:join(Dir, "cert.pem"),
    KeyFile = filename:join(Dir, "key.pem"),
    Cmd = io_lib:format(
        "openssl req -x509 -newkey rsa:2048 -keyout ~s -out ~s "
        "-days 1 -nodes -subj '/CN=localhost' 2>/dev/null",
        [KeyFile, CertFile]
    ),
    _ = os:cmd(lists:flatten(Cmd)),
    {CertFile, KeyFile}.

%%====================================================================
%% Port utilities
%%====================================================================

-spec find_free_port() -> inet:port_number().
find_free_port() ->
    {ok, LSock} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(LSock),
    gen_tcp:close(LSock),
    Port.

%%====================================================================
%% Response collection (unchanged)
%%====================================================================

%% @doc Collect HTTP response in active mode.
-spec collect_response(gen_http_h1:conn(), reference(), timeout()) ->
    {gen_http_h1:conn(), map()}.
collect_response(Conn, Ref, Timeout) ->
    collect_response_loop(Conn, Ref, #{}, Timeout).

-spec collect_response_loop(gen_http_h1:conn(), reference(), map(), timeout()) ->
    {gen_http_h1:conn(), map()}.
collect_response_loop(Conn, Ref, Acc, Timeout) ->
    receive
        Msg ->
            case gen_http_h1:stream(Conn, Msg) of
                {ok, NewConn, Responses} ->
                    NewAcc = process_responses(Responses, Ref, Acc),
                    case maps:get(done, NewAcc, false) of
                        true -> {NewConn, NewAcc};
                        false -> collect_response_loop(NewConn, Ref, NewAcc, Timeout)
                    end;
                {error, NewConn, Reason, Responses} ->
                    NewAcc = process_responses(Responses, Ref, Acc),
                    {NewConn, NewAcc#{error => Reason}};
                unknown ->
                    collect_response_loop(Conn, Ref, Acc, Timeout)
            end
    after Timeout ->
        {Conn, Acc#{error => timeout}}
    end.

-spec process_responses([gen_http_h1:response()], reference(), map()) -> map().
process_responses([], _Ref, Acc) ->
    Acc;
process_responses([{status, Ref, Status} | Rest], Ref, Acc) ->
    process_responses(Rest, Ref, Acc#{status => Status});
process_responses([{headers, Ref, Headers} | Rest], Ref, Acc) ->
    process_responses(Rest, Ref, Acc#{headers => Headers});
process_responses([{data, Ref, Data} | Rest], Ref, Acc) ->
    OldBody = maps:get(body, Acc, <<>>),
    process_responses(Rest, Ref, Acc#{body => <<OldBody/binary, Data/binary>>});
process_responses([{done, Ref} | Rest], Ref, Acc) ->
    process_responses(Rest, Ref, Acc#{done => true});
process_responses([{error, Ref, Error} | Rest], Ref, Acc) ->
    process_responses(Rest, Ref, Acc#{error => Error});
process_responses([_ | Rest], Ref, Acc) ->
    process_responses(Rest, Ref, Acc).

%% @doc Collect all responses in passive mode until {done, _} or error.
-spec recv_all(gen_http_h1:conn(), timeout()) ->
    {gen_http_h1:conn(), [gen_http:response()]}.
recv_all(Conn, Timeout) ->
    recv_all(Conn, Timeout, []).

-spec recv_all(gen_http_h1:conn(), timeout(), [gen_http:response()]) ->
    {gen_http_h1:conn(), [gen_http:response()]}.
recv_all(Conn, Timeout, Acc) ->
    case gen_http_h1:recv(Conn, 0, Timeout) of
        {ok, Conn2, Responses} ->
            NewAcc = Acc ++ Responses,
            case
                lists:any(
                    fun
                        ({done, _}) -> true;
                        (_) -> false
                    end,
                    Responses
                )
            of
                true -> {Conn2, NewAcc};
                false -> recv_all(Conn2, Timeout, NewAcc)
            end;
        {error, Conn2, _Reason, Responses} ->
            {Conn2, Acc ++ Responses}
    end.

%%====================================================================
%% Internal helpers
%%====================================================================

make_tmp_dir() ->
    Rand = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "gen_http_test_" ++ Rand),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

wait_for_port(_Port, 0, _Interval) ->
    ok;
wait_for_port(Port, Retries, Interval) ->
    case gen_tcp:connect("127.0.0.1", Port, [], 200) of
        {ok, Sock} ->
            gen_tcp:close(Sock);
        {error, _} ->
            timer:sleep(Interval),
            wait_for_port(Port, Retries - 1, Interval)
    end.

read_os_pid(PortRef) ->
    case erlang:port_info(PortRef, os_pid) of
        {os_pid, OsPid} -> integer_to_list(OsPid);
        undefined -> "0"
    end.

drain_port(PortRef) ->
    receive
        {PortRef, _} -> drain_port(PortRef)
    after 500 ->
        catch erlang:port_close(PortRef),
        ok
    end.
