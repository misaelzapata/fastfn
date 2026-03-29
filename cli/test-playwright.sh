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
export BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
export COMPOSE_PROJECT_NAME="$PROJECT_NAME"
export FN_RUNTIMES="${FN_RUNTIMES:-python,node,php,rust}"
export FN_DEFAULT_TIMEOUT_MS="${FN_DEFAULT_TIMEOUT_MS:-180000}"
export FASTFN_PLAYWRIGHT_INSTALL_BROWSERS="${FASTFN_PLAYWRIGHT_INSTALL_BROWSERS:-1}"
NODE20_WRAPPER=0

if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
  if [[ "$NODE_MAJOR" != "20" ]] && command -v npx >/dev/null 2>&1; then
    NODE20_WRAPPER=1
  fi
fi

run_node_cmd() {
  if [[ "$NODE20_WRAPPER" == "1" ]]; then
    local quoted_cmd=""
    printf -v quoted_cmd '%q ' "$@"
    env -u NO_COLOR npx --yes -p node@20 bash -lc "${quoted_cmd% }"
    return
  fi
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
if [[ "$FASTFN_PLAYWRIGHT_INSTALL_BROWSERS" == "1" ]]; then
  run_node_cmd ./node_modules/.bin/playwright install chromium
fi

docker compose -f "$ROOT_DIR/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true

# Use a temp copy to keep the repo clean (deps installs, caches, job specs).
WORK_DIR="$(mktemp -d -t fastfn-playwright-functions.XXXXXX)"
cp -R "$ROOT_DIR/tests/fixtures/local-dev-samples-migrated/." "$WORK_DIR"/
# Force runtime-layout root mounting so console create/edit flows can add new
# functions under /app/srv/fn/functions/<runtime>/... during UI tests.
mkdir -p "$WORK_DIR"/node "$WORK_DIR"/python "$WORK_DIR"/php "$WORK_DIR"/rust "$WORK_DIR"/lua "$WORK_DIR"/go
# The bind-mounted temp fixture must stay writable from inside the container so
# console create/edit flows can create runtime directories during UI tests.
chmod -R a+rwX "$WORK_DIR" 2>/dev/null || true

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

warm_url "/node-hello"
warm_url "/python-hello"
warm_url "/php-hello"
warm_url "/rust-hello"
warm_url "/node-deps"
warm_url "/python-deps"

run_node_cmd ./node_modules/.bin/playwright test -c tests/e2e/playwright.config.cjs
