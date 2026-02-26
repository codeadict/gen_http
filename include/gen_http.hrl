-type scheme() :: http | https.
-type address() :: inet:socket_address() | inet:hostname().
-type status() :: non_neg_integer().
-type headers() :: [{binary(), binary()}].
-type request_ref() :: reference().
-type http2_response() ::
    {pong, request_ref()} | {push_promise, request_ref(), headers()}.
-type response() ::
    {status, request_ref(), status()}
    | {headers, request_ref(), headers()}
    | {data, request_ref(), binary()}
    | {trailers, request_ref(), headers()}
    | {done, request_ref()}
    | {error, request_ref(), term()}.
-type socket() :: gen_tcp:socket() | ssl:sslsocket().

-define(DEFAULT_PROTOCOLS, [http1, http2]).
