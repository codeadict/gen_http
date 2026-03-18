# Changelog

## 0.1.0

Initial release.

- HTTP/1.1 and HTTP/2 client support
- Unified API across both protocols via `gen_http` module
- ALPN protocol negotiation for HTTPS
- Active and passive socket modes
- Request pipelining (HTTP/1.1) and stream multiplexing (HTTP/2)
- HPACK header compression with Huffman coding
- Flow control (HTTP/2)
- Structured error types with retry classification
- Connection metadata via private key-value store
- TLS certificate verification enabled by default
