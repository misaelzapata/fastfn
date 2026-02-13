# FastFn Makefile
# The single entry point for development, testing, and operations.

.PHONY: help up down logs restart clean test test-unit test-e2e build-cli

# Default: print help
help:
	@echo "FastFn Management Commands"
	@echo "--------------------------"
	@echo "make up          - Start the stack (detach mode)"
	@echo "make down        - Stop the stack"
	@echo "make logs        - Follow logs"
	@echo "make restart     - Restart stack"
	@echo "make clean       - Remove containers and orphans"
	@echo "make test        - Run ALL tests"
	@echo "make test-unit   - Run unit tests only"
	@echo "make test-e2e    - Run Playwright E2E tests"
	@echo "make build-cli   - Build the Go CLI (requires go installed)"

# --- Operations ---

up:
	docker compose up -d

dev:
	@echo "Starting dev mode..."
	bin/fastfn dev .

down:
	docker compose down

logs:
	docker compose logs -f openresty

restart:
	docker compose restart openresty

clean:
	docker compose down --remove-orphans
	rm -rf test-results/

# --- Testing ---

test: test-unit test-e2e test-integration

test-unit:
	@echo "Running Unit Tests..."
	@if [ -f tests/unit/test_sdks.sh ]; then bash tests/unit/test_sdks.sh; fi
	@echo "Running Runtime Handler Tests..."
	@node tests/unit/test_node_handler.js
	@if command -v php >/dev/null; then php tests/unit/test_php_handler.php; else echo "Skipping PHP handler (runtime not found)"; fi
	@python3 tests/unit/test_python_handlers.py
	@python3 tests/unit/test_rust_handler.py

test-integration:
	@echo "Running Integration Tests..."
	@node tests/integration/test_multilang_e2e.js

test-e2e:
	@echo "Running E2E Tests..."
	npm run test:e2e:ui

# --- CLI Build (Placeholder) ---

build-cli:
	@echo "Building fastfn CLI..."
	cd cli && go build -o ../bin/fastfn
