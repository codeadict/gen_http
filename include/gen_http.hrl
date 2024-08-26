-type scheme() :: http | https.
-type address() :: inet:socket_address() | bitstring().
-type status() :: non_neg_integer().
-type headers() :: [{binary(), binary()}].
-type request_ref() :: reference().
-type http2_response() ::
    {pong, request_ref()} | {push_promise, request_ref(), headers()}.
-type response() :: {status, request_ref(), status()}.
-type socket() :: term().

-define(DEFAULT_PROTOCOLS, [http1, http2]).
