-module(prop_gen_http_parser_h1).

-include_lib("proper/include/proper.hrl").
-include_lib("stdlib/include/assert.hrl").

prop_encoded_chunk_always_contains_at_least_two_crlfs() ->
    ?FORALL(Chunk, iodata(), begin
        Encoded = gen_http_parser_h1:encode_chunk(Chunk),
        %% Flatten iolist to binary to count CRLFs
        Binary = iolist_to_binary(Encoded),
        %% Count occurrences of "\r\n"
        CrlfCount = count_crlf(Binary),
        %% HTTP chunked encoding always has at least 2 CRLFs:
        %% one after the size, one after the chunk data
        ?assert(CrlfCount >= 2),
        true
    end).

-spec count_crlf(binary()) -> non_neg_integer().
count_crlf(Binary) ->
    count_crlf(Binary, 0).

-spec count_crlf(binary(), non_neg_integer()) -> non_neg_integer().
count_crlf(<<"\r\n", Rest/binary>>, Count) ->
    count_crlf(Rest, Count + 1);
count_crlf(<<_:8, Rest/binary>>, Count) ->
    count_crlf(Rest, Count);
count_crlf(<<>>, Count) ->
    Count.
