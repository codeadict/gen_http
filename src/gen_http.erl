-module(gen_http).

%% @doc Unified interface for HTTP/1.1 and HTTP/2 connections.
%%
%% Protocol-agnostic functions that work with both gen_http_h1 and gen_http_h2.

%% Targeted inlining for small dispatch/wrapper helpers
-compile(
    {inline, [
        normalize_h2_response/1
    ]}
).

-include("include/gen_http.hrl").

-export([
    %% Connection management
    connect/3,
    connect/4,
    close/1,
    is_open/1,
    get_socket/1,
    set_mode/2,
    controlling_process/2,
    put_log/2,
    %% Request/Response
    request/5,
    stream/2,
    recv/3,
    %% Metadata
    put_private/3,
    get_private/2,
    get_private/3,
    delete_private/2,
    %% Error classification
    is_retriable_error/1,
    classify_error/1
]).

-export_type([
    conn/0,
    address/0,
    headers/0,
    response/0,
    scheme/0,
    socket/0,
    transport_error/0,
    http1_protocol_error/0,
    http2_protocol_error/0,
    application_error/0,
    error_reason/0
]).

-opaque conn() :: gen_http_h1:conn() | gen_http_h2:conn().

%%====================================================================
%% Structured Error Types
%%====================================================================

%% @doc Transport-level errors (network, socket, DNS).
%%
%% These errors are typically retryable after a delay or reconnection.
-type transport_error() ::
    closed
    | timeout
    | econnrefused
    | econnreset
    | ehostunreach
    | enetunreach
    | nxdomain
    | {ssl_error, term()}
    | {send_failed, term()}
    | {setopts_failed, term()}
    | {connect_failed, term()}
    | {controlling_process_failed, term()}.

%% @doc HTTP/1.1 protocol errors.
%%
%% These indicate protocol violations or malformed responses.
%% Usually not retryable on the same connection.
-type http1_protocol_error() ::
    invalid_status_line
    | invalid_header
    | invalid_chunk_size
    | invalid_content_length
    | {unknown_transfer_encoding, binary()}
    | {parse_error, term()}.

%% @doc HTTP/2 protocol errors.
%%
%% These indicate HTTP/2 frame or stream errors.
%% Usually not retryable on the same connection.
-type http2_protocol_error() ::
    {frame_size_error, integer()}
    | {frame_parse_error, term()}
    | {protocol_error, term()}
    | {compression_error, term()}
    | {hpack_decode_error, term()}
    | {flow_control_error, term()}
    | {stream_closed, pos_integer()}
    | {invalid_stream_id, pos_integer()}
    | {settings_timeout, term()}
    | {goaway, term()}
    | {rst_stream, term()}
    | max_concurrent_streams_exceeded.

%% @doc Application-level errors.
%%
%% These are policy violations (not protocol errors).
-type application_error() ::
    connection_closed
    | pipeline_full
    | {invalid_request_ref, reference()}
    | unexpected_close.

%% @doc Structured error reason.
%%
%% All errors are wrapped in one of these categories to make it easy
%% to determine if an error is retryable.
-type error_reason() ::
    {transport_error, transport_error()}
    | {protocol_error, http1_protocol_error() | http2_protocol_error()}
    | {application_error, application_error()}.

%%====================================================================
%% API Functions - Connection Management
%%====================================================================

%% @doc Connect to an HTTP server.
%%
%% Automatically negotiates HTTP/1.1 or HTTP/2 based on ALPN when using HTTPS.
%% For HTTP (non-TLS), always uses HTTP/1.1.
%%
%% ## Examples
%%
%% ```erlang
%% %% Connect to HTTP server
%% {ok, Conn} = gen_http:connect(http, "example.com", 80).
%%
%% %% Connect to HTTPS server (negotiates HTTP/1.1 or HTTP/2)
%% {ok, Conn} = gen_http:connect(https, "example.com", 443).
%% ```
-spec connect(scheme(), address(), inet:port_number()) ->
    {ok, conn()} | {error, error_reason()}.
connect(Scheme, Address, Port) ->
    connect(Scheme, Address, Port, #{}).

%% @doc Connect to an HTTP server with options.
%%
%% ## Options
%%
%%   - `mode` - Socket mode: `active` (default) or `passive`
%%   - `timeout` - Connection timeout in milliseconds (default: 5000)
%%   - `protocols` - List of protocols to negotiate for HTTPS: `[http1]`, `[http2]`, or `[http2, http1]` (default)
%%
%% ## Examples
%%
%% ```erlang
%% %% Connect in passive mode (for one-shot requests)
%% {ok, Conn} = gen_http:connect(https, "example.com", 443, #{mode => passive}).
%%
%% %% Force HTTP/1.1 only
%% {ok, Conn} = gen_http:connect(https, "example.com", 443, #{protocols => [http1]}).
%% ```
-spec connect(scheme(), address(), inet:port_number(), map()) ->
    {ok, conn()} | {error, error_reason()}.
connect(http, Address, Port, Opts) ->
    %% HTTP always uses HTTP/1.1
    gen_http_h1:connect(http, Address, Port, Opts);
connect(https, Address, Port, Opts) ->
    %% HTTPS negotiates protocol via ALPN
    Protocols = maps:get(protocols, Opts, [http2, http1]),
    negotiate_protocol(https, Address, Port, Opts, Protocols).

%% @doc Close the connection.
-spec close(conn()) -> {ok, conn()}.
close(Conn) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn -> gen_http_h1:close(Conn);
        gen_http_h2_conn -> gen_http_h2:close(Conn)
    end.

%% @doc Switch the connection socket mode between active and passive.
%%
%% Active mode (default):
%%   - Socket delivers messages to the owning process automatically
%%   - Uses `{active, once}` for flow control
%%   - Process messages with `stream/2`
%%
%% Passive mode:
%%   - Explicit data retrieval using `recv/3`
%%   - Blocks until data is available
%%   - Useful for request/response patterns
%%
%% ## Examples
%%
%% ```erlang
%% %% Start in active mode
%% {ok, Conn} = gen_http:connect(https, "example.com", 443),
%%
%% %% Switch to passive mode for blocking I/O
%% {ok, Conn2} = gen_http:set_mode(Conn, passive),
%% {ok, Conn3, Responses} = gen_http:recv(Conn2, 0, 5000),
%%
%% %% Switch back to active mode
%% {ok, Conn4} = gen_http:set_mode(Conn3, active),
%% ```
-spec set_mode(conn(), active | passive) -> {ok, conn()} | {error, conn(), error_reason()}.
set_mode(Conn, Mode) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn -> gen_http_h1:set_mode(Conn, Mode);
        gen_http_h2_conn -> gen_http_h2:set_mode(Conn, Mode)
    end.

%% @doc Transfer socket ownership to another process.
%%
%% This is useful for connection pooling patterns where you want to hand off
%% an established connection to a worker process.
%%
%% After calling this, the new process will receive socket messages.
%% Make sure to transfer ownership BEFORE switching to active mode, otherwise
%% messages may be lost.
%%
%% ## Examples
%%
%% ```erlang
%% %% Create connection in one process
%% {ok, Conn} = gen_http:connect(https, "example.com", 443),
%%
%% %% Transfer to worker process
%% WorkerPid = spawn_worker(),
%% {ok, Conn2} = gen_http:controlling_process(Conn, WorkerPid),
%% ```
-spec controlling_process(conn(), pid()) -> {ok, conn()} | {error, conn(), error_reason()}.
controlling_process(Conn, Pid) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn -> gen_http_h1:controlling_process(Conn, Pid);
        gen_http_h2_conn -> gen_http_h2:controlling_process(Conn, Pid)
    end.

%% @doc Enable or disable debug logging for this connection.
%%
%% When enabled, the connection will log debug information about frames,
%% requests, and responses. This is useful for debugging but adds overhead.
%%
%% Logging is disabled by default for maximum performance.
%%
%% ## Examples
%%
%% ```erlang
%% %% Enable logging for debugging
%% {ok, Conn} = gen_http:connect(https, "example.com", 443),
%% {ok, Conn2} = gen_http:put_log(Conn, true),
%%
%% %% Disable logging
%% {ok, Conn3} = gen_http:put_log(Conn2, false),
%% ```
-spec put_log(conn(), boolean()) -> {ok, conn()}.
put_log(Conn, Log) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn -> gen_http_h1:put_log(Conn, Log);
        gen_http_h2_conn -> gen_http_h2:put_log(Conn, Log)
    end.

%%====================================================================
%% API Functions - Request/Response
%%====================================================================

%% @doc Send an HTTP request.
%%
%% Works with both HTTP/1.1 and HTTP/2 connections.
%% Returns a request reference that identifies this request in responses.
%%
%% ## Examples
%%
%% ```erlang
%% {ok, Conn} = gen_http:connect(https, "httpbin.org", 443),
%% {ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>).
%% ```
-spec request(conn(), binary(), binary(), headers(), iodata() | stream) ->
    {ok, conn(), reference()}
    | {error, conn(), error_reason()}.
request(Conn, Method, Path, Headers, Body) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn ->
            gen_http_h1:request(Conn, Method, Path, Headers, Body);
        gen_http_h2_conn ->
            case gen_http_h2:request(Conn, Method, Path, Headers, Body) of
                {ok, Conn2, Ref, _StreamId} -> {ok, Conn2, Ref};
                {error, _, _} = Error -> Error
            end
    end.

%% @doc Process incoming socket messages.
%%
%% Works with both HTTP/1.1 and HTTP/2 connections.
%% Returns list of responses (status, headers, data, done, errors).
%%
%% ## Examples
%%
%% ```erlang
%% receive
%%     Msg when is_tuple(Msg), element(1, Msg) =:= tcp; element(1, Msg) =:= ssl ->
%%         case gen_http:stream(Conn, Msg) of
%%             {ok, Conn2, Responses} ->
%%                 process_responses(Responses);
%%             {error, Conn2, Reason, Responses} ->
%%                 handle_error(Reason)
%%         end
%% end.
%% ```
-spec stream(conn(), term()) ->
    {ok, conn(), [response()]}
    | {error, conn(), error_reason(), [response()]}
    | unknown.
stream(Conn, Message) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn ->
            gen_http_h1:stream(Conn, Message);
        gen_http_h2_conn ->
            case gen_http_h2:stream(Conn, Message) of
                {ok, Conn2, Responses} ->
                    {ok, Conn2, normalize_h2_responses(Responses)};
                {error, Conn2, Reason, Responses} ->
                    {error, Conn2, Reason, normalize_h2_responses(Responses)};
                unknown ->
                    unknown
            end
    end.

%% @doc Receive data from the connection in passive mode.
%%
%% This function blocks until data is received or timeout occurs.
%% The connection must be in passive mode (see `connect/4` with `mode => passive`),
%% otherwise this function raises a `badarg` error.
%%
%% Use this when you want explicit control over when to receive data,
%% as opposed to active mode where messages are delivered to your process automatically.
%%
%% ## Examples
%%
%% ```erlang
%% %% Connect in passive mode
%% {ok, Conn} = gen_http:connect(https, "httpbin.org", 443, #{mode => passive}),
%% {ok, Conn2, Ref} = gen_http:request(Conn, <<"GET">>, <<"/get">>, [], <<>>),
%%
%% %% Explicitly receive data (0 = all available data, 5000ms timeout)
%% {ok, Conn3, Responses} = gen_http:recv(Conn2, 0, 5000),
%% %% Responses contains parsed HTTP messages
%% ```
-spec recv(conn(), non_neg_integer(), timeout()) ->
    {ok, conn(), [response()]} | {error, conn(), error_reason()}.
recv(Conn, ByteCount, Timeout) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn ->
            gen_http_h1:recv(Conn, ByteCount, Timeout);
        gen_http_h2_conn ->
            case gen_http_h2:recv(Conn, ByteCount, Timeout) of
                {ok, Conn2, Responses} ->
                    {ok, Conn2, normalize_h2_responses(Responses)};
                {error, _, _} = Error ->
                    Error
            end
    end.

%%====================================================================
%% API Functions - Metadata
%%====================================================================

%% @doc Check if connection is open.
%%
%% Works with both HTTP/1.1 and HTTP/2 connections.
-spec is_open(conn()) -> boolean().
is_open(Conn) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn -> gen_http_h1:is_open(Conn);
        gen_http_h2_conn -> gen_http_h2:is_open(Conn)
    end.

%% @doc Get the underlying socket.
%%
%% Works with both HTTP/1.1 and HTTP/2 connections.
-spec get_socket(conn()) -> socket().
get_socket(Conn) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn -> gen_http_h1:get_socket(Conn);
        gen_http_h2_conn -> gen_http_h2:get_socket(Conn)
    end.

%% @doc Store a private key-value pair in the connection.
%%
%% Attach metadata to connections (e.g., pool ID, metrics, tags).
%% Works with both HTTP/1.1 and HTTP/2 connections.
%%
%% ## Examples
%%
%% ```erlang
%% %% Tag connection with pool ID
%% Conn2 = gen_http:put_private(Conn, pool_id, worker_pool_1),
%%
%% %% Attach custom metadata
%% Conn3 = gen_http:put_private(Conn2, request_count, 0),
%% Conn4 = gen_http:put_private(Conn3, created_at, erlang:timestamp()).
%% ```
-spec put_private(conn(), Key :: term(), Value :: term()) -> conn().
put_private(Conn, Key, Value) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn -> gen_http_h1:put_private(Conn, Key, Value);
        gen_http_h2_conn -> gen_http_h2:put_private(Conn, Key, Value)
    end.

%% @doc Get a private value from the connection.
%%
%% Returns `undefined` if the key doesn't exist.
%% Works with both HTTP/1.1 and HTTP/2 connections.
-spec get_private(conn(), Key :: term()) -> term() | undefined.
get_private(Conn, Key) ->
    get_private(Conn, Key, undefined).

%% @doc Get a private value from the connection with a default.
%%
%% Works with both HTTP/1.1 and HTTP/2 connections.
%%
%% ## Examples
%%
%% ```erlang
%% PoolId = gen_http:get_private(Conn, pool_id, default_pool),
%% Count = gen_http:get_private(Conn, request_count, 0).
%% ```
-spec get_private(conn(), Key :: term(), Default :: term()) -> term().
get_private(Conn, Key, Default) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn -> gen_http_h1:get_private(Conn, Key, Default);
        gen_http_h2_conn -> gen_http_h2:get_private(Conn, Key, Default)
    end.

%% @doc Delete a private key from the connection.
%%
%% Works with both HTTP/1.1 and HTTP/2 connections.
-spec delete_private(conn(), Key :: term()) -> conn().
delete_private(Conn, Key) when is_tuple(Conn) ->
    case element(1, Conn) of
        gen_http_h1_conn -> gen_http_h1:delete_private(Conn, Key);
        gen_http_h2_conn -> gen_http_h2:delete_private(Conn, Key)
    end.

%%====================================================================
%% Error Classification
%%====================================================================

%% @doc Check if an error is retriable.
%%
%% Returns `true` for transport errors that may succeed if retried,
%% `false` for protocol errors that indicate a bug or incompatibility.
%%
%% ## Examples
%%
%% ```erlang
%% case gen_http_h1:request(Conn, <<"GET">>, <<"/">>, [], <<>>) of
%%     {ok, Conn2, Ref} ->
%%         {ok, Conn2, Ref};
%%     {error, _Conn, Reason} ->
%%         case gen_http:is_retriable_error(Reason) of
%%             true ->
%%                 %% Network error, try again
%%                 retry_request();
%%             false ->
%%                 %% Protocol error or policy violation, don't retry
%%                 {error, Reason}
%%         end
%% end.
%% ```
-spec is_retriable_error(error_reason()) -> boolean().
is_retriable_error({transport_error, _}) ->
    %% Transport errors are generally retriable
    true;
is_retriable_error({protocol_error, _}) ->
    %% Protocol errors indicate incompatibility or bugs
    false;
is_retriable_error({application_error, connection_closed}) ->
    %% Connection closed, can retry with new connection
    true;
is_retriable_error({application_error, unexpected_close}) ->
    %% Unexpected close, can retry
    true;
is_retriable_error({application_error, _}) ->
    %% Other application errors (pipeline_full, invalid_ref) are not retriable
    false.

%% @doc Classify an error reason into its category.
%%
%% Returns `transport`, `protocol`, or `application`.
%%
%% ## Examples
%%
%% ```erlang
%% case gen_http:classify_error(ErrorReason) of
%%     transport ->
%%         %% Network issue, can retry
%%         schedule_retry();
%%     protocol ->
%%         %% Protocol violation, log and alert
%%         logger:error("Protocol error: ~p", [ErrorReason]);
%%     application ->
%%         %% Application policy violation
%%         handle_application_error(ErrorReason)
%% end.
%% ```
-spec classify_error(error_reason()) -> transport | protocol | application.
classify_error({transport_error, _}) -> transport;
classify_error({protocol_error, _}) -> protocol;
classify_error({application_error, _}) -> application.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @doc Convert address to binary format.

%% @doc Negotiate HTTP protocol via ALPN for HTTPS connections.
-spec negotiate_protocol(scheme(), address(), inet:port_number(), map(), [http1 | http2]) ->
    {ok, conn()} | {error, error_reason()}.
negotiate_protocol(https, Address, Port, Opts, Protocols) ->
    %% Set ALPN protocols for negotiation
    AlpnProtocols = lists:filtermap(
        fun
            (http1) -> {true, <<"http/1.1">>};
            (http2) -> {true, <<"h2">>};
            (_) -> false
        end,
        Protocols
    ),

    %% Add ALPN to transport options
    TransportOpts = maps:get(transport_opts, Opts, []),
    NewTransportOpts = [{alpn_advertise, AlpnProtocols} | TransportOpts],
    NewOpts = Opts#{transport_opts => NewTransportOpts},

    %% Try HTTP/2 first if in protocol list
    case lists:member(http2, Protocols) of
        true ->
            case gen_http_h2:connect(https, Address, Port, NewOpts) of
                {ok, Conn} ->
                    {ok, Conn};
                {error, Reason} ->
                    %% Fall back to HTTP/1.1 if HTTP/2 fails and http1 is in list
                    case lists:member(http1, Protocols) of
                        true ->
                            gen_http_h1:connect(https, Address, Port, NewOpts);
                        false ->
                            {error, Reason}
                    end
            end;
        false ->
            %% Only HTTP/1.1 requested
            gen_http_h1:connect(https, Address, Port, NewOpts)
    end.

%% @doc Normalize HTTP/2 responses to the unified response() shape.
%%
%% HTTP/2 responses carry a stream_id that the unified interface strips.
%% Headers responses also contain the :status pseudo-header which gets
%% extracted as a separate {status, Ref, Status} event to match HTTP/1.
-spec normalize_h2_responses([gen_http_h2:h2_response()]) -> [response()].
normalize_h2_responses(Responses) ->
    lists:flatmap(fun normalize_h2_response/1, Responses).

-spec normalize_h2_response(gen_http_h2:h2_response()) -> [response()].
normalize_h2_response({headers, Ref, _StreamId, Headers}) ->
    %% Extract :status pseudo-header and emit as separate status event
    case lists:keyfind(<<":status">>, 1, Headers) of
        {<<":status">>, StatusBin} ->
            Status = binary_to_integer(StatusBin),
            CleanHeaders = [H || {K, _} = H <- Headers, K =/= <<":status">>],
            [{status, Ref, Status}, {headers, Ref, CleanHeaders}];
        false ->
            %% No :status (shouldn't happen with well-formed responses)
            CleanHeaders = [H || {K, _} = H <- Headers, K =/= <<":status">>],
            [{headers, Ref, CleanHeaders}]
    end;
normalize_h2_response({data, Ref, _StreamId, Data}) ->
    [{data, Ref, Data}];
normalize_h2_response({done, Ref, _StreamId}) ->
    [{done, Ref}];
normalize_h2_response({error, Ref, _StreamId, Reason}) ->
    [{error, Ref, Reason}];
normalize_h2_response({push_promise, _Ref, _StreamId, _PromisedStreamId, _Headers} = PP) ->
    %% Push promises are HTTP/2-specific, pass through as-is
    [PP].

%%====================================================================
%% Unit Tests
%%====================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Error Classification Tests
%%--------------------------------------------------------------------

is_retriable_transport_errors_test() ->
    %% Transport errors are retriable
    ?assert(is_retriable_error({transport_error, closed})),
    ?assert(is_retriable_error({transport_error, timeout})),
    ?assert(is_retriable_error({transport_error, econnrefused})),
    ?assert(is_retriable_error({transport_error, econnreset})),
    ?assert(is_retriable_error({transport_error, ehostunreach})),
    ?assert(is_retriable_error({transport_error, {ssl_error, foo}})),
    ?assert(is_retriable_error({transport_error, {send_failed, closed}})).

is_not_retriable_protocol_errors_test() ->
    %% Protocol errors are not retriable
    ?assertNot(is_retriable_error({protocol_error, invalid_status_line})),
    ?assertNot(is_retriable_error({protocol_error, invalid_header})),
    ?assertNot(is_retriable_error({protocol_error, invalid_chunk_size})),
    ?assertNot(is_retriable_error({protocol_error, {frame_size_error, 100}})),
    ?assertNot(is_retriable_error({protocol_error, max_concurrent_streams_exceeded})).

is_retriable_some_application_errors_test() ->
    %% Some application errors are retriable
    ?assert(is_retriable_error({application_error, connection_closed})),
    ?assert(is_retriable_error({application_error, unexpected_close})).

is_not_retriable_some_application_errors_test() ->
    %% Some application errors are not retriable
    ?assertNot(is_retriable_error({application_error, pipeline_full})),
    ?assertNot(is_retriable_error({application_error, {invalid_request_ref, make_ref()}})).

classify_error_transport_test() ->
    ?assertEqual(transport, classify_error({transport_error, closed})),
    ?assertEqual(transport, classify_error({transport_error, timeout})),
    ?assertEqual(transport, classify_error({transport_error, {send_failed, foo}})).

classify_error_protocol_test() ->
    ?assertEqual(protocol, classify_error({protocol_error, invalid_status_line})),
    ?assertEqual(protocol, classify_error({protocol_error, {frame_size_error, 100}})),
    ?assertEqual(protocol, classify_error({protocol_error, max_concurrent_streams_exceeded})).

classify_error_application_test() ->
    ?assertEqual(application, classify_error({application_error, connection_closed})),
    ?assertEqual(application, classify_error({application_error, pipeline_full})),
    ?assertEqual(application, classify_error({application_error, unexpected_close})).

%%--------------------------------------------------------------------
%% Error Pattern Matching Tests
%%--------------------------------------------------------------------

pattern_match_transport_error_test() ->
    Error = {transport_error, closed},

    %% Can match on category
    case Error of
        {transport_error, _} ->
            ok;
        _ ->
            ?assert(false)
    end,

    %% Can match on specific error
    case Error of
        {transport_error, closed} ->
            ok;
        _ ->
            ?assert(false)
    end.

pattern_match_protocol_error_test() ->
    Error = {protocol_error, invalid_status_line},

    %% Can match on category
    case Error of
        {protocol_error, _} ->
            ok;
        _ ->
            ?assert(false)
    end,

    %% Can match on specific error
    case Error of
        {protocol_error, invalid_status_line} ->
            ok;
        _ ->
            ?assert(false)
    end.

pattern_match_application_error_test() ->
    Error = {application_error, pipeline_full},

    %% Can match on category
    case Error of
        {application_error, _} ->
            ok;
        _ ->
            ?assert(false)
    end,

    %% Can match on specific error
    case Error of
        {application_error, pipeline_full} ->
            ok;
        _ ->
            ?assert(false)
    end.

%%--------------------------------------------------------------------
%% Retry Logic Example Test
%%--------------------------------------------------------------------

retry_logic_example_test() ->
    %% Example of how users can implement retry logic
    Transport = {transport_error, closed},
    Protocol = {protocol_error, invalid_status_line},
    AppClosed = {application_error, connection_closed},
    AppFull = {application_error, pipeline_full},

    %% Transport errors should be retried
    ?assert(should_retry(Transport)),

    %% Protocol errors should not be retried
    ?assertNot(should_retry(Protocol)),

    %% Connection closed should be retried (with new connection)
    ?assert(should_retry(AppClosed)),

    %% Pipeline full should not be retried (backpressure)
    ?assertNot(should_retry(AppFull)).

%% Helper function showing retry pattern
should_retry(Error) ->
    is_retriable_error(Error).

%%--------------------------------------------------------------------
%% HTTP/2 Response Normalization Tests
%%--------------------------------------------------------------------

normalize_h2_headers_with_status_test() ->
    Ref = make_ref(),
    H2 = [{headers, Ref, 1, [{<<":status">>, <<"200">>}, {<<"content-type">>, <<"text/plain">>}]}],
    Result = normalize_h2_responses(H2),
    ?assertEqual(
        [
            {status, Ref, 200},
            {headers, Ref, [{<<"content-type">>, <<"text/plain">>}]}
        ],
        Result
    ).

normalize_h2_data_test() ->
    Ref = make_ref(),
    H2 = [{data, Ref, 3, <<"hello">>}],
    ?assertEqual([{data, Ref, <<"hello">>}], normalize_h2_responses(H2)).

normalize_h2_done_test() ->
    Ref = make_ref(),
    H2 = [{done, Ref, 5}],
    ?assertEqual([{done, Ref}], normalize_h2_responses(H2)).

normalize_h2_error_test() ->
    Ref = make_ref(),
    H2 = [{error, Ref, 7, stream_closed}],
    ?assertEqual([{error, Ref, stream_closed}], normalize_h2_responses(H2)).

normalize_h2_full_response_test() ->
    Ref = make_ref(),
    H2 = [
        {headers, Ref, 1, [{<<":status">>, <<"404">>}, {<<"server">>, <<"nginx">>}]},
        {data, Ref, 1, <<"not found">>},
        {done, Ref, 1}
    ],
    Result = normalize_h2_responses(H2),
    ?assertEqual(
        [
            {status, Ref, 404},
            {headers, Ref, [{<<"server">>, <<"nginx">>}]},
            {data, Ref, <<"not found">>},
            {done, Ref}
        ],
        Result
    ).

-endif.
