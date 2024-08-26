-module(gen_http_app).

-behaviour(application).

-export([start/2, stop/1, get_app_env/1, get_app_env/2, user_agent/0]).

-spec start(normal | {takeover, node()} | {failover, node()}, term()) ->
    {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    gen_http_sup:start_link().

-spec stop([]) -> ok.
stop(_State) ->
    ok.

%% @doc return a configuration value
get_app_env(Key) ->
    get_app_env(Key, undefined).

%% @doc return a configuration value
get_app_env(Key, Default) ->
    case application:get_env(gen_http, Key) of
        {ok, Val} ->
            Val;
        undefined ->
            Default
    end.

%% @doc returns the defualt user agent to use
user_agent() ->
    Version =
        case application:get_key(gen_http, vsn) of
            {ok, FullVersion} ->
                list_to_binary(hd(string:tokens(FullVersion, "-")));
            _ ->
                <<"0.0.0">>
        end,
    <<"gen_http/", Version/binary>>.
