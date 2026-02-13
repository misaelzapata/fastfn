#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fastfn_lua_test_${RANDOM}_$$}"
DC=(docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.yml")

# Build image to ensure the exact same OpenResty runtime used in integration.
"${DC[@]}" build openresty >/dev/null

"${DC[@]}" run --rm --no-deps \
  -v "$ROOT_DIR/tests:/app/tests" \
  openresty \
  resty /app/tests/unit/lua_runner.lua
