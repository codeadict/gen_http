-module(test_helper).

%% @doc Common test utilities for gen_http tests.
%%
%% This module provides helper functions for setting up test servers
%% and managing test infrastructure.

-export([
    http_server/0,
    https_server/0,
    http_port/0,
    https_port/0,
    skip_if_no_server/0,
    is_server_available/0,
    collect_response/3
]).

%% @doc Get HTTP test server configuration.
-spec http_server() -> {http, string(), inet:port_number()}.
http_server() ->
    {http, "localhost", http_port()}.

%% @doc Get HTTPS test server configuration.
-spec https_server() -> {https, string(), inet:port_number()}.
https_server() ->
    {https, "localhost", https_port()}.

%% @doc Get HTTP test server port.
-spec http_port() -> inet:port_number().
http_port() ->
    case os:getenv("HTTPBIN_HTTP_PORT") of
        false -> 8080;
        Port -> list_to_integer(Port)
    end.

%% @doc Get HTTPS test server port.
-spec https_port() -> inet:port_number().
https_port() ->
    case os:getenv("HTTPBIN_HTTPS_PORT") of
        false -> 8443;
        Port -> list_to_integer(Port)
    end.

%% @doc Skip test if local test server is not available.
%%
%% Returns `ok` if server is available, `{skip, Reason}` otherwise.
-spec skip_if_no_server() -> ok | {skip, string()}.
skip_if_no_server() ->
    case is_server_available() of
        true -> ok;
        false -> {skip, "Test server not available. Run: docker compose -f test/support/docker-compose.yml up -d"}
    end.

%% @doc Check if local test server is available.
-spec is_server_available() -> boolean().
is_server_available() ->
    {http, Host, Port} = http_server(),
    case gen_tcp:connect(Host, Port, [], 1000) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            true;
        {error, _} ->
            false
    end.

%% @doc Collect HTTP response in active mode.
%%
%% Waits for response messages and processes them using gen_http_h1:stream/2.
%% Returns the updated connection and response map containing status, headers, body.
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
