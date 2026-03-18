-module(gen_http_transport).

-include("include/gen_http.hrl").

?MODULEDOC("""
Transport behaviour for pluggable network backends.

Defines the callbacks that TCP and SSL transport modules must implement.
`gen_http` ships with two implementations: `gen_http_tcp` and `gen_http_ssl`.

This module is used internally by the connection modules to abstract over
the underlying socket type.
""").

-export([module_for_scheme/1]).

-export_type([scheme/0, address/0, socket/0]).

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

-callback setopts(Socket :: socket(), Opts :: list()) -> ok | {error, Reason :: term()}.

-callback controlling_process(Socket :: socket(), Pid :: pid()) ->
    ok | {error, Reason :: term()}.

-callback recv(Socket :: socket(), Length :: non_neg_integer(), Timeout :: timeout()) ->
    {ok, binary() | list()} | {error, Reason :: term()}.

-callback peername(Socket :: socket()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, Reason :: term()}.

-callback sockname(Socket :: socket()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, Reason :: term()}.

-callback getstat(Socket :: socket()) ->
    {ok, [{atom(), integer()}]} | {error, Reason :: term()}.

%%====================================================================
%% Utility Functions
%%====================================================================

?DOC("""
Returns the transport module for a given scheme.

- `http` -> `gen_http_tcp`
- `https` -> `gen_http_ssl`
""").
-spec module_for_scheme(scheme()) -> module().
module_for_scheme(http) -> gen_http_tcp;
module_for_scheme(https) -> gen_http_ssl.
