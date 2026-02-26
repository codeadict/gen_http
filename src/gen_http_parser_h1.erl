-module(gen_http_parser_h1).

%% Compiler optimizations
-compile(inline).
-compile({inline_size, 128}).

-export([
    decode_response_status_line/1,
    decode_response_header/1,
    encode_chunk/1,
    encode_request/4
]).

-export_type([
    http_version/0,
    status_code/0,
    reason_phrase/0,
    header_name/0,
    header_value/0
]).

-type http_version() :: {non_neg_integer(), non_neg_integer()}.
-type status_code() :: non_neg_integer().
-type reason_phrase() :: binary().
-type header_name() :: binary().
-type header_value() :: binary().

-define(IS_DIGIT(Val), (Val >= $0 andalso Val =< $9)).
-define(IS_ALPHA(Val), ((Val >= $A andalso Val =< $Z) orelse (Val >= $a andalso Val =< $z))).
-define(IS_HEX(Val),
    (?IS_DIGIT(Val) orelse (Val >= $A andalso Val =< $F) orelse (Val >= $a andalso Val =< $f))
).

%%%=========================================================================
%%%  API
%%%=========================================================================

-spec encode_request(binary(), binary() | string(), [{binary(), binary()}], iodata() | undefined | stream) ->
    {ok, iodata()} | {error, term()}.
encode_request(Method, Target, Headers, Body) ->
    try
        {ok, [
            encode_request_line(Method, Target),
            encode_headers(Headers),
            $\r,
            $\n,
            encode_body(Body)
        ]}
    catch
        throw:{gen_http, Reason}:_Stacktrace ->
            {error, Reason}
    end.

-spec encode_chunk(eof | {eof, [{binary(), binary()}]} | iodata()) -> iodata().
encode_chunk(eof) ->
    [$0, $\r, $\n, $\r, $\n];
encode_chunk({eof, TrailingHeaders}) ->
    [$0, $\r, $\n, encode_headers(TrailingHeaders), $\r, $\n];
encode_chunk(Chunk) ->
    Length = erlang:iolist_size(Chunk),
    [integer_to_binary(Length, 16), $\r, $\n, Chunk, $\r, $\n].

-spec decode_response_status_line(binary()) ->
    {ok, {http_version(), status_code(), reason_phrase()}, binary()} | more | error.
decode_response_status_line(Data) ->
    case erlang:decode_packet(http_bin, Data, []) of
        {ok, {http_response, Version, Status, Reason}, Rest} ->
            {ok, {Version, Status, Reason}, Rest};
        {ok, _Other, _Rest} ->
            error;
        {more, _Length} ->
            more;
        {error, _Reason} ->
            error
    end.

-spec decode_response_header(binary()) ->
    {ok, {header_name(), header_value()}, binary()} | {ok, eof, binary()} | more | error.
decode_response_header(Data) ->
    case erlang:decode_packet(httph_bin, Data, []) of
        {ok, {http_header, _, Name, _Reserved, Value}, Rest} ->
            {ok, {header_name(Name), Value}, Rest};
        {ok, http_eoh, Rest} ->
            {ok, eof, Rest};
        {ok, _Other, _Rest} ->
            error;
        {more, _Length} ->
            more;
        {error, _Reason} ->
            error
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec header_name(atom() | binary()) -> binary().
%% Pre-mapped common HTTP response headers — avoids atom_to_binary + string:lowercase
%% per response. erlang:decode_packet returns atoms for well-known headers.
header_name('Cache-Control') ->
    <<"cache-control">>;
header_name('Connection') ->
    <<"connection">>;
header_name('Content-Encoding') ->
    <<"content-encoding">>;
header_name('Content-Length') ->
    <<"content-length">>;
header_name('Content-Type') ->
    <<"content-type">>;
header_name('Date') ->
    <<"date">>;
header_name('Etag') ->
    <<"etag">>;
header_name('Expires') ->
    <<"expires">>;
header_name('Last-Modified') ->
    <<"last-modified">>;
header_name('Location') ->
    <<"location">>;
header_name('Server') ->
    <<"server">>;
header_name('Set-Cookie') ->
    <<"set-cookie">>;
header_name('Transfer-Encoding') ->
    <<"transfer-encoding">>;
header_name('Vary') ->
    <<"vary">>;
header_name('Accept-Ranges') ->
    <<"accept-ranges">>;
header_name('Age') ->
    <<"age">>;
header_name('Access-Control-Allow-Origin') ->
    <<"access-control-allow-origin">>;
header_name('Content-Disposition') ->
    <<"content-disposition">>;
header_name('Strict-Transport-Security') ->
    <<"strict-transport-security">>;
header_name('X-Content-Type-Options') ->
    <<"x-content-type-options">>;
header_name(Name) when is_atom(Name) ->
    string:lowercase(atom_to_binary(Name, utf8));
header_name(Name) when is_binary(Name) ->
    string:lowercase(Name).

-spec encode_request_line(binary(), binary() | list()) -> iolist().
encode_request_line(Method, Target) ->
    validate_target(Target),
    [Method, $\s, Target, " HTTP/1.1", $\r, $\n].

-spec encode_headers([{binary() | atom(), binary() | list()}]) -> iolist().
encode_headers(Headers) ->
    lists:foldl(
        fun({Name, Value}, Acc) ->
            validate_header_name(Name),
            validate_header_value(Name, Value),
            [Acc, Name, $:, $\s, Value, $\r, $\n]
        end,
        <<>>,
        Headers
    ).

-spec encode_body(undefined | stream | iodata()) -> iodata().
encode_body(undefined) -> "";
encode_body(stream) -> "";
encode_body(Body) -> Body.

-spec validate_target(binary() | list()) -> ok.
validate_target(Target) when is_list(Target) ->
    validate_target(list_to_binary(Target));
validate_target(Target) ->
    validate_target(Target, Target).

-spec validate_target(binary(), binary()) -> ok.
validate_target(<<$%, Char1, Char2, Rest/binary>>, OriginalTarget) when
    ?IS_HEX(Char1) andalso ?IS_HEX(Char2)
->
    validate_target(Rest, OriginalTarget);
validate_target(<<Char, Rest/binary>>, OriginalTarget) ->
    case is_reserved(Char) orelse is_unreserved(Char) of
        true ->
            validate_target(Rest, OriginalTarget);
        false ->
            throw({gen_http, {invalid_request_target, OriginalTarget}})
    end;
validate_target(<<>>, _OriginalTarget) ->
    ok.

-spec validate_header_name(binary() | list()) -> ok.
validate_header_name(Name) when is_list(Name) ->
    validate_header_name(list_to_binary(Name));
validate_header_name(Name) ->
    validate_header_name_loop(Name, Name).

-spec validate_header_name_loop(binary(), binary()) -> ok.
validate_header_name_loop(<<>>, _Orig) ->
    ok;
validate_header_name_loop(<<Char, Rest/binary>>, Orig) ->
    case is_tchar(Char) of
        true -> validate_header_name_loop(Rest, Orig);
        false -> throw({gen_http, {invalid_header_name, Orig}})
    end.

-spec validate_header_value(binary() | list(), binary() | list()) -> ok.
validate_header_value(Name, Value) when is_list(Name) ->
    validate_header_value(list_to_binary(Name), Value);
validate_header_value(Name, Value) when is_list(Value) ->
    validate_header_value(Name, list_to_binary(Value));
validate_header_value(Name, Value) when is_binary(Name) andalso is_binary(Value) ->
    validate_header_value_loop(Name, Value, Value).

-spec validate_header_value_loop(binary(), binary(), binary()) -> ok.
validate_header_value_loop(_Name, <<>>, _Orig) ->
    ok;
validate_header_value_loop(Name, <<Char, Rest/binary>>, Orig) ->
    case is_vchar(Char) orelse Char =:= $\s orelse Char =:= $\t of
        true -> validate_header_value_loop(Name, Rest, Orig);
        false -> throw({gen_http, {invalid_header_value, Name, Orig}})
    end.

%%------------------------------------------------------------------------------------------
%% As specified in [RFC 3986, section 2.3](https://tools.ietf.org/html/rfc3986#section-2.3),
%% the following characters are unreserved:
%%
%%   unreserved  = ALPHA / DIGIT / "-" / "." / "_" / "~"
%%
%%------------------------------------------------------------------------------------------
-spec is_unreserved(char()) -> boolean().
is_unreserved($-) -> true;
is_unreserved($.) -> true;
is_unreserved($_) -> true;
is_unreserved($~) -> true;
is_unreserved(Char) when ?IS_ALPHA(Char) orelse ?IS_DIGIT(Char) -> true;
is_unreserved(_) -> false.

%%--------------------------------------------------------------------------------------------------
%%  Return true if input char is reserved.
%%
%%  As specified in:
%%
%%  [RFC 3986, Chapter 2.2. Reserved Characters](https://tools.ietf.org/html/rfc3986#section-2.2)
%%
%%   reserved    = gen-delims / sub-delims
%%
%%   gen-delims  = ":" / "/" / "?" / "#" / "[" / "]" / "@"
%%
%%   sub-delims  = "!" / "$" / "&" / "'" / "(" / ")"
%%               / "*" / "+" / "," / ";" / "="
%%
%%--------------------------------------------------------------------------------------------------
-spec is_reserved(char()) -> boolean().
is_reserved($:) -> true;
is_reserved($/) -> true;
is_reserved($?) -> true;
is_reserved($#) -> true;
is_reserved($[) -> true;
is_reserved($]) -> true;
is_reserved($@) -> true;
is_reserved($!) -> true;
is_reserved($$) -> true;
is_reserved($&) -> true;
is_reserved($') -> true;
is_reserved($() -> true;
is_reserved($)) -> true;
is_reserved($*) -> true;
is_reserved($+) -> true;
is_reserved($,) -> true;
is_reserved($;) -> true;
is_reserved($=) -> true;
is_reserved(_) -> false.

-spec is_tchar(byte()) -> boolean().
is_tchar(Char) when ?IS_ALPHA(Char) orelse ?IS_DIGIT(Char) -> true;
is_tchar($!) -> true;
is_tchar($#) -> true;
is_tchar($$) -> true;
is_tchar($%) -> true;
is_tchar($&) -> true;
is_tchar($') -> true;
is_tchar($*) -> true;
is_tchar($+) -> true;
is_tchar($-) -> true;
is_tchar($.) -> true;
is_tchar($^) -> true;
is_tchar($_) -> true;
is_tchar($`) -> true;
is_tchar($|) -> true;
is_tchar($~) -> true;
is_tchar(_) -> false.

-spec is_vchar(byte()) -> boolean().
is_vchar(Char) when Char >= 33 andalso Char =< 126 ->
    true;
is_vchar(_) ->
    false.

%%====================================================================
%% Unit Tests
%%====================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

encode_with_header_test() ->
    ?assertEqual(
        <<"GET / HTTP/1.1\r\nfoo: bar\r\n\r\n">>,
        encode_request_helper("GET", "/", [{"foo", "bar"}], undefined)
    ).

encode_with_invalid_header_name_test() ->
    ?assertEqual(
        {error, {invalid_header_name, <<"f oo">>}},
        encode_request("GET", "/", [{"f oo", "bar"}], undefined)
    ).

encode_with_invalid_header_value_test() ->
    ?assertEqual(
        {error, {invalid_header_value, <<"foo">>, <<"bar\r\n">>}},
        encode_request("GET", "/", [{"foo", "bar\r\n"}], undefined)
    ).

encode_with_invalid_target_test() ->
    Cases = [
        <<"/ /">>,
        <<"/%foo">>,
        <<"/foo%x">>
    ],
    [
        ?assertEqual(
            {error, {invalid_request_target, Target}},
            encode_request("GET", Target, [], undefined)
        )
     || Target <- Cases
    ].

encode_with_valid_target_test() ->
    ?assertEqual(
        <<"GET /foo%20bar HTTP/1.1\r\n\r\n">>,
        encode_request_helper("GET", "/foo%20bar", [], undefined)
    ).

encode_request_with_body_test() ->
    ?assertEqual(
        <<"GET / HTTP/1.1\r\n\r\nBODY">>,
        encode_request_helper("GET", "/", [], "BODY")
    ).

encode_request_with_body_and_headers_test() ->
    ?assertEqual(
        <<"GET / HTTP/1.1\r\nfoo: bar\r\n\r\nBODY">>,
        encode_request_helper("GET", "/", [{"foo", "bar"}], "BODY")
    ).

encode_chunk_with_eof_test() ->
    ?assertEqual(
        "0\r\n\r\n",
        encode_chunk(eof)
    ).

encode_chunk_with_iodata_test() ->
    Cases = [
        {"foo", <<"3\r\nfoo\r\n">>},
        {["hello ", $w, [[<<"or">>], $l], $d], <<"B\r\nhello world\r\n">>}
    ],

    [
        ?assertEqual(Expected, iolist_to_binary(encode_chunk(Input)))
     || {Input, Expected} <- Cases
    ].

encode_chunk_eof_with_trailers_test() ->
    Result = iolist_to_binary(encode_chunk({eof, [{<<"x-checksum">>, <<"abc">>}]})),
    ?assertEqual(<<"0\r\nx-checksum: abc\r\n\r\n">>, Result).

encode_request_stream_body_test() ->
    ?assertEqual(
        <<"GET / HTTP/1.1\r\n\r\n">>,
        encode_request_helper("GET", "/", [], stream)
    ).

decode_status_valid_test() ->
    ?assertMatch(
        {ok, {{1, 1}, 200, <<"OK">>}, <<"rest">>},
        decode_response_status_line(<<"HTTP/1.1 200 OK\r\nrest">>)
    ).

decode_status_not_response_test() ->
    %% A request line instead of a response triggers the _Other clause.
    ?assertEqual(error, decode_response_status_line(<<"GET / HTTP/1.1\r\n">>)).

decode_status_more_test() ->
    ?assertEqual(more, decode_response_status_line(<<"HTTP/1.1 2">>)).

decode_status_error_test() ->
    ?assertEqual(error, decode_response_status_line(<<0, 0, 13, 10>>)).

decode_header_known_atoms_test() ->
    %% Headers that OTP's decode_packet returns as atoms, exercising
    %% the header_name/1 atom clauses. Each input needs trailing data
    %% after \r\n so decode_packet doesn't return `more`.
    Cases = [
        {<<"Content-Type: text/html\r\n\r\n">>, <<"content-type">>, <<"text/html">>},
        {<<"Content-Length: 42\r\n\r\n">>, <<"content-length">>, <<"42">>},
        {<<"Server: nginx\r\n\r\n">>, <<"server">>, <<"nginx">>},
        {<<"Date: Mon, 01 Jan 2024\r\n\r\n">>, <<"date">>, <<"Mon, 01 Jan 2024">>},
        {<<"Cache-Control: no-cache\r\n\r\n">>, <<"cache-control">>, <<"no-cache">>},
        {<<"Connection: keep-alive\r\n\r\n">>, <<"connection">>, <<"keep-alive">>},
        {<<"Content-Encoding: gzip\r\n\r\n">>, <<"content-encoding">>, <<"gzip">>},
        {<<"Etag: \"abc\"\r\n\r\n">>, <<"etag">>, <<"\"abc\"">>},
        {<<"Expires: Thu, 01 Jan 2025\r\n\r\n">>, <<"expires">>, <<"Thu, 01 Jan 2025">>},
        {<<"Last-Modified: Fri, 02 Feb\r\n\r\n">>, <<"last-modified">>, <<"Fri, 02 Feb">>},
        {<<"Location: /new\r\n\r\n">>, <<"location">>, <<"/new">>},
        {<<"Set-Cookie: a=b\r\n\r\n">>, <<"set-cookie">>, <<"a=b">>},
        {<<"Transfer-Encoding: chunked\r\n\r\n">>, <<"transfer-encoding">>, <<"chunked">>},
        {<<"Vary: Accept\r\n\r\n">>, <<"vary">>, <<"Accept">>},
        {<<"Accept-Ranges: bytes\r\n\r\n">>, <<"accept-ranges">>, <<"bytes">>},
        {<<"Age: 600\r\n\r\n">>, <<"age">>, <<"600">>}
    ],
    lists:foreach(
        fun({Input, ExpName, ExpVal}) ->
            ?assertMatch({ok, {ExpName, ExpVal}, _}, decode_response_header(Input))
        end,
        Cases
    ).

decode_header_unknown_binary_test() ->
    %% Unknown header: decode_packet returns it as binary, exercises
    %% the is_binary clause of header_name/1.
    ?assertMatch(
        {ok, {<<"x-custom-header">>, <<"val">>}, _},
        decode_response_header(<<"X-Custom-Header: val\r\n\r\n">>)
    ).

decode_header_eof_test() ->
    ?assertMatch({ok, eof, _}, decode_response_header(<<"\r\nrest">>)).

decode_header_more_test() ->
    ?assertEqual(more, decode_response_header(<<"Content-Ty">>)).

encode_target_all_reserved_chars_test() ->
    %% Target containing all RFC 3986 reserved characters.
    Target = <<"/a:b?c=d&e#f@g[h]i!j$k'l(m)n*o+p,q;r">>,
    {ok, _} = encode_request(<<"GET">>, Target, [], undefined).

encode_target_unreserved_chars_test() ->
    Target = <<"/a-b.c_d~e">>,
    {ok, _} = encode_request(<<"GET">>, Target, [], undefined).

encode_header_tchar_chars_test() ->
    %% Header name with tchar characters beyond alpha/digit.
    Name = <<"x!#$%&'*+-.^_`|~z">>,
    {ok, _} = encode_request(<<"GET">>, <<"/">>, [{Name, <<"v">>}], undefined).

encode_request_helper(Method, Target, Headers, Body) ->
    {ok, IoData} = encode_request(Method, Target, Headers, Body),
    iolist_to_binary(IoData).

-endif.
