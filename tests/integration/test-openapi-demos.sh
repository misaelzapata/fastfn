#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-120}"
KEEP_UP="${KEEP_UP:-0}"

TEST_HOST="${TEST_HOST:-127.0.0.1}"
TEST_PORT="${TEST_PORT:-${FN_HOST_PORT:-8080}}"
BASE_URL="${BASE_URL:-http://${TEST_HOST}:${TEST_PORT}}"
CURL_CONNECT_TIMEOUT_SECS="${CURL_CONNECT_TIMEOUT_SECS:-2}"
CURL_MAX_TIME_SECS="${CURL_MAX_TIME_SECS:-30}"

export FN_HOST_PORT="${FN_HOST_PORT:-$TEST_PORT}"
export FASTFN_TEST_BASE_URL="$BASE_URL"
HELPER_PY="$ROOT_DIR/scripts/ci/fastfn_shell_helpers.py"
DEMO_CHECK_PY="$ROOT_DIR/scripts/ci/openapi_demo_checks.py"

curl_fastfn() {
  curl --connect-timeout "$CURL_CONNECT_TIMEOUT_SECS" --max-time "$CURL_MAX_TIME_SECS" "$@"
}

STACK_PID=""
STACK_LOG=""
FUNCTIONS_SNAPSHOT_DIR=""

export_lua_coverage_report() {
  if [[ "${FN_LUA_COVERAGE:-0}" != "1" ]]; then
    return
  fi
  local out_path="${FN_LUA_COVERAGE_REPORT_HOST:-$ROOT_DIR/coverage/lua/luacov.integration.report.out}"
  mkdir -p "$(dirname "$out_path")"
  (
    cd "$ROOT_DIR"
    docker compose exec -T openresty sh -lc '
      report="${FN_LUA_COVERAGE_REPORT:-/tmp/luacov.report.out}"
      cfg="${LUACOV_CONFIG:-/tmp/.luacov}"
      if command -v luacov >/dev/null 2>&1 && [ -f "$cfg" ]; then
        LUACOV_CONFIG="$cfg" luacov >/dev/null 2>&1 || true
      fi
      if [ -f "$report" ]; then
        cat "$report"
      fi
    '
  ) >"$out_path" 2>/dev/null || true
}

cleanup() {
  export_lua_coverage_report
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_UP" != "1" ]]; then
    (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  fi
  if [[ -n "$FUNCTIONS_SNAPSHOT_DIR" && -d "$FUNCTIONS_SNAPSHOT_DIR" ]]; then
    rm -rf "$FUNCTIONS_SNAPSHOT_DIR" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

wait_for_health() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    local code
    code="$(curl_fastfn -sS -o /tmp/fastfn-openapi-demos-health.out -w '%{http_code}' "${BASE_URL}/_fn/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      if python3 "$HELPER_PY" health-all-up --file /tmp/fastfn-openapi-demos-health.out >/dev/null 2>&1
      then
        ready=1
        break
      fi
    fi
    sleep 1
  done
  if [[ "$ready" != "1" ]]; then
    echo "FAIL health did not become ready"
    if [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]]; then
      tail -n 220 "$STACK_LOG" || true
    fi
    exit 1
  fi
}

wait_for_catalog_ready() {
  local ready=0
  local prev_signature=""
  local stable_hits=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    local body_file code signature
    body_file="$(mktemp)"
    code="$(curl_fastfn -sS -o "$body_file" -w '%{http_code}' "${BASE_URL}/_fn/catalog" 2>/dev/null || true)"

    if [[ "$code" == "200" ]]; then
      signature="$(python3 "$HELPER_PY" catalog-signature --file "$body_file" 2>/dev/null || true)"
      if [[ -n "$signature" ]]; then
        if [[ "$signature" == "$prev_signature" ]]; then
          stable_hits=$((stable_hits + 1))
        else
          prev_signature="$signature"
          stable_hits=1
        fi
      else
        prev_signature=""
        stable_hits=0
      fi

      if [[ "$stable_hits" -ge 2 ]]; then
        rm -f "$body_file"
        ready=1
        break
      fi
    fi

    rm -f "$body_file"
    sleep 1
  done

  if [[ "$ready" != "1" ]]; then
    echo "FAIL catalog did not become ready"
    if [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]]; then
      tail -n 220 "$STACK_LOG" || true
    fi
    exit 1
  fi
}

start_stack() {
  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  FUNCTIONS_SNAPSHOT_DIR="$(mktemp -d -t fastfn-openapi-demos-functions.XXXXXX)"
  while IFS= read -r -d '' rel; do
    mkdir -p "$FUNCTIONS_SNAPSHOT_DIR/$(dirname "$rel")"
    cp "$ROOT_DIR/$rel" "$FUNCTIONS_SNAPSHOT_DIR/$rel"
  done < <(cd "$ROOT_DIR" && git ls-files -z examples/functions)
  STACK_LOG="$(mktemp -t fastfn-openapi-demos.XXXXXX.log)"
  (
    cd "$ROOT_DIR"
    exec env \
      FN_SCHEDULER_ENABLED=0 \
      FN_DEFAULT_TIMEOUT_MS="${FN_DEFAULT_TIMEOUT_MS:-90000}" \
      FN_RUNTIMES="${FN_RUNTIMES:-python,node,php,rust}" \
      FN_LUA_COVERAGE="${FN_LUA_COVERAGE:-0}" \
      FN_LUA_COVERAGE_STATS="${FN_LUA_COVERAGE_STATS:-/tmp/luacov.stats.out}" \
      FN_LUA_COVERAGE_REPORT="${FN_LUA_COVERAGE_REPORT:-/tmp/luacov.report.out}" \
      LUACOV_CONFIG="${LUACOV_CONFIG:-/tmp/.luacov}" \
      EDGE_AUTH_TOKEN=dev-token \
      EDGE_FILTER_API_KEY=dev \
      GITHUB_WEBHOOK_SECRET=dev \
      ./bin/fastfn dev --build "$FUNCTIONS_SNAPSHOT_DIR/examples/functions" >"$STACK_LOG" 2>&1
  ) &
  STACK_PID="$!"
  wait_for_health
  wait_for_catalog_ready
}

warm_endpoint() {
  local path="$1"
  local expected="${2:-200}"
  local attempts="${3:-40}"
  local method="${4:-GET}"
  for _ in $(seq 1 "$attempts"); do
    local code
    code="$(curl_fastfn -sS -X "$method" -o /tmp/fastfn-openapi-demos-warm.out -w '%{http_code}' "${BASE_URL}$path" 2>/dev/null || true)"
    if [[ "$code" == "$expected" ]]; then
      return 0
    fi
    if [[ "$code" == "400" || "$code" == "401" || "$code" == "404" || "$code" == "405" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "FAIL warm-up endpoint did not stabilize: $path"
  cat /tmp/fastfn-openapi-demos-warm.out || true
  exit 1
}

warm_heavy_endpoints() {
  warm_endpoint "/ts-hello?name=warm"
  warm_endpoint "/pack-qr-node?text=warm"
  warm_endpoint "/pack-qr?text=warm"
  warm_endpoint "/rust-profile?name=warm"
  warm_endpoint "/polyglot-tutorial/step-4"
  warm_endpoint "/polyglot-tutorial/step-5?name=warm"
  warm_endpoint "/polyglot-db-demo/items/demo" "404" "80" "DELETE"
}

assert_openapi_examples() {
  # Avoid passing OpenAPI as an env var: it can exceed ARG_MAX in CI (E2BIG).
  #
  # Use a temp file instead of stdin because python reads the script from stdin.
  local openapi_path rc
  openapi_path="$(mktemp -t fastfn-openapi-demos-openapi.XXXXXX.json)"
  curl_fastfn -sS "${BASE_URL}/_fn/openapi.json" >"$openapi_path"
  set +e
  python3 "$DEMO_CHECK_PY" assert-examples --openapi-file "$openapi_path"
  rc="$?"
  set -e
  rm -f "$openapi_path" >/dev/null 2>&1 || true
  return "$rc"
}

run_public_sweep() {
  python3 "$DEMO_CHECK_PY" public-sweep --base-url "$BASE_URL" --webhook-secret dev --print-each
}

echo "== openapi demo examples =="
start_stack
assert_openapi_examples
warm_heavy_endpoints

echo "== versioned compat route (/hello@v2) =="
code="$(curl_fastfn -sS -o /tmp/fastfn-openapi-demos-hello-v2.out -w '%{http_code}' "${BASE_URL}/hello@v2?name=World" 2>/dev/null || true)"
if [[ "$code" != "200" ]]; then
  echo "FAIL /hello@v2 expected=200 got=$code"
  cat /tmp/fastfn-openapi-demos-hello-v2.out || true
  if [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]]; then
    tail -n 220 "$STACK_LOG" || true
  fi
  exit 1
fi

echo "== openapi demo public sweep (all methods) =="
if ! run_public_sweep; then
  if [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]]; then
    echo "-- stack log tail --"
    tail -n 220 "$STACK_LOG" || true
  fi
  exit 1
fi

echo "PASS test-openapi-demos.sh"
