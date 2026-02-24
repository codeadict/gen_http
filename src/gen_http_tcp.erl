-module(gen_http_tcp).
-behaviour(gen_http_transport).

-include("include/gen_http.hrl").

-export([
    connect/3,
    upgrade/5,
    negotiated_protocol/1,
    send/2,
    close/1,
    setopts/2,
    controlling_process/2,
    recv/3
]).

-export_type([address/0, scheme/0, socket/0]).

%% @doc Establish a TCP connection to the given address and port.
%%
%% Opens a TCP socket with binary mode, raw packets, active=false initially,
%% and TCP_NODELAY enabled for low latency.
%%
%% Options:
%%   - `timeout` (default 5000) - Connection timeout in milliseconds
%%   - `socket_opts` - Additional socket options to pass to gen_tcp
%%
%% Returns `{ok, Socket}` on success or `{error, Reason}` on failure.
-spec connect(address(), inet:port_number(), proplists:proplist()) ->
    {ok, socket()} | {error, term()}.
connect(Address, Port, Opts) ->
    %% Convert binary addresses to charlists for gen_tcp compatibility
    NormalizedAddress =
        case Address of
            Bin when is_binary(Bin) -> binary_to_list(Bin);
            _ -> Address
        end,

    %% Default buffer sizes optimized for HTTP traffic (64KB - high throughput)
    DefaultBufSize = 65536,

    SocketOpts = [
        binary,
        {packet, raw},
        {active, false},
        {nodelay, true},
        %% Buffer tuning (fasthttp pattern)
        {sndbuf, proplists:get_value(sndbuf, Opts, DefaultBufSize)},
        {recbuf, proplists:get_value(recbuf, Opts, DefaultBufSize)},
        %% Socket reuse
        {reuseaddr, true},
        %% Keepalive configuration
        {keepalive, proplists:get_value(keepalive, Opts, true)},
        %% Send timeout (5 seconds default)
        {send_timeout, proplists:get_value(send_timeout, Opts, 5000)},
        %% Close socket if send times out
        {send_timeout_close, true}
        | proplists:get_value(socket_opts, Opts, [])
    ],
    Timeout = proplists:get_value(timeout, Opts, 5000),
    gen_tcp:connect(NormalizedAddress, Port, SocketOpts, Timeout).

%% @doc Upgrade is not supported for plain TCP transport.
%%
%% TCP connections cannot be upgraded to TLS. Use gen_http_ssl for secure connections.
-spec upgrade(socket(), scheme(), binary(), inet:port_number(), proplists:proplist()) ->
    {ok, socket()} | {error, term()}.
upgrade(_Socket, _OriginalScheme, _Hostname, _Port, _Opts) ->
    {error, not_supported}.

%% @doc ALPN protocol negotiation is not available for plain TCP.
%%
%% Protocol negotiation requires TLS with ALPN extension.
-spec negotiated_protocol(socket()) -> {error, protocol_not_negotiated}.
negotiated_protocol(_Socket) ->
    {error, protocol_not_negotiated}.

%% @doc Send data through the TCP socket.
-spec send(socket(), iodata()) -> ok | {error, term()}.
send(Socket, Data) ->
    gen_tcp:send(Socket, Data).

%% @doc Close the TCP socket.
-spec close(socket()) -> ok | {error, term()}.
close(Socket) ->
    gen_tcp:close(Socket).

%% @doc Set socket options.
%%
%% Common options:
%%   - `{active, true | false | once | N}` - Control message delivery
%%   - `{buffer, Size}` - Set buffer size
%%   - `{packet, Type}` - Packet framing mode
-spec setopts(socket(), list()) -> ok | {error, term()}.
setopts(Socket, Opts) ->
    inet:setopts(Socket, Opts).

%% @doc Transfer socket ownership to another process.
%%
%% The new process will receive TCP messages for this socket.
-spec controlling_process(socket(), pid()) -> ok | {error, term()}.
controlling_process(Socket, Pid) ->
    gen_tcp:controlling_process(Socket, Pid).

%% @doc Receive data from the TCP socket in passive mode.
%%
%% This function blocks until data is received or timeout occurs.
%% Length of 0 means receive all available data.
%%
%% Returns `{ok, Data}` on success, `{error, closed}` if socket closed,
%% or `{error, Reason}` on other errors.
-spec recv(socket(), non_neg_integer(), timeout()) ->
    {ok, binary() | list()} | {error, term()}.
recv(Socket, Length, Timeout) ->
    gen_tcp:recv(Socket, Length, Timeout).
