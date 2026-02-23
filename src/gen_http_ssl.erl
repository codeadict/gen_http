-module(gen_http_ssl).
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

%% @doc Establish an SSL/TLS connection with ALPN support.
%%
%% Opens an SSL socket with ALPN protocol advertisement for HTTP/2 and HTTP/1.1.
%% The server will choose which protocol to use during the TLS handshake.
%%
%% Options:
%%   - `timeout` (default 5000) - Connection timeout in milliseconds
%%   - `alpn_advertise` (default [<<"h2">>, <<"http/1.1">>]) - Protocols to advertise
%%   - `socket_opts` - Additional SSL options
%%   - `verify` (default verify_peer) - Certificate verification mode
%%   - `cacerts` - CA certificates for verification
%%
%% Returns `{ok, Socket}` on success or `{error, Reason}` on failure.
-spec connect(address(), inet:port_number(), proplists:proplist()) ->
    {ok, socket()} | {error, term()}.
connect(Address, Port, Opts) ->
    %% Convert binary addresses to charlists for ssl compatibility
    NormalizedAddress =
        case Address of
            Bin when is_binary(Bin) -> binary_to_list(Bin);
            _ -> Address
        end,
    AlpnProtocols = proplists:get_value(alpn_advertise, Opts, [<<"h2">>, <<"http/1.1">>]),
    Timeout = proplists:get_value(timeout, Opts, 5000),

    %% Default buffer sizes optimized for HTTPS traffic (64KB - high throughput)
    DefaultBufSize = 65536,

    %% Base SSL options
    BaseOpts = [
        binary,
        {packet, raw},
        {active, false},
        {alpn_advertised_protocols, AlpnProtocols},
        %% Buffer tuning (fasthttp pattern)
        {sndbuf, proplists:get_value(sndbuf, Opts, DefaultBufSize)},
        {recbuf, proplists:get_value(recbuf, Opts, DefaultBufSize)},
        %% Socket reuse
        {reuseaddr, true},
        %% TLS session reuse (TLS 1.3 optimization)
        {reuse_sessions, true}
    ],

    %% Add verification options (verify_peer by default)
    VerifyOpts =
        case proplists:get_value(verify, Opts, verify_peer) of
            verify_peer ->
                [
                    {verify, verify_peer},
                    {depth, 10},
                    {customize_hostname_check, [
                        {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
                    ]}
                    | get_cacerts_opts(Opts)
                ];
            verify_none ->
                [{verify, verify_none}];
            Other ->
                [{verify, Other}]
        end,

    %% Combine all options
    SocketOpts = BaseOpts ++ VerifyOpts ++ proplists:get_value(socket_opts, Opts, []),

    ssl:connect(NormalizedAddress, Port, SocketOpts, Timeout).

%% @doc Upgrade a plain TCP socket to TLS with ALPN support.
%%
%% This is used for protocols that start with plaintext and upgrade to TLS
%% (like HTTP/1.1 Upgrade or STARTTLS).
%%
%% Options:
%%   - `timeout` (default 5000) - Handshake timeout
%%   - `alpn_advertise` - Protocols to advertise via ALPN
%%   - `socket_opts` - Additional SSL options
-spec upgrade(socket(), scheme(), binary(), inet:port_number(), proplists:proplist()) ->
    {ok, socket()} | {error, term()}.
upgrade(Socket, _OriginalScheme, Hostname, _Port, Opts) ->
    AlpnProtocols = proplists:get_value(alpn_advertise, Opts, [<<"h2">>, <<"http/1.1">>]),
    Timeout = proplists:get_value(timeout, Opts, 5000),

    SSLOpts = [
        binary,
        {packet, raw},
        {active, false},
        {alpn_advertised_protocols, AlpnProtocols},
        {server_name_indication, binary_to_list(Hostname)}
        | proplists:get_value(socket_opts, Opts, [])
    ],

    ssl:connect(Socket, SSLOpts, Timeout).

%% @doc Get the protocol negotiated via ALPN during TLS handshake.
%%
%% Returns:
%%   - `{ok, <<"h2">>}` if HTTP/2 was negotiated
%%   - `{ok, <<"http/1.1">>}` if HTTP/1.1 was negotiated
%%   - `{error, protocol_not_negotiated}` if ALPN was not used
-spec negotiated_protocol(socket()) ->
    {ok, binary()} | {error, protocol_not_negotiated}.
negotiated_protocol(Socket) ->
    case ssl:negotiated_protocol(Socket) of
        {ok, Protocol} -> {ok, Protocol};
        {error, protocol_not_negotiated} -> {error, protocol_not_negotiated}
    end.

%% @doc Send data through the SSL socket.
-spec send(socket(), iodata()) -> ok | {error, term()}.
send(Socket, Data) ->
    ssl:send(Socket, Data).

%% @doc Close the SSL socket.
-spec close(socket()) -> ok.
close(Socket) ->
    ssl:close(Socket).

%% @doc Set socket options.
-spec setopts(socket(), list()) -> ok | {error, term()}.
setopts(Socket, Opts) ->
    ssl:setopts(Socket, Opts).

%% @doc Transfer socket ownership to another process.
-spec controlling_process(socket(), pid()) -> ok | {error, term()}.
controlling_process(Socket, Pid) ->
    ssl:controlling_process(Socket, Pid).

%% @doc Receive data from the SSL socket in passive mode.
%%
%% This function blocks until data is received or timeout occurs.
%% Length of 0 means receive all available data.
%%
%% Returns `{ok, Data}` on success, `{error, closed}` if socket closed,
%% or `{error, Reason}` on other errors.
-spec recv(socket(), non_neg_integer(), timeout()) ->
    {ok, binary() | list()} | {error, term()}.
recv(Socket, Length, Timeout) ->
    ssl:recv(Socket, Length, Timeout).

%%====================================================================
%% Internal functions
%%====================================================================

%% @doc Get CA certificate options for SSL verification.
%% Uses OTP 25+ cacerts_get/0 if available, falls back to user-provided certs.
-spec get_cacerts_opts(proplists:proplist()) -> proplists:proplist().
get_cacerts_opts(Opts) ->
    case proplists:get_value(cacerts, Opts) of
        undefined ->
            %% Try to get system CA certs (OTP 25+)
            try public_key:cacerts_get() of
                CACerts when is_list(CACerts) ->
                    [{cacerts, CACerts}]
            catch
                _:_ ->
                    %% Fall back to default if not available
                    []
            end;
        CACerts ->
            [{cacerts, CACerts}]
    end.
