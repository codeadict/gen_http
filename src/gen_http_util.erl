-module(gen_http_util).

-export([scheme_to_transport/1]).

scheme_to_transport(http) ->
    gen_http_tcp;
scheme_to_transport(https) ->
    gen_http_ssl;
scheme_to_transport(Module) when is_atom(Module) ->
    Module.
