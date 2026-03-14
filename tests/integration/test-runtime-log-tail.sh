#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-120}"
KEEP_UP="${KEEP_UP:-0}"
FN_ADMIN_TOKEN="${FN_ADMIN_TOKEN:-test-admin-token}"
TEST_SUFFIX="${TEST_SUFFIX:-$$}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fastfn-runtime-logs-${TEST_SUFFIX}}"
PYTHON_BIN="${PYTHON_BIN:-${FN_PYTHON_BIN:-}}"

TEST_HOST="${TEST_HOST:-127.0.0.1}"
TEST_PORT="${TEST_PORT:-${FN_HOST_PORT:-8080}}"
BASE_URL="${BASE_URL:-http://${TEST_HOST}:${TEST_PORT}}"
CURL_CONNECT_TIMEOUT_SECS="${CURL_CONNECT_TIMEOUT_SECS:-2}"
CURL_MAX_TIME_SECS="${CURL_MAX_TIME_SECS:-30}"

export FN_HOST_PORT="${FN_HOST_PORT:-$TEST_PORT}"
export FASTFN_TEST_BASE_URL="$BASE_URL"

if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
  else
    echo "FAIL test-runtime-log-tail.sh requires python or python3 for assertions"
    exit 1
  fi
fi

curl_fastfn() {
  curl --connect-timeout "$CURL_CONNECT_TIMEOUT_SECS" --max-time "$CURL_MAX_TIME_SECS" "$@"
}

STACK_PID=""
STACK_LOG=""
STACK_EXIT_FILE=""
WORK_DIR="$(mktemp -d "$ROOT_DIR/tests/results/runtime-log-tail.${TEST_SUFFIX}.XXXXXX")"
FIXTURES_DIR="$WORK_DIR/functions"

mkdir -p "$FIXTURES_DIR"
cp -R "$ROOT_DIR/tests/fixtures/runtime-logs/." "$FIXTURES_DIR/"

cleanup() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$STACK_EXIT_FILE" ]]; then
    rm -f "$STACK_EXIT_FILE" >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_UP" != "1" ]]; then
    (cd "$ROOT_DIR" && COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" docker compose down --remove-orphans >/dev/null 2>&1) || true
  fi
  rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}

trap cleanup EXIT

wait_for_health() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    if [[ -n "$STACK_EXIT_FILE" && -s "$STACK_EXIT_FILE" ]]; then
      echo "FAIL fastfn exited before health became ready"
      [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
      exit 1
    fi
    if [[ -n "$STACK_PID" ]] && ! kill -0 "$STACK_PID" >/dev/null 2>&1; then
      echo "FAIL fastfn exited before health became ready"
      [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
      exit 1
    fi

    local code
    code="$(curl_fastfn -sS -o /tmp/fastfn-runtime-log-tail-health.out -w '%{http_code}' "${BASE_URL}/_fn/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      ready=1
      break
    fi
    sleep 1
  done

  if [[ "$ready" != "1" ]]; then
    echo "FAIL health did not become ready"
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
    exit 1
  fi
}

start_stack() {
  STACK_LOG="$(mktemp -t fastfn-runtime-log-tail.XXXXXX.log)"
  STACK_EXIT_FILE="$(mktemp -t fastfn-runtime-log-tail.exit.XXXXXX)"
  (
    cd "$ROOT_DIR"
    env \
      COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
      FN_ADMIN_TOKEN="$FN_ADMIN_TOKEN" \
      FN_UI_ENABLED=0 \
      ./bin/fastfn dev --build "$FIXTURES_DIR" >"$STACK_LOG" 2>&1
    echo "$?" >"$STACK_EXIT_FILE"
  ) &
  STACK_PID="$!"
  wait_for_health
}

assert_invoke_writes_runtime_log() {
  local code
  code="$(curl_fastfn -sS -o /tmp/fastfn-runtime-log-tail-invoke.out -w '%{http_code}' \
    "${BASE_URL}/echo-logs?id=42&name=Debug" 2>/dev/null || true)"
  if [[ "$code" != "200" ]]; then
    echo "FAIL GET /echo-logs expected=200 got=$code"
    cat /tmp/fastfn-runtime-log-tail-invoke.out 2>/dev/null || true
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
    exit 1
  fi

  if ! grep -Fq '{"ok":true}' /tmp/fastfn-runtime-log-tail-invoke.out; then
    echo "FAIL /echo-logs response missing expected body"
    cat /tmp/fastfn-runtime-log-tail-invoke.out
    exit 1
  fi

  local found=0
  for _ in $(seq 1 40); do
    code="$(curl_fastfn -sS -o /tmp/fastfn-runtime-log-tail-runtime.json -w '%{http_code}' \
      "${BASE_URL}/_fn/logs?file=runtime&format=json&runtime=python&fn=echo-logs&version=default&stream=stdout&lines=50" \
      -H "x-fn-admin-token: $FN_ADMIN_TOKEN" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      if LOG_JSON=/tmp/fastfn-runtime-log-tail-runtime.json "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import json
import os
from pathlib import Path

obj = json.loads(Path(os.environ["LOG_JSON"]).read_text(encoding="utf-8"))
assert obj.get("file") == "runtime"
assert obj.get("runtime") == "python"
assert obj.get("fn") == "echo-logs"
assert obj.get("version") == "default"
assert obj.get("stream") == "stdout"
lines = obj.get("data") or []
assert isinstance(lines, list) and lines
line = next(
    item for item in lines
    if "[python]" in item
    and "[fn:echo-logs@default stdout]" in item
    and "'id': '42'" in item
    and "'name': 'Debug'" in item
)
assert "stderr" not in line
PY
      then
        found=1
        break
      fi
    fi
    sleep 0.5
  done

  if [[ "$found" != "1" ]]; then
    echo "FAIL runtime log tail never exposed the handler debug line"
    cat /tmp/fastfn-runtime-log-tail-runtime.json 2>/dev/null || true
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
    exit 1
  fi

  code="$(curl_fastfn -sS -o /tmp/fastfn-runtime-log-tail-stderr.json -w '%{http_code}' \
    "${BASE_URL}/_fn/logs?file=runtime&format=json&runtime=python&fn=echo-logs&version=default&stream=stderr&lines=20" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" 2>/dev/null || true)"
  if [[ "$code" != "200" ]]; then
    echo "FAIL runtime stderr log tail expected=200 got=$code"
    cat /tmp/fastfn-runtime-log-tail-stderr.json 2>/dev/null || true
    exit 1
  fi

  LOG_JSON=/tmp/fastfn-runtime-log-tail-stderr.json "$PYTHON_BIN" - <<'PY'
import json
import os
from pathlib import Path

obj = json.loads(Path(os.environ["LOG_JSON"]).read_text(encoding="utf-8"))
assert obj.get("stream") == "stderr"
assert (obj.get("data") or []) == []
PY
}

if [[ ! -x "$ROOT_DIR/bin/fastfn" ]]; then
  "$ROOT_DIR/cli/build.sh"
fi

start_stack
assert_invoke_writes_runtime_log
echo "PASS test-runtime-log-tail.sh"
