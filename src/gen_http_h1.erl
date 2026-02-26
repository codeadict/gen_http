-module(gen_http_h1).
-feature(maybe_expr, enable).

%% @doc HTTP/1.1 connection state machine.
%%
%% Process-less HTTP/1.1 client. Supports:
%% - Request pipelining
%% - Keep-alive connections
%% - Chunked transfer encoding
%% - Body streaming (request and response)
%%
%% Connection state is a pure data structure passed between function calls.

%% Targeted inlining for small hot-path helpers
-compile(
    {inline, [
        is_open/1,
        get_socket/1,
        maybe_concat/2,
        has_alpn_option/1,
        fast_body_path/2,
        transport_error/1,
        protocol_error/1,
        application_error/1
    ]}
).

-include("include/gen_http.hrl").

%% Max hex digits in a chunk size line (16 hex chars = 64-bit max)
-define(MAX_CHUNK_HEX_LEN, 16).
%% Hard cap on a single chunk size (~2GB). Prevents allocation attacks
%% even if the buffer size limit hasn't been hit yet.
-define(MAX_CHUNK_SIZE, 2147483647).

-export([
    connect/3,
    connect/4,
    request/5,
    stream/2,
    stream_request_body/3,
    recv/3,
    set_mode/2,
    controlling_process/2,
    put_log/2,
    close/1,
    is_open/1,
    is_alive/1,
    get_socket/1,
    put_private/3,
    get_private/2,
    get_private/3,
    delete_private/2
]).

-export_type([
    conn/0,
    request_state/0,
    address/0,
    headers/0,
    request_ref/0,
    response/0,
    scheme/0,
    socket/0
]).

%% eqWalizer has limited support for maybe expressions
-eqwalizer({nowarn_function, connect/4}).
-eqwalizer({nowarn_function, send_request_streaming/5}).
-eqwalizer({nowarn_function, send_request_normal/5}).
-eqwalizer({nowarn_function, send_chunk/3}).

-record(gen_http_h1_conn, {
    transport :: module(),
    socket :: socket(),
    host :: binary(),
    port :: inet:port_number(),
    scheme :: scheme(),

    %% Connection state
    state = open :: open | closed,
    mode = active :: active | passive,

    %% Request/Response tracking
    buffer = <<>> :: binary(),
    %% Active request being parsed — stored directly to avoid queue
    %% operations on the hot path (every recv during body reading).
    current_request = undefined :: request_state() | undefined,
    %% Pipelined requests waiting to be processed.
    requests = queue:new() :: queue:queue(request_state()),
    streaming_request = undefined :: request_ref() | undefined,

    %% Settings
    max_pipeline = 10 :: pos_integer(),
    max_buffer_size = 1048576 :: pos_integer(),
    max_header_count = 100 :: pos_integer(),
    log = false :: boolean(),

    %% User metadata storage
    private = #{} :: #{term() => term()}
}).

-record(request_state, {
    ref :: request_ref(),
    method :: binary(),

    %% Response parsing state
    status = undefined :: status() | undefined,
    response_headers = [] :: headers(),

    %% Body parsing state
    body_state = undefined ::
        undefined
        | {content_length, non_neg_integer()}
        | {chunked, reading_size | {reading_data, non_neg_integer()}}
        | until_close
        | done,

    bytes_received = 0 :: non_neg_integer()
}).

-type conn() :: #gen_http_h1_conn{}.
-type request_state() :: #request_state{}.

%%====================================================================
%% API Functions
%%====================================================================

%% @doc Establish an HTTP/1.1 connection with default options.
-spec connect(scheme(), address(), inet:port_number()) ->
    {ok, conn()} | {error, term()}.
connect(Scheme, Address, Port) ->
    connect(Scheme, Address, Port, #{}).

%% @doc Establish an HTTP/1.1 connection with options.
%%
%% Options:
%%   - `timeout` (default 5000) - Connection timeout in milliseconds
%%   - `mode` (default active) - Socket mode (active | passive)
%%   - `max_pipeline` (default 10) - Maximum pipelined requests
-spec connect(scheme(), address(), inet:port_number(), map()) ->
    {ok, conn()} | {error, term()}.
connect(Scheme, Address, Port, Opts) ->
    case validate_opts(Opts) of
        ok ->
            connect_impl(Scheme, Address, Port, Opts);
        {error, _} = Err ->
            Err
    end.

-spec connect_impl(scheme(), address(), inet:port_number(), map()) ->
    {ok, conn()} | {error, term()}.
connect_impl(Scheme, Address, Port, Opts) ->
    Transport = gen_http_transport:module_for_scheme(Scheme),
    Timeout = maps:get(timeout, Opts, 5000),
    Mode = maps:get(mode, Opts, active),
    MaxPipeline = maps:get(max_pipeline, Opts, 10),
    MaxBufferSize = maps:get(max_buffer_size, Opts, 1048576),
    MaxHeaderCount = maps:get(max_header_count, Opts, 100),

    TransportOpts = maps:get(transport_opts, Opts, []),

    %% For HTTPS, ensure we only advertise HTTP/1.1 (not h2)
    ConnectOpts =
        case Scheme of
            https ->
                AlpnOpts =
                    case has_alpn_option(TransportOpts) of
                        true -> [];
                        false -> [{alpn_advertise, [<<"http/1.1">>]}]
                    end,
                [{timeout, Timeout} | AlpnOpts ++ TransportOpts];
            _ ->
                [{timeout, Timeout} | TransportOpts]
        end,

    maybe
        {ok, Socket} ?= Transport:connect(Address, Port, ConnectOpts),
        ok ?= setup_socket_mode(Transport, Socket, Mode),
        Conn = make_connection(
            Transport,
            Socket,
            Scheme,
            Address,
            Port,
            #{
                mode => Mode,
                max_pipeline => MaxPipeline,
                max_buffer_size => MaxBufferSize,
                max_header_count => MaxHeaderCount
            }
        ),
        {ok, Conn}
    else
        {error, Reason} -> {error, transport_error({connect_failed, Reason})}
    end.

%% @doc Send an HTTP request.
%%
%% Body can be:
%%   - `iodata()` - Send entire body immediately
%%   - `stream` - Use stream_request_body/3 to send body chunks
%%
%% Returns `{ok, Conn, RequestRef}` on success.
-spec request(conn(), binary(), binary(), headers(), iodata() | stream) ->
    {ok, conn(), request_ref()} | {error, conn(), term()}.
request(Conn, Method, Path, Headers, Body) ->
    case check_can_send_request(Conn) of
        ok ->
            send_request(Conn, Method, Path, Headers, Body);
        {error, Reason} ->
            {error, Conn, Reason}
    end.

%% @doc Stream a chunk of request body.
%%
%% Use `eof` to indicate end of body.
-spec stream_request_body(conn(), request_ref(), iodata() | eof) ->
    {ok, conn()} | {error, conn(), term()}.
stream_request_body(Conn, RequestRef, Chunk) ->
    case Conn#gen_http_h1_conn.streaming_request of
        RequestRef ->
            send_chunk(Conn, RequestRef, Chunk);
        _ ->
            {error, Conn, application_error({invalid_request_ref, RequestRef})}
    end.

%% @doc Receive data from the connection in passive mode.
%%
%% This function blocks until data is received or timeout occurs.
%% The connection must be in passive mode, otherwise this raises badarg.
%%
%% Options:
%%   - ByteCount - Number of bytes to receive (0 for all available)
%%   - Timeout - Timeout in milliseconds
%%
%% Returns `{ok, Conn, Responses}` on success or `{error, Conn, Reason}` on failure.
-spec recv(conn(), non_neg_integer(), timeout()) ->
    {ok, conn(), [response()]} | {error, conn(), term()}.
recv(#gen_http_h1_conn{mode = passive} = Conn, ByteCount, Timeout) ->
    #gen_http_h1_conn{transport = Transport, socket = Socket} = Conn,
    case Transport:recv(Socket, ByteCount, Timeout) of
        {ok, Data} ->
            handle_data(Conn, Data);
        {error, closed} ->
            handle_closed(Conn);
        {error, timeout} ->
            {error, Conn, transport_error(timeout)};
        {error, Reason} ->
            NewConn = Conn#gen_http_h1_conn{state = closed},
            {error, NewConn, transport_error(Reason)}
    end;
recv(#gen_http_h1_conn{mode = active}, _, _) ->
    error(badarg, [recv_requires_passive_mode]).

%% @doc Switch the connection socket mode between active and passive.
%%
%% Active mode (default):
%%   - Socket delivers messages to the owning process automatically
%%   - Uses `{active, once}` for flow control
%%   - Process them with `stream/2`
%%
%% Passive mode:
%%   - Explicit data retrieval using `recv/3`
%%   - Blocks until data is available
%%
%% Returns `{ok, Conn}` with updated mode or `{error, Conn, Reason}` on failure.
-spec set_mode(conn(), active | passive) -> {ok, conn()} | {error, conn(), term()}.
set_mode(Conn, Mode) when Mode =:= active; Mode =:= passive ->
    #gen_http_h1_conn{transport = Transport, socket = Socket, mode = CurrentMode} = Conn,
    case Mode of
        CurrentMode ->
            %% Already in target mode, no-op
            {ok, Conn};
        _ ->
            %% Convert mode to socket option
            SocketMode =
                case Mode of
                    active -> {active, once};
                    passive -> {active, false}
                end,
            case Transport:setopts(Socket, [SocketMode]) of
                ok -> {ok, Conn#gen_http_h1_conn{mode = Mode}};
                {error, Reason} -> {error, Conn, transport_error({setopts_failed, Reason})}
            end
    end.

%% @doc Transfer socket ownership to another process.
%%
%% This is useful for connection pooling patterns where you want to hand off
%% an established connection to a worker process.
%%
%% After calling this, the new process will receive socket messages.
%%
%% Returns `{ok, Conn}` on success or `{error, Conn, Reason}` on failure.
-spec controlling_process(conn(), pid()) -> {ok, conn()} | {error, conn(), term()}.
controlling_process(Conn, Pid) when is_pid(Pid) ->
    #gen_http_h1_conn{transport = Transport, socket = Socket} = Conn,
    case Transport:controlling_process(Socket, Pid) of
        ok -> {ok, Conn};
        {error, Reason} -> {error, Conn, transport_error({controlling_process_failed, Reason})}
    end.

%% @doc Enable or disable debug logging for this connection.
%%
%% When enabled, the connection will log debug information about frames,
%% requests, and responses. This is useful for debugging but adds overhead.
%%
%% Returns `{ok, Conn}` with updated logging state.
-spec put_log(conn(), boolean()) -> {ok, conn()}.
put_log(Conn, Log) when is_boolean(Log) ->
    {ok, Conn#gen_http_h1_conn{log = Log}}.

%% @doc Process incoming socket messages.
%%
%% Call this function when receiving TCP/SSL messages.
%% Returns parsed responses or errors.
-spec stream(conn(), term()) ->
    {ok, conn(), [response()]}
    | {error, conn(), term(), [response()]}
    | unknown.
stream(Conn, Message) ->
    Socket = Conn#gen_http_h1_conn.socket,
    case Message of
        {tcp, Socket, Data} -> handle_data(Conn, Data);
        {ssl, Socket, Data} -> handle_data(Conn, Data);
        {tcp_closed, Socket} -> handle_closed(Conn);
        {ssl_closed, Socket} -> handle_closed(Conn);
        {tcp_error, Socket, Reason} -> handle_error(Conn, Reason);
        {ssl_error, Socket, Reason} -> handle_error(Conn, Reason);
        _ -> unknown
    end.

%% @doc Close the connection.
-spec close(conn()) -> {ok, conn()}.
close(Conn) ->
    case Conn#gen_http_h1_conn.state of
        open ->
            Transport = Conn#gen_http_h1_conn.transport,
            Socket = Conn#gen_http_h1_conn.socket,
            Transport:close(Socket),
            {ok, Conn#gen_http_h1_conn{state = closed}};
        closed ->
            {ok, Conn}
    end.

%% @doc Check if connection is open.
-spec is_open(conn()) -> boolean().
is_open(#gen_http_h1_conn{state = State}) ->
    State =:= open.

%% @doc Check if the underlying socket is still alive.
%%
%% Does a non-blocking recv to detect if the server has closed the connection
%% while it was idle. Useful for connection pool implementations that want to
%% avoid sending requests on stale connections.
-spec is_alive(conn()) -> boolean().
is_alive(#gen_http_h1_conn{state = closed}) ->
    false;
is_alive(#gen_http_h1_conn{transport = Transport, socket = Socket}) ->
    case Transport:recv(Socket, 0, 0) of
        {error, timeout} -> true;
        {error, closed} -> false;
        {ok, _Data} -> false;
        {error, _} -> false
    end.

%% @doc Get the underlying socket.
-spec get_socket(conn()) -> socket().
get_socket(#gen_http_h1_conn{socket = Socket}) ->
    Socket.

%% @doc Store a private key-value pair in the connection.
%%
%% Attach metadata to connections (e.g., pool ID, metrics, tags).
-spec put_private(conn(), Key :: term(), Value :: term()) -> conn().
put_private(#gen_http_h1_conn{private = Private} = Conn, Key, Value) ->
    Conn#gen_http_h1_conn{private = Private#{Key => Value}}.

%% @doc Get a private value from the connection.
%%
%% Returns `undefined` if the key doesn't exist.
-spec get_private(conn(), Key :: term()) -> term() | undefined.
get_private(Conn, Key) ->
    get_private(Conn, Key, undefined).

%% @doc Get a private value from the connection with a default.
-spec get_private(conn(), Key :: term(), Default :: term()) -> term().
get_private(#gen_http_h1_conn{private = Private}, Key, Default) ->
    maps:get(Key, Private, Default).

%% @doc Delete a private key from the connection.
-spec delete_private(conn(), Key :: term()) -> conn().
delete_private(#gen_http_h1_conn{private = Private} = Conn, Key) ->
    Conn#gen_http_h1_conn{private = maps:remove(Key, Private)}.

%%====================================================================
%% Internal Functions - Connection Setup
%%====================================================================

-define(VALID_OPTS, [timeout, mode, max_pipeline, max_buffer_size, max_header_count, transport_opts, protocols]).

-spec validate_opts(map()) -> ok | {error, {unknown_option, term()}}.
validate_opts(Opts) ->
    case maps:keys(Opts) -- ?VALID_OPTS of
        [] -> ok;
        [Unknown | _] -> {error, {unknown_option, Unknown}}
    end.

-spec has_alpn_option(proplists:proplist()) -> boolean().
has_alpn_option(Opts) ->
    proplists:is_defined(alpn_advertise, Opts) orelse
        proplists:is_defined(alpn_advertised_protocols, Opts).

-spec setup_socket_mode(module(), socket(), active | passive) -> ok | {error, gen_http:error_reason()}.
setup_socket_mode(Transport, Socket, active) ->
    case Transport:setopts(Socket, [{active, once}]) of
        ok ->
            ok;
        {error, Reason} ->
            Transport:close(Socket),
            {error, transport_error({setopts_failed, Reason})}
    end;
setup_socket_mode(_Transport, _Socket, passive) ->
    ok.

-spec make_connection(module(), socket(), scheme(), address(), inet:port_number(), map()) -> conn().
make_connection(Transport, Socket, Scheme, Address, Port, Settings) ->
    #gen_http_h1_conn{
        transport = Transport,
        socket = Socket,
        host = normalize_host(Address),
        port = Port,
        scheme = Scheme,
        state = open,
        mode = maps:get(mode, Settings),
        max_pipeline = maps:get(max_pipeline, Settings),
        max_buffer_size = maps:get(max_buffer_size, Settings),
        max_header_count = maps:get(max_header_count, Settings)
    }.

-spec check_can_send_request(conn()) -> ok | {error, gen_http:error_reason()}.
check_can_send_request(#gen_http_h1_conn{state = closed}) ->
    {error, application_error(connection_closed)};
check_can_send_request(#gen_http_h1_conn{
    current_request = Current, requests = Requests, max_pipeline = MaxPipeline
}) ->
    ActiveCount =
        case Current of
            undefined -> 0;
            _ -> 1
        end,
    case queue:len(Requests) + ActiveCount >= MaxPipeline of
        true -> {error, application_error(pipeline_full)};
        false -> ok
    end.

%%====================================================================
%% Internal Functions - Request Sending
%%====================================================================

-spec send_request(conn(), binary(), binary(), headers(), iodata() | stream) ->
    {ok, conn(), request_ref()} | {error, conn(), term()}.
send_request(Conn, Method, Path, Headers, stream) ->
    send_request_streaming(Conn, Method, Path, Headers);
send_request(Conn, Method, Path, Headers, Body) ->
    send_request_normal(Conn, Method, Path, Headers, Body).

-spec send_request_streaming(conn(), binary(), binary(), headers()) ->
    {ok, conn(), request_ref()} | {error, conn(), term()}.
send_request_streaming(Conn, Method, Path, Headers) ->
    #gen_http_h1_conn{
        transport = Transport,
        socket = Socket,
        host = Host,
        port = Port
    } = Conn,

    RequestRef = make_ref(),
    HeadersWithDefaults = add_default_headers(Headers, Host, Port, stream),
    ChunkedHeaders = add_chunked_encoding(HeadersWithDefaults),

    maybe
        {ok, Encoded} ?= gen_http_parser_h1:encode_request(Method, Path, ChunkedHeaders, undefined),
        ok ?= Transport:send(Socket, Encoded),
        NewConn = queue_request_state(Conn, RequestRef, Method),
        {ok, NewConn#gen_http_h1_conn{streaming_request = RequestRef}, RequestRef}
    else
        {error, Reason} when is_atom(Reason); is_tuple(Reason) ->
            handle_send_error(Conn, Reason)
    end.

-spec send_request_normal(conn(), binary(), binary(), headers(), iodata()) ->
    {ok, conn(), request_ref()} | {error, conn(), term()}.
send_request_normal(Conn, Method, Path, Headers, Body) ->
    #gen_http_h1_conn{
        transport = Transport,
        socket = Socket,
        host = Host,
        port = Port
    } = Conn,

    RequestRef = make_ref(),
    HeadersWithDefaults = add_default_headers(Headers, Host, Port, Body),

    maybe
        {ok, Encoded} ?= gen_http_parser_h1:encode_request(Method, Path, HeadersWithDefaults, Body),
        ok ?= Transport:send(Socket, Encoded),
        NewConn = queue_request_state(Conn, RequestRef, Method),
        {ok, NewConn, RequestRef}
    else
        {error, Reason} when is_atom(Reason); is_tuple(Reason) ->
            handle_send_error(Conn, Reason)
    end.

-spec queue_request_state(conn(), request_ref(), binary()) -> conn().
queue_request_state(Conn, RequestRef, Method) ->
    ReqState = #request_state{ref = RequestRef, method = Method},
    case Conn#gen_http_h1_conn.current_request of
        undefined ->
            Conn#gen_http_h1_conn{current_request = ReqState};
        _ ->
            NewRequests = queue:in(ReqState, Conn#gen_http_h1_conn.requests),
            Conn#gen_http_h1_conn{requests = NewRequests}
    end.

-spec handle_send_error(conn(), term()) -> {error, conn(), gen_http:error_reason()}.
handle_send_error(Conn, Reason) ->
    ErrorType =
        case Reason of
            {encode_failed, _} -> protocol_error(Reason);
            _ -> transport_error({send_failed, Reason})
        end,
    case is_send_error(Reason) of
        true ->
            NewConn = Conn#gen_http_h1_conn{state = closed},
            {error, NewConn, ErrorType};
        false ->
            {error, Conn, ErrorType}
    end.

-spec is_send_error(term()) -> boolean().
is_send_error({send_failed, _}) -> true;
is_send_error(closed) -> true;
is_send_error(enotconn) -> true;
is_send_error(_) -> false.

-spec send_chunk(conn(), request_ref(), iodata() | eof) ->
    {ok, conn()} | {error, conn(), term()}.
send_chunk(Conn, _RequestRef, eof) ->
    #gen_http_h1_conn{transport = Transport, socket = Socket} = Conn,
    Encoded = gen_http_parser_h1:encode_chunk(eof),
    maybe
        ok ?= Transport:send(Socket, Encoded),
        {ok, Conn#gen_http_h1_conn{streaming_request = undefined}}
    else
        {error, Reason} ->
            NewConn = Conn#gen_http_h1_conn{state = closed},
            {error, NewConn, transport_error({send_failed, Reason})}
    end;
send_chunk(Conn, _RequestRef, Chunk) ->
    #gen_http_h1_conn{transport = Transport, socket = Socket} = Conn,
    Encoded = gen_http_parser_h1:encode_chunk(Chunk),
    maybe
        ok ?= Transport:send(Socket, Encoded),
        {ok, Conn}
    else
        {error, Reason} ->
            NewConn = Conn#gen_http_h1_conn{state = closed},
            {error, NewConn, transport_error({send_failed, Reason})}
    end.

%%====================================================================
%% Internal Functions - Header Management
%%====================================================================

-spec add_default_headers(headers(), binary(), inet:port_number(), iodata() | stream) ->
    headers().
add_default_headers(Headers, Host, Port, Body) ->
    {HasHost, HasCL, HasConn, HasUA} = scan_default_headers(Headers),
    H1 =
        case HasHost of
            false -> [{<<"host">>, format_host(Host, Port)} | Headers];
            true -> Headers
        end,
    H2 = maybe_add_content_length(H1, Body, HasCL),
    H3 =
        case HasConn of
            false -> [{<<"connection">>, <<"keep-alive">>} | H2];
            true -> H2
        end,
    case HasUA of
        false -> [{<<"user-agent">>, <<"gen_http/0.1">>} | H3];
        true -> H3
    end.

-spec scan_default_headers(headers()) ->
    {boolean(), boolean(), boolean(), boolean()}.
scan_default_headers(Headers) ->
    scan_default_headers(Headers, false, false, false, false).

-spec scan_default_headers(headers(), boolean(), boolean(), boolean(), boolean()) ->
    {boolean(), boolean(), boolean(), boolean()}.
scan_default_headers([], H, C, K, U) ->
    {H, C, K, U};
scan_default_headers([{<<"host">>, _} | Rest], _, C, K, U) ->
    scan_default_headers(Rest, true, C, K, U);
scan_default_headers([{<<"content-length">>, _} | Rest], H, _, K, U) ->
    scan_default_headers(Rest, H, true, K, U);
scan_default_headers([{<<"connection">>, _} | Rest], H, C, _, U) ->
    scan_default_headers(Rest, H, C, true, U);
scan_default_headers([{<<"user-agent">>, _} | Rest], H, C, K, _) ->
    scan_default_headers(Rest, H, C, K, true);
scan_default_headers([_ | Rest], H, C, K, U) ->
    scan_default_headers(Rest, H, C, K, U).

-spec maybe_add_content_length(headers(), iodata() | stream, boolean()) -> headers().
maybe_add_content_length(Headers, _, true) ->
    Headers;
maybe_add_content_length(Headers, stream, _) ->
    Headers;
maybe_add_content_length(Headers, <<>>, _) ->
    Headers;
maybe_add_content_length(Headers, Body, false) when is_binary(Body); is_list(Body) ->
    Length = iolist_size(Body),
    [{<<"content-length">>, integer_to_binary(Length)} | Headers].

-spec add_chunked_encoding(headers()) -> headers().
add_chunked_encoding(Headers) ->
    [{<<"transfer-encoding">>, <<"chunked">>} | Headers].

-spec format_host(binary(), inet:port_number()) -> binary().
format_host(Host, 80) -> Host;
format_host(Host, 443) -> Host;
format_host(Host, Port) -> <<Host/binary, $:, (integer_to_binary(Port))/binary>>.

-spec normalize_host(address()) -> binary().
normalize_host(Host) when is_binary(Host) -> Host;
normalize_host(Host) when is_list(Host) -> list_to_binary(Host);
normalize_host(Host) when is_atom(Host) -> atom_to_binary(Host, utf8).

%%====================================================================
%% Internal Functions - Response Parsing
%%====================================================================

-spec handle_data(conn(), binary()) ->
    {ok, conn(), [response()]} | {error, conn(), term(), [response()]}.
handle_data(Conn, Data) ->
    #gen_http_h1_conn{
        buffer = Buffer,
        mode = Mode,
        transport = Transport,
        socket = Socket,
        max_buffer_size = MaxBuf
    } = Conn,
    NewBuffer = maybe_concat(Buffer, Data),
    case byte_size(NewBuffer) > MaxBuf of
        true ->
            {error, Conn, {application_error, buffer_overflow}, []};
        false ->
            %% Try the fast path first without copying Buffer into the conn record.
            %% fast_body_path/2 only needs the conn + buffer; it builds the updated
            %% conn internally, saving one 13-element tuple copy on every recv call
            %% during body reading.
            case fast_body_path(Conn, NewBuffer) of
                {fast, NewConn, Responses} ->
                    reactivate_socket_if_needed(Transport, Socket, Mode, NewConn),
                    {ok, NewConn, Responses};
                normal ->
                    Conn1 = Conn#gen_http_h1_conn{buffer = NewBuffer},
                    case parse_responses(Conn1, []) of
                        {ok, NewConn, RevResponses} ->
                            reactivate_socket_if_needed(Transport, Socket, Mode, NewConn),
                            {ok, NewConn, lists:reverse(RevResponses)};
                        {error, NewConn, Reason, RevResponses} ->
                            {error, NewConn, Reason, lists:reverse(RevResponses)}
                    end
            end
    end.

%% @doc Fast path for the common hot-path: mid-body content-length reading
%% where the buffer doesn't complete the body. Skips the full parse chain
%% (parse_responses → handle_response_parsing → parse_response → parse_body).
%% Buffer is passed separately so handle_data can skip one conn record copy.
-spec fast_body_path(conn(), binary()) -> {fast, conn(), [response()]} | normal.
fast_body_path(
    #gen_http_h1_conn{
        current_request =
            #request_state{
                body_state = {content_length, Total},
                ref = Ref,
                bytes_received = BytesReceived
            } = ReqState
    } = Conn,
    Buffer
) ->
    Remaining = Total - BytesReceived,
    case byte_size(Buffer) < Remaining of
        true ->
            NewReqState = ReqState#request_state{
                bytes_received = BytesReceived + byte_size(Buffer)
            },
            {fast, Conn#gen_http_h1_conn{current_request = NewReqState, buffer = <<>>}, [{data, Ref, Buffer}]};
        false ->
            normal
    end;
fast_body_path(_, _) ->
    normal.

-spec reactivate_socket_if_needed(module(), socket(), active | passive, conn()) -> ok.
reactivate_socket_if_needed(Transport, Socket, active, #gen_http_h1_conn{state = open}) ->
    Transport:setopts(Socket, [{active, once}]);
reactivate_socket_if_needed(_, _, _, _) ->
    ok.

-spec parse_responses(conn(), [response()]) ->
    {ok, conn(), [response()]} | {error, conn(), term(), [response()]}.
parse_responses(Conn, Acc) ->
    case Conn#gen_http_h1_conn.current_request of
        undefined ->
            %% No active request — try to promote the next pipelined request.
            case queue:out(Conn#gen_http_h1_conn.requests) of
                {empty, _} ->
                    {ok, Conn, Acc};
                {{value, ReqState}, RestRequests} ->
                    NewConn = Conn#gen_http_h1_conn{
                        current_request = ReqState,
                        requests = RestRequests
                    },
                    handle_response_parsing(NewConn, Acc)
            end;
        _ ->
            handle_response_parsing(Conn, Acc)
    end.

%% Acc is kept in reverse order — handle_data does a single lists:reverse
%% at the end. lists:reverse(Responses, Acc) prepends the (small, typically
%% 1-4 element) forward-order Responses list onto the reverse Acc.
-spec handle_response_parsing(conn(), [response()]) ->
    {ok, conn(), [response()]} | {error, conn(), term(), [response()]}.
handle_response_parsing(Conn, Acc) ->
    ReqState = Conn#gen_http_h1_conn.current_request,
    Buffer = Conn#gen_http_h1_conn.buffer,
    MaxHeaderCount = Conn#gen_http_h1_conn.max_header_count,
    case parse_response(Buffer, ReqState, MaxHeaderCount) of
        {done, Responses, NewReqState, RestBuffer} ->
            NewConn = Conn#gen_http_h1_conn{
                current_request = undefined,
                buffer = RestBuffer
            },
            maybe_close_and_continue(NewConn, NewReqState, lists:reverse(Responses, Acc));
        {continue, Responses, NewReqState, RestBuffer} ->
            NewConn = Conn#gen_http_h1_conn{
                current_request = NewReqState,
                buffer = RestBuffer
            },
            {ok, NewConn, lists:reverse(Responses, Acc)};
        {error, Reason} ->
            NewConn = Conn#gen_http_h1_conn{state = closed},
            {error, NewConn, Reason, Acc}
    end.

-spec maybe_close_and_continue(conn(), request_state(), [response()]) ->
    {ok, conn(), [response()]}.
maybe_close_and_continue(Conn, ReqState, Acc) ->
    case should_close_connection(ReqState) of
        true ->
            FinalConn = Conn#gen_http_h1_conn{state = closed},
            {ok, FinalConn, Acc};
        false ->
            parse_responses(Conn, Acc)
    end.

-spec parse_response(binary(), request_state(), pos_integer()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}
    | {error, term()}.
parse_response(Buffer, #request_state{status = undefined} = ReqState, MaxHeaderCount) ->
    parse_status_line(Buffer, ReqState, MaxHeaderCount);
parse_response(Buffer, #request_state{body_state = undefined} = ReqState, MaxHeaderCount) ->
    parse_headers(Buffer, ReqState, [], 0, MaxHeaderCount);
parse_response(Buffer, ReqState, _MaxHeaderCount) ->
    parse_body(Buffer, ReqState).

-spec parse_status_line(binary(), request_state(), pos_integer()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}
    | {error, {protocol_error, invalid_status_line}}.
parse_status_line(Buffer, ReqState, MaxHeaderCount) ->
    case gen_http_parser_h1:decode_response_status_line(Buffer) of
        {ok, {_Version, StatusCode, _Reason}, Rest} ->
            StatusResp = {status, ReqState#request_state.ref, StatusCode},
            NewReqState = ReqState#request_state{status = StatusCode},
            case parse_response(Rest, NewReqState, MaxHeaderCount) of
                {done, Responses, FinalReqState, FinalRest} ->
                    {done, [StatusResp | Responses], FinalReqState, FinalRest};
                {continue, Responses, FinalReqState, FinalRest} ->
                    {continue, [StatusResp | Responses], FinalReqState, FinalRest};
                {error, Reason} ->
                    {error, Reason}
            end;
        more ->
            {continue, [], ReqState, Buffer};
        error ->
            {error, protocol_error(invalid_status_line)}
    end.

-spec parse_headers(binary(), request_state(), headers(), non_neg_integer(), pos_integer()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}
    | {error, term()}.
parse_headers(Buffer, ReqState, HeadersAcc, Count, MaxHeaderCount) ->
    case gen_http_parser_h1:decode_response_header(Buffer) of
        {ok, {Name, Value}, Rest} ->
            case Count >= MaxHeaderCount of
                true ->
                    {error, protocol_error(too_many_headers)};
                false ->
                    parse_headers(Rest, ReqState, [{Name, Value} | HeadersAcc], Count + 1, MaxHeaderCount)
            end;
        {ok, eof, Rest} ->
            handle_headers_complete(Rest, ReqState, lists:reverse(HeadersAcc), MaxHeaderCount);
        more ->
            {continue, [], ReqState, Buffer};
        error ->
            {error, protocol_error(invalid_header)}
    end.

handle_headers_complete(Rest, ReqState, Headers, MaxHeaderCount) ->
    HeadersResp = {headers, ReqState#request_state.ref, Headers},
    Status = ReqState#request_state.status,

    %% RFC 9110 Section 15.2 / RFC 9112 Section 9.2:
    %% Client MUST be able to parse one or more 1xx responses before final response.
    %% After a 1xx response, continue parsing for the next response.
    case is_informational_status(Status) of
        true ->
            %% Reset request state to parse the next response (could be another 1xx or final)
            ResetReqState = ReqState#request_state{
                status = undefined,
                response_headers = [],
                body_state = undefined,
                bytes_received = 0
            },
            %% Continue parsing without emitting {done, ...}
            case parse_status_line(Rest, ResetReqState, MaxHeaderCount) of
                {done, MoreResponses, FinalReqState, FinalRest} ->
                    {done, [HeadersResp | MoreResponses], FinalReqState, FinalRest};
                {continue, MoreResponses, FinalReqState, FinalRest} ->
                    {continue, [HeadersResp | MoreResponses], FinalReqState, FinalRest};
                {error, Reason} ->
                    {error, Reason}
            end;
        false ->
            %% Non-1xx response - handle normally
            case determine_body_state(Status, Headers) of
                {error, _} = Err ->
                    Err;
                BodyState ->
                    NewReqState = ReqState#request_state{response_headers = Headers, body_state = BodyState},
                    case BodyState of
                        done ->
                            %% No body (204, 304, etc.)
                            DoneResp = {done, ReqState#request_state.ref},
                            {done, [HeadersResp, DoneResp], NewReqState, Rest};
                        _ ->
                            %% Has body, continue parsing
                            combine_header_and_body_responses(Rest, NewReqState, HeadersResp)
                    end
            end
    end.

%% @doc Check if a status code is informational (1xx).
%% RFC 9110 Section 15.2: 1xx responses are interim responses.
-spec is_informational_status(status()) -> boolean().
is_informational_status(Status) when Status >= 100, Status =< 199 -> true;
is_informational_status(_) -> false.

-spec combine_header_and_body_responses(binary(), request_state(), response()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}
    | {error, term()}.
combine_header_and_body_responses(Rest, NewReqState, HeadersResp) ->
    case parse_body(Rest, NewReqState) of
        {done, BodyResponses, FinalReqState, FinalRest} ->
            {done, [HeadersResp | BodyResponses], FinalReqState, FinalRest};
        {continue, BodyResponses, FinalReqState, FinalRest} ->
            {continue, [HeadersResp | BodyResponses], FinalReqState, FinalRest};
        {error, Reason} ->
            {error, Reason}
    end.

-spec parse_body(binary(), request_state()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}
    | {error, term()}.
parse_body(Buffer, #request_state{body_state = done, ref = Ref} = ReqState) ->
    {done, [{done, Ref}], ReqState, Buffer};
parse_body(Buffer, #request_state{body_state = {content_length, Total}} = ReqState) ->
    parse_content_length_body(Buffer, ReqState, Total);
parse_body(Buffer, #request_state{body_state = {chunked, reading_size}, ref = Ref} = ReqState) ->
    parse_chunk_size(Buffer, ReqState, Ref);
parse_body(Buffer, #request_state{body_state = {chunked, {reading_data, Size}}, ref = Ref} = ReqState) ->
    parse_chunk_data(Buffer, ReqState, Ref, Size);
parse_body(Buffer, #request_state{body_state = until_close, ref = Ref} = ReqState) ->
    case Buffer of
        <<>> -> {continue, [], ReqState, <<>>};
        _ -> {continue, [{data, Ref, Buffer}], ReqState, <<>>}
    end.

-spec parse_content_length_body(binary(), request_state(), non_neg_integer()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}.
parse_content_length_body(Buffer, ReqState, Total) ->
    #request_state{ref = Ref, bytes_received = BytesReceived} = ReqState,
    Remaining = Total - BytesReceived,

    case byte_size(Buffer) >= Remaining of
        true ->
            <<Body:Remaining/binary, Rest/binary>> = Buffer,
            NewReqState = ReqState#request_state{body_state = done},
            Responses =
                case Body of
                    <<>> -> [{done, Ref}];
                    _ -> [{data, Ref, Body}, {done, Ref}]
                end,
            {done, Responses, NewReqState, Rest};
        false ->
            NewReqState = ReqState#request_state{
                bytes_received = BytesReceived + byte_size(Buffer)
            },
            {continue, [{data, Ref, Buffer}], NewReqState, <<>>}
    end.

-spec parse_chunk_size(binary(), request_state(), request_ref()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}
    | {error, term()}.
parse_chunk_size(Buffer, ReqState, Ref) ->
    case binary:split(Buffer, <<"\r\n">>) of
        [SizeHex, Rest] ->
            %% Strip any chunk extensions (after ";")
            SizeHexClean =
                case binary:split(SizeHex, <<";">>) of
                    [S, _] -> S;
                    [S] -> S
                end,
            case byte_size(SizeHexClean) > ?MAX_CHUNK_HEX_LEN of
                true ->
                    {error, protocol_error(chunk_size_overflow)};
                false ->
                    try binary_to_integer(SizeHexClean, 16) of
                        0 ->
                            %% Zero-length chunk. Parse optional trailers.
                            parse_trailers(Rest, ReqState, Ref, []);
                        Size when Size > ?MAX_CHUNK_SIZE ->
                            {error, protocol_error(chunk_size_overflow)};
                        Size ->
                            %% Non-zero chunk, read data
                            NewReqState = ReqState#request_state{body_state = {chunked, {reading_data, Size}}},
                            parse_chunk_data(Rest, NewReqState, Ref, Size)
                    catch
                        error:badarg ->
                            {error, protocol_error(invalid_chunk_size)}
                    end
            end;
        [_] ->
            %% No CRLF found yet, need more data
            {continue, [], ReqState, Buffer}
    end.

-spec parse_chunk_data(binary(), request_state(), request_ref(), non_neg_integer()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}.
parse_chunk_data(Buffer, ReqState, Ref, Size) ->
    %% +2 for trailing CRLF
    case byte_size(Buffer) >= Size + 2 of
        true ->
            <<ChunkData:Size/binary, "\r\n", Rest/binary>> = Buffer,
            NewReqState = ReqState#request_state{body_state = {chunked, reading_size}},
            case ChunkData of
                <<>> ->
                    parse_chunk_size(Rest, NewReqState, Ref);
                _ ->
                    DataResp = {data, Ref, ChunkData},
                    case parse_chunk_size(Rest, NewReqState, Ref) of
                        {done, More, FinalReqState, FinalRest} ->
                            {done, [DataResp | More], FinalReqState, FinalRest};
                        {continue, More, FinalReqState, FinalRest} ->
                            {continue, [DataResp | More], FinalReqState, FinalRest};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end;
        false ->
            %% Need more data
            {continue, [], ReqState, Buffer}
    end.

%% @doc Parse optional trailer headers after the zero-length final chunk.
%% RFC 9112 Section 7.1.2: trailers may appear between the last chunk and
%% the final CRLF. When no trailers are present, decode_response_header
%% returns `{ok, eof, Rest}` on seeing `\r\n` immediately.
-spec parse_trailers(binary(), request_state(), request_ref(), headers()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}
    | {error, term()}.
parse_trailers(Buffer, ReqState, Ref, TrailerAcc) ->
    case gen_http_parser_h1:decode_response_header(Buffer) of
        {ok, {Name, Value}, Rest} ->
            parse_trailers(Rest, ReqState, Ref, [{Name, Value} | TrailerAcc]);
        {ok, eof, Rest} ->
            NewReqState = ReqState#request_state{body_state = done},
            Responses =
                case TrailerAcc of
                    [] -> [{done, Ref}];
                    _ -> [{trailers, Ref, lists:reverse(TrailerAcc)}, {done, Ref}]
                end,
            {done, Responses, NewReqState, Rest};
        more ->
            {continue, [], ReqState, Buffer};
        error ->
            {error, protocol_error(invalid_trailer)}
    end.

-spec determine_body_state(status(), headers()) ->
    done | {content_length, non_neg_integer()} | {chunked, reading_size} | until_close | {error, term()}.
determine_body_state(Status, _Headers) when Status =:= 204; Status =:= 304 ->
    done;
determine_body_state(Status, _Headers) when Status >= 100, Status =< 199 ->
    done;
determine_body_state(_Status, Headers) ->
    %% Extract transfer-encoding and content-length in a single pass.
    %% Uses byte_size dispatch to skip irrelevant headers efficiently.
    extract_body_params(Headers, undefined, undefined).

-spec extract_body_params(headers(), binary() | undefined, binary() | undefined) ->
    done | {content_length, non_neg_integer()} | {chunked, reading_size} | until_close | {error, term()}.
extract_body_params([], TransferEncoding, ContentLength) ->
    case TransferEncoding of
        <<"chunked">> ->
            {chunked, reading_size};
        _ ->
            case ContentLength of
                undefined ->
                    until_close;
                LengthBin ->
                    case binary_to_integer(LengthBin) of
                        0 -> done;
                        Length -> {content_length, Length}
                    end
            end
    end;
extract_body_params([{Name, Value} | Rest], TE, CL) ->
    case byte_size(Name) of
        17 ->
            case Name of
                <<"transfer-encoding">> -> extract_body_params(Rest, Value, CL);
                _ -> extract_body_params(Rest, TE, CL)
            end;
        14 ->
            case Name of
                <<"content-length">> ->
                    case CL of
                        undefined ->
                            extract_body_params(Rest, TE, Value);
                        Value ->
                            %% Same value repeated, RFC 9110 §8.6 allows it
                            extract_body_params(Rest, TE, CL);
                        _ ->
                            %% Different value, RFC 9110 §8.6 says reject
                            {error, protocol_error(conflicting_content_length)}
                    end;
                _ ->
                    extract_body_params(Rest, TE, CL)
            end;
        _ ->
            extract_body_params(Rest, TE, CL)
    end.

-spec should_close_connection(request_state()) -> boolean().
should_close_connection(#request_state{response_headers = Headers}) ->
    find_connection_close(Headers).

-spec find_connection_close(headers()) -> boolean().
find_connection_close([]) ->
    false;
find_connection_close([{Name, Value} | Rest]) ->
    case byte_size(Name) of
        10 ->
            case Name of
                <<"connection">> -> Value =:= <<"close">>;
                _ -> find_connection_close(Rest)
            end;
        _ ->
            find_connection_close(Rest)
    end.

%%====================================================================
%% Internal Functions - Connection Lifecycle
%%====================================================================

-spec handle_closed(conn()) ->
    {error, conn(), gen_http:error_reason(), [response()]}.
handle_closed(Conn) ->
    AllRequests =
        case Conn#gen_http_h1_conn.current_request of
            undefined -> Conn#gen_http_h1_conn.requests;
            CurrentReq -> queue:in_r(CurrentReq, Conn#gen_http_h1_conn.requests)
        end,
    Responses = generate_close_responses(AllRequests),
    NewConn = Conn#gen_http_h1_conn{
        state = closed, current_request = undefined, requests = queue:new()
    },
    {error, NewConn, application_error(connection_closed), Responses}.

-spec generate_close_responses(queue:queue(request_state())) -> [response()].
generate_close_responses(Requests) ->
    Folded = queue:fold(fun generate_close_response/2, [], Requests),
    lists:reverse(Folded).

-spec generate_close_response(request_state(), [response()]) -> [response()].
generate_close_response(#request_state{ref = Ref, body_state = until_close}, Acc) ->
    [{done, Ref} | Acc];
generate_close_response(#request_state{body_state = done}, Acc) ->
    Acc;
generate_close_response(
    #request_state{ref = Ref, body_state = {content_length, Total}, bytes_received = Received},
    Acc
) when Received > 0 ->
    [{error, Ref, application_error({incomplete_body, Received, Total})} | Acc];
generate_close_response(#request_state{ref = Ref, body_state = {chunked, _}}, Acc) ->
    [{error, Ref, application_error(incomplete_chunked_body)} | Acc];
generate_close_response(#request_state{ref = Ref}, Acc) ->
    [{error, Ref, application_error(unexpected_close)} | Acc].

-spec handle_error(conn(), term()) ->
    {error, conn(), gen_http:error_reason(), [response()]}.
handle_error(Conn, Reason) ->
    AllRequests =
        case Conn#gen_http_h1_conn.current_request of
            undefined -> Conn#gen_http_h1_conn.requests;
            CurrentReq -> queue:in_r(CurrentReq, Conn#gen_http_h1_conn.requests)
        end,
    Responses = generate_error_responses(AllRequests, Reason),
    NewConn = Conn#gen_http_h1_conn{
        state = closed, current_request = undefined, requests = queue:new()
    },
    {error, NewConn, transport_error(Reason), Responses}.

-spec generate_error_responses(queue:queue(request_state()), term()) -> [response()].
generate_error_responses(Requests, Reason) ->
    Folded = queue:fold(
        fun(#request_state{ref = Ref}, Acc) ->
            [{error, Ref, transport_error(Reason)} | Acc]
        end,
        [],
        Requests
    ),
    lists:reverse(Folded).

%%====================================================================
%% Internal Functions - Error Wrapping
%%====================================================================

%% @doc Wrap transport errors in structured format.
-spec transport_error(term()) -> gen_http:error_reason().
transport_error(closed) -> {transport_error, closed};
transport_error(timeout) -> {transport_error, timeout};
transport_error(econnrefused) -> {transport_error, econnrefused};
transport_error(econnreset) -> {transport_error, econnreset};
transport_error(ehostunreach) -> {transport_error, ehostunreach};
transport_error(enetunreach) -> {transport_error, enetunreach};
transport_error(nxdomain) -> {transport_error, nxdomain};
transport_error({ssl_error, _} = E) -> {transport_error, E};
transport_error({send_failed, _} = E) -> {transport_error, E};
transport_error({setopts_failed, _} = E) -> {transport_error, E};
transport_error({connect_failed, _} = E) -> {transport_error, E};
transport_error({controlling_process_failed, _} = E) -> {transport_error, E};
transport_error(Other) -> {transport_error, Other}.

%% @doc Wrap protocol errors in structured format.
-spec protocol_error(
    {encode_failed, term()}
    | invalid_status_line
    | invalid_header
    | invalid_chunk_size
    | chunk_size_overflow
    | too_many_headers
    | conflicting_content_length
    | invalid_trailer
) -> gen_http:error_reason().
protocol_error({encode_failed, _} = E) -> {protocol_error, E};
protocol_error(invalid_status_line) -> {protocol_error, invalid_status_line};
protocol_error(invalid_header) -> {protocol_error, invalid_header};
protocol_error(invalid_chunk_size) -> {protocol_error, invalid_chunk_size};
protocol_error(chunk_size_overflow) -> {protocol_error, chunk_size_overflow};
protocol_error(too_many_headers) -> {protocol_error, too_many_headers};
protocol_error(conflicting_content_length) -> {protocol_error, conflicting_content_length};
protocol_error(invalid_trailer) -> {protocol_error, invalid_trailer}.

%% @doc Wrap application errors in structured format.
-spec application_error(
    connection_closed
    | pipeline_full
    | {invalid_request_ref, reference()}
    | unexpected_close
    | {incomplete_body, non_neg_integer(), non_neg_integer()}
    | incomplete_chunked_body
) -> gen_http:error_reason().
application_error(connection_closed) -> {application_error, connection_closed};
application_error(pipeline_full) -> {application_error, pipeline_full};
application_error({invalid_request_ref, _} = E) -> {application_error, E};
application_error(unexpected_close) -> {application_error, unexpected_close};
application_error({incomplete_body, _, _} = E) -> {application_error, E};
application_error(incomplete_chunked_body) -> {application_error, incomplete_chunked_body}.

%%====================================================================
%% Internal Functions - Utilities
%%====================================================================

%% @doc Efficiently append data to buffer.
%%
%% Avoids unnecessary allocation when buffer is empty by reusing incoming data directly.
%% This optimization is critical in the hot path of response parsing.
-spec maybe_concat(binary(), binary()) -> binary().
maybe_concat(<<>>, Data) ->
    Data;
maybe_concat(Buffer, Data) ->
    <<Buffer/binary, Data/binary>>.

%%====================================================================
%% Unit Tests
%%====================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Header Count Limit Tests
%%--------------------------------------------------------------------

too_many_headers_test() ->
    %% Simulate a response with headers exceeding the limit.
    %% Build a buffer with status line + 5 headers + empty line, limit to 3.
    StatusLine = <<"HTTP/1.1 200 OK\r\n">>,
    Headers = iolist_to_binary([
        <<"h1: v1\r\n">>,
        <<"h2: v2\r\n">>,
        <<"h3: v3\r\n">>,
        <<"h4: v4\r\n">>,
        <<"h5: v5\r\n">>,
        <<"\r\n">>
    ]),
    Buffer = <<StatusLine/binary, Headers/binary>>,

    %% Create a minimal conn record with low max_header_count
    Ref = make_ref(),
    ReqState = #request_state{ref = Ref, method = <<"GET">>},
    Conn = #gen_http_h1_conn{
        transport = gen_http_tcp,
        socket = undefined,
        host = <<"localhost">>,
        port = 80,
        scheme = http,
        buffer = Buffer,
        current_request = ReqState,
        max_header_count = 3
    },

    %% Parsing should fail with too_many_headers
    case parse_responses(Conn, []) of
        {error, _, {protocol_error, too_many_headers}, _} -> ok;
        Other -> ?assertEqual({error, too_many_headers}, Other)
    end.

headers_under_limit_test() ->
    %% 3 headers with limit of 100 should work fine
    StatusLine = <<"HTTP/1.1 200 OK\r\n">>,
    Headers = iolist_to_binary([
        <<"content-length: 0\r\n">>,
        <<"x-foo: bar\r\n">>,
        <<"x-baz: qux\r\n">>,
        <<"\r\n">>
    ]),
    Buffer = <<StatusLine/binary, Headers/binary>>,
    Ref = make_ref(),
    ReqState = #request_state{ref = Ref, method = <<"GET">>},
    Conn = #gen_http_h1_conn{
        transport = gen_http_tcp,
        socket = undefined,
        host = <<"localhost">>,
        port = 80,
        scheme = http,
        buffer = Buffer,
        current_request = ReqState,
        max_header_count = 100
    },
    case parse_responses(Conn, []) of
        {ok, _, Responses} ->
            ?assert(
                lists:any(
                    fun
                        ({status, _, 200}) -> true;
                        (_) -> false
                    end,
                    Responses
                )
            );
        Other ->
            ?assertEqual({ok, parsed}, Other)
    end.

%%--------------------------------------------------------------------
%% Chunk Size Overflow Tests
%%--------------------------------------------------------------------

chunk_size_overflow_hex_too_long_test() ->
    %% Hex string longer than 16 chars should be rejected
    Ref = make_ref(),
    ReqState = #request_state{
        ref = Ref,
        method = <<"GET">>,
        body_state = {chunked, reading_size}
    },
    %% 17 hex chars
    Buffer = <<"FFFFFFFFFFFFFFFFF\r\ndata\r\n">>,
    Result = parse_chunk_size(Buffer, ReqState, Ref),
    ?assertMatch({error, {protocol_error, chunk_size_overflow}}, Result).

chunk_size_overflow_value_too_large_test() ->
    %% Chunk size larger than MAX_CHUNK_SIZE (~2GB) should be rejected
    Ref = make_ref(),
    ReqState = #request_state{
        ref = Ref,
        method = <<"GET">>,
        body_state = {chunked, reading_size}
    },
    %% 0x80000000 = 2147483648 > MAX_CHUNK_SIZE (2147483647)
    Buffer = <<"80000000\r\ndata\r\n">>,
    Result = parse_chunk_size(Buffer, ReqState, Ref),
    ?assertMatch({error, {protocol_error, chunk_size_overflow}}, Result).

chunk_size_normal_test() ->
    %% A normal chunk size should parse fine
    Ref = make_ref(),
    ReqState = #request_state{
        ref = Ref,
        method = <<"GET">>,
        body_state = {chunked, reading_size}
    },
    Buffer = <<"a\r\n0123456789\r\n0\r\n\r\n">>,
    Result = parse_chunk_size(Buffer, ReqState, Ref),
    ?assertMatch({done, _, _, _}, Result).

%%--------------------------------------------------------------------
%% Conflicting Content-Length Tests
%%--------------------------------------------------------------------

conflicting_content_length_test() ->
    %% Two Content-Length headers with different values should be rejected
    Headers = [
        {<<"content-length">>, <<"100">>},
        {<<"content-length">>, <<"200">>}
    ],
    Result = extract_body_params(Headers, undefined, undefined),
    ?assertMatch({error, {protocol_error, conflicting_content_length}}, Result).

duplicate_content_length_same_value_test() ->
    %% Two Content-Length headers with the same value should be accepted (RFC 9110 §8.6)
    Headers = [
        {<<"content-length">>, <<"100">>},
        {<<"content-length">>, <<"100">>}
    ],
    Result = extract_body_params(Headers, undefined, undefined),
    ?assertEqual({content_length, 100}, Result).

%%--------------------------------------------------------------------
%% Trailer Parsing Tests
%%--------------------------------------------------------------------

trailers_parsed_correctly_test() ->
    %% After zero-length chunk, trailer headers should be parsed
    Ref = make_ref(),
    ReqState = #request_state{
        ref = Ref,
        method = <<"GET">>,
        body_state = {chunked, reading_size}
    },
    Buffer = <<"0\r\ntrailer-key: trailer-val\r\n\r\n">>,
    Result = parse_chunk_size(Buffer, ReqState, Ref),
    ?assertMatch({done, [{trailers, Ref, [{<<"trailer-key">>, <<"trailer-val">>}]}, {done, Ref}], _, _}, Result).

no_trailers_test() ->
    %% Zero-length chunk followed directly by CRLF (no trailers)
    Ref = make_ref(),
    ReqState = #request_state{
        ref = Ref,
        method = <<"GET">>,
        body_state = {chunked, reading_size}
    },
    Buffer = <<"0\r\n\r\n">>,
    Result = parse_chunk_size(Buffer, ReqState, Ref),
    ?assertMatch({done, [{done, Ref}], _, _}, Result).

%%--------------------------------------------------------------------
%% Close Response Tests
%%--------------------------------------------------------------------

until_close_generates_done_test() ->
    Ref = make_ref(),
    ReqState = #request_state{ref = Ref, method = <<"GET">>, body_state = until_close},
    Result = generate_close_response(ReqState, []),
    ?assertEqual([{done, Ref}], Result).

partial_content_length_generates_incomplete_body_test() ->
    Ref = make_ref(),
    ReqState = #request_state{
        ref = Ref,
        method = <<"GET">>,
        body_state = {content_length, 1000},
        bytes_received = 500
    },
    Result = generate_close_response(ReqState, []),
    ?assertMatch([{error, Ref, {application_error, {incomplete_body, 500, 1000}}}], Result).

chunked_close_generates_incomplete_chunked_test() ->
    Ref = make_ref(),
    ReqState = #request_state{
        ref = Ref,
        method = <<"GET">>,
        body_state = {chunked, reading_size}
    },
    Result = generate_close_response(ReqState, []),
    ?assertMatch([{error, Ref, {application_error, incomplete_chunked_body}}], Result).

done_state_generates_nothing_test() ->
    ReqState = #request_state{
        ref = make_ref(),
        method = <<"GET">>,
        body_state = done
    },
    Result = generate_close_response(ReqState, []),
    ?assertEqual([], Result).

%%--------------------------------------------------------------------
%% is_alive Tests
%%--------------------------------------------------------------------

is_alive_closed_state_test() ->
    Conn = #gen_http_h1_conn{
        transport = gen_http_tcp,
        socket = undefined,
        host = <<"localhost">>,
        port = 80,
        scheme = http,
        state = closed
    },
    ?assertNot(is_alive(Conn)).

-endif.
