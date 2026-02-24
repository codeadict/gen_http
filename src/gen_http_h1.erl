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

%% Compiler optimizations for hot-path functions
-compile(inline).
-compile({inline_size, 128}).

-include("include/gen_http.hrl").

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
    requests = queue:new() :: queue:queue(request_state()),
    streaming_request = undefined :: request_ref() | undefined,

    %% Settings
    max_pipeline = 10 :: pos_integer(),
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
    Transport = gen_http_transport:module_for_scheme(Scheme),
    Timeout = maps:get(timeout, Opts, 5000),
    Mode = maps:get(mode, Opts, active),
    MaxPipeline = maps:get(max_pipeline, Opts, 10),

    TransportOpts = maps:get(transport_opts, Opts, []),

    %% For HTTPS, ensure we only advertise HTTP/1.1 (not h2)
    ConnectOpts =
        case Scheme of
            https ->
                AlpnOpts =
                    case proplists:get_value(alpn_advertise, TransportOpts) of
                        undefined -> [{alpn_advertise, [<<"http/1.1">>]}];
                        %% User explicitly set ALPN, respect it
                        _ -> []
                    end,
                [{timeout, Timeout} | AlpnOpts ++ TransportOpts];
            _ ->
                [{timeout, Timeout} | TransportOpts]
        end,

    maybe
        {ok, Socket} ?= Transport:connect(Address, Port, ConnectOpts),
        ok ?= setup_socket_mode(Transport, Socket, Mode),
        Conn = make_connection(Transport, Socket, Scheme, Address, Port, Mode, MaxPipeline),
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

%% @doc Get the underlying socket.
-spec get_socket(conn()) -> socket().
get_socket(#gen_http_h1_conn{socket = Socket}) ->
    Socket.

%% @doc Store a private key-value pair in the connection.
%%
%% Attach metadata to connections (e.g., pool ID, metrics, tags).
-spec put_private(conn(), Key :: term(), Value :: term()) -> conn().
put_private(#gen_http_h1_conn{private = Private} = Conn, Key, Value) ->
    Conn#gen_http_h1_conn{private = maps:put(Key, Value, Private)}.

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

-spec make_connection(
    module(),
    socket(),
    scheme(),
    address(),
    inet:port_number(),
    active | passive,
    pos_integer()
) -> conn().
make_connection(Transport, Socket, Scheme, Address, Port, Mode, MaxPipeline) ->
    #gen_http_h1_conn{
        transport = Transport,
        socket = Socket,
        host = normalize_host(Address),
        port = Port,
        scheme = Scheme,
        state = open,
        mode = Mode,
        max_pipeline = MaxPipeline
    }.

-spec check_can_send_request(conn()) -> ok | {error, gen_http:error_reason()}.
check_can_send_request(#gen_http_h1_conn{state = closed}) ->
    {error, application_error(connection_closed)};
check_can_send_request(#gen_http_h1_conn{requests = Requests, max_pipeline = MaxPipeline}) ->
    case queue:len(Requests) >= MaxPipeline of
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
    NewRequests = queue:in(ReqState, Conn#gen_http_h1_conn.requests),
    Conn#gen_http_h1_conn{requests = NewRequests}.

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
    H1 = add_host_header(Headers, Host, Port),
    H2 = add_content_length_header(H1, Body),
    add_connection_header(H2).

-spec add_host_header(headers(), binary(), inet:port_number()) -> headers().
add_host_header(Headers, Host, Port) ->
    case lists:keyfind(<<"host">>, 1, Headers) of
        false -> [{<<"host">>, format_host(Host, Port)} | Headers];
        _ -> Headers
    end.

-spec add_content_length_header(headers(), iodata() | stream) -> headers().
add_content_length_header(Headers, stream) ->
    Headers;
add_content_length_header(Headers, <<>>) ->
    Headers;
add_content_length_header(Headers, Body) when is_binary(Body); is_list(Body) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        false ->
            Length = iolist_size(Body),
            [{<<"content-length">>, integer_to_binary(Length)} | Headers];
        _ ->
            Headers
    end.

-spec add_connection_header(headers()) -> headers().
add_connection_header(Headers) ->
    case lists:keyfind(<<"connection">>, 1, Headers) of
        false -> [{<<"connection">>, <<"keep-alive">>} | Headers];
        _ -> Headers
    end.

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
    #gen_http_h1_conn{buffer = Buffer, mode = Mode, transport = Transport, socket = Socket} = Conn,
    NewBuffer = maybe_concat(Buffer, Data),

    case parse_responses(Conn#gen_http_h1_conn{buffer = NewBuffer}, []) of
        {ok, NewConn, Responses} ->
            reactivate_socket_if_needed(Transport, Socket, Mode, NewConn),
            {ok, NewConn, Responses};
        {error, NewConn, Reason, Responses} ->
            {error, NewConn, Reason, Responses}
    end.

-spec reactivate_socket_if_needed(module(), socket(), active | passive, conn()) -> ok.
reactivate_socket_if_needed(Transport, Socket, active, #gen_http_h1_conn{state = open}) ->
    Transport:setopts(Socket, [{active, once}]);
reactivate_socket_if_needed(_, _, _, _) ->
    ok.

-spec parse_responses(conn(), [response()]) ->
    {ok, conn(), [response()]} | {error, conn(), term(), [response()]}.
parse_responses(Conn, Acc) ->
    case queue:out(Conn#gen_http_h1_conn.requests) of
        {empty, _} ->
            {ok, Conn, Acc};
        {{value, ReqState}, RestRequests} ->
            handle_response_parsing(Conn, ReqState, RestRequests, Acc)
    end.

-spec handle_response_parsing(conn(), request_state(), queue:queue(request_state()), [response()]) ->
    {ok, conn(), [response()]} | {error, conn(), term(), [response()]}.
handle_response_parsing(Conn, ReqState, RestRequests, Acc) ->
    Buffer = Conn#gen_http_h1_conn.buffer,
    case parse_response(Buffer, ReqState) of
        {done, Responses, NewReqState, RestBuffer} ->
            NewConn = Conn#gen_http_h1_conn{requests = RestRequests, buffer = RestBuffer},
            maybe_close_and_continue(NewConn, NewReqState, Acc ++ Responses);
        {continue, Responses, NewReqState, RestBuffer} ->
            NewRequests = queue:in_r(NewReqState, RestRequests),
            NewConn = Conn#gen_http_h1_conn{requests = NewRequests, buffer = RestBuffer},
            {ok, NewConn, Acc ++ Responses};
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

-spec parse_response(binary(), request_state()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}
    | {error, term()}.
parse_response(Buffer, #request_state{status = undefined} = ReqState) ->
    parse_status_line(Buffer, ReqState);
parse_response(Buffer, #request_state{body_state = undefined} = ReqState) ->
    parse_headers(Buffer, ReqState, []);
parse_response(Buffer, ReqState) ->
    parse_body(Buffer, ReqState).

-spec parse_status_line(binary(), request_state()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}
    | {error, {protocol_error, invalid_status_line}}.
parse_status_line(Buffer, ReqState) ->
    case gen_http_parser_h1:decode_response_status_line(Buffer) of
        {ok, {_Version, StatusCode, _Reason}, Rest} ->
            StatusResp = {status, ReqState#request_state.ref, StatusCode},
            NewReqState = ReqState#request_state{status = StatusCode},
            case parse_response(Rest, NewReqState) of
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

-spec parse_headers(binary(), request_state(), headers()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}
    | {error, term()}.
parse_headers(Buffer, ReqState, HeadersAcc) ->
    case gen_http_parser_h1:decode_response_header(Buffer) of
        {ok, {Name, Value}, Rest} ->
            parse_headers(Rest, ReqState, [{Name, Value} | HeadersAcc]);
        {ok, eof, Rest} ->
            handle_headers_complete(Rest, ReqState, lists:reverse(HeadersAcc));
        more ->
            {continue, [], ReqState, Buffer};
        error ->
            {error, protocol_error(invalid_header)}
    end.

-dialyzer({nowarn_function, handle_headers_complete/3}).
handle_headers_complete(Rest, ReqState, Headers) ->
    HeadersResp = {headers, ReqState#request_state.ref, Headers},
    BodyState = determine_body_state(ReqState#request_state.status, Headers),
    NewReqState = ReqState#request_state{response_headers = Headers, body_state = BodyState},

    case BodyState of
        done ->
            DoneResp = {done, ReqState#request_state.ref},
            {done, [HeadersResp, DoneResp], NewReqState, Rest};
        _ ->
            combine_header_and_body_responses(Rest, NewReqState, HeadersResp)
    end.

-spec combine_header_and_body_responses(binary(), request_state(), response()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}.
combine_header_and_body_responses(Rest, NewReqState, HeadersResp) ->
    case parse_body(Rest, NewReqState) of
        {done, BodyResponses, FinalReqState, FinalRest} ->
            {done, [HeadersResp | BodyResponses], FinalReqState, FinalRest};
        {continue, BodyResponses, FinalReqState, FinalRest} ->
            {continue, [HeadersResp | BodyResponses], FinalReqState, FinalRest}
    end.

-spec parse_body(binary(), request_state()) ->
    {done, [response()], request_state(), binary()}
    | {continue, [response()], request_state(), binary()}.
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
            Responses =
                case Body of
                    <<>> -> [];
                    _ -> [{data, Ref, Body}]
                end,
            NewReqState = ReqState#request_state{body_state = done},
            {done, Responses ++ [{done, Ref}], NewReqState, Rest};
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
            try binary_to_integer(SizeHexClean, 16) of
                0 ->
                    %% Last chunk, consume trailing CRLF
                    case Rest of
                        <<"\r\n", FinalRest/binary>> ->
                            NewReqState = ReqState#request_state{body_state = done},
                            {done, [{done, Ref}], NewReqState, FinalRest};
                        _ ->
                            %% Wait for trailing CRLF
                            {continue, [], ReqState, Buffer}
                    end;
                Size ->
                    %% Non-zero chunk, read data
                    NewReqState = ReqState#request_state{body_state = {chunked, {reading_data, Size}}},
                    parse_chunk_data(Rest, NewReqState, Ref, Size)
            catch
                error:badarg ->
                    {error, protocol_error(invalid_chunk_size)}
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
            Responses =
                case ChunkData of
                    <<>> -> [];
                    _ -> [{data, Ref, ChunkData}]
                end,
            %% Continue reading next chunk
            NewReqState = ReqState#request_state{body_state = {chunked, reading_size}},
            case parse_chunk_size(Rest, NewReqState, Ref) of
                {done, MoreResponses, FinalReqState, FinalRest} ->
                    {done, Responses ++ MoreResponses, FinalReqState, FinalRest};
                {continue, MoreResponses, FinalReqState, FinalRest} ->
                    {continue, Responses ++ MoreResponses, FinalReqState, FinalRest};
                {error, Reason} ->
                    {error, Reason}
            end;
        false ->
            %% Need more data
            {continue, [], ReqState, Buffer}
    end.

-spec determine_body_state(status(), headers()) ->
    done | {content_length, non_neg_integer()} | {chunked, reading_size} | until_close.
determine_body_state(Status, _Headers) when Status =:= 204; Status =:= 304 ->
    done;
determine_body_state(Status, _Headers) when Status >= 100, Status =< 199 ->
    done;
determine_body_state(_Status, Headers) ->
    case lists:keyfind(<<"transfer-encoding">>, 1, Headers) of
        {_, <<"chunked">>} ->
            {chunked, reading_size};
        _ ->
            case lists:keyfind(<<"content-length">>, 1, Headers) of
                {_, LengthBin} ->
                    Length = binary_to_integer(LengthBin),
                    case Length of
                        0 -> done;
                        _ -> {content_length, Length}
                    end;
                false ->
                    until_close
            end
    end.

-spec should_close_connection(request_state()) -> boolean().
should_close_connection(#request_state{response_headers = Headers}) ->
    case lists:keyfind(<<"connection">>, 1, Headers) of
        {_, <<"close">>} -> true;
        _ -> false
    end.

%%====================================================================
%% Internal Functions - Connection Lifecycle
%%====================================================================

-spec handle_closed(conn()) ->
    {error, conn(), gen_http:error_reason(), [response()]}.
handle_closed(Conn) ->
    Responses = generate_close_responses(Conn#gen_http_h1_conn.requests),
    NewConn = Conn#gen_http_h1_conn{state = closed, requests = queue:new()},
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
generate_close_response(#request_state{ref = Ref}, Acc) ->
    [{error, Ref, application_error(unexpected_close)} | Acc].

-spec handle_error(conn(), term()) ->
    {error, conn(), gen_http:error_reason(), [response()]}.
handle_error(Conn, Reason) ->
    Responses = generate_error_responses(Conn#gen_http_h1_conn.requests, Reason),
    NewConn = Conn#gen_http_h1_conn{state = closed, requests = queue:new()},
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
) -> gen_http:error_reason().
protocol_error({encode_failed, _} = E) -> {protocol_error, E};
protocol_error(invalid_status_line) -> {protocol_error, invalid_status_line};
protocol_error(invalid_header) -> {protocol_error, invalid_header};
protocol_error(invalid_chunk_size) -> {protocol_error, invalid_chunk_size}.

%% @doc Wrap application errors in structured format.
-spec application_error(
    connection_closed
    | pipeline_full
    | {invalid_request_ref, reference()}
    | unexpected_close
) -> gen_http:error_reason().
application_error(connection_closed) -> {application_error, connection_closed};
application_error(pipeline_full) -> {application_error, pipeline_full};
application_error({invalid_request_ref, _} = E) -> {application_error, E};
application_error(unexpected_close) -> {application_error, unexpected_close}.

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
