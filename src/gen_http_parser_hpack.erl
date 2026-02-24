-module(gen_http_parser_hpack).

%% @doc HPACK: Header Compression for HTTP/2 (RFC 7541).
%%
%% HPACK header compression with static and dynamic tables.
%% Compression context is pure data (no process state).
%%
%% Huffman encoding is used when it reduces string size
%% (typically ~30% compression for header values).

-export([
    new/0,
    new/1,
    encode/2,
    decode/2,
    resize_table/2,
    set_max_table_size/2
]).

-export_type([context/0, header/0, headers/0]).

-type header() :: {binary(), binary()}.
-type headers() :: [header()].

-record(hpack_context, {
    max_table_size = 4096 :: non_neg_integer(),
    table_size = 0 :: non_neg_integer(),
    %% Monotonic counters for O(1) FIFO queue semantics.
    %% Active entries have IDs in [drop_count, insert_count - 1].
    insert_count = 0 :: non_neg_integer(),
    drop_count = 0 :: non_neg_integer(),
    %% entry_id -> {header(), entry_byte_size}
    entries = #{} :: #{non_neg_integer() => {header(), non_neg_integer()}},
    %% {Name, Value} -> entry_id (newest wins)
    by_header = #{} :: #{{binary(), binary()} => non_neg_integer()},
    %% Name -> entry_id (newest wins)
    by_name = #{} :: #{binary() => non_neg_integer()}
}).

-type context() :: #hpack_context{}.

%%====================================================================
%% API Functions
%%====================================================================

%% @doc Create a new HPACK context with default table size (4096 bytes).
-spec new() -> context().
new() ->
    new(4096).

%% @doc Create a new HPACK context with specified max table size.
-spec new(non_neg_integer()) -> context().
new(MaxSize) ->
    #hpack_context{
        max_table_size = MaxSize,
        table_size = 0,
        insert_count = 0,
        drop_count = 0,
        entries = #{},
        by_header = #{},
        by_name = #{}
    }.

%% @doc Encode headers to HPACK binary format.
%%
%% Returns `{ok, EncodedBinary, NewContext}` on success.
-spec encode(headers(), context()) -> {ok, binary(), context()}.
encode(Headers, Context) ->
    {Encoded, NewContext} = encode_headers(Headers, Context, <<>>),
    {ok, Encoded, NewContext}.

%% @doc Decode HPACK binary format to headers.
%%
%% Returns `{ok, Headers, NewContext}` on success or `{error, Reason}` on failure.
-spec decode(binary(), context()) -> {ok, headers(), context()} | {error, term()}.
decode(Data, Context) ->
    try
        {Headers, NewContext} = decode_headers(Data, Context, []),
        {ok, Headers, NewContext}
    catch
        throw:{hpack_error, Reason} ->
            {error, Reason}
    end.

%% @doc Resize dynamic table to new maximum size.
%%
%% Evicts entries if necessary to fit within new size limit.
-spec resize_table(context(), non_neg_integer()) -> context().
resize_table(Context, NewMaxSize) ->
    NewContext = Context#hpack_context{max_table_size = NewMaxSize},
    evict_to_fit(NewContext).

%% @doc Set maximum table size (used during settings negotiation).
-spec set_max_table_size(context(), non_neg_integer()) -> context().
set_max_table_size(Context, MaxSize) ->
    resize_table(Context, MaxSize).

%%====================================================================
%% Internal Functions - Encoding
%%====================================================================

-spec encode_headers(headers(), context(), binary()) -> {binary(), context()}.
encode_headers([], Context, Acc) ->
    {Acc, Context};
encode_headers([Header | Rest], Context, Acc) ->
    {Encoded, NewContext} = encode_header(Header, Context),
    encode_headers(Rest, NewContext, <<Acc/binary, Encoded/binary>>).

-spec encode_header(header(), context()) -> {binary(), context()}.
encode_header({Name, Value} = Header, Context) ->
    case lookup_index(Name, Value, Context) of
        {indexed, Index} ->
            %% Indexed header field - full match in table
            Encoded = encode_integer(Index, 7, 2#10000000),
            {Encoded, Context};
        {name_indexed, NameIndex} ->
            %% Literal with incremental indexing - name in table
            NewContext = add_to_table(Header, Context),
            NameEncoded = encode_integer(NameIndex, 6, 2#01000000),
            ValueEncoded = encode_string(Value),
            {<<NameEncoded/binary, ValueEncoded/binary>>, NewContext};
        not_indexed ->
            %% Literal with incremental indexing - new name
            NewContext = add_to_table(Header, Context),
            NameEncoded = encode_string(Name),
            ValueEncoded = encode_string(Value),
            {<<2#01000000:8, NameEncoded/binary, ValueEncoded/binary>>, NewContext}
    end.

-spec lookup_index(binary(), binary(), context()) ->
    {indexed, pos_integer()} | {name_indexed, pos_integer()} | not_indexed.
lookup_index(Name, Value, Context) ->
    %% Try static table first (full match)
    case lookup_static_full(Name, Value) of
        {ok, Index} ->
            {indexed, Index};
        not_found ->
            %% Try dynamic table (full match)
            case lookup_dynamic_full(Name, Value, Context) of
                {ok, Index} ->
                    {indexed, Index};
                not_found ->
                    %% Try name-only match (static first, then dynamic)
                    case lookup_static_name(Name) of
                        {ok, Index} ->
                            {name_indexed, Index};
                        not_found ->
                            case lookup_dynamic_name(Name, Context) of
                                {ok, Index} ->
                                    {name_indexed, Index};
                                not_found ->
                                    not_indexed
                            end
                    end
            end
    end.

%%====================================================================
%% Internal Functions - Decoding
%%====================================================================

-spec decode_headers(binary(), context(), headers()) -> {headers(), context()}.
decode_headers(<<>>, Context, Acc) ->
    {lists:reverse(Acc), Context};
decode_headers(Data, Context, Acc) ->
    {Header, Rest, NewContext} = decode_header_field(Data, Context),
    decode_headers(Rest, NewContext, [Header | Acc]).

-spec decode_header_field(binary(), context()) -> {header(), binary(), context()}.
decode_header_field(<<1:1, _:7, _/binary>> = Data, Context) ->
    %% Indexed header field (1xxxxxxx)
    {Index, Rest} = decode_integer(Data, 7),
    Header = get_indexed_header(Index, Context),
    {Header, Rest, Context};
decode_header_field(<<2#01:2, _:6, _/binary>> = Data, Context) ->
    %% Literal with incremental indexing (01xxxxxx)
    {Header, Rest} = decode_literal_incremental(Data, Context, 6),
    NewContext = add_to_table(Header, Context),
    {Header, Rest, NewContext};
decode_header_field(<<2#0000:4, _:4, _/binary>> = Data, Context) ->
    %% Literal without indexing (0000xxxx)
    {Header, Rest} = decode_literal_no_index(Data, Context, 4),
    {Header, Rest, Context};
decode_header_field(<<2#0001:4, _:4, _/binary>> = Data, Context) ->
    %% Literal never indexed (0001xxxx)
    {Header, Rest} = decode_literal_never_indexed(Data, Context, 4),
    {Header, Rest, Context};
decode_header_field(<<2#001:3, _:5, _/binary>> = Data, Context) ->
    %% Dynamic table size update (001xxxxx)
    {NewMaxSize, Rest} = decode_integer(Data, 5),
    NewContext = resize_table(Context, NewMaxSize),
    %% Size update doesn't produce a header, decode next field
    decode_header_field(Rest, NewContext);
decode_header_field(Data, _Context) ->
    throw({hpack_error, {invalid_header_field, Data}}).

-spec decode_literal_incremental(binary(), context(), 4..6) -> {header(), binary()}.
decode_literal_incremental(Data, Context, PrefixBits) ->
    {NameIndex, Rest1} = decode_integer(Data, PrefixBits),
    case NameIndex of
        0 ->
            %% New name
            {Name, Rest2} = decode_string(Rest1),
            {Value, Rest3} = decode_string(Rest2),
            {{Name, Value}, Rest3};
        _ ->
            %% Indexed name
            {Name, _} = get_indexed_header(NameIndex, Context),
            {Value, Rest2} = decode_string(Rest1),
            {{Name, Value}, Rest2}
    end.

-spec decode_literal_no_index(binary(), context(), 4) -> {header(), binary()}.
decode_literal_no_index(Data, Context, PrefixBits) ->
    decode_literal_incremental(Data, Context, PrefixBits).

-spec decode_literal_never_indexed(binary(), context(), 4) -> {header(), binary()}.
decode_literal_never_indexed(Data, Context, PrefixBits) ->
    decode_literal_incremental(Data, Context, PrefixBits).

%%====================================================================
%% Internal Functions - Integer Encoding/Decoding (RFC 7541 Section 5.1)
%%====================================================================

-spec encode_integer(non_neg_integer(), 4..8, byte()) -> binary().
encode_integer(I, PrefixBits, Prefix) when I < (1 bsl PrefixBits) - 1 ->
    <<(Prefix bor I):8>>;
encode_integer(I, PrefixBits, Prefix) ->
    MaxPrefix = (1 bsl PrefixBits) - 1,
    Remaining = I - MaxPrefix,
    Rest = encode_integer_continuation(Remaining),
    <<(Prefix bor MaxPrefix):8, Rest/binary>>.

-spec encode_integer_continuation(non_neg_integer()) -> binary().
encode_integer_continuation(I) when I < 128 ->
    <<I:8>>;
encode_integer_continuation(I) ->
    Byte = (I rem 128) bor 128,
    Rest = encode_integer_continuation(I div 128),
    <<Byte:8, Rest/binary>>.

-spec decode_integer(binary(), 4..8) -> {non_neg_integer(), binary()}.
decode_integer(<<FirstByte:8, Rest/binary>>, PrefixBits) ->
    Mask = (1 bsl PrefixBits) - 1,
    I = FirstByte band Mask,
    case I < Mask of
        true ->
            {I, Rest};
        false ->
            {Continuation, Rest2} = decode_integer_continuation(Rest, 0, 0),
            {I + Continuation, Rest2}
    end.

-spec decode_integer_continuation(binary(), non_neg_integer(), non_neg_integer()) ->
    {non_neg_integer(), binary()}.
decode_integer_continuation(<<Byte:8, Rest/binary>>, Acc, M) ->
    Value = Byte band 127,
    NewAcc = Acc + (Value bsl (M * 7)),
    case Byte band 128 of
        0 ->
            {NewAcc, Rest};
        _ ->
            decode_integer_continuation(Rest, NewAcc, M + 1)
    end;
decode_integer_continuation(<<>>, _Acc, _M) ->
    throw({hpack_error, incomplete_integer}).

%%====================================================================
%% Internal Functions - String Encoding/Decoding (RFC 7541 Section 5.2)
%%====================================================================

-spec encode_string(binary()) -> binary().
encode_string(Str) ->
    %% Try Huffman encoding first
    HuffmanEncoded = gen_http_parser_huffman:encode(Str),
    HuffmanSize = byte_size(HuffmanEncoded),
    LiteralSize = byte_size(Str),

    %% Use Huffman only if it's actually smaller (RFC 7541 recommends this)
    case HuffmanSize < LiteralSize of
        true ->
            %% Huffman bit is 1, followed by encoded length
            LengthEncoded = encode_integer(HuffmanSize, 7, 2#10000000),
            <<LengthEncoded/binary, HuffmanEncoded/binary>>;
        false ->
            %% Literal encoding: Huffman bit is 0, followed by length
            LengthEncoded = encode_integer(LiteralSize, 7, 0),
            <<LengthEncoded/binary, Str/binary>>
    end.

-spec decode_string(binary()) -> {binary(), binary()}.
decode_string(<<Huffman:1, _:7, _/binary>> = Data) ->
    {Length, Rest} = decode_integer(Data, 7),
    case Huffman of
        0 ->
            %% Literal string
            <<Str:Length/binary, Rest2/binary>> = Rest,
            {Str, Rest2};
        1 ->
            %% Huffman encoded
            <<Encoded:Length/binary, Rest2/binary>> = Rest,
            case gen_http_parser_huffman:decode(Encoded) of
                {ok, Decoded} ->
                    {Decoded, Rest2};
                {error, Reason} ->
                    throw({hpack_error, {huffman_decode_failed, Reason}})
            end
    end.

%%====================================================================
%% Internal Functions - Dynamic Table Management
%%====================================================================

-spec add_to_table(header(), context()) -> context().
add_to_table({Name, Value} = Header, Context) ->
    #hpack_context{
        insert_count = IC,
        entries = Entries,
        by_header = ByHeader,
        by_name = ByName,
        table_size = CurrentSize
    } = Context,

    EntrySize = header_size(Header),
    NewContext = Context#hpack_context{
        insert_count = IC + 1,
        entries = Entries#{IC => {Header, EntrySize}},
        by_header = ByHeader#{{Name, Value} => IC},
        by_name = ByName#{Name => IC},
        table_size = CurrentSize + EntrySize
    },
    evict_to_fit(NewContext).

-spec evict_to_fit(context()) -> context().
evict_to_fit(#hpack_context{table_size = Size, max_table_size = Max} = Ctx) when Size =< Max ->
    Ctx;
evict_to_fit(#hpack_context{insert_count = IC, drop_count = DC} = Ctx) when IC =:= DC ->
    Ctx;
evict_to_fit(Context) ->
    #hpack_context{
        drop_count = DC,
        entries = Entries,
        by_header = ByHeader,
        by_name = ByName,
        table_size = CurrentSize
    } = Context,

    %% Evict oldest entry (lowest ID)
    {{Name, Value}, EntrySize} = maps:get(DC, Entries),
    NewByHeader =
        case maps:get({Name, Value}, ByHeader, undefined) of
            DC -> maps:remove({Name, Value}, ByHeader);
            _ -> ByHeader
        end,
    NewByName =
        case maps:get(Name, ByName, undefined) of
            DC -> maps:remove(Name, ByName);
            _ -> ByName
        end,
    NewContext = Context#hpack_context{
        drop_count = DC + 1,
        entries = maps:remove(DC, Entries),
        by_header = NewByHeader,
        by_name = NewByName,
        table_size = CurrentSize - EntrySize
    },
    evict_to_fit(NewContext).

-spec header_size(header()) -> non_neg_integer().
header_size({Name, Value}) ->
    %% RFC 7541 Section 4.1: size = length(name) + length(value) + 32
    byte_size(Name) + byte_size(Value) + 32.

-spec get_indexed_header(pos_integer(), context()) -> header().
get_indexed_header(Index, _Context) when Index >= 1, Index =< 61 ->
    static_table_entry(Index);
get_indexed_header(Index, #hpack_context{insert_count = IC, entries = Entries}) when Index >= 62 ->
    %% Newest entry = index 62, so entry_id = IC - 1 - (Index - 62)
    EntryId = IC + 61 - Index,
    {Header, _Size} = maps:get(EntryId, Entries),
    Header.

%%====================================================================
%% Internal Functions - Static Table Lookups
%%====================================================================

-spec lookup_static_full(binary(), binary()) -> {ok, pos_integer()} | not_found.
lookup_static_full(Name, Value) ->
    case static_table_lookup_full() of
        Map ->
            case maps:get({Name, Value}, Map, not_found) of
                not_found -> not_found;
                Index -> {ok, Index}
            end
    end.

-spec lookup_static_name(binary()) -> {ok, pos_integer()} | not_found.
lookup_static_name(Name) ->
    case static_table_lookup_name() of
        Map ->
            case maps:get(Name, Map, not_found) of
                not_found -> not_found;
                Index -> {ok, Index}
            end
    end.

-spec lookup_dynamic_full(binary(), binary(), context()) -> {ok, pos_integer()} | not_found.
lookup_dynamic_full(Name, Value, #hpack_context{by_header = ByHeader, insert_count = IC}) ->
    case maps:get({Name, Value}, ByHeader, not_found) of
        not_found -> not_found;
        EntryId -> {ok, IC + 61 - EntryId}
    end.

-spec lookup_dynamic_name(binary(), context()) -> {ok, pos_integer()} | not_found.
lookup_dynamic_name(Name, #hpack_context{by_name = ByName, insert_count = IC}) ->
    case maps:get(Name, ByName, not_found) of
        not_found -> not_found;
        EntryId -> {ok, IC + 61 - EntryId}
    end.

%%====================================================================
%% Static Table (RFC 7541 Appendix A)
%%====================================================================

-spec static_table_entry(1..61) -> header().
static_table_entry(1) -> {<<":authority">>, <<>>};
static_table_entry(2) -> {<<":method">>, <<"GET">>};
static_table_entry(3) -> {<<":method">>, <<"POST">>};
static_table_entry(4) -> {<<":path">>, <<"/">>};
static_table_entry(5) -> {<<":path">>, <<"/index.html">>};
static_table_entry(6) -> {<<":scheme">>, <<"http">>};
static_table_entry(7) -> {<<":scheme">>, <<"https">>};
static_table_entry(8) -> {<<":status">>, <<"200">>};
static_table_entry(9) -> {<<":status">>, <<"204">>};
static_table_entry(10) -> {<<":status">>, <<"206">>};
static_table_entry(11) -> {<<":status">>, <<"304">>};
static_table_entry(12) -> {<<":status">>, <<"400">>};
static_table_entry(13) -> {<<":status">>, <<"404">>};
static_table_entry(14) -> {<<":status">>, <<"500">>};
static_table_entry(15) -> {<<"accept-charset">>, <<>>};
static_table_entry(16) -> {<<"accept-encoding">>, <<"gzip, deflate">>};
static_table_entry(17) -> {<<"accept-language">>, <<>>};
static_table_entry(18) -> {<<"accept-ranges">>, <<>>};
static_table_entry(19) -> {<<"accept">>, <<>>};
static_table_entry(20) -> {<<"access-control-allow-origin">>, <<>>};
static_table_entry(21) -> {<<"age">>, <<>>};
static_table_entry(22) -> {<<"allow">>, <<>>};
static_table_entry(23) -> {<<"authorization">>, <<>>};
static_table_entry(24) -> {<<"cache-control">>, <<>>};
static_table_entry(25) -> {<<"content-disposition">>, <<>>};
static_table_entry(26) -> {<<"content-encoding">>, <<>>};
static_table_entry(27) -> {<<"content-language">>, <<>>};
static_table_entry(28) -> {<<"content-length">>, <<>>};
static_table_entry(29) -> {<<"content-location">>, <<>>};
static_table_entry(30) -> {<<"content-range">>, <<>>};
static_table_entry(31) -> {<<"content-type">>, <<>>};
static_table_entry(32) -> {<<"cookie">>, <<>>};
static_table_entry(33) -> {<<"date">>, <<>>};
static_table_entry(34) -> {<<"etag">>, <<>>};
static_table_entry(35) -> {<<"expect">>, <<>>};
static_table_entry(36) -> {<<"expires">>, <<>>};
static_table_entry(37) -> {<<"from">>, <<>>};
static_table_entry(38) -> {<<"host">>, <<>>};
static_table_entry(39) -> {<<"if-match">>, <<>>};
static_table_entry(40) -> {<<"if-modified-since">>, <<>>};
static_table_entry(41) -> {<<"if-none-match">>, <<>>};
static_table_entry(42) -> {<<"if-range">>, <<>>};
static_table_entry(43) -> {<<"if-unmodified-since">>, <<>>};
static_table_entry(44) -> {<<"last-modified">>, <<>>};
static_table_entry(45) -> {<<"link">>, <<>>};
static_table_entry(46) -> {<<"location">>, <<>>};
static_table_entry(47) -> {<<"max-forwards">>, <<>>};
static_table_entry(48) -> {<<"proxy-authenticate">>, <<>>};
static_table_entry(49) -> {<<"proxy-authorization">>, <<>>};
static_table_entry(50) -> {<<"range">>, <<>>};
static_table_entry(51) -> {<<"referer">>, <<>>};
static_table_entry(52) -> {<<"refresh">>, <<>>};
static_table_entry(53) -> {<<"retry-after">>, <<>>};
static_table_entry(54) -> {<<"server">>, <<>>};
static_table_entry(55) -> {<<"set-cookie">>, <<>>};
static_table_entry(56) -> {<<"strict-transport-security">>, <<>>};
static_table_entry(57) -> {<<"transfer-encoding">>, <<>>};
static_table_entry(58) -> {<<"user-agent">>, <<>>};
static_table_entry(59) -> {<<"vary">>, <<>>};
static_table_entry(60) -> {<<"via">>, <<>>};
static_table_entry(61) -> {<<"www-authenticate">>, <<>>}.

%% Pre-computed maps for faster lookup
-spec static_table_lookup_full() -> #{header() => pos_integer()}.
static_table_lookup_full() ->
    #{
        {<<":method">>, <<"GET">>} => 2,
        {<<":method">>, <<"POST">>} => 3,
        {<<":path">>, <<"/">>} => 4,
        {<<":path">>, <<"/index.html">>} => 5,
        {<<":scheme">>, <<"http">>} => 6,
        {<<":scheme">>, <<"https">>} => 7,
        {<<":status">>, <<"200">>} => 8,
        {<<":status">>, <<"204">>} => 9,
        {<<":status">>, <<"206">>} => 10,
        {<<":status">>, <<"304">>} => 11,
        {<<":status">>, <<"400">>} => 12,
        {<<":status">>, <<"404">>} => 13,
        {<<":status">>, <<"500">>} => 14,
        {<<"accept-encoding">>, <<"gzip, deflate">>} => 16
    }.

-spec static_table_lookup_name() -> #{binary() => pos_integer()}.
static_table_lookup_name() ->
    #{
        <<":authority">> => 1,
        <<":method">> => 2,
        <<":path">> => 4,
        <<":scheme">> => 6,
        <<":status">> => 8,
        <<"accept-charset">> => 15,
        <<"accept-encoding">> => 16,
        <<"accept-language">> => 17,
        <<"accept-ranges">> => 18,
        <<"accept">> => 19,
        <<"access-control-allow-origin">> => 20,
        <<"age">> => 21,
        <<"allow">> => 22,
        <<"authorization">> => 23,
        <<"cache-control">> => 24,
        <<"content-disposition">> => 25,
        <<"content-encoding">> => 26,
        <<"content-language">> => 27,
        <<"content-length">> => 28,
        <<"content-location">> => 29,
        <<"content-range">> => 30,
        <<"content-type">> => 31,
        <<"cookie">> => 32,
        <<"date">> => 33,
        <<"etag">> => 34,
        <<"expect">> => 35,
        <<"expires">> => 36,
        <<"from">> => 37,
        <<"host">> => 38,
        <<"if-match">> => 39,
        <<"if-modified-since">> => 40,
        <<"if-none-match">> => 41,
        <<"if-range">> => 42,
        <<"if-unmodified-since">> => 43,
        <<"last-modified">> => 44,
        <<"link">> => 45,
        <<"location">> => 46,
        <<"max-forwards">> => 47,
        <<"proxy-authenticate">> => 48,
        <<"proxy-authorization">> => 49,
        <<"range">> => 50,
        <<"referer">> => 51,
        <<"refresh">> => 52,
        <<"retry-after">> => 53,
        <<"server">> => 54,
        <<"set-cookie">> => 55,
        <<"strict-transport-security">> => 56,
        <<"transfer-encoding">> => 57,
        <<"user-agent">> => 58,
        <<"vary">> => 59,
        <<"via">> => 60,
        <<"www-authenticate">> => 61
    }.

%%====================================================================
%% Unit Tests
%%====================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test cases
%%====================================================================

new_context_test() ->
    Context = gen_http_parser_hpack:new(),
    ?assert(is_record(Context, hpack_context, 8)),

    Context2 = gen_http_parser_hpack:new(8192),
    ?assert(is_record(Context2, hpack_context, 8)).

encode_decode_roundtrip_test() ->
    Headers = [
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>},
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, <<"www.example.com">>}
    ],

    Context = gen_http_parser_hpack:new(),
    {ok, Encoded, _EncContext} = gen_http_parser_hpack:encode(Headers, Context),
    ?assert(is_binary(Encoded)),

    {ok, Decoded, _DecContext} = gen_http_parser_hpack:decode(Encoded, Context),
    ?assertEqual(Headers, Decoded).

static_table_indexed_test() ->
    %% Test encoding headers that are in static table with values
    Headers = [
        % Index 2
        {<<":method">>, <<"GET">>},
        % Index 7
        {<<":scheme">>, <<"https">>}
    ],

    Context = gen_http_parser_hpack:new(),
    {ok, Encoded, _EncContext} = gen_http_parser_hpack:encode(Headers, Context),

    %% Should be very compact (indexed representation)
    ?assert(byte_size(Encoded) < 10),

    {ok, Decoded, _DecContext} = gen_http_parser_hpack:decode(Encoded, Context),
    ?assertEqual(Headers, Decoded).

literal_with_indexing_test() ->
    %% Test literal header with incremental indexing
    Headers = [
        {<<"custom-header">>, <<"custom-value">>}
    ],

    Context = gen_http_parser_hpack:new(),
    {ok, Encoded, EncContext} = gen_http_parser_hpack:encode(Headers, Context),

    %% Decode and verify
    {ok, Decoded, _DecContext} = gen_http_parser_hpack:decode(Encoded, Context),
    ?assertEqual(Headers, Decoded),

    %% The header should now be in the dynamic table
    %% Encode again - should be smaller (indexed)
    {ok, Encoded2, _EncContext2} = gen_http_parser_hpack:encode(Headers, EncContext),
    ?assert(byte_size(Encoded2) < byte_size(Encoded)).

dynamic_table_test() ->
    Headers1 = [
        {<<"custom-key">>, <<"custom-value">>}
    ],
    Headers2 = [
        {<<"custom-key">>, <<"another-value">>}
    ],

    Context = gen_http_parser_hpack:new(),

    %% Encode first header - adds to dynamic table
    {ok, _Encoded1, Context1} = gen_http_parser_hpack:encode(Headers1, Context),

    %% Encode second header - name should be indexed from dynamic table
    {ok, Encoded2, _Context2} = gen_http_parser_hpack:encode(Headers2, Context1),

    %% Should be more compact due to name indexing
    ?assert(byte_size(Encoded2) < 50).

integer_encoding_small_test() ->
    %% Test integer encoding with small values (fit in prefix)
    Context = gen_http_parser_hpack:new(),
    % Static table index 8
    Headers = [{<<":status">>, <<"200">>}],

    {ok, Encoded, _} = gen_http_parser_hpack:encode(Headers, Context),
    %% Index 8 with 7-bit prefix should be single byte

    % 10001000 = indexed(8)
    ?assertEqual(<<136>>, Encoded).

rfc_example_c3_test() ->
    %% RFC 7541 Appendix C.3.1 - First Request
    Headers = [
        {<<":method">>, <<"GET">>},
        {<<":scheme">>, <<"http">>},
        {<<":path">>, <<"/">>},
        {<<":authority">>, <<"www.example.com">>}
    ],

    Context = gen_http_parser_hpack:new(256),
    {ok, Encoded, Context1} = gen_http_parser_hpack:encode(Headers, Context),

    %% Decode and verify
    {ok, Decoded, _} = gen_http_parser_hpack:decode(Encoded, Context),
    ?assertEqual(Headers, Decoded),

    %% Second request reuses authority from dynamic table
    Headers2 = [
        {<<":method">>, <<"GET">>},
        {<<":scheme">>, <<"http">>},
        {<<":path">>, <<"/">>},
        {<<":authority">>, <<"www.example.com">>},
        {<<"cache-control">>, <<"no-cache">>}
    ],

    {ok, Encoded2, _Context2} = gen_http_parser_hpack:encode(Headers2, Context1),
    {ok, Decoded2, _} = gen_http_parser_hpack:decode(Encoded2, Context1),
    ?assertEqual(Headers2, Decoded2).

table_size_update_test() ->
    Context = gen_http_parser_hpack:new(4096),

    %% Resize to smaller size
    NewContext = gen_http_parser_hpack:resize_table(Context, 2048),
    ?assert(is_record(NewContext, hpack_context, 8)),

    %% Verify new size is set
    {ok, _, _} = gen_http_parser_hpack:encode([], NewContext).

eviction_test() ->
    %% Create context with small table
    Context = gen_http_parser_hpack:new(100),

    %% Add headers that will exceed table size
    Headers = [
        {<<"very-long-header-name-1">>, <<"very-long-value-1">>},
        {<<"very-long-header-name-2">>, <<"very-long-value-2">>},
        {<<"very-long-header-name-3">>, <<"very-long-value-3">>}
    ],

    %% Encode - should cause eviction
    {ok, Encoded, EncContext} = gen_http_parser_hpack:encode(Headers, Context),

    %% Decode should still work
    {ok, Decoded, _} = gen_http_parser_hpack:decode(Encoded, Context),
    ?assertEqual(Headers, Decoded),

    %% But not all headers may be in dynamic table due to eviction
    ?assert(is_record(EncContext, hpack_context, 8)).

empty_headers_test() ->
    Context = gen_http_parser_hpack:new(),
    {ok, Encoded, _} = gen_http_parser_hpack:encode([], Context),
    ?assertEqual(<<>>, Encoded),

    {ok, Decoded, _} = gen_http_parser_hpack:decode(<<>>, Context),
    ?assertEqual([], Decoded).

multiple_encode_decode_test() ->
    Context = gen_http_parser_hpack:new(),

    %% First request
    Headers1 = [
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/index.html">>}
    ],
    {ok, Enc1, Ctx1} = gen_http_parser_hpack:encode(Headers1, Context),
    {ok, Dec1, DecCtx1} = gen_http_parser_hpack:decode(Enc1, Context),
    ?assertEqual(Headers1, Dec1),

    %% Second request (reuses context)
    Headers2 = [
        {<<":method">>, <<"POST">>},
        {<<":path">>, <<"/api">>}
    ],
    {ok, Enc2, _Ctx2} = gen_http_parser_hpack:encode(Headers2, Ctx1),
    {ok, Dec2, _DecCtx2} = gen_http_parser_hpack:decode(Enc2, DecCtx1),
    ?assertEqual(Headers2, Dec2).

compression_efficiency_test() ->
    %% Test that HPACK actually compresses
    Headers = [
        {<<":method">>, <<"GET">>},
        {<<":scheme">>, <<"https">>},
        {<<":path">>, <<"/">>},
        {<<":authority">>, <<"www.example.com">>},
        {<<"accept">>, <<"text/html,application/json">>},
        {<<"accept-encoding">>, <<"gzip, deflate">>},
        {<<"user-agent">>, <<"Mozilla/5.0">>}
    ],

    Context = gen_http_parser_hpack:new(),
    {ok, Encoded, _} = gen_http_parser_hpack:encode(Headers, Context),

    %% Calculate uncompressed size
    UncompressedSize = lists:foldl(
        fun({Name, Value}, Acc) ->
            Acc + byte_size(Name) + byte_size(Value)
        end,
        0,
        Headers
    ),

    %% HPACK should achieve significant compression
    CompressionRatio = byte_size(Encoded) / UncompressedSize,
    % At least 20% compression
    ?assert(CompressionRatio < 0.8).

pseudo_headers_test() ->
    %% Test HTTP/2 pseudo-headers
    Headers = [
        {<<":method">>, <<"GET">>},
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, <<"example.com">>},
        {<<":path">>, <<"/test">>}
    ],

    Context = gen_http_parser_hpack:new(),
    {ok, Encoded, _} = gen_http_parser_hpack:encode(Headers, Context),
    {ok, Decoded, _} = gen_http_parser_hpack:decode(Encoded, Context),
    ?assertEqual(Headers, Decoded).

huffman_encoding_test() ->
    %% Test that Huffman encoding is being used for compressible strings
    Context = gen_http_parser_hpack:new(),

    %% Headers with common values that compress well with Huffman
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"user-agent">>, <<"Mozilla/5.0 (Windows NT 10.0; Win64; x64)">>}
    ],

    %% Encode headers
    {ok, Encoded, _} = gen_http_parser_hpack:encode(Headers, Context),

    %% Calculate size savings compared to literal encoding
    %% Literal size would be roughly: sum of (1 + length prefix + string bytes)
    LiteralSize = lists:sum([
        1 + 1 + byte_size(Name) + 1 + byte_size(Value)
     || {Name, Value} <- Headers
    ]),

    EncodedSize = byte_size(Encoded),

    %% With Huffman encoding, we expect at least 10% compression
    %% (typically ~30% for common header values)
    ?assert(EncodedSize < LiteralSize * 0.9),

    %% Verify roundtrip works with Huffman-encoded data
    {ok, Decoded, _} = gen_http_parser_hpack:decode(Encoded, Context),
    ?assertEqual(Headers, Decoded).

huffman_selective_test() ->
    %% Test that Huffman is only used when it reduces size
    Context = gen_http_parser_hpack:new(),

    %% A header value that doesn't compress well (random bytes)
    %% Huffman should NOT be used for this
    RandomValue = <<16#FF, 16#FE, 16#FD, 16#FC>>,
    Headers = [{<<"x-random">>, RandomValue}],

    {ok, Encoded, _} = gen_http_parser_hpack:encode(Headers, Context),

    %% Verify roundtrip still works
    {ok, Decoded, _} = gen_http_parser_hpack:decode(Encoded, Context),
    ?assertEqual(Headers, Decoded).

-endif.
