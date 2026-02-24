-module(gen_http_parser_h2).

-include("gen_http_h2_frames.hrl").

-define(MAX_FRAME_SIZE, 16384).

-export([
    set_flags/2,
    set_flags/3,
    is_flag_set/3,
    decode_next/1,
    decode_next/2,
    encode/1,
    encode_raw/4
]).

-export_type([packet/0]).

-spec encode(packet()) -> iodata().
encode(#data{stream_id = StreamId, flags = Flags, data = Data, padding = undefined}) ->
    encode_raw(?PACKET_DATA, Flags, StreamId, Data);
encode(#data{stream_id = StreamId, flags = Flags, data = Data, padding = Padding}) ->
    Flags1 = set_flags(Flags, data, [padded]),
    Payload1 = [byte_size(Padding), Data, Padding],
    encode_raw(?PACKET_DATA, Flags1, StreamId, Payload1);
encode(
    #h2_headers{
        stream_id = StreamId,
        flags = Flags,
        is_exclusive = IsExclusive,
        stream_dependency = StreamDep,
        weight = Weight,
        hbf = Hbf,
        padding = Padding
    } = _Frame
) ->
    {Payload, Flags1} =
        case (not is_falsy(StreamDep)) andalso (not is_falsy(Weight)) of
            true ->
                ExclusiveBit = boolean_to_integer(IsExclusive =:= true),
                {
                    [<<ExclusiveBit:1, StreamDep:31>>, Weight - 1, Hbf],
                    set_flags(Flags, headers, [priority])
                };
            false ->
                {Hbf, Flags}
        end,

    {Payload1, Flags2} =
        case is_falsy(Padding) of
            false ->
                {[byte_size(Padding), Payload, Padding], set_flags(Flags1, headers, [padded])};
            _ ->
                {Payload, Flags1}
        end,
    encode_raw(
        ?PACKET_HEADERS,
        Flags2,
        StreamId,
        Payload1
    );
encode(#priority{
    stream_id = StreamId,
    flags = Flags,
    is_exclusive = IsExclusive,
    stream_dependency = StreamDep,
    weight = Weight
}) ->
    Payload = [<<(boolean_to_integer(IsExclusive)):1/integer, StreamDep:31/integer>>, Weight - 1],
    encode_raw(
        ?PACKET_PRIORITY,
        Flags,
        StreamId,
        Payload
    );
encode(#rst_stream{stream_id = StreamId, flags = Flags, error_code = ErrorCode}) ->
    Payload = <<(dehumanize_error_code(ErrorCode)):32/integer>>,
    encode_raw(
        ?PACKET_RST_STREAM,
        Flags,
        StreamId,
        Payload
    );
encode(#settings{stream_id = StreamId, flags = Flags, params = Params}) ->
    Payload = lists:map(
        fun
            ({header_table_size, Value}) ->
                <<1:16/integer, Value:32/integer>>;
            ({enable_push, Value}) ->
                <<2:16/integer, (boolean_to_integer(Value)):32/integer>>;
            ({max_concurrent_streams, Value}) ->
                <<3:16/integer, Value:32/integer>>;
            ({initial_window_size, Value}) ->
                <<4:16/integer, Value:32/integer>>;
            ({max_frame_size, Value}) ->
                <<5:16/integer, Value:32/integer>>;
            ({max_header_list_size, Value}) ->
                <<6:16/integer, Value:32/integer>>;
            ({enable_connect_protocol, Value}) ->
                <<8:16/integer, (boolean_to_integer(Value)):32/integer>>
        end,
        Params
    ),
    encode_raw(
        ?PACKET_SETTINGS,
        Flags,
        StreamId,
        Payload
    );
encode(#push_promise{
    stream_id = StreamId,
    flags = Flags,
    promised_stream_id = PromisedStreamId,
    hbf = Hbf,
    padding = Padding
}) ->
    Payload = [<<0:1/integer, PromisedStreamId:31/integer>>, Hbf],
    {Payload1, Flags1} =
        case is_falsy(Padding) of
            true ->
                {Payload, Flags};
            false ->
                {
                    [erlang:byte_size(Padding), Payload, Padding],
                    set_flags(Flags, push_promise, [padded])
                }
        end,
    encode_raw(
        ?PACKET_PUSH_PROMISE,
        Flags1,
        StreamId,
        Payload1
    );
encode(#ping{stream_id = 0, flags = Flags, opaque_data = OpaqueData}) ->
    encode_raw(
        ?PACKET_PING,
        Flags,
        0,
        OpaqueData
    );
encode(#goaway{
    stream_id = 0,
    flags = Flags,
    last_stream_id = LastStreamId,
    error_code = ErrorCode,
    debug_data = DebugData
}) ->
    Payload = [
        <<0:1/integer, LastStreamId:31/integer, (dehumanize_error_code(ErrorCode)):32/integer>>,
        DebugData
    ],
    encode_raw(
        ?PACKET_GOAWAY,
        Flags,
        0,
        Payload
    );
encode(#window_update{stream_id = StreamId, flags = Flags, window_size_increment = Wsi}) ->
    Payload = <<0:1/integer, Wsi:31/integer>>,
    encode_raw(
        ?PACKET_WINDOW_UPDATE,
        Flags,
        StreamId,
        Payload
    );
encode(#continuation{stream_id = StreamId, flags = Flags, hbf = Hbf}) ->
    encode_raw(
        ?PACKET_CONTINUATION,
        Flags,
        StreamId,
        Hbf
    ).

-spec encode_raw(byte(), byte(), non_neg_integer(), iodata()) -> iodata().
encode_raw(Type, Flags, StreamId, Payload) ->
    [
        <<(erlang:iolist_size(Payload)):24/integer>>,
        Type,
        Flags,
        <<0:1/integer, StreamId:31/integer>>,
        Payload
    ].

-spec set_flags(atom(), list()) -> byte().
set_flags(FrameName, Flags) ->
    set_flags(0, FrameName, Flags).

-spec set_flags(byte(), atom(), list()) -> byte().
set_flags(InitialFlags, FrameName, Flags) when
    is_integer(InitialFlags) andalso is_list(Flags)
->
    lists:foldl(fun(Flag, Acc) -> set_flag(Acc, FrameName, Flag) end, InitialFlags, Flags).

-spec set_flag(byte(), atom(), atom()) -> byte().
set_flag(Flag, data, end_stream) ->
    Flag bor 1;
set_flag(Flag, data, padded) ->
    Flag bor 8;
set_flag(Flag, ping, ack) ->
    Flag bor 1;
set_flag(Flag, continuation, end_headers) ->
    Flag bor 4;
set_flag(Flag, headers, end_stream) ->
    Flag bor 1;
set_flag(Flag, headers, end_headers) ->
    Flag bor 4;
set_flag(Flag, headers, padded) ->
    Flag bor 8;
set_flag(Flag, headers, priority) ->
    Flag bor 32;
set_flag(Flag, settings, ack) ->
    Flag bor 1;
set_flag(Flag, push_promise, end_headers) ->
    Flag bor 4;
set_flag(Flag, push_promise, padded) ->
    Flag bor 8.

-spec is_flag_set(byte(), atom(), atom()) -> boolean().
is_flag_set(Flag, data, end_stream) ->
    Flag band 1 == 1;
is_flag_set(Flag, data, padded) ->
    Flag band 8 == 8;
is_flag_set(Flag, ping, ack) ->
    Flag band 1 == 1;
is_flag_set(Flag, continuation, end_headers) ->
    Flag band 4 == 4;
is_flag_set(Flag, headers, end_stream) ->
    Flag band 1 == 1;
is_flag_set(Flag, headers, end_headers) ->
    Flag band 4 == 4;
is_flag_set(Flag, headers, padded) ->
    Flag band 8 == 8;
is_flag_set(Flag, headers, priority) ->
    Flag band 32 == 32;
is_flag_set(Flag, settings, ack) ->
    Flag band 1 == 1;
is_flag_set(Flag, push_promise, end_headers) ->
    Flag band 4 == 4;
is_flag_set(Flag, push_promise, padded) ->
    Flag band 8 == 8.

decode_contents(?PACKET_DATA, Flags, StreamId, Payload) ->
    decode_data(Flags, StreamId, Payload);
decode_contents(?PACKET_HEADERS, Flags, StreamId, Payload) ->
    decode_headers(Flags, StreamId, Payload);
decode_contents(?PACKET_PRIORITY, Flags, StreamId, Payload) ->
    decode_priority(Flags, StreamId, Payload);
decode_contents(?PACKET_RST_STREAM, Flags, StreamId, Payload) ->
    decode_rst_stream(Flags, StreamId, Payload);
decode_contents(?PACKET_SETTINGS, Flags, StreamId, Payload) ->
    decode_settings(Flags, StreamId, Payload);
decode_contents(?PACKET_PUSH_PROMISE, Flags, StreamId, Payload) ->
    decode_push_promise(Flags, StreamId, Payload);
decode_contents(?PACKET_PING, Flags, StreamId, Payload) ->
    decode_ping(Flags, StreamId, Payload);
decode_contents(?PACKET_GOAWAY, Flags, StreamId, Payload) ->
    decode_goaway(Flags, StreamId, Payload);
decode_contents(?PACKET_WINDOW_UPDATE, Flags, StreamId, Payload) ->
    decode_window_update(Flags, StreamId, Payload);
decode_contents(?PACKET_CONTINUATION, Flags, StreamId, Payload) ->
    decode_continuation(Flags, StreamId, Payload);
decode_contents(_Type, _Flags, _StreamId, _Payload) ->
    #unknown{}.

%% Decodes the next frame of the given binary.
%%
%% Returns `{:ok, frame, rest}` if successful, `{:error, reason}` if not.
-spec decode_next(binary()) ->
    {ok, packet(), binary()}
    | more
    | {error,
        {frame_size_error, atom()}
        | {protocol_error, binary()}
        | payload_too_big}.
decode_next(Data) -> decode_next(Data, ?MAX_FRAME_SIZE).

-spec decode_next(binary(), non_neg_integer()) ->
    {ok, packet(), binary()}
    | more
    | {error,
        {frame_size_error, atom()}
        | {protocol_error, binary()}
        | payload_too_big}.
decode_next(Data, MaxFrameSize) when erlang:is_binary(Data) ->
    try
        case decode_next_raw(Data) of
            {ok, {_Type, _Flags, _StreamId, Payload}, _Rest} when
                erlang:byte_size(Payload) > MaxFrameSize
            ->
                {error, payload_too_big};
            {ok, {Type, Flags, StreamId, Payload}, Rest} ->
                {ok,
                    decode_contents(
                        Type,
                        Flags,
                        StreamId,
                        Payload
                    ),
                    Rest};
            more ->
                more
        end
    catch
        throw:{gen_http, Reason}:_Stacktrace ->
            {error, Reason}
    end.

decode_next_raw(
    <<Length:24/integer, Type/integer, Flags/integer, _Reserved:1/integer, StreamId:31/integer, Payload:Length/binary,
        Rest/binary>>
) ->
    {ok, {Type, Flags, StreamId, Payload}, Rest};
decode_next_raw(_Other) ->
    more.

decode_data(Flags, StreamId, Payload) ->
    {Data, Padding} = decode_padding(data, Flags, Payload),
    #data{
        stream_id = StreamId,
        flags = Flags,
        data = Data,
        padding = Padding
    }.

decode_priority(_Flags, _StreamId, Payload) when erlang:byte_size(Payload) /= 5 ->
    throw({gen_http, {frame_size_error, priority}});
decode_priority(Flags, StreamId, Payload) ->
    <<Exclusive:1/integer, StreamDep:31/integer, Weight:8/integer>> = Payload,
    #priority{
        stream_id = StreamId,
        flags = Flags,
        is_exclusive = Exclusive == 1,
        stream_dependency = StreamDep,
        weight = Weight + 1
    }.

decode_headers(Flags, StreamId, Payload) ->
    {Data, Padding} = decode_padding(headers, Flags, Payload),

    {IsExclusive, StreamDep, Weight, Data1} =
        case is_flag_set(Flags, headers, priority) of
            true ->
                <<IsExclusive1:1/integer, StreamDep1:31/integer, Weight1:8/integer, Rest/binary>> =
                    Data,
                {IsExclusive1 == 1, StreamDep1, Weight1 + 1, Rest};
            _ ->
                {undefined, undefined, undefined, Data}
        end,
    #h2_headers{
        stream_id = StreamId,
        flags = Flags,
        is_exclusive = IsExclusive,
        stream_dependency = StreamDep,
        weight = Weight,
        hbf = Data1,
        padding = Padding
    }.

decode_rst_stream(_Flags, _StreamId, Payload) when
    erlang:byte_size(Payload) /= 4
->
    throw({gen_http, {frame_size_error, rst_stream}});
decode_rst_stream(Flags, StreamId, <<ErrorCode:32/integer>> = _Payload) ->
    Error = humanize_error_code(ErrorCode),
    #rst_stream{stream_id = StreamId, flags = Flags, error_code = Error}.

%% http://httpwg.org/specs/rfc7540.html#rfc.section.6.5
decode_settings(_Flags, _StreamId, Payload) when erlang:byte_size(Payload) rem 6 /= 0 ->
    throw({gen_http, {frame_size_error, settings}});
decode_settings(Flags, StreamId, Payload) ->
    Params = decode_settings_params(Payload),
    #settings{stream_id = StreamId, flags = Flags, params = Params}.

%% From http://httpwg.org/specs/rfc7540.html#SettingValues
decode_settings_params(Payload) ->
    decode_settings_params(Payload, []).

decode_settings_params(<<>>, Acc) ->
    lists:reverse(Acc);
decode_settings_params(<<Identifier:16/integer, Value:32/integer, Rest/binary>>, Acc) ->
    Acc1 =
        case Identifier of
            1 -> [{header_table_size, Value} | Acc];
            2 -> [{enable_push, Value == 1} | Acc];
            3 -> [{max_concurrent_streams, Value} | Acc];
            4 -> [{initial_window_size, Value} | Acc];
            5 -> [{max_frame_size, Value} | Acc];
            6 -> [{max_header_list_size, Value} | Acc];
            8 -> [{enable_connect_protocol, Value == 1} | Acc];
            %% An endpoint that receives a SETTINGS frame with any unknown or unsupported identifier MUST
            %% ignore that setting.
            _Other -> Acc
        end,
    decode_settings_params(Rest, Acc1).

decode_push_promise(Flags, StreamId, Payload) ->
    {Data, Padding} = decode_padding(push_promise, Flags, Payload),

    <<_Reserved:1/integer, PromisedStreamId:31/integer, Hbf/binary>> = Data,
    #push_promise{
        stream_id = StreamId,
        flags = Flags,
        promised_stream_id = PromisedStreamId,
        hbf = Hbf,
        padding = Padding
    }.

decode_ping(_Flags, _StreamId, Payload) when erlang:byte_size(Payload) /= 8 ->
    throw({gen_http, {frame_size_error, ping}});
decode_ping(Flags, StreamId, Payload) ->
    #ping{stream_id = StreamId, flags = Flags, opaque_data = Payload}.

decode_goaway(Flags, StreamId, Payload) ->
    <<_Reserved:1/integer, LastStreamId:31/integer, ErrorCode:32/integer, DebugData/binary>> =
        Payload,
    #goaway{
        stream_id = StreamId,
        flags = Flags,
        last_stream_id = LastStreamId,
        error_code = humanize_error_code(ErrorCode),
        debug_data = DebugData
    }.

decode_window_update(_Flags, _StreamId, Payload) when erlang:byte_size(Payload) /= 4 ->
    throw({gen_http, {frame_size_error, window_update}});
decode_window_update(_Flags, _StreamId, <<_Reserved:1/integer, 0:31/integer>>) ->
    throw({gen_http, {protocol_error, <<"bad WINDOW_SIZE increment">>}});
decode_window_update(Flags, StreamId, <<_Reserved1:1/integer, WindowSizeIncrement:31/integer>>) ->
    #window_update{
        stream_id = StreamId,
        flags = Flags,
        window_size_increment = WindowSizeIncrement
    }.

decode_continuation(Flags, StreamId, Payload) ->
    #continuation{stream_id = StreamId, flags = Flags, hbf = Payload}.

decode_padding(Frame, Flags, <<PadLen/integer, Rest/binary>> = Payload) when
    Flags band 8 == 8
->
    case PadLen >= erlang:byte_size(Payload) of
        false ->
            DataLen = erlang:byte_size(Payload) - PadLen - 1,
            <<Data:DataLen/binary, Padding:PadLen/binary>> = Rest,
            {Data, Padding};
        true ->
            DbgMessage =
                list_to_binary(
                    io_lib:format(
                        "the padding length of a ~p frame is bigger than the payload "
                        "length",
                        [Frame]
                    )
                ),
            throw({gen_http, {protocol_error, DbgMessage}})
    end;
decode_padding(_Frame, _Flags, Payload) ->
    {Payload, undefined}.

humanize_error_code(0) ->
    no_error;
humanize_error_code(1) ->
    protocol_error;
humanize_error_code(2) ->
    internal_error;
humanize_error_code(3) ->
    flow_control_error;
humanize_error_code(4) ->
    settings_timeout;
humanize_error_code(5) ->
    stream_closed;
humanize_error_code(6) ->
    frame_size_error;
humanize_error_code(7) ->
    refused_stream;
humanize_error_code(8) ->
    cancel;
humanize_error_code(9) ->
    compression_error;
humanize_error_code(10) ->
    connect_error;
humanize_error_code(11) ->
    enhance_your_calm;
humanize_error_code(12) ->
    inadequate_security;
humanize_error_code(13) ->
    http11_required;
humanize_error_code(Code) ->
    {custom_error, Code}.

dehumanize_error_code(no_error) ->
    0;
dehumanize_error_code(protocol_error) ->
    1;
dehumanize_error_code(internal_error) ->
    2;
dehumanize_error_code(flow_control_error) ->
    3;
dehumanize_error_code(settings_timeout) ->
    4;
dehumanize_error_code(stream_closed) ->
    5;
dehumanize_error_code(frame_size_error) ->
    6;
dehumanize_error_code(refused_stream) ->
    7;
dehumanize_error_code(cancel) ->
    8;
dehumanize_error_code(compression_error) ->
    9;
dehumanize_error_code(connect_error) ->
    10;
dehumanize_error_code(enhance_your_calm) ->
    11;
dehumanize_error_code(inadequate_security) ->
    12;
dehumanize_error_code(http11_required) ->
    13;
dehumanize_error_code({custom_error, Code}) ->
    Code.

boolean_to_integer(true) -> 1;
boolean_to_integer(_Other) -> 0.

is_falsy(Value) when Value =:= false orelse Value =:= undefined ->
    true;
is_falsy(_) ->
    false.

%%====================================================================
%% Unit Tests
%%====================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

set_flags_test() ->
    ?assertEqual(
        16#01,
        gen_http_parser_h2:set_flags(ping, [ack])
    ),
    ?assertEqual(
        16#01,
        gen_http_parser_h2:set_flags(data, [end_stream])
    ),
    ?assertException(
        error,
        function_clause,
        gen_http_parser_h2:set_flags(data, [ack])
    ).

set_flags_with_opts_test() ->
    ?assertEqual(
        16#01 bor 16#08,
        gen_http_parser_h2:set_flags(16#01, data, [padded])
    ),
    ?assertException(
        error,
        function_clause,
        gen_http_parser_h2:set_flags(16#00, data, [ack])
    ).

is_flag_set_test() ->
    ?assertEqual(
        true,
        gen_http_parser_h2:is_flag_set(16#08, data, padded)
    ),
    ?assertEqual(
        false,
        gen_http_parser_h2:is_flag_set(16#00, data, padded)
    ),
    ?assertException(
        error,
        function_clause,
        gen_http_parser_h2:is_flag_set(16#00, data, ack)
    ).

decode_next_with_incomplete_frame_test() ->
    ?assertEqual(
        more,
        gen_http_parser_h2:decode_next(<<>>)
    ).

%% -------------------
%% DATA frame tests
%% -------------------

data_with_bad_padding_test() ->
    %% the pad length is >= payload byte size
    Payload = <<6:8, "hello">>,
    DbgData = <<"the padding length of a data frame is bigger than the payload length">>,
    Packet = list_to_binary(gen_http_parser_h2:encode_raw(16#00, 16#08, 3, Payload)),
    ?assertEqual(
        {error, {protocol_error, DbgData}},
        gen_http_parser_h2:decode_next(Packet)
    ).

-endif.
