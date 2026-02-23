-module(prop_gen_http_parser_huffman).

-include_lib("proper/include/proper.hrl").
-include_lib("stdlib/include/assert.hrl").

%% -------------------------------------------------------------------
%% Huffman Encode/Decode Round-trip Property
%% -------------------------------------------------------------------

prop_huffman_encode_decode_roundtrip() ->
    ?FORALL(
        Input,
        printable_binary(),
        begin
            Encoded = gen_http_parser_huffman:encode(Input),
            %% Pad to byte boundary if needed
            Padded = pad_to_byte_boundary(Encoded),
            case gen_http_parser_huffman:decode(Padded) of
                {ok, Decoded} ->
                    ?assertEqual(Input, Decoded),
                    true;
                {error, _Reason} ->
                    %% Huffman encoding should never fail for valid input
                    false
            end
        end
    ).

%% -------------------------------------------------------------------
%% Compression Property - Common strings should compress well
%% -------------------------------------------------------------------

prop_huffman_compression_common_strings() ->
    ?FORALL(
        Input,
        oneof([
            <<"GET">>,
            <<"POST">>,
            <<"application/json">>,
            <<"text/html">>,
            <<"gzip, deflate">>,
            <<"www.example.com">>,
            <<"https">>,
            <<"http">>
        ]),
        begin
            Encoded = gen_http_parser_huffman:encode(Input),
            Padded = pad_to_byte_boundary(Encoded),
            %% Common HTTP strings should compress or stay similar size
            byte_size(Padded) =< byte_size(Input) + 1
        end
    ).

%% -------------------------------------------------------------------
%% Empty Input Property
%% -------------------------------------------------------------------

prop_huffman_empty_input() ->
    ?FORALL(
        Input,
        oneof([<<>>, <<"">>]),
        begin
            Encoded = gen_http_parser_huffman:encode(Input),
            ?assertEqual(<<>>, Encoded),
            true
        end
    ).

%% -------------------------------------------------------------------
%% Generators
%% -------------------------------------------------------------------

-spec printable_binary() -> proper_types:type().
printable_binary() ->
    ?LET(
        Chars,
        list(printable_char()),
        list_to_binary(Chars)
    ).

-spec printable_char() -> proper_types:type().
printable_char() ->
    %% HTTP header field values are typically printable ASCII (32-126)
    %% plus some common extended ASCII
    oneof(lists:seq(32, 126) ++ [9, 10, 13]).

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------

-spec pad_to_byte_boundary(bitstring()) -> binary().
pad_to_byte_boundary(Bits) ->
    case bit_size(Bits) rem 8 of
        0 ->
            Bits;
        Remainder ->
            Padding = 8 - Remainder,
            <<Bits/bitstring, 0:Padding>>
    end.
