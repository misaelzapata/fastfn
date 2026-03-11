#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STACK_PID=""
STACK_LOG=""
TEST_HOST="${TEST_HOST:-127.0.0.1}"
TEST_PORT="${TEST_PORT:-${FN_HOST_PORT:-8080}}"
BASE_URL="${BASE_URL:-http://${TEST_HOST}:${TEST_PORT}}"

cleanup() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
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

start_stack() {
  local target_dir="$1"
  shift

  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  STACK_LOG="$(mktemp -t fastfn-home-routing.XXXXXX.log)"
  (
    cd "$ROOT_DIR"
    env FN_HOT_RELOAD=0 "$@" ./bin/fastfn dev --build "$target_dir" >"$STACK_LOG" 2>&1
  ) &
  STACK_PID="$!"

  wait_for_health
}

stop_stack() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
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
  if ! grep -qi "^location: ${expected_location}\r\?$" "$headers_file"; then
    echo "FAIL GET $path expected Location: $expected_location"
    cat "$headers_file" || true
    rm -f "$headers_file" "$body_file"
    exit 1
  fi
  rm -f "$headers_file" "$body_file"
}

echo "== home routing: FN_HOME_FUNCTION + folder alias from fn.config =="
start_stack "tests/fixtures/home-routing" "FN_RUNTIMES=node" "FN_HOME_FUNCTION=/node/home-routing/welcome"
assert_body_contains "/" '"endpoint":"welcome"'
assert_body_contains "/node/home-routing/portal" '"endpoint":"portal-dashboard"'
assert_body_contains "/node/home-routing/portal/dashboard" '"endpoint":"portal-dashboard"'
stop_stack

echo "== home routing: FN_HOME_FUNCTION override =="
start_stack "tests/fixtures/home-routing" "FN_RUNTIMES=node" "FN_HOME_FUNCTION=/node/home-routing/portal/dashboard"
assert_body_contains "/" '"endpoint":"portal-dashboard"'
stop_stack

echo "== home routing: FN_HOME_REDIRECT =="
start_stack "tests/fixtures/home-routing" "FN_RUNTIMES=node" "FN_HOME_REDIRECT=/_fn/docs"
assert_redirect "/" "/_fn/docs"
stop_stack

echo "PASS test-home-routing.sh"
