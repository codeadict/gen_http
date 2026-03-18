# SSL Certificates

gen_http verifies server certificates by default. This page covers how
that works and how to customize it.

## Default Behavior

When you call `gen_http:connect(https, ...)`, the library:

1. Opens a TLS connection with `verify_peer` enabled
2. Loads CA certificates from the system store (OTP 25+ `public_key:cacerts_get/0`)
3. Validates the server certificate chain against those CAs
4. Checks hostname matching per RFC 6125

This means HTTPS connections fail if the server presents an invalid,
expired, or self-signed certificate. That's the right default.

## Custom CA Certificates

If you need to trust specific CAs (corporate proxies, internal services):

```erlang
{ok, Conn} = gen_http:connect(https, "internal.corp", 443, #{
    transport_opts => [
        {cacerts, MyCACerts}
    ]
}).
```

Where `MyCACerts` is a list of DER-encoded certificates. You can load
them from PEM files:

```erlang
{ok, PemBin} = file:read_file("/path/to/ca-bundle.pem"),
PemEntries = public_key:pem_decode(PemBin),
CACerts = [Der || {'Certificate', Der, _} <- PemEntries].
```

## Disabling Verification

For development and testing only:

```erlang
{ok, Conn} = gen_http:connect(https, "localhost", 4443, #{
    transport_opts => [
        {verify, verify_none}
    ]
}).
```

Don't ship this to production. Without verification, any server can
impersonate your target host.

## SNI (Server Name Indication)

gen_http sets SNI automatically when you connect using a hostname string.
This tells TLS servers which certificate to present -- needed for shared
hosting, CDNs, and reverse proxies.

SNI is not set when connecting to IP addresses directly, since SNI
requires a hostname.

## ALPN Protocol Negotiation

ALPN (Application-Layer Protocol Negotiation) happens during the TLS
handshake. gen_http advertises `h2` and `http/1.1` by default, and the
server picks which protocol to use.

You can control this with the `protocols` option:

```erlang
%% Only advertise HTTP/2
{ok, Conn} = gen_http:connect(https, "example.com", 443, #{
    protocols => [http2]
}).

%% Only advertise HTTP/1.1
{ok, Conn} = gen_http:connect(https, "example.com", 443, #{
    protocols => [http1]
}).
```

Or pass raw ALPN options through `transport_opts`:

```erlang
{ok, Conn} = gen_http:connect(https, "example.com", 443, #{
    transport_opts => [
        {alpn_advertise, [<<"h2">>]}
    ]
}).
```

## Session Reuse

gen_http enables TLS session reuse (`reuse_sessions`) by default. On
repeated connections to the same server, the TLS handshake skips the
full certificate exchange and uses a cached session. Faster reconnects,
less CPU overhead.

## Additional SSL Options

Pass any `ssl:connect/3` option through `transport_opts`:

```erlang
{ok, Conn} = gen_http:connect(https, "example.com", 443, #{
    transport_opts => [
        {depth, 3},
        {ciphers, [TlsCipher]},
        {versions, ['tlsv1.2', 'tlsv1.3']}
    ]
}).
```

See the OTP `ssl` module documentation for the full list of options.
