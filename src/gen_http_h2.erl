-module(gen_http_h2).
-feature(maybe_expr, enable).

%% @doc HTTP/2 connection state machine.
%%
%% Process-less HTTP/2 client. Supports:
%% - Stream multiplexing (multiple concurrent requests)
%% - Flow control (connection and stream level)
%% - Settings negotiation
%% - HPACK header compression
%% - Server push
%% - GOAWAY handling
%%
%% Connection state is a pure data structure passed between function calls.

%% Targeted inlining for small hot-path helpers
-compile(
    {inline, [
        is_open/1,
        get_socket/1,
        ensure_binary/1,
        has_alpn_option/1,
        server_max_frame_size/1,
        max_header_block_size/1,
        update_stream/3,
        remove_stream/2,
        transport_error/1,
        protocol_error/1,
        application_error/1
    ]}
).

-include("include/gen_http.hrl").
-include("gen_http_h2_frames.hrl").

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
    get_socket/1,
    get_window_size/2,
    put_private/3,
    get_private/2,
    get_private/3,
    delete_private/2
]).

-export_type([
    conn/0,
    stream_id/0,
    h2_response/0,
    address/0,
    headers/0,
    request_ref/0,
    response/0,
    scheme/0,
    socket/0
]).

%% eqWalizer has limited support for maybe expressions
-eqwalizer({nowarn_function, connect/4}).
-eqwalizer({nowarn_function, send_request/5}).
-eqwalizer({nowarn_function, send_data_frame/4}).

-type stream_id() :: pos_integer().
-type stream_state_name() :: idle | open | half_closed_local | half_closed_remote | closed.
-type h2_response() ::
    {headers, reference(), stream_id(), headers()}
    | {data, reference(), stream_id(), binary()}
    | {done, reference(), stream_id()}
    | {push_promise, reference(), stream_id(), stream_id(), headers()}
    | {error, reference(), stream_id(), term()}.

%%====================================================================
%% HTTP/2 Constants
%%====================================================================

-define(CONNECTION_PREFACE, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>).
%% Use 8MB window size (125x the RFC default of 65535).
%% Larger windows reduce WINDOW_UPDATE frame overhead for real payloads.
-define(DEFAULT_WINDOW_SIZE, 8000000).
-define(MAX_FRAME_SIZE, 16384).
%% Cap accumulated header block size to prevent CONTINUATION flood (CVE-2024-27316)
-define(MAX_HEADER_BLOCK_SIZE, 65536).
%% RFC 7540 Section 6.9.1: flow control window must not exceed 2^31-1
-define(MAX_WINDOW_SIZE, 2147483647).

%% Default settings
-define(DEFAULT_SETTINGS, #{
    header_table_size => 4096,
    enable_push => false,
    max_concurrent_streams => 100,
    initial_window_size => ?DEFAULT_WINDOW_SIZE,
    max_frame_size => ?MAX_FRAME_SIZE,
    max_header_list_size => undefined
}).

-record(gen_http_h2_conn, {
    %% Transport
    transport :: module(),
    socket :: socket(),
    host :: binary(),
    port :: inet:port_number(),
    scheme :: http | https,

    %% Connection state
    state = open :: open | closing | closed,
    mode = active :: active | passive,

    %% HTTP/2 State
    buffer = <<>> :: binary(),
    hpack_encode :: gen_http_parser_hpack:context(),
    hpack_decode :: gen_http_parser_hpack:context(),

    %% Streams
    streams = #{} :: #{stream_id() => stream_state()},
    next_stream_id = 1 :: pos_integer(),
    max_concurrent = 100 :: pos_integer(),

    %% Flow Control
    send_window = ?DEFAULT_WINDOW_SIZE :: non_neg_integer(),
    recv_window = ?DEFAULT_WINDOW_SIZE :: non_neg_integer(),
    initial_window_size = ?DEFAULT_WINDOW_SIZE :: pos_integer(),

    %% Settings
    local_settings = #{} :: map(),
    remote_settings = #{} :: map(),
    settings_acked = false :: boolean(),

    %% Connection preface sent
    preface_sent = false :: boolean(),

    %% Buffer limit (default 1MB)
    max_buffer_size = 1048576 :: pos_integer(),

    %% Logging
    log = false :: boolean(),

    %% User metadata storage
    private = #{} :: #{term() => term()}
}).

-record(stream_state, {
    id :: stream_id(),
    state = idle :: stream_state_name(),
    ref :: reference(),
    method :: binary(),

    %% Response
    status :: status() | undefined,
    response_headers = [] :: headers(),

    %% Flow Control
    send_window :: non_neg_integer(),
    recv_window :: non_neg_integer(),

    %% Data
    %% For CONTINUATION frames
    headers_buffer = <<>> :: binary(),
    %% Outbound data waiting for flow control window
    send_buffer = <<>> :: binary(),
    %% Whether END_STREAM should be sent after send_buffer drains
    send_end_stream = false :: boolean()
}).

-type conn() :: #gen_http_h2_conn{}.
-type stream_state() :: #stream_state{}.

%%====================================================================
%% API Functions
%%====================================================================

%% @doc Establish an HTTP/2 connection.
-spec connect(scheme(), address(), inet:port_number()) ->
    {ok, conn()} | {error, term()}.
connect(Scheme, Address, Port) ->
    connect(Scheme, Address, Port, #{}).

%% @doc Establish an HTTP/2 connection with options.
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
    MaxConcurrent = maps:get(max_concurrent, Opts, 100),
    MaxBufferSize = maps:get(max_buffer_size, Opts, 1048576),

    TransportOpts = maps:get(transport_opts, Opts, []),

    %% For HTTPS, ensure we advertise h2 protocol
    ConnectOpts =
        case Scheme of
            https ->
                AlpnOpts =
                    case has_alpn_option(TransportOpts) of
                        true -> [];
                        false -> [{alpn_advertise, [<<"h2">>, <<"http/1.1">>]}]
                    end,
                [{timeout, Timeout} | AlpnOpts ++ TransportOpts];
            http ->
                %% HTTP/2 over cleartext requires h2c upgrade (not implemented yet)
                [{timeout, Timeout} | TransportOpts]
        end,

    maybe
        {ok, Socket} ?= Transport:connect(Address, Port, ConnectOpts),
        ok ?= setup_socket_mode(Transport, Socket, Mode),
        %% Create connection with HPACK contexts
        HpackEncode = gen_http_parser_hpack:new(),
        HpackDecode = gen_http_parser_hpack:new(),
        Conn = #gen_http_h2_conn{
            transport = Transport,
            socket = Socket,
            host = ensure_binary(Address),
            port = Port,
            scheme = Scheme,
            mode = Mode,
            max_concurrent = MaxConcurrent,
            max_buffer_size = MaxBufferSize,
            hpack_encode = HpackEncode,
            hpack_decode = HpackDecode,
            initial_window_size = ?DEFAULT_WINDOW_SIZE,
            local_settings = ?DEFAULT_SETTINGS
        },
        %% Send connection preface and initial SETTINGS
        Conn2 = send_preface(Conn),
        {ok, Conn2}
    else
        {error, Reason} -> {error, transport_error({connect_failed, Reason})}
    end.

%% @doc Send an HTTP/2 request.
-spec request(conn(), binary(), binary(), headers(), iodata() | stream) ->
    {ok, conn(), reference(), stream_id()} | {error, conn(), term()}.
request(Conn, Method, Path, Headers, Body) ->
    send_request(Conn, Method, Path, Headers, Body).

%% @doc Process socket messages (active mode).
-spec stream(conn(), term()) ->
    {ok, conn(), [h2_response()]}
    | {error, conn(), term(), [h2_response()]}
    | unknown.
stream(Conn, Message) ->
    Socket = Conn#gen_http_h2_conn.socket,
    case Message of
        {tcp, Socket, Data} -> handle_data(Conn, Data);
        {ssl, Socket, Data} -> handle_data(Conn, Data);
        {tcp_closed, Socket} -> handle_closed(Conn);
        {ssl_closed, Socket} -> handle_closed(Conn);
        {tcp_error, Socket, Reason} -> handle_error(Conn, Reason);
        {ssl_error, Socket, Reason} -> handle_error(Conn, Reason);
        _ -> unknown
    end.

%% @doc Stream request body (chunked upload).
-spec stream_request_body(conn(), stream_id(), iodata() | eof) ->
    {ok, conn()} | {error, conn(), term()}.
stream_request_body(Conn, StreamId, Chunk) ->
    send_data_frame(Conn, StreamId, Chunk, false).

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
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
recv(#gen_http_h2_conn{mode = passive} = Conn, ByteCount, Timeout) ->
    #gen_http_h2_conn{transport = Transport, socket = Socket} = Conn,
    case Transport:recv(Socket, ByteCount, Timeout) of
        {ok, Data} ->
            handle_data(Conn, Data);
        {error, closed} ->
            handle_closed(Conn);
        {error, timeout} ->
            {error, Conn, transport_error(timeout)};
        {error, Reason} ->
            NewConn = Conn#gen_http_h2_conn{state = closed},
            {error, NewConn, transport_error(Reason)}
    end;
recv(#gen_http_h2_conn{mode = active}, _, _) ->
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
    #gen_http_h2_conn{transport = Transport, socket = Socket, mode = CurrentMode} = Conn,
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
                ok -> {ok, Conn#gen_http_h2_conn{mode = Mode}};
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
    #gen_http_h2_conn{transport = Transport, socket = Socket} = Conn,
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
    {ok, Conn#gen_http_h2_conn{log = Log}}.

%% @doc Close the connection.
-spec close(conn()) -> {ok, conn()}.
close(Conn) ->
    case Conn#gen_http_h2_conn.state of
        open ->
            %% Send GOAWAY frame
            GoAway = #goaway{
                stream_id = 0,
                last_stream_id = 0,
                error_code = no_error,
                debug_data = <<>>
            },
            Conn2 = send_frame(Conn, GoAway),

            %% Close socket
            Transport = Conn2#gen_http_h2_conn.transport,
            Socket = Conn2#gen_http_h2_conn.socket,
            Transport:close(Socket),

            {ok, Conn2#gen_http_h2_conn{state = closed}};
        _ ->
            {ok, Conn}
    end.

%% @doc Check if connection is open.
-spec is_open(conn()) -> boolean().
is_open(#gen_http_h2_conn{state = State}) ->
    State =:= open.

%% @doc Get the underlying socket.
-spec get_socket(conn()) -> socket().
get_socket(#gen_http_h2_conn{socket = Socket}) ->
    Socket.

%% @doc Get available send window size.
%%
%% Pass `StreamId = 0` for the connection-level window, or a stream ID
%% for the effective window (min of connection and stream windows).
%% Callers using `stream_request_body/3` should check this before
%% sending to avoid exceeding the flow control window.
-spec get_window_size(conn(), stream_id() | 0) -> {ok, non_neg_integer()} | {error, term()}.
get_window_size(Conn, 0) ->
    {ok, Conn#gen_http_h2_conn.send_window};
get_window_size(Conn, StreamId) ->
    case maps:find(StreamId, Conn#gen_http_h2_conn.streams) of
        {ok, Stream} ->
            ConnWindow = Conn#gen_http_h2_conn.send_window,
            StreamWindow = Stream#stream_state.send_window,
            {ok, min(ConnWindow, StreamWindow)};
        error ->
            {error, {invalid_stream_id, StreamId}}
    end.

%% @doc Store a private key-value pair in the connection.
%%
%% Attach metadata to connections (e.g., pool ID, metrics, tags).
-spec put_private(conn(), Key :: term(), Value :: term()) -> conn().
put_private(#gen_http_h2_conn{private = Private} = Conn, Key, Value) ->
    Conn#gen_http_h2_conn{private = Private#{Key => Value}}.

%% @doc Get a private value from the connection.
%%
%% Returns `undefined` if the key doesn't exist.
-spec get_private(conn(), Key :: term()) -> term() | undefined.
get_private(Conn, Key) ->
    get_private(Conn, Key, undefined).

%% @doc Get a private value from the connection with a default.
-spec get_private(conn(), Key :: term(), Default :: term()) -> term().
get_private(#gen_http_h2_conn{private = Private}, Key, Default) ->
    maps:get(Key, Private, Default).

%% @doc Delete a private key from the connection.
-spec delete_private(conn(), Key :: term()) -> conn().
delete_private(#gen_http_h2_conn{private = Private} = Conn, Key) ->
    Conn#gen_http_h2_conn{private = maps:remove(Key, Private)}.

%%====================================================================
%% Internal Functions - Connection Setup
%%====================================================================

-define(VALID_OPTS, [timeout, mode, max_concurrent, max_buffer_size, transport_opts, protocols]).

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

-spec ensure_binary(address()) -> binary().
ensure_binary(Addr) when is_binary(Addr) -> Addr;
ensure_binary(Addr) when is_list(Addr) -> list_to_binary(Addr);
ensure_binary(Addr) when is_atom(Addr) -> atom_to_binary(Addr, utf8).

%% @doc Send connection preface, initial SETTINGS, and connection-level WINDOW_UPDATE.
%%
%% The SETTINGS frame advertises our stream-level initial_window_size.
%% RFC 7540 Section 6.9.2: the connection-level window starts at 65535
%% and can only be increased via WINDOW_UPDATE, so we send one to raise
%% it to DEFAULT_WINDOW_SIZE.
-spec send_preface(conn()) -> conn().
send_preface(Conn) ->
    #gen_http_h2_conn{transport = Transport, socket = Socket} = Conn,

    %% Send magic string
    Preface = ?CONNECTION_PREFACE,

    %% Send initial SETTINGS frame (filter out undefined values)
    AllParams = maps:to_list(Conn#gen_http_h2_conn.local_settings),
    FilteredParams = lists:filter(fun({_Key, Value}) -> Value =/= undefined end, AllParams),
    Settings = #settings{
        stream_id = 0,
        params = FilteredParams
    },
    EncodedSettings = gen_http_parser_h2:encode(Settings),

    %% Send connection-level WINDOW_UPDATE to raise from RFC default (65535)
    %% to our desired window size. Batched into a single send with the preface.
    ConnWindowIncrement = ?DEFAULT_WINDOW_SIZE - 65535,
    WindowUpdate = #window_update{
        stream_id = 0,
        window_size_increment = ConnWindowIncrement
    },
    WindowUpdateData = gen_http_parser_h2:encode(WindowUpdate),

    %% Single batched send: preface + SETTINGS + WINDOW_UPDATE
    ok = Transport:send(Socket, [Preface, EncodedSettings, WindowUpdateData]),

    Conn#gen_http_h2_conn{preface_sent = true}.

%%====================================================================
%% Internal Functions - Request Sending
%%====================================================================

-spec send_request(conn(), binary(), binary(), headers(), iodata() | stream) ->
    {ok, conn(), reference(), stream_id()} | {error, conn(), term()}.
send_request(Conn, Method, Path, Headers, Body) ->
    %% Check if we can create a new stream
    case can_create_stream(Conn) of
        false ->
            {error, Conn, protocol_error(max_concurrent_streams_exceeded)};
        true ->
            %% Allocate stream ID
            StreamId = Conn#gen_http_h2_conn.next_stream_id,
            Ref = make_ref(),

            %% Create stream state
            Stream = #stream_state{
                id = StreamId,
                state = idle,
                ref = Ref,
                method = Method,
                send_window = Conn#gen_http_h2_conn.initial_window_size,
                recv_window = Conn#gen_http_h2_conn.initial_window_size
            },

            %% Add pseudo-headers
            Scheme = atom_to_binary(Conn#gen_http_h2_conn.scheme, utf8),
            Authority = format_authority(
                Conn#gen_http_h2_conn.host,
                Conn#gen_http_h2_conn.port
            ),
            PseudoHeaders = [
                {<<":method">>, Method},
                {<<":path">>, Path},
                {<<":scheme">>, Scheme},
                {<<":authority">>, Authority}
            ],

            %% Add default user-agent if not provided
            HasUA = lists:keymember(<<"user-agent">>, 1, Headers),
            UserHeaders =
                case HasUA of
                    true -> Headers;
                    false -> [{<<"user-agent">>, <<"gen_http/0.1">>} | Headers]
                end,

            %% Combine with user headers
            AllHeaders = PseudoHeaders ++ UserHeaders,

            %% Encode headers with HPACK
            {ok, HeaderBlock, NewHpackEncode} = gen_http_parser_hpack:encode(
                AllHeaders,
                Conn#gen_http_h2_conn.hpack_encode
            ),

            %% Send HEADERS frame
            HeadersFrame = #h2_headers{
                stream_id = StreamId,
                flags =
                    case Body of
                        <<>> -> gen_http_parser_h2:set_flags(0, headers, [end_headers, end_stream]);
                        _ -> gen_http_parser_h2:set_flags(0, headers, [end_headers])
                    end,
                hbf = HeaderBlock
            },

            Conn2 = send_frame(Conn, HeadersFrame),

            %% Update stream state
            NewStream = Stream#stream_state{
                state =
                    case Body of
                        <<>> -> half_closed_local;
                        _ -> open
                    end
            },

            Conn3 = Conn2#gen_http_h2_conn{
                streams = maps:put(StreamId, NewStream, Conn2#gen_http_h2_conn.streams),
                %% Client uses odd numbers
                next_stream_id = StreamId + 2,
                hpack_encode = NewHpackEncode
            },

            %% Send body if present
            case Body of
                <<>> ->
                    {ok, Conn3, Ref, StreamId};
                stream ->
                    %% Streaming body, caller will send chunks
                    {ok, Conn3, Ref, StreamId};
                _ ->
                    %% Send body immediately
                    case send_all_data(Conn3, StreamId, Body) of
                        {ok, Conn4} -> {ok, Conn4, Ref, StreamId};
                        {error, Conn4, Reason} -> {error, Conn4, Reason}
                    end
            end
    end.

-spec can_create_stream(conn()) -> boolean().
can_create_stream(Conn) ->
    ActiveStreams = maps:size(Conn#gen_http_h2_conn.streams),
    ActiveStreams < Conn#gen_http_h2_conn.max_concurrent.

-spec format_authority(binary(), inet:port_number()) -> binary().
format_authority(Host, 80) -> Host;
format_authority(Host, 443) -> Host;
format_authority(Host, Port) -> <<Host/binary, ":", (integer_to_binary(Port))/binary>>.

%%====================================================================
%% Internal Functions - Frame Sending
%%====================================================================

-spec send_frame(conn(), tuple()) -> conn().
send_frame(Conn, Frame) ->
    #gen_http_h2_conn{transport = Transport, socket = Socket} = Conn,
    Encoded = gen_http_parser_h2:encode(Frame),
    case Transport:send(Socket, Encoded) of
        ok -> Conn;
        {error, closed} -> Conn#gen_http_h2_conn{state = closed};
        {error, Reason} -> error({send_error, Reason})
    end.

-spec send_data_frame(conn(), stream_id(), iodata() | eof, boolean()) ->
    {ok, conn()} | {error, conn(), term()}.
send_data_frame(Conn, StreamId, eof, _IsLast) ->
    %% Send empty DATA frame with END_STREAM flag
    case maps:find(StreamId, Conn#gen_http_h2_conn.streams) of
        {ok, Stream} ->
            case Stream#stream_state.send_buffer of
                <<>> ->
                    %% No buffered data, send END_STREAM now
                    DataFrame = #data{
                        stream_id = StreamId,
                        flags = gen_http_parser_h2:set_flags(0, data, [end_stream]),
                        data = <<>>
                    },
                    Conn2 = send_frame(Conn, DataFrame),
                    NewStream = Stream#stream_state{state = half_closed_local},
                    {ok, update_stream(Conn2, StreamId, NewStream)};
                _ ->
                    %% Data still buffered, mark END_STREAM pending
                    NewStream = Stream#stream_state{send_end_stream = true},
                    {ok, update_stream(Conn, StreamId, NewStream)}
            end;
        error ->
            {error, Conn, application_error({invalid_stream_id, StreamId})}
    end;
send_data_frame(Conn, StreamId, Data, IsLast) when is_binary(Data) orelse is_list(Data) ->
    BinData = iolist_to_binary(Data),
    case maps:find(StreamId, Conn#gen_http_h2_conn.streams) of
        {ok, Stream} ->
            %% Append new data to anything already buffered
            AllData = <<(Stream#stream_state.send_buffer)/binary, BinData/binary>>,
            EndStream = IsLast orelse Stream#stream_state.send_end_stream,
            send_buffered_data(Conn, StreamId, Stream, AllData, EndStream);
        error ->
            {error, Conn, application_error({invalid_stream_id, StreamId})}
    end.

%% @doc Send as much buffered data as flow control and max frame size allow.
%% Any remainder is stored in the stream's send_buffer for later flushing
%% when WINDOW_UPDATE frames arrive.
-spec send_buffered_data(conn(), stream_id(), stream_state(), binary(), boolean()) ->
    {ok, conn()}.
send_buffered_data(Conn, StreamId, Stream, <<>>, true) ->
    %% All data sent, send END_STREAM
    DataFrame = #data{
        stream_id = StreamId,
        flags = gen_http_parser_h2:set_flags(0, data, [end_stream]),
        data = <<>>
    },
    Conn2 = send_frame(Conn, DataFrame),
    NewStream = Stream#stream_state{
        send_buffer = <<>>,
        send_end_stream = false,
        state = half_closed_local
    },
    {ok, update_stream(Conn2, StreamId, NewStream)};
send_buffered_data(Conn, StreamId, Stream, <<>>, false) ->
    %% Nothing to send, nothing buffered
    NewStream = Stream#stream_state{send_buffer = <<>>, send_end_stream = false},
    {ok, update_stream(Conn, StreamId, NewStream)};
send_buffered_data(Conn, StreamId, Stream, Data, EndStream) ->
    ConnWindow = Conn#gen_http_h2_conn.send_window,
    StreamWindow = Stream#stream_state.send_window,
    MaxFrameSize = server_max_frame_size(Conn),
    Window = min(ConnWindow, StreamWindow),
    MaxSend = min(Window, byte_size(Data)),
    case MaxSend of
        0 ->
            %% Flow control blocked, buffer the rest
            NewStream = Stream#stream_state{
                send_buffer = Data,
                send_end_stream = EndStream
            },
            {ok, update_stream(Conn, StreamId, NewStream)};
        _ ->
            %% Send frames up to MaxSend bytes, each at most MaxFrameSize
            {Conn2, Stream2, Remaining} =
                send_data_chunks(Conn, StreamId, Stream, Data, MaxSend, MaxFrameSize, EndStream),
            case Remaining of
                <<>> when EndStream ->
                    %% Everything sent and this was the last chunk
                    NewStream = Stream2#stream_state{
                        send_buffer = <<>>,
                        send_end_stream = false,
                        state = half_closed_local
                    },
                    {ok, update_stream(Conn2, StreamId, NewStream)};
                _ ->
                    NewStream = Stream2#stream_state{
                        send_buffer = Remaining,
                        send_end_stream = EndStream
                    },
                    {ok, update_stream(Conn2, StreamId, NewStream)}
            end
    end.

%% @doc Send DATA frames in chunks, respecting max frame size and window.
%% Returns updated conn, stream, and any unsent remainder.
-spec send_data_chunks(
    conn(),
    stream_id(),
    stream_state(),
    binary(),
    non_neg_integer(),
    pos_integer(),
    boolean()
) ->
    {conn(), stream_state(), binary()}.
send_data_chunks(Conn, _StreamId, Stream, Data, 0, _MaxFrameSize, _EndStream) ->
    %% Window exhausted
    {Conn, Stream, Data};
send_data_chunks(Conn, _StreamId, Stream, <<>>, _Budget, _MaxFrameSize, _EndStream) ->
    %% All data sent
    {Conn, Stream, <<>>};
send_data_chunks(Conn, StreamId, Stream, Data, Budget, MaxFrameSize, EndStream) ->
    ChunkSize = min(Budget, min(MaxFrameSize, byte_size(Data))),
    <<Chunk:ChunkSize/binary, Rest/binary>> = Data,

    %% Set END_STREAM only if this is the last chunk and no data remains
    Flags =
        case EndStream andalso Rest =:= <<>> of
            true -> gen_http_parser_h2:set_flags(0, data, [end_stream]);
            false -> 0
        end,

    DataFrame = #data{
        stream_id = StreamId,
        flags = Flags,
        data = Chunk
    },
    Conn2 = send_frame(Conn, DataFrame),

    %% Update flow control windows
    NewStreamWindow = Stream#stream_state.send_window - ChunkSize,
    NewConnWindow = Conn2#gen_http_h2_conn.send_window - ChunkSize,
    Stream2 = Stream#stream_state{send_window = NewStreamWindow},
    Conn3 = Conn2#gen_http_h2_conn{send_window = NewConnWindow},

    NewBudget = Budget - ChunkSize,
    send_data_chunks(Conn3, StreamId, Stream2, Rest, NewBudget, MaxFrameSize, EndStream).

%% @doc Get the server's max frame size from negotiated settings.
-spec server_max_frame_size(conn()) -> pos_integer().
server_max_frame_size(Conn) ->
    maps:get(max_frame_size, Conn#gen_http_h2_conn.remote_settings, ?MAX_FRAME_SIZE).

%% @doc Get the max header block size we accept.
%% Uses our local SETTINGS_MAX_HEADER_LIST_SIZE if set, otherwise the default cap.
-spec max_header_block_size(conn()) -> pos_integer().
max_header_block_size(Conn) ->
    case maps:get(max_header_list_size, Conn#gen_http_h2_conn.local_settings, undefined) of
        undefined -> ?MAX_HEADER_BLOCK_SIZE;
        Size -> Size
    end.

-spec send_all_data(conn(), stream_id(), iodata()) ->
    {ok, conn()} | {error, conn(), term()}.
send_all_data(Conn, StreamId, Data) ->
    BinData = iolist_to_binary(Data),
    send_data_frame(Conn, StreamId, BinData, true).

%%====================================================================
%% Internal Functions - Frame Receiving
%%====================================================================

-spec handle_data(conn(), binary()) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term(), [h2_response()]}.
handle_data(Conn, Data) ->
    #gen_http_h2_conn{
        buffer = Buffer,
        mode = Mode,
        transport = Transport,
        socket = Socket,
        max_buffer_size = MaxBuf
    } = Conn,
    NewBuffer = <<Buffer/binary, Data/binary>>,
    case byte_size(NewBuffer) > MaxBuf of
        true ->
            {error, Conn, {application_error, buffer_overflow}, []};
        false ->
            case parse_frames(Conn#gen_http_h2_conn{buffer = NewBuffer}, []) of
                {ok, NewConn, Responses} ->
                    reactivate_socket_if_needed(Transport, Socket, Mode, NewConn),
                    {ok, NewConn, lists:reverse(Responses)};
                {error, NewConn, Reason, Responses} ->
                    {error, NewConn, Reason, lists:reverse(Responses)}
            end
    end.

-spec parse_frames(conn(), [h2_response()]) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term(), [h2_response()]}.
parse_frames(Conn, Acc) ->
    case gen_http_parser_h2:decode_next(Conn#gen_http_h2_conn.buffer) of
        {ok, Frame, Rest} ->
            case handle_frame(Conn#gen_http_h2_conn{buffer = Rest}, Frame) of
                {ok, NewConn, Responses} ->
                    parse_frames(NewConn, lists:reverse(Responses, Acc));
                {error, NewConn, Reason} ->
                    {error, NewConn, Reason, Acc}
            end;
        more ->
            {ok, Conn, Acc};
        {error, Reason} ->
            {error, Conn, protocol_error({frame_parse_error, Reason}), Acc}
    end.

-spec handle_frame(conn(), tuple()) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
handle_frame(Conn, Frame) ->
    handle_frame_dispatch(Conn, Frame).

handle_frame_dispatch(
    Conn,
    #settings{stream_id = 0, flags = Flags, params = Params}
) ->
    handle_settings_frame(Conn, Flags, Params);
handle_frame_dispatch(Conn, #h2_headers{stream_id = StreamId} = Frame) ->
    handle_headers_frame(Conn, StreamId, Frame);
handle_frame_dispatch(Conn, #data{stream_id = StreamId} = Frame) ->
    handle_data_frame(Conn, StreamId, Frame);
handle_frame_dispatch(
    Conn,
    #window_update{stream_id = StreamId, window_size_increment = Inc}
) ->
    handle_window_update_frame(Conn, StreamId, Inc);
handle_frame_dispatch(
    Conn,
    #goaway{last_stream_id = LastId, error_code = ErrorCode, debug_data = Debug}
) ->
    handle_goaway_frame(Conn, LastId, ErrorCode, Debug);
handle_frame_dispatch(Conn, #rst_stream{stream_id = StreamId, error_code = ErrorCode}) ->
    handle_rst_stream_frame(Conn, StreamId, ErrorCode);
handle_frame_dispatch(Conn, #ping{flags = Flags, opaque_data = Data}) ->
    handle_ping_frame(Conn, Flags, Data);
handle_frame_dispatch(Conn, #push_promise{stream_id = StreamId} = Frame) ->
    handle_push_promise_frame(Conn, StreamId, Frame);
handle_frame_dispatch(Conn, #priority{stream_id = StreamId} = Frame) ->
    handle_priority_frame(Conn, StreamId, Frame);
handle_frame_dispatch(Conn, #continuation{stream_id = StreamId} = Frame) ->
    handle_continuation_frame(Conn, StreamId, Frame);
handle_frame_dispatch(Conn, _UnknownFrame) ->
    %% Ignore unknown frames as per HTTP/2 spec
    {ok, Conn, []}.

%%====================================================================
%% Internal Functions - Frame Handlers
%%====================================================================

%% @doc Handle SETTINGS frame.
-spec handle_settings_frame(conn(), byte(), list()) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
handle_settings_frame(Conn, Flags, Params) ->
    AckFlag = gen_http_parser_h2:is_flag_set(Flags, settings, ack),
    case AckFlag of
        true ->
            %% ACK for our SETTINGS, just acknowledge
            {ok, Conn#gen_http_h2_conn{settings_acked = true}, []};
        false ->
            %% Server sent SETTINGS, update and send ACK
            NewRemoteSettings = lists:foldl(
                fun({Key, Value}, Acc) ->
                    Acc#{Key => Value}
                end,
                Conn#gen_http_h2_conn.remote_settings,
                Params
            ),

            %% If initial_window_size changed, update all streams
            Result =
                case lists:keyfind(initial_window_size, 1, Params) of
                    {initial_window_size, NewWindowSize} ->
                        OldWindowSize = Conn#gen_http_h2_conn.initial_window_size,
                        Delta = NewWindowSize - OldWindowSize,
                        update_all_stream_windows(Conn, Delta);
                    false ->
                        {ok, Conn}
                end,

            case Result of
                {error, _, _} = Err ->
                    Err;
                {ok, Conn2} ->
                    %% If header_table_size changed, update HPACK contexts
                    Conn3 =
                        case lists:keyfind(header_table_size, 1, Params) of
                            {header_table_size, NewTableSize} ->
                                HpackEncode = Conn2#gen_http_h2_conn.hpack_encode,
                                HpackDecode = Conn2#gen_http_h2_conn.hpack_decode,
                                HpackEncode2 = gen_http_parser_hpack:resize_table(HpackEncode, NewTableSize),
                                HpackDecode2 = gen_http_parser_hpack:resize_table(HpackDecode, NewTableSize),
                                Conn2#gen_http_h2_conn{
                                    hpack_encode = HpackEncode2,
                                    hpack_decode = HpackDecode2
                                };
                            false ->
                                Conn2
                        end,

                    Conn4 = Conn3#gen_http_h2_conn{remote_settings = NewRemoteSettings},

                    %% Send SETTINGS ACK
                    AckFrame = #settings{
                        stream_id = 0,
                        flags = gen_http_parser_h2:set_flags(0, settings, [ack]),
                        params = []
                    },
                    Conn5 = send_frame(Conn4, AckFrame),

                    {ok, Conn5, []}
            end
    end.

%% @doc Handle HEADERS frame (response headers).
-spec handle_headers_frame(conn(), stream_id(), #h2_headers{}) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
handle_headers_frame(Conn, StreamId, #h2_headers{flags = Flags, hbf = HeaderBlock}) ->
    case maps:find(StreamId, Conn#gen_http_h2_conn.streams) of
        {ok, Stream} ->
            EndHeaders = gen_http_parser_h2:is_flag_set(Flags, headers, end_headers),
            EndStream = gen_http_parser_h2:is_flag_set(Flags, headers, end_stream),
            FullHeaderBlock = <<(Stream#stream_state.headers_buffer)/binary, HeaderBlock/binary>>,

            case byte_size(FullHeaderBlock) > max_header_block_size(Conn) of
                true ->
                    {error, Conn, protocol_error({frame_parse_error, header_block_too_large})};
                false ->
                    case EndHeaders of
                        true ->
                            decode_and_emit_headers(Conn, StreamId, Stream, FullHeaderBlock, EndStream);
                        false ->
                            NewStream = Stream#stream_state{headers_buffer = FullHeaderBlock},
                            {ok, update_stream(Conn, StreamId, NewStream), []}
                    end
            end;
        error ->
            {ok, Conn, []}
    end.

%% @doc Decode complete header block and emit response events.
-spec decode_and_emit_headers(conn(), stream_id(), stream_state(), binary(), boolean()) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
decode_and_emit_headers(Conn, StreamId, Stream, HeaderBlock, EndStream) ->
    case gen_http_parser_hpack:decode(HeaderBlock, Conn#gen_http_h2_conn.hpack_decode) of
        {ok, Headers, NewHpackDecode} ->
            case extract_status(Headers) of
                {ok, Status} ->
                    emit_header_events(Conn, StreamId, Stream, Headers, Status, NewHpackDecode, EndStream);
                {error, missing_status} ->
                    {error, Conn, protocol_error({frame_parse_error, missing_status_pseudo_header})}
            end;
        {error, Reason} ->
            {error, Conn, protocol_error({hpack_decode_error, Reason})}
    end.

-spec emit_header_events(
    conn(),
    stream_id(),
    stream_state(),
    headers(),
    status(),
    gen_http_parser_hpack:context(),
    boolean()
) ->
    {ok, conn(), [h2_response()]}.
emit_header_events(Conn, StreamId, Stream, Headers, Status, NewHpackDecode, EndStream) ->
    %% Remove all pseudo-headers *except* :status from the event headers.
    %% The unified layer (gen_http) extracts :status to emit a separate
    %% {status, Ref, Code} event, and direct gen_http_h2 callers can also
    %% read it from the headers list.
    EventHeaders = remove_pseudo_headers_except_status(Headers),
    %% For internal storage, strip all pseudo-headers.
    StoredHeaders = remove_pseudo_headers(Headers),

    %% RFC 9113 Section 8.1: Informational responses (1xx) do not terminate the request.
    %% The HEADERS frame that carries an informational response does not have END_STREAM set.
    %% Client MUST be able to receive one or more 1xx responses before the final response.
    case is_informational_status(Status) of
        true ->
            %% 1xx informational response - emit headers but don't store in stream state.
            %% Stream continues waiting for the final (non-1xx) response.
            Conn2 = Conn#gen_http_h2_conn{hpack_decode = NewHpackDecode},
            %% Clear headers buffer since we've processed this HEADERS frame
            NewStream = Stream#stream_state{headers_buffer = <<>>},
            Conn3 = update_stream(Conn2, StreamId, NewStream),
            HeaderEvent = {headers, Stream#stream_state.ref, StreamId, EventHeaders},
            {ok, Conn3, [HeaderEvent]};
        false ->
            %% Final (non-1xx) response - store status/headers in stream state
            %% RFC 7540 §5.1: Determine correct state transition.
            %% half_closed_local + remote END_STREAM → closed (fully done)
            StreamFullyClosed = EndStream andalso Stream#stream_state.state =:= half_closed_local,

            Conn2 =
                case StreamFullyClosed of
                    true ->
                        %% Stream is done — remove from map to free resources
                        remove_stream(Conn, StreamId);
                    false ->
                        NewStreamState =
                            case EndStream of
                                true -> half_closed_remote;
                                false -> Stream#stream_state.state
                            end,
                        NewStream = Stream#stream_state{
                            status = Status,
                            response_headers = StoredHeaders,
                            headers_buffer = <<>>,
                            state = NewStreamState
                        },
                        update_stream(Conn, StreamId, NewStream)
                end,

            Conn3 = Conn2#gen_http_h2_conn{hpack_decode = NewHpackDecode},
            HeaderEvent = {headers, Stream#stream_state.ref, StreamId, EventHeaders},
            DoneEvent =
                case EndStream of
                    true -> [{done, Stream#stream_state.ref, StreamId}];
                    false -> []
                end,
            {ok, Conn3, [HeaderEvent | DoneEvent]}
    end.

%% @doc Check if a status code is informational (1xx).
%% RFC 9110 Section 15.2: 1xx responses are interim responses.
-spec is_informational_status(status()) -> boolean().
is_informational_status(Status) when Status >= 100, Status =< 199 -> true;
is_informational_status(_) -> false.

%% @doc Handle DATA frame (response body).
-spec handle_data_frame(conn(), stream_id(), #data{}) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
handle_data_frame(Conn, StreamId, #data{flags = Flags, data = Data}) ->
    case maps:find(StreamId, Conn#gen_http_h2_conn.streams) of
        {ok, Stream} ->
            EndStream = gen_http_parser_h2:is_flag_set(Flags, data, end_stream),
            DataSize = byte_size(Data),

            %% RFC 7540 §5.1: half_closed_local + remote END_STREAM → closed
            StreamFullyClosed = EndStream andalso Stream#stream_state.state =:= half_closed_local,

            %% Update flow control windows
            NewRecvWindow = Stream#stream_state.recv_window - DataSize,
            ConnRecvWindow = Conn#gen_http_h2_conn.recv_window - DataSize,

            %% Batch WINDOW_UPDATE frames into a single send to reduce syscalls.
            %% Skip stream-level WINDOW_UPDATE if the stream is being closed
            %% (no more data will arrive on this stream).
            {StreamWuData, FinalStreamWindow} =
                case StreamFullyClosed of
                    true ->
                        {<<>>, NewRecvWindow};
                    false ->
                        case NewRecvWindow < (?DEFAULT_WINDOW_SIZE div 2) of
                            true ->
                                Increment = ?DEFAULT_WINDOW_SIZE - NewRecvWindow,
                                StreamWu = #window_update{
                                    stream_id = StreamId,
                                    window_size_increment = Increment
                                },
                                {gen_http_parser_h2:encode(StreamWu), NewRecvWindow + Increment};
                            false ->
                                {<<>>, NewRecvWindow}
                        end
                end,

            {ConnWuData, FinalConnWindow} =
                case ConnRecvWindow < (?DEFAULT_WINDOW_SIZE div 2) of
                    true ->
                        Increment2 = ?DEFAULT_WINDOW_SIZE - ConnRecvWindow,
                        ConnWu = #window_update{
                            stream_id = 0,
                            window_size_increment = Increment2
                        },
                        {gen_http_parser_h2:encode(ConnWu), ConnRecvWindow + Increment2};
                    false ->
                        {<<>>, ConnRecvWindow}
                end,

            Conn3 =
                case {StreamWuData, ConnWuData} of
                    {<<>>, <<>>} ->
                        Conn;
                    _ ->
                        #gen_http_h2_conn{transport = Transport, socket = Socket} = Conn,
                        ok = Transport:send(Socket, [StreamWuData, ConnWuData]),
                        Conn
                end,

            %% Update or remove stream
            Conn4 =
                case StreamFullyClosed of
                    true ->
                        %% Stream is done — remove from map to free resources
                        remove_stream(Conn3, StreamId);
                    false ->
                        NewStreamState =
                            case EndStream of
                                true -> half_closed_remote;
                                false -> Stream#stream_state.state
                            end,
                        NewStream = Stream#stream_state{
                            recv_window = FinalStreamWindow,
                            state = NewStreamState
                        },
                        update_stream(Conn3, StreamId, NewStream)
                end,

            Conn5 = Conn4#gen_http_h2_conn{recv_window = FinalConnWindow},

            %% Generate response events
            DataEvent = {data, Stream#stream_state.ref, StreamId, Data},
            DoneEvent =
                case EndStream of
                    true -> [{done, Stream#stream_state.ref, StreamId}];
                    false -> []
                end,

            {ok, Conn5, [DataEvent | DoneEvent]};
        error ->
            %% Unknown stream, send RST_STREAM
            RstFrame = #rst_stream{
                stream_id = StreamId,
                error_code = stream_closed
            },
            {ok, send_frame(Conn, RstFrame), []}
    end.

%% @doc Handle WINDOW_UPDATE frame.
%%
%% After updating the window, flushes any send-buffered data that was
%% waiting for flow control capacity.
-spec handle_window_update_frame(conn(), stream_id(), non_neg_integer()) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
handle_window_update_frame(Conn, 0, Increment) ->
    NewWindow = Conn#gen_http_h2_conn.send_window + Increment,
    case NewWindow > ?MAX_WINDOW_SIZE of
        true ->
            {error, Conn, protocol_error({flow_control_error, connection_window_overflow})};
        false ->
            NewConn = Conn#gen_http_h2_conn{send_window = NewWindow},
            flush_all_send_buffers(NewConn)
    end;
handle_window_update_frame(Conn, StreamId, Increment) ->
    case maps:find(StreamId, Conn#gen_http_h2_conn.streams) of
        {ok, Stream} ->
            NewWindow = Stream#stream_state.send_window + Increment,
            case NewWindow > ?MAX_WINDOW_SIZE of
                true ->
                    {error, Conn, protocol_error({flow_control_error, stream_window_overflow})};
                false ->
                    NewStream = Stream#stream_state{send_window = NewWindow},
                    Conn2 = update_stream(Conn, StreamId, NewStream),
                    flush_stream_send_buffer(Conn2, StreamId)
            end;
        error ->
            {ok, Conn, []}
    end.

%% @doc Flush buffered send data for a single stream.
-spec flush_stream_send_buffer(conn(), stream_id()) ->
    {ok, conn(), [h2_response()]}.
flush_stream_send_buffer(Conn, StreamId) ->
    case Conn#gen_http_h2_conn.streams of
        #{StreamId := Stream} ->
            case Stream#stream_state.send_buffer of
                <<>> ->
                    {ok, Conn, []};
                Buffered ->
                    EndStream = Stream#stream_state.send_end_stream,
                    {ok, Conn2} = send_buffered_data(
                        Conn, StreamId, Stream, Buffered, EndStream
                    ),
                    {ok, Conn2, []}
            end;
        _ ->
            {ok, Conn, []}
    end.

%% @doc Flush send buffers for all streams that have pending data.
-spec flush_all_send_buffers(conn()) ->
    {ok, conn(), [h2_response()]}.
flush_all_send_buffers(Conn) ->
    StreamIds = maps:fold(
        fun(Id, S, Acc) ->
            case byte_size(S#stream_state.send_buffer) > 0 of
                true -> [Id | Acc];
                false -> Acc
            end
        end,
        [],
        Conn#gen_http_h2_conn.streams
    ),
    flush_streams(Conn, StreamIds).

-spec flush_streams(conn(), [stream_id()]) -> {ok, conn(), [h2_response()]}.
flush_streams(Conn, []) ->
    {ok, Conn, []};
flush_streams(Conn, [StreamId | Rest]) ->
    {ok, Conn2, _} = flush_stream_send_buffer(Conn, StreamId),
    flush_streams(Conn2, Rest).

%% @doc Handle GOAWAY frame.
-spec handle_goaway_frame(conn(), stream_id(), atom(), binary()) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
handle_goaway_frame(Conn, LastStreamId, ErrorCode, _DebugData) ->
    %% Mark connection as closing
    NewConn = Conn#gen_http_h2_conn{state = closing},

    %% Generate error events for streams > LastStreamId
    Responses = maps:fold(
        fun(StreamId, Stream, Acc) ->
            case StreamId > LastStreamId of
                true ->
                    [{error, Stream#stream_state.ref, StreamId, {goaway, ErrorCode}} | Acc];
                false ->
                    Acc
            end
        end,
        [],
        Conn#gen_http_h2_conn.streams
    ),

    {ok, NewConn, Responses}.

%% @doc Handle RST_STREAM frame.
-spec handle_rst_stream_frame(conn(), stream_id(), atom()) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
handle_rst_stream_frame(Conn, StreamId, ErrorCode) ->
    case maps:find(StreamId, Conn#gen_http_h2_conn.streams) of
        {ok, Stream} ->
            %% Remove stream — RST_STREAM terminates it immediately
            Conn2 = remove_stream(Conn, StreamId),

            %% Generate error event
            Response = {error, Stream#stream_state.ref, StreamId, {rst_stream, ErrorCode}},
            {ok, Conn2, [Response]};
        error ->
            {ok, Conn, []}
    end.

%% @doc Handle PING frame.
-spec handle_ping_frame(conn(), byte(), binary()) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
handle_ping_frame(Conn, Flags, OpaqueData) ->
    AckFlag = gen_http_parser_h2:is_flag_set(Flags, ping, ack),
    case AckFlag of
        true ->
            %% ACK for our PING, ignore
            {ok, Conn, []};
        false ->
            %% Server sent PING, send ACK
            PingAck = #ping{
                stream_id = 0,
                flags = gen_http_parser_h2:set_flags(0, ping, [ack]),
                opaque_data = OpaqueData
            },
            {ok, send_frame(Conn, PingAck), []}
    end.

%% @doc Handle PUSH_PROMISE frame.
-spec handle_push_promise_frame(conn(), stream_id(), #push_promise{}) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
handle_push_promise_frame(Conn, _StreamId, _Frame) ->
    %% TODO: Implement server push support
    {ok, Conn, []}.

%% @doc Handle PRIORITY frame.
-spec handle_priority_frame(conn(), stream_id(), #priority{}) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
handle_priority_frame(Conn, _StreamId, _Frame) ->
    %% TODO: Implement stream priority
    {ok, Conn, []}.

%% @doc Handle CONTINUATION frame.
-spec handle_continuation_frame(conn(), stream_id(), #continuation{}) ->
    {ok, conn(), [h2_response()]} | {error, conn(), term()}.
handle_continuation_frame(Conn, StreamId, #continuation{flags = Flags, hbf = HeaderBlock}) ->
    case maps:find(StreamId, Conn#gen_http_h2_conn.streams) of
        {ok, Stream} ->
            EndHeaders = gen_http_parser_h2:is_flag_set(Flags, continuation, end_headers),
            FullHeaderBlock = <<(Stream#stream_state.headers_buffer)/binary, HeaderBlock/binary>>,

            case byte_size(FullHeaderBlock) > max_header_block_size(Conn) of
                true ->
                    {error, Conn, protocol_error({frame_parse_error, header_block_too_large})};
                false ->
                    case EndHeaders of
                        true ->
                            decode_and_emit_headers(Conn, StreamId, Stream, FullHeaderBlock, false);
                        false ->
                            NewStream = Stream#stream_state{headers_buffer = FullHeaderBlock},
                            {ok, update_stream(Conn, StreamId, NewStream), []}
                    end
            end;
        error ->
            {ok, Conn, []}
    end.

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
%% Only handles errors that are actually raised in this module
-spec protocol_error(
    max_concurrent_streams_exceeded
    | {frame_parse_error, term()}
    | {hpack_decode_error, term()}
    | {flow_control_error, term()}
) -> gen_http:error_reason().
protocol_error({frame_parse_error, _} = E) -> {protocol_error, E};
protocol_error({hpack_decode_error, _} = E) -> {protocol_error, E};
protocol_error({flow_control_error, _} = E) -> {protocol_error, E};
protocol_error(max_concurrent_streams_exceeded) -> {protocol_error, max_concurrent_streams_exceeded}.

%% @doc Wrap application errors in structured format.
-spec application_error(
    connection_closed
    | {invalid_stream_id, pos_integer()}
    | unexpected_close
) -> gen_http:error_reason().
application_error(connection_closed) -> {application_error, connection_closed};
application_error({invalid_stream_id, _} = E) -> {application_error, E};
application_error(unexpected_close) -> {application_error, unexpected_close}.

%%====================================================================
%% Internal Functions - Header Processing
%%====================================================================

-spec extract_status(headers()) -> {ok, status()} | {error, missing_status}.
extract_status(Headers) ->
    case lists:keyfind(<<":status">>, 1, Headers) of
        {<<":status">>, StatusBin} ->
            {ok, binary_to_integer(StatusBin)};
        false ->
            {error, missing_status}
    end.

-spec remove_pseudo_headers(headers()) -> headers().
remove_pseudo_headers(Headers) ->
    lists:filter(
        fun({Name, _}) ->
            case Name of
                <<$:, _/binary>> -> false;
                _ -> true
            end
        end,
        Headers
    ).

-spec remove_pseudo_headers_except_status(headers()) -> headers().
remove_pseudo_headers_except_status(Headers) ->
    lists:filter(
        fun
            ({<<":status">>, _}) -> true;
            ({<<$:, _/binary>>, _}) -> false;
            ({_, _}) -> true
        end,
        Headers
    ).

-spec update_all_stream_windows(conn(), integer()) ->
    {ok, conn()} | {error, conn(), term()}.
update_all_stream_windows(Conn, Delta) ->
    try
        NewStreams = maps:map(
            fun(_Id, Stream) ->
                NewWindow = Stream#stream_state.send_window + Delta,
                case NewWindow > ?MAX_WINDOW_SIZE of
                    true -> throw(window_overflow);
                    false -> Stream#stream_state{send_window = NewWindow}
                end
            end,
            Conn#gen_http_h2_conn.streams
        ),
        {ok, Conn#gen_http_h2_conn{streams = NewStreams}}
    catch
        throw:window_overflow ->
            {error, Conn, protocol_error({flow_control_error, settings_window_overflow})}
    end.

%%====================================================================
%% Internal Functions - Connection Close
%%====================================================================

-spec handle_closed(conn()) ->
    {error, conn(), term(), [h2_response()]}.
handle_closed(Conn) ->
    NewConn = Conn#gen_http_h2_conn{state = closed},
    Responses = generate_close_responses(Conn#gen_http_h2_conn.streams),
    {error, NewConn, application_error(connection_closed), Responses}.

-spec handle_error(conn(), term()) ->
    {error, conn(), gen_http:error_reason(), [h2_response()]}.
handle_error(Conn, Reason) ->
    NewConn = Conn#gen_http_h2_conn{state = closed},
    Responses = generate_error_responses(Conn#gen_http_h2_conn.streams, Reason),
    {error, NewConn, transport_error(Reason), Responses}.

%%====================================================================
%% Internal Functions - Utilities
%%====================================================================

-spec update_stream(conn(), stream_id(), stream_state()) -> conn().
update_stream(Conn, StreamId, Stream) ->
    Streams = maps:put(StreamId, Stream, Conn#gen_http_h2_conn.streams),
    Conn#gen_http_h2_conn{streams = Streams}.

%% @doc Remove a fully closed stream from the streams map.
%%
%% Called when both endpoints have sent END_STREAM (RFC 7540 §5.1).
%% Frees resources and keeps the stream count accurate for
%% `max_concurrent_streams` enforcement.
-spec remove_stream(conn(), stream_id()) -> conn().
remove_stream(Conn, StreamId) ->
    Streams = maps:remove(StreamId, Conn#gen_http_h2_conn.streams),
    Conn#gen_http_h2_conn{streams = Streams}.

-spec reactivate_socket_if_needed(module(), socket(), active | passive, conn()) -> ok.
reactivate_socket_if_needed(Transport, Socket, active, #gen_http_h2_conn{state = open}) ->
    Transport:setopts(Socket, [{active, once}]);
reactivate_socket_if_needed(_, _, _, _) ->
    ok.

-spec generate_close_responses(#{stream_id() => stream_state()}) -> [h2_response()].
generate_close_responses(Streams) ->
    maps:fold(
        fun(_Id, Stream, Acc) ->
            case Stream#stream_state.state of
                closed ->
                    Acc;
                _ ->
                    [
                        {error, Stream#stream_state.ref, Stream#stream_state.id, application_error(unexpected_close)}
                        | Acc
                    ]
            end
        end,
        [],
        Streams
    ).

-spec generate_error_responses(#{stream_id() => stream_state()}, term()) -> [h2_response()].
generate_error_responses(Streams, Reason) ->
    maps:fold(
        fun(_Id, Stream, Acc) ->
            [{error, Stream#stream_state.ref, Stream#stream_state.id, transport_error(Reason)} | Acc]
        end,
        [],
        Streams
    ).
