-module(gen_http_transport).

-include("include/gen_http.hrl").

-callback connect(
    Address :: address(),
    Port :: inet:port_number(),
    Opts :: proplists:proplist()
) ->
    {ok, Socket :: term()} | {error, Reason :: term()}.

-callback upgrade(
    Socket :: socket(),
    OriginalScheme :: scheme(),
    Hostname :: binary(),
    Port :: inet:port_number(),
    Opts :: proplists:proplist()
) ->
    {ok, socket()} | {error, term()}.

-callback negotiated_protocol(Socket :: socket()) ->
    {ok, Protocol :: binary()} | {error, protocol_not_negotiated}.

-callback send(Socket :: socket(), Payload :: iodata()) -> ok | {error, Reason :: term()}.

-callback close(Socket :: socket()) -> ok | {error, Reason :: term()}.
