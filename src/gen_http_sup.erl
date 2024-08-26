-module(gen_http_sup).

-behaviour(supervisor).

%% API.
-export([start_link/0]).

%% Supervisor callbacks.
-export([init/1]).

%% From supervisor.
-type start_link_err() :: {already_started, pid()} | shutdown | term().
-type start_link_ret() :: {ok, pid()} | ignore | {error, start_link_err()}.

-spec start_link() -> start_link_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @private
init([]) ->
    {ok, {{one_for_one, 5, 3600}, []}}.
