-ifndef(H2_FRAMES_HRL).
-define(H2_FRAMES_HRL, true).

-define(PACKET_DATA, 0).
-define(PACKET_HEADERS, 1).
-define(PACKET_PRIORITY, 2).
-define(PACKET_RST_STREAM, 3).
-define(PACKET_SETTINGS, 4).
-define(PACKET_PUSH_PROMISE, 5).
-define(PACKET_PING, 6).
-define(PACKET_GOAWAY, 7).
-define(PACKET_WINDOW_UPDATE, 8).
-define(PACKET_CONTINUATION, 9).

-record(data, {
    stream_id :: non_neg_integer(),
    flags = 16#0 :: byte(),
    data :: binary(),
    padding :: binary() | undefined
}).
-record(h2_headers, {
    stream_id :: non_neg_integer(),
    flags = 16#0 :: byte(),
    is_exclusive :: boolean() | undefined,
    stream_dependency :: non_neg_integer() | undefined,
    weight :: pos_integer() | undefined,
    hbf :: binary(),
    padding :: binary() | undefined
}).
-record(priority, {
    stream_id :: non_neg_integer(),
    flags = 16#0 :: byte(),
    is_exclusive :: boolean(),
    stream_dependency :: non_neg_integer(),
    weight :: pos_integer()
}).
-record(rst_stream, {
    stream_id :: non_neg_integer(),
    flags = 16#0 :: byte(),
    error_code :: atom() | {custom_error, non_neg_integer()}
}).
-record(settings, {
    stream_id :: non_neg_integer(),
    flags = 16#0 :: byte(),
    params :: list({atom(), term()})
}).
-record(push_promise, {
    stream_id :: non_neg_integer(),
    flags = 16#0 :: byte(),
    promised_stream_id :: non_neg_integer(),
    hbf :: binary(),
    padding :: binary() | undefined
}).
-record(ping, {
    stream_id :: non_neg_integer(),
    flags = 16#0 :: byte(),
    opaque_data :: binary()
}).
-record(goaway, {
    stream_id :: non_neg_integer(),
    flags = 16#0 :: byte(),
    last_stream_id :: non_neg_integer(),
    error_code :: atom() | {custom_error, non_neg_integer()},
    debug_data :: binary()
}).
-record(window_update, {
    stream_id :: non_neg_integer(),
    flags = 16#0 :: byte(),
    window_size_increment :: non_neg_integer()
}).
-record(continuation, {
    stream_id :: non_neg_integer(),
    flags = 16#0 :: byte(),
    hbf :: binary()
}).
-record(unknown, {}).

-type data() :: #data{}.
%% Note: Renamed record from 'headers' to 'h2_headers' to avoid type conflict with gen_http.hrl
-type h2_headers_frame() :: #h2_headers{}.
-type priority() :: #priority{}.
-type rst_stream() :: #rst_stream{}.
-type settings() :: #settings{}.
-type push_promise() :: #push_promise{}.
-type ping() :: #ping{}.
-type goaway() :: #goaway{}.
-type window_update() :: #window_update{}.
-type continuation() :: #continuation{}.
-type unknown() :: #unknown{}.
-type packet() ::
    data()
    | h2_headers_frame()
    | priority()
    | rst_stream()
    | settings()
    | push_promise()
    | ping()
    | goaway()
    | window_update()
    | continuation()
    | unknown().
-endif.
