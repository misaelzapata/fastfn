#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FASTFN_PID=""
WORK_DIR=""
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fastfn_playwright_${RANDOM}_$$}"

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
export COMPOSE_PROJECT_NAME="$PROJECT_NAME"
export FN_RUNTIMES="${FN_RUNTIMES:-python,node,php,rust}"
export FN_DEFAULT_TIMEOUT_MS="${FN_DEFAULT_TIMEOUT_MS:-180000}"

run_node_cmd() {
  env -u NO_COLOR "$@"
}

cleanup() {
  if [[ -n "$FASTFN_PID" ]] && kill -0 "$FASTFN_PID" >/dev/null 2>&1; then
    kill "$FASTFN_PID" >/dev/null 2>&1 || true
    wait "$FASTFN_PID" >/dev/null 2>&1 || true
  fi
  (cd "$ROOT_DIR" && docker compose -f docker-compose.yml down --remove-orphans >/dev/null 2>&1) || true
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
  fi
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

# Use a temp copy to keep the repo clean (deps installs, caches, job specs).
WORK_DIR="$(mktemp -d -t fastfn-playwright-functions.XXXXXX)"
cp -R "$ROOT_DIR/tests/fixtures/local-dev-samples-migrated/." "$WORK_DIR"/

warm_url() {
  local path="$1"
  local expected="${2:-200}"
  local attempts="${3:-120}"
  local method="${4:-GET}"
  for _ in $(seq 1 "$attempts"); do
    local code
    code="$(curl -sS -X "$method" -o /tmp/fastfn-playwright-warm.out -w '%{http_code}' "$BASE_URL$path" 2>/dev/null || true)"
    if [[ "$code" == "$expected" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "FAIL warm-up did not stabilize: $path (last_code=$code)"
  cat /tmp/fastfn-playwright-warm.out || true
  tail -n 200 /tmp/fastfn-playwright.log || true
  exit 1
}

FN_UI_ENABLED="$FN_UI_ENABLED" \
FN_CONSOLE_API_ENABLED="$FN_CONSOLE_API_ENABLED" \
FN_CONSOLE_WRITE_ENABLED="$FN_CONSOLE_WRITE_ENABLED" \
FN_CONSOLE_LOCAL_ONLY="$FN_CONSOLE_LOCAL_ONLY" \
FN_ADMIN_TOKEN="$FN_ADMIN_TOKEN" \
FN_ASSISTANT_ENABLED="$FN_ASSISTANT_ENABLED" \
FN_ASSISTANT_PROVIDER="$FN_ASSISTANT_PROVIDER" \
FN_RUNTIMES="$FN_RUNTIMES" \
FN_DEFAULT_TIMEOUT_MS="$FN_DEFAULT_TIMEOUT_MS" \
./bin/fastfn dev --build "$WORK_DIR" >/tmp/fastfn-playwright.log 2>&1 &
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

warm_url "/fn/node-hello"
warm_url "/fn/python-hello"
warm_url "/fn/php-hello"
warm_url "/fn/rust-hello"
warm_url "/fn/node-deps"
warm_url "/fn/python-deps"

run_node_cmd npm run test:e2e:ui
