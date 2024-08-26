-module(gen_http_headers).

-export([from_raw/1, find/2, remove_unallowed_trailer/1]).

-type raw() :: {OriginalName :: binary(), Value :: binary()}.
-type canonical() ::
    {OriginalName :: binary(), CanonicalName :: binary(), Value :: binary()}.

%% Control headers (https://svn.tools.ietf.org/svn/wg/httpbis/specs/rfc7231.html#rfc.section.5.1)
%% Conditionals (https://svn.tools.ietf.org/svn/wg/httpbis/specs/rfc7231.html#rfc.section.5.2)
%% Authentication/authorization (https://tools.ietf.org/html/rfc7235#section-5.3)
%% Cookie management (https://tools.ietf.org/html/rfc6265)
%% Control data (https://svn.tools.ietf.org/svn/wg/httpbis/specs/rfc7231.html#rfc.section.7.1)
-define(DISALLOWED_TRAILERS,
    sets:from_list([
        "content-encoding",
        "content-range",
        "content-type",
        "trailer",
        "transfer-encoding",
        "cache-control",
        "expect",
        "host",
        "max-forwards",
        "pragma",
        "range",
        "te",
        "if-match",
        "if-unmodified-since",
        "if-range",
        "authorization",
        "proxy-authenticate",
        "proxy-authorization",
        "www-authenticate",
        "cookie",
        "set-cookie",
        "age",
        "cache-control",
        "expires",
        "date",
        "location",
        "retry-after",
        "vary",
        "warning"
    ])
).

-spec from_raw([raw()]) -> [canonical()].
from_raw(Headers) ->
    lists:map(fun({Name, Val}) -> {Name, string:lowercase(Name), Val} end, Headers).

-spec find([canonical()], binary()) -> {binary(), binary()} | false.
find(Name, Headers) ->
    case lists:keyfind(Name, 2, Headers) of
        false -> false;
        {FoundName, _, FoundValue} -> {FoundName, FoundValue}
    end.

-spec remove_unallowed_trailer([raw()]) -> [raw()].
remove_unallowed_trailer(Headers) ->
    lists:filter(
        fun({Name, _Val}) -> sets:is_element(Name, ?DISALLOWED_TRAILERS) /= true end,
        Headers
    ).
