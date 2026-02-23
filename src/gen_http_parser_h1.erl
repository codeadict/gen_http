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

-define(IS_DIGIT(Val), Val >= $0 andalso Val =< $9).
-define(IS_ALPHA(Val), Val >= $A andalso Val =< $Z orelse Val >= $a andalso Val =< $z).
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
    [
        case is_tchar(Char) of
            true -> ok;
            false -> throw({gen_http, {invalid_header_name, Name}})
        end
     || <<Char>> <= Name
    ],
    ok.

-spec validate_header_value(binary() | list(), binary() | list()) -> ok.
validate_header_value(Name, Value) when is_list(Name) ->
    validate_header_value(list_to_binary(Name), Value);
validate_header_value(Name, Value) when is_list(Value) ->
    validate_header_value(Name, list_to_binary(Value));
validate_header_value(Name, Value) when is_binary(Name) andalso is_binary(Value) ->
    [
        case is_vchar(Char) orelse Char =:= $\s orelse Char =:= $\t of
            true -> ok;
            false -> throw({gen_http, {invalid_header_value, Name, Value}})
        end
     || <<Char>> <= Value
    ],
    ok.

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

encode_request_helper(Method, Target, Headers, Body) ->
    {ok, IoData} = encode_request(Method, Target, Headers, Body),
    iolist_to_binary(IoData).

-endif.
