# Testing gen_http

This directory contains tests for the gen_http HTTP client library.

## Test Infrastructure

Tests use a local Docker-based infrastructure instead of making requests to external websites. This provides:

- **Reliability**: Tests don't fail due to network issues
- **Speed**: Local requests are much faster
- **Control**: We control the test server behavior
- **Privacy**: No external requests during development

### Test Server Setup

The test infrastructure uses:

- **httpbin**: HTTP testing service (provides /get, /post, /status/*, etc.)
- **Caddy**: Reverse proxy providing HTTPS with self-signed certificates

## Running Tests

### 1. Start Test Infrastructure

```bash
# Start the test servers
docker compose -f test/support/docker-compose.yml up -d

# Check servers are healthy
docker compose -f test/support/docker-compose.yml ps

# View logs if needed
docker compose -f test/support/docker-compose.yml logs -f
```

### 2. Run Tests

```bash
# Run all unit tests
rebar3 eunit

# Run Common Test integration tests (requires docker servers)
rebar3 ct

# Run property-based tests
rebar3 proper

# Run all tests
rebar3 test

# Run HTTP/2 compliance tests (excluded by default - slow, requires special setup)
# Note: This requires the h2-test-harness-patched Docker image to be built
rebar3 ct --suite=h2_compliance_SUITE
```

### 3. Stop Test Infrastructure

```bash
# Stop and remove containers
docker compose -f test/support/docker-compose.yml down

# Stop and remove containers + volumes
docker compose -f test/support/docker-compose.yml down -v
```

## Test Server Endpoints

The local httpbin service provides the following endpoints:

- `GET /get` - Returns GET request data
- `POST /post` - Returns POST request data
- `GET /status/{code}` - Returns specified HTTP status code
- `GET /delay/{seconds}` - Delays response
- `GET /redirect/{n}` - 302 redirect n times
- `POST /anything` - Returns anything sent
- And many more (see [httpbin.org](https://httpbin.org/) for full API)

## Configuration

Test server ports can be configured via environment variables:

- `HTTPBIN_HTTP_PORT` (default: 8080) - HTTP server port
- `HTTPBIN_HTTPS_PORT` (default: 8443) - HTTPS server port

Create a `.env` file in the project root:

```bash
HTTPBIN_HTTP_PORT=8080
HTTPBIN_HTTPS_PORT=8443
```

## Troubleshooting

### Tests are skipped

If tests are being skipped with "Test server not available", ensure:

1. Docker Compose is running: `docker compose -f test/support/docker-compose.yml ps`
2. Services are healthy: `docker compose -f test/support/docker-compose.yml ps` (should show "healthy")
3. Ports are accessible: `curl http://localhost:8080/get`

### Port conflicts

If ports 8080 or 8443 are already in use:

1. Stop conflicting services
2. Or change ports in `.env` file
3. Restart Docker Compose

### SSL certificate errors

The Caddy server uses self-signed certificates for local testing. Tests should use the `verify_none` SSL option:

```erlang
{ok, Conn} = gen_http:connect(https, "localhost", 8443, #{
    transport_opts => [{verify, verify_none}]
}).
```

## Test Structure

- `test_helper.erl` - Common test utilities and server configuration
- `*_SUITE.erl` - Common Test suites (integration tests)
  - `features_SUITE.erl` - Feature tests
  - `http1_SUITE.erl` - HTTP/1.1 protocol tests
  - `http2_SUITE.erl` - HTTP/2 protocol tests
  - `ssl_SUITE.erl` - SSL/TLS tests
  - `unified_SUITE.erl` - Unified API tests
  - `h2_compliance_SUITE.erl` - HTTP/2 RFC compliance (excluded by default)
- `prop_*.erl` - Property-based tests using PropEr
