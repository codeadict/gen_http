-module(prop_gen_http_parser_h2).

-include("gen_http_h2_frames.hrl").

-include_lib("proper/include/proper.hrl").

-include_lib("stdlib/include/assert.hrl").

-define(assertRoundTrip(Frame), begin
    Encoded = list_to_binary(gen_http_parser_h2:encode(Frame)),
    ?assertEqual(
        {ok, Frame, <<"rest">>},
        gen_http_parser_h2:decode_next(<<Encoded/binary, "rest">>)
    )
end).

%% -------------------------------------------------------------------
%% DATA Packet
%% -------------------------------------------------------------------

prop_data_frame_no_padding() ->
    ?FORALL(
        {StreamId, Data},
        {non_zero_stream_id(), binary()},
        begin
            ?assertRoundTrip(#data{stream_id = StreamId, flags = 16#00, data = Data}),
            true
        end
    ).

prop_data_frame_with_padding() ->
    ?FORALL(
        {StreamId, Data, Padding},
        {non_zero_stream_id(), binary(), binary()},
        begin
            ?assertRoundTrip(#data{
                stream_id = StreamId,
                flags = 16#08,
                data = Data,
                padding = Padding
            }),
            true
        end
    ).

%% -------------------------------------------------------------------
%% PRIORITY Packet
%% -------------------------------------------------------------------

prop_priority_frame() ->
    ?FORALL(
        {StreamId, StreamDep, Exclusive, Weight},
        {non_zero_stream_id(), non_zero_stream_id(), boolean(), integer(1, 256)},
        begin
            ?assertRoundTrip(#priority{
                stream_id = StreamId,
                flags = 16#00,
                is_exclusive = Exclusive,
                stream_dependency = StreamDep,
                weight = Weight
            }),
            true
        end
    ).

%% -------------------------------------------------------------------
%% RST_STREAM Packet
%% -------------------------------------------------------------------

prop_rst_stream_frame() ->
    ?FORALL(
        {StreamId, ErrorCode},
        {non_zero_stream_id(), error_code()},
        begin
            ?assertRoundTrip(#rst_stream{
                stream_id = StreamId, flags = 16#00, error_code = ErrorCode
            }),
            true
        end
    ).

%% -------------------------------------------------------------------
%% SETTINGS Packet
%% -------------------------------------------------------------------

prop_settings_frame_with_parameters() ->
    ?FORALL(
        Params,
        [
            {header_table_size, pos_integer()},
            {enable_push, boolean()},
            {max_concurrent_streams, non_neg_integer()},
            {initial_window_size, pos_integer()},
            {max_frame_size, pos_integer()},
            {max_header_list_size, pos_integer()},
            {enable_connect_protocol, boolean()}
        ],
        begin
            ?assertRoundTrip(#settings{stream_id = 0, flags = 16#01, params = Params}),
            true
        end
    ).

%% -------------------------------------------------------------------
%% PUSH_PROMISE Packet
%% -------------------------------------------------------------------

prop_push_promise_frame_no_padding() ->
    ?FORALL(
        {StreamId, PromisedStreamId, Hbf},
        {non_zero_stream_id(), non_zero_stream_id(), binary()},
        begin
            ?assertRoundTrip(#push_promise{
                stream_id = StreamId,
                flags = 16#00,
                promised_stream_id = PromisedStreamId,
                hbf = Hbf,
                padding = undefined
            }),
            true
        end
    ).

prop_push_promise_frame_with_padding() ->
    ?FORALL(
        {StreamId, PromisedStreamId, Hbf, Padding},
        {non_zero_stream_id(), non_zero_stream_id(), binary(), binary()},
        begin
            ?assertRoundTrip(#push_promise{
                stream_id = StreamId,
                flags = 16#08,
                promised_stream_id = PromisedStreamId,
                hbf = Hbf,
                padding = Padding
            }),
            true
        end
    ).

%% -------------------------------------------------------------------
%% PING Packet
%% -------------------------------------------------------------------

prop_ping_frame() ->
    ?FORALL(Data, binary(8), begin
        ?assertRoundTrip(#ping{stream_id = 0, flags = 16#00, opaque_data = Data}),
        true
    end).

%% -------------------------------------------------------------------
%% GOAWAY Packet
%% -------------------------------------------------------------------

prop_goaway_frame() ->
    ?FORALL({StreamId, ErrorCode, DebugData}, {non_zero_stream_id(), error_code(), binary()}, begin
        ?assertRoundTrip(#goaway{
            stream_id = 0,
            flags = 16#00,
            last_stream_id = StreamId,
            error_code = ErrorCode,
            debug_data = DebugData
        }),
        true
    end).

%% -------------------------------------------------------------------
%% WINDOW_UPDATE Packet
%% -------------------------------------------------------------------

prop_window_update_frame() ->
    ?FORALL({StreamId, Wsi}, {oneof([0, non_zero_stream_id()]), pos_integer()}, begin
        ?assertRoundTrip(#window_update{
            stream_id = StreamId,
            flags = 16#00,
            window_size_increment = Wsi
        }),
        true
    end).

%% -------------------------------------------------------------------
%% HEADERS Packet (the missing frame type from the original suite)
%% -------------------------------------------------------------------

prop_headers_frame_no_padding_no_priority() ->
    ?FORALL(
        {StreamId, Hbf},
        {non_zero_stream_id(), binary()},
        begin
            ?assertRoundTrip(#h2_headers{
                stream_id = StreamId,
                flags = 16#00,
                hbf = Hbf,
                is_exclusive = undefined,
                stream_dependency = undefined,
                weight = undefined,
                padding = undefined
            }),
            true
        end
    ).

prop_headers_frame_with_priority() ->
    ?FORALL(
        {StreamId, Hbf, StreamDep, Exclusive, Weight},
        {non_zero_stream_id(), binary(), non_zero_stream_id(), boolean(), integer(1, 256)},
        begin
            ?assertRoundTrip(#h2_headers{
                stream_id = StreamId,
                flags = 16#20,
                hbf = Hbf,
                is_exclusive = Exclusive,
                stream_dependency = StreamDep,
                weight = Weight,
                padding = undefined
            }),
            true
        end
    ).

prop_headers_frame_with_padding() ->
    ?FORALL(
        {StreamId, Hbf, Padding},
        {non_zero_stream_id(), binary(), binary()},
        begin
            ?assertRoundTrip(#h2_headers{
                stream_id = StreamId,
                flags = 16#08,
                hbf = Hbf,
                is_exclusive = undefined,
                stream_dependency = undefined,
                weight = undefined,
                padding = Padding
            }),
            true
        end
    ).

prop_headers_frame_with_priority_and_padding() ->
    ?FORALL(
        {StreamId, Hbf, StreamDep, Exclusive, Weight, Padding},
        {non_zero_stream_id(), binary(), non_zero_stream_id(), boolean(), integer(1, 256), binary()},
        begin
            ?assertRoundTrip(#h2_headers{
                stream_id = StreamId,
                flags = 16#28,
                hbf = Hbf,
                is_exclusive = Exclusive,
                stream_dependency = StreamDep,
                weight = Weight,
                padding = Padding
            }),
            true
        end
    ).

prop_headers_frame_end_stream() ->
    ?FORALL(
        {StreamId, Hbf},
        {non_zero_stream_id(), binary()},
        begin
            ?assertRoundTrip(#h2_headers{
                stream_id = StreamId,
                flags = 16#01,
                hbf = Hbf,
                is_exclusive = undefined,
                stream_dependency = undefined,
                weight = undefined,
                padding = undefined
            }),
            true
        end
    ).

%% -------------------------------------------------------------------
%% CONTINUATION Packet
%% -------------------------------------------------------------------

prop_continuation_frame() ->
    ?FORALL({StreamId, Hbf}, {non_zero_stream_id(), binary()}, begin
        ?assertRoundTrip(#continuation{stream_id = StreamId, hbf = Hbf}),
        true
    end).

-spec non_zero_stream_id() -> proper_types:type().
non_zero_stream_id() ->
    ?LET(
        X,
        pos_integer(),
        begin
            X * 2 + 1
        end
    ).

error_code() ->
    proper_types:oneof([
        no_error,
        protocol_error,
        internal_error,
        flow_control_error,
        settings_timeout,
        stream_closed,
        frame_size_error,
        refused_stream,
        cancel,
        compression_error,
        connect_error,
        enhance_your_calm,
        inadequate_security,
        http11_required,
        {custom_error, 16#11},
        {custom_error, 16#FF},
        {custom_error, 70007}
    ]).
