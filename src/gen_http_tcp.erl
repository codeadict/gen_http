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
    recv/3,
    peername/1,
    sockname/1,
    getstat/1
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

    %% Base socket options. Don't hardcode sndbuf/recbuf — let the OS
    %% auto-tune them (macOS default ~400KB, Linux ~128KB). The
    %% optimize_buffer/1 call after connect sets the Erlang-level
    %% buffer to max(sndbuf, recbuf, buffer) so recv returns large
    %% chunks. Users can still override via socket_opts or top-level
    %% sndbuf/recbuf options.
    BaseOpts = [
        binary,
        {packet, raw},
        {active, false},
        {nodelay, true},
        {reuseaddr, true},
        {keepalive, proplists:get_value(keepalive, Opts, true)},
        {send_timeout, proplists:get_value(send_timeout, Opts, 5000)},
        {send_timeout_close, true}
    ],
    %% Allow explicit sndbuf/recbuf override via transport_opts
    BufOverrides = [{K, V} || {K, V} <- Opts, K =:= sndbuf orelse K =:= recbuf],
    SocketOpts = BaseOpts ++ BufOverrides ++ proplists:get_value(socket_opts, Opts, []),
    Timeout = proplists:get_value(timeout, Opts, 5000),
    case gen_tcp:connect(NormalizedAddress, Port, SocketOpts, Timeout) of
        {ok, Socket} ->
            optimize_buffer(Socket),
            {ok, Socket};
        {error, _} = Err ->
            Err
    end.

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

%% @doc Get the remote address and port.
-spec peername(socket()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername(Socket) ->
    inet:peername(Socket).

%% @doc Get the local address and port.
-spec sockname(socket()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
sockname(Socket) ->
    inet:sockname(Socket).

%% @doc Get socket statistics (bytes sent/received, etc.).
-spec getstat(socket()) -> {ok, [{atom(), integer()}]} | {error, term()}.
getstat(Socket) ->
    inet:getstat(Socket).

%% @doc Optimize the Erlang-level buffer to match OS socket buffers.
%%
%% Queries the actual sndbuf/recbuf/buffer sizes from the OS and sets
%% the Erlang-level buffer to the maximum of the three. This ensures
%% Erlang can take advantage of kernel auto-tuning.
-spec optimize_buffer(socket()) -> ok.
optimize_buffer(Socket) ->
    _ =
        case inet:getopts(Socket, [sndbuf, recbuf, buffer]) of
            {ok, Opts} ->
                SndBuf = proplists:get_value(sndbuf, Opts, 0),
                RecBuf = proplists:get_value(recbuf, Opts, 0),
                Buffer = proplists:get_value(buffer, Opts, 0),
                NewBuffer = max(SndBuf, max(RecBuf, Buffer)),
                case NewBuffer > Buffer of
                    true -> _ = inet:setopts(Socket, [{buffer, NewBuffer}]);
                    false -> ok
                end;
            {error, _} ->
                ok
        end,
    ok.
