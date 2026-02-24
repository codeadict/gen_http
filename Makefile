.PHONY: help compile test test-integration test-unit test-proper clean dialyzer xref format \
	server-start server-stop server-status server-logs server-health

help:  ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

compile: ## Compile the project
	rebar3 compile

clean: ## Clean build artifacts
	rebar3 clean

format: ## Format code with erlfmt
	rebar3 fmt -w

test: rebar3 test ## Run all tests (requires test server)

dialyzer: ## Run Dialyzer type checker
	rebar3 dialyzer

xref: ## Run cross-reference analysis
	rebar3 xref

# Test server management
server-start: ## Start test server (Docker Compose)
	@echo "Starting test server..."
	docker compose -f test/support/docker-compose.yml up -d
	@echo "Waiting for services to be healthy..."
	@timeout 30 sh -c 'until docker compose -f test/support/docker-compose.yml ps | grep -q "(healthy)"; do sleep 1; done' || \
		(echo "Timeout waiting for services" && exit 1)
	@echo "✓ Test server ready at http://localhost:8080 and https://localhost:8443"

server-stop: ## Stop test server
	docker compose -f test/support/docker-compose.yml down

server-status: ## Show test server status
	docker compose -f test/support/docker-compose.yml ps

server-logs: ## Show test server logs
	docker compose -f test/support/docker-compose.yml logs -f

server-health: ## Check if test server is healthy
	@curl -sf http://localhost:8080/status/200 > /dev/null && \
		echo "✓ HTTP server is healthy" || \
		echo "✗ HTTP server not responding"
	@curl -sfk https://localhost:8443/status/200 > /dev/null && \
		echo "✓ HTTPS server is healthy" || \
		echo "✗ HTTPS server not responding"

# Common workflows
dev: compile test ## Compile and run tests

ci: clean compile dialyzer xref test ## Run full CI pipeline

.DEFAULT_GOAL := help
