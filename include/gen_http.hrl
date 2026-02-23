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
    | {done, request_ref()}.
-type socket() :: term().

-define(DEFAULT_PROTOCOLS, [http1, http2]).
