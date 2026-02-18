# FastFN Makefile
# Convenience wrapper around the repo's canonical CI scripts.
#
# Notes:
# - CI entrypoint: scripts/ci/test-pipeline.sh
# - Core suite (unit + integration): cli/test-all.sh
# - Playwright UI E2E: cli/test-playwright.sh

.PHONY: help up down logs restart clean dev build-cli test test-core test-unit test-unit-lua test-integration test-e2e

help:
	@echo "FastFN Management Commands"
	@echo "--------------------------"
	@echo "make dev           - Run FastFN dev in the current directory"
	@echo "make up            - Start the Docker stack (detach mode)"
	@echo "make down          - Stop the Docker stack"
	@echo "make logs          - Follow OpenResty logs"
	@echo "make restart       - Restart OpenResty"
	@echo "make clean         - Remove containers/networks and test artifacts"
	@echo "make build-cli     - Build ./bin/fastfn"
	@echo "make test          - Run the full local CI pipeline (includes UI E2E)"
	@echo "make test-core     - Run core suite only (skip UI E2E)"
	@echo "make test-unit     - Run unit tests only (fast loop)"
	@echo "make test-unit-lua - Run Lua/OpenResty unit suite"
	@echo "make test-integration - Run integration suite scripts"
	@echo "make test-e2e      - Run Playwright UI E2E only"

up:
	docker compose up -d

dev:
	bin/fastfn dev .

down:
	docker compose down

logs:
	docker compose logs -f openresty

restart:
	docker compose restart openresty

clean:
	docker compose down --remove-orphans
	rm -rf tests/results playwright-report

build-cli:
	bash cli/build.sh

# Full pipeline (mirrors CI) in one command.
test:
	RUN_UI_E2E=1 bash scripts/ci/test-pipeline.sh

# Same as `make test`, but skips Playwright UI tests.
test-core:
	RUN_UI_E2E=0 bash scripts/ci/test-pipeline.sh

# Fast local loop for most changes (no Docker stack required).
test-unit:
	python3 tests/unit/test-python-handlers.py
	python3 tests/unit/test-go-handler.py
	@if command -v node >/dev/null 2>&1; then env -u NO_COLOR node tests/unit/test-node-handler.js; else echo "skip: node unit (node not found)"; fi
	@if command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then python3 tests/unit/test-rust-handler.py; else echo "skip: rust unit (rust toolchain not found)"; fi
	@if command -v php >/dev/null 2>&1; then php tests/unit/test-php-handler.php; else echo "skip: php unit (php not found)"; fi
	bash tests/unit/test-sdks.sh

test-unit-lua:
	bash cli/test-lua.sh

test-integration:
	bash tests/integration/test-api.sh
	bash tests/integration/test-openapi-system.sh
	bash tests/integration/test-openapi-native.sh
	bash tests/integration/test-openapi-demos.sh
	bash tests/integration/test-hotreload-runtime-matrix.sh
	bash tests/integration/test-cli-init-auto.sh

test-e2e:
	bash cli/test-playwright.sh
