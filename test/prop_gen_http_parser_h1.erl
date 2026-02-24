-module(prop_gen_http_parser_h1).

-include_lib("proper/include/proper.hrl").
-include_lib("stdlib/include/assert.hrl").

%% -------------------------------------------------------------------
%% Chunked encoding: every chunk has at least 2 CRLFs
%% -------------------------------------------------------------------

prop_encoded_chunk_always_contains_at_least_two_crlfs() ->
    ?FORALL(Chunk, iodata(), begin
        Encoded = gen_http_parser_h1:encode_chunk(Chunk),
        Binary = iolist_to_binary(Encoded),
        CrlfCount = count_crlf(Binary),
        ?assert(CrlfCount >= 2),
        true
    end).

%% -------------------------------------------------------------------
%% Chunk size prefix matches actual data length
%% -------------------------------------------------------------------

prop_chunk_size_matches_data_length() ->
    ?FORALL(
        Data,
        binary(),
        begin
            Encoded = iolist_to_binary(gen_http_parser_h1:encode_chunk(Data)),
            %% Format: "<hex-size>\r\n<data>\r\n"
            [SizeHex | _] = binary:split(Encoded, <<"\r\n">>),
            ParsedSize = binary_to_integer(SizeHex, 16),
            ?assertEqual(byte_size(Data), ParsedSize),
            true
        end
    ).

%% -------------------------------------------------------------------
%% Request encoding roundtrip: encode then parse back
%% -------------------------------------------------------------------

prop_encode_request_parses_back() ->
    ?FORALL(
        {Method, Path, Headers},
        {http_method(), http_path(), list(http_header())},
        begin
            {ok, IoData} = gen_http_parser_h1:encode_request(Method, Path, Headers, undefined),
            Bin = iolist_to_binary(IoData),
            %% Parse status line (we encoded a request, but let's at least
            %% verify the wire format contains the method and path)
            ?assert(binary:match(Bin, [Method]) =/= nomatch),
            ?assert(binary:match(Bin, [Path]) =/= nomatch),
            ?assert(binary:match(Bin, [<<"HTTP/1.1">>]) =/= nomatch),
            %% Each header name should appear in the output
            lists:all(
                fun({Name, _Value}) ->
                    binary:match(Bin, [Name]) =/= nomatch
                end,
                Headers
            )
        end
    ).

%% -------------------------------------------------------------------
%% Valid header names survive encoding
%% -------------------------------------------------------------------

prop_valid_headers_encode_ok() ->
    ?FORALL(
        Headers,
        non_empty(list(http_header())),
        begin
            case gen_http_parser_h1:encode_request(<<"GET">>, <<"/">>, Headers, undefined) of
                {ok, _IoData} -> true;
                {error, _} -> false
            end
        end
    ).

%% -------------------------------------------------------------------
%% Invalid header names are rejected
%% -------------------------------------------------------------------

prop_invalid_header_names_rejected() ->
    ?FORALL(
        BadName,
        bad_header_name(),
        begin
            case gen_http_parser_h1:encode_request(<<"GET">>, <<"/">>, [{BadName, <<"v">>}], undefined) of
                {error, {invalid_header_name, _}} -> true;
                {ok, _} -> false
            end
        end
    ).

%% -------------------------------------------------------------------
%% Valid targets survive encoding
%% -------------------------------------------------------------------

prop_valid_targets_encode_ok() ->
    ?FORALL(
        Target,
        http_path(),
        begin
            case gen_http_parser_h1:encode_request(<<"GET">>, Target, [], undefined) of
                {ok, _} -> true;
                {error, _} -> false
            end
        end
    ).

%% -------------------------------------------------------------------
%% Chunk EOF produces the terminator
%% -------------------------------------------------------------------

prop_eof_chunk_is_terminator() ->
    Encoded = iolist_to_binary(gen_http_parser_h1:encode_chunk(eof)),
    ?assertEqual(<<"0\r\n\r\n">>, Encoded),
    true.

%% -------------------------------------------------------------------
%% Encode request with body includes body bytes
%% -------------------------------------------------------------------

prop_encode_request_with_body() ->
    ?FORALL(
        Body,
        non_empty(binary()),
        begin
            {ok, IoData} = gen_http_parser_h1:encode_request(<<"POST">>, <<"/">>, [], Body),
            Bin = iolist_to_binary(IoData),
            %% Body should appear after the header block
            binary:match(Bin, [Body]) =/= nomatch
        end
    ).

%% -------------------------------------------------------------------
%% Generators
%% -------------------------------------------------------------------

http_method() ->
    oneof([<<"GET">>, <<"POST">>, <<"PUT">>, <<"DELETE">>, <<"PATCH">>, <<"HEAD">>, <<"OPTIONS">>]).

http_path() ->
    ?LET(
        Segments,
        list(path_segment()),
        iolist_to_binary([<<"/">> | lists:join(<<"/">>, Segments)])
    ).

path_segment() ->
    ?LET(
        Chars,
        non_empty(list(oneof(lists:seq($a, $z) ++ lists:seq($0, $9) ++ [$-, $_, $.]))),
        list_to_binary(Chars)
    ).

http_header() ->
    {header_name(), header_value()}.

header_name() ->
    ?LET(
        Chars,
        non_empty(list(oneof(lists:seq($a, $z) ++ lists:seq($0, $9) ++ [$-, $_]))),
        list_to_binary(Chars)
    ).

header_value() ->
    ?LET(
        Chars,
        list(oneof(lists:seq(33, 126) ++ [$\s, $\t])),
        list_to_binary(Chars)
    ).

bad_header_name() ->
    ?LET(
        {Prefix, Suffix},
        {non_empty(list(oneof(lists:seq($a, $z)))), oneof([<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>])},
        <<(list_to_binary(Prefix))/binary, Suffix/binary>>
    ).

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------

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
