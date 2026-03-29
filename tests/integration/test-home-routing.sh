#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STACK_PID=""
STACK_LOG=""
TEST_HOST="${TEST_HOST:-127.0.0.1}"
TEST_PORT="${TEST_PORT:-${FN_HOST_PORT:-8080}}"
BASE_URL="${BASE_URL:-http://${TEST_HOST}:${TEST_PORT}}"
HELPER_PY="$ROOT_DIR/scripts/ci/fastfn_shell_helpers.py"

terminate_stack_pid() {
  local pid="${1:-}"
  if [[ -z "$pid" ]]; then
    return 0
  fi

  if kill -0 "$pid" >/dev/null 2>&1; then
    pkill -P "$pid" >/dev/null 2>&1 || true
    kill "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
  fi

  if kill -0 "$pid" >/dev/null 2>&1; then
    pkill -9 -P "$pid" >/dev/null 2>&1 || true
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi

  wait "$pid" >/dev/null 2>&1 || true
  pkill -P "$pid" >/dev/null 2>&1 || true
}

cleanup() {
  terminate_stack_pid "$STACK_PID"
  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
}
trap cleanup EXIT

wait_for_health() {
  local ready=0
  for _ in $(seq 1 120); do
    local code
    code="$(curl -sS -o /tmp/fastfn-home-routing-health.out -w '%{http_code}' "${BASE_URL}/_fn/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" != "1" ]]; then
    echo "FAIL health did not become ready"
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 200 "$STACK_LOG" || true
    exit 1
  fi
}

wait_for_catalog_ready() {
  local ready=0
  local prev_signature=""
  local stable_hits=0
  for _ in $(seq 1 120); do
    local body_file code signature
    body_file="$(mktemp)"
    code="$(curl -sS -o "$body_file" -w '%{http_code}' "${BASE_URL}/_fn/catalog" 2>/dev/null || true)"

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
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 200 "$STACK_LOG" || true
    exit 1
  fi
}

start_stack() {
  local target_dir="$1"
  shift

  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  STACK_LOG="$(mktemp -t fastfn-home-routing.XXXXXX.log)"
  (
    cd "$ROOT_DIR"
    exec env FN_HOT_RELOAD=0 "$@" ./bin/fastfn dev --build "$target_dir" >"$STACK_LOG" 2>&1
  ) &
  STACK_PID="$!"

  wait_for_health
  wait_for_catalog_ready
}

stop_stack() {
  terminate_stack_pid "$STACK_PID"
  STACK_PID=""
  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
}

assert_body_contains() {
  local path="$1"
  local fragment="$2"
  local body
  body="$(curl -sS "${BASE_URL}${path}")"
  if [[ "$body" != *"$fragment"* ]]; then
    echo "FAIL GET $path missing fragment: $fragment"
    echo "$body"
    exit 1
  fi
}

assert_redirect() {
  local path="$1"
  local expected_location="$2"
  local headers_file body_file code
  headers_file="$(mktemp)"
  body_file="$(mktemp)"
  code="$(curl -sS -D "$headers_file" -o "$body_file" -w '%{http_code}' "${BASE_URL}${path}")"
  if [[ "$code" != "302" ]]; then
    echo "FAIL GET $path expected=302 got=$code"
    cat "$body_file" || true
    cat "$headers_file" || true
    rm -f "$headers_file" "$body_file"
    exit 1
  fi
  if ! tr -d '\r' <"$headers_file" | grep -qi "^location: ${expected_location}$"; then
    echo "FAIL GET $path expected Location: $expected_location"
    cat "$headers_file" || true
    rm -f "$headers_file" "$body_file"
    exit 1
  fi
  rm -f "$headers_file" "$body_file"
}

echo "== home routing: FN_HOME_FUNCTION + folder alias from fn.config =="
start_stack "tests/fixtures/home-routing" "FN_RUNTIMES=node" "FN_HOME_FUNCTION=/welcome"
assert_body_contains "/" '"endpoint":"welcome"'
assert_body_contains "/portal" '"endpoint":"portal-dashboard"'
assert_body_contains "/portal/dashboard" '"endpoint":"portal-dashboard"'
stop_stack

echo "== home routing: FN_HOME_FUNCTION override =="
start_stack "tests/fixtures/home-routing" "FN_RUNTIMES=node" "FN_HOME_FUNCTION=/portal/dashboard"
assert_body_contains "/" '"endpoint":"portal-dashboard"'
stop_stack

echo "== home routing: FN_HOME_REDIRECT =="
start_stack "tests/fixtures/home-routing" "FN_RUNTIMES=node" "FN_HOME_REDIRECT=/_fn/docs"
assert_redirect "/" "/_fn/docs"
stop_stack

echo "PASS test-home-routing.sh"
