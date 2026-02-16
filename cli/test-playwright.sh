#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FASTFN_PID=""

if [[ -n "${FORCE_COLOR:-}" && -n "${NO_COLOR:-}" ]]; then
  unset NO_COLOR
fi

export FN_UI_ENABLED="${FN_UI_ENABLED:-1}"
export FN_CONSOLE_API_ENABLED="${FN_CONSOLE_API_ENABLED:-1}"
export FN_CONSOLE_WRITE_ENABLED="${FN_CONSOLE_WRITE_ENABLED:-1}"
export FN_CONSOLE_LOCAL_ONLY="${FN_CONSOLE_LOCAL_ONLY:-1}"
export FN_ADMIN_TOKEN="${FN_ADMIN_TOKEN:-test-admin-token}"
export FN_ASSISTANT_ENABLED="${FN_ASSISTANT_ENABLED:-1}"
export FN_ASSISTANT_PROVIDER="${FN_ASSISTANT_PROVIDER:-mock}"
export BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"

run_node_cmd() {
  env -u NO_COLOR "$@"
}

cleanup() {
  if [[ -n "$FASTFN_PID" ]] && kill -0 "$FASTFN_PID" >/dev/null 2>&1; then
    kill "$FASTFN_PID" >/dev/null 2>&1 || true
    wait "$FASTFN_PID" >/dev/null 2>&1 || true
  fi
  docker compose -f "$ROOT_DIR/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "$ROOT_DIR"

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to run Playwright tests"
  exit 1
fi

run_node_cmd npm install --no-fund --no-audit
run_node_cmd npx playwright install --with-deps chromium

docker compose -f "$ROOT_DIR/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true

FN_UI_ENABLED="$FN_UI_ENABLED" \
FN_CONSOLE_API_ENABLED="$FN_CONSOLE_API_ENABLED" \
FN_CONSOLE_WRITE_ENABLED="$FN_CONSOLE_WRITE_ENABLED" \
FN_CONSOLE_LOCAL_ONLY="$FN_CONSOLE_LOCAL_ONLY" \
FN_ADMIN_TOKEN="$FN_ADMIN_TOKEN" \
FN_ASSISTANT_ENABLED="$FN_ASSISTANT_ENABLED" \
FN_ASSISTANT_PROVIDER="$FN_ASSISTANT_PROVIDER" \
./bin/fastfn dev examples/functions/next-style >/tmp/fastfn-playwright.log 2>&1 &
FASTFN_PID="$!"

for _ in $(seq 1 90); do
  if curl -fsS "$BASE_URL/_fn/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "$BASE_URL/_fn/health" >/dev/null 2>&1; then
  echo "fastfn dev did not become healthy"
  tail -n 200 /tmp/fastfn-playwright.log || true
  exit 1
fi

run_node_cmd npm run test:e2e:ui
