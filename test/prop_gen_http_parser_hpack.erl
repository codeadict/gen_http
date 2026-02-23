-module(prop_gen_http_parser_hpack).

-include_lib("proper/include/proper.hrl").
-include_lib("stdlib/include/assert.hrl").

%% -------------------------------------------------------------------
%% HPACK Encode/Decode Round-trip Property
%% -------------------------------------------------------------------

prop_hpack_encode_decode_roundtrip() ->
    ?FORALL(
        Headers,
        list(header()),
        begin
            Ctx = gen_http_parser_hpack:new(),
            {ok, Encoded, _CtxAfterEncode} = gen_http_parser_hpack:encode(Headers, Ctx),
            {ok, Decoded, _CtxAfterDecode} = gen_http_parser_hpack:decode(Encoded, Ctx),
            ?assertEqual(Headers, Decoded),
            true
        end
    ).

%% -------------------------------------------------------------------
%% Header Name Property - Names must be lowercase
%% -------------------------------------------------------------------

prop_header_names_are_lowercase() ->
    ?FORALL(
        Headers,
        list(header()),
        begin
            lists:all(
                fun({Name, _Value}) ->
                    binary_to_list(Name) =:= string:lowercase(binary_to_list(Name))
                end,
                Headers
            )
        end
    ).

%% -------------------------------------------------------------------
%% Dynamic Table Property - Headers with same context should work
%% -------------------------------------------------------------------

prop_hpack_with_dynamic_table() ->
    ?FORALL(
        HeadersList,
        non_empty(list(list(header()))),
        begin
            %% Encode and decode multiple header sets with same context
            Ctx0 = gen_http_parser_hpack:new(),
            encode_decode_sequence(HeadersList, Ctx0, Ctx0)
        end
    ).

-spec encode_decode_sequence([gen_http_parser_hpack:headers()], term(), term()) -> boolean().
encode_decode_sequence([], _EncodeCtx, _DecodeCtx) ->
    true;
encode_decode_sequence([Headers | Rest], EncodeCtx, DecodeCtx) ->
    case gen_http_parser_hpack:encode(Headers, EncodeCtx) of
        {ok, Encoded, EncodeCtx2} ->
            case gen_http_parser_hpack:decode(Encoded, DecodeCtx) of
                {ok, Decoded, DecodeCtx2} ->
                    case Headers =:= Decoded of
                        true -> encode_decode_sequence(Rest, EncodeCtx2, DecodeCtx2);
                        false -> false
                    end;
                {error, _} ->
                    false
            end;
        {error, _} ->
            false
    end.

%% -------------------------------------------------------------------
%% Generators
%% -------------------------------------------------------------------

-spec header() -> proper_types:type().
header() ->
    {header_name(), header_value()}.

-spec header_name() -> proper_types:type().
header_name() ->
    ?LET(
        Name,
        oneof([
            %% Common header names
            <<"content-type">>,
            <<"content-length">>,
            <<"user-agent">>,
            <<"accept">>,
            <<"accept-encoding">>,
            <<"cache-control">>,
            <<"authorization">>,
            <<"host">>,
            %% HTTP/2 pseudo-headers
            <<":method">>,
            <<":scheme">>,
            <<":authority">>,
            <<":path">>,
            <<":status">>,
            %% Random lowercase header name
            ?LET(
                Chars,
                non_empty(list(oneof(lists:seq($a, $z) ++ [$-]))),
                list_to_binary(Chars)
            )
        ]),
        Name
    ).

-spec header_value() -> proper_types:type().
header_value() ->
    ?LET(
        Value,
        oneof([
            %% Common values
            <<"application/json">>,
            <<"text/html">>,
            <<"gzip, deflate">>,
            <<"GET">>,
            <<"POST">>,
            <<"https">>,
            <<"http">>,
            <<"/">>,
            <<"200">>,
            <<"404">>,
            %% Random printable ASCII value
            ?LET(
                Chars,
                list(oneof(lists:seq(32, 126))),
                list_to_binary(Chars)
            )
        ]),
        Value
    ).
