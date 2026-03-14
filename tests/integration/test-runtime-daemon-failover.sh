#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-120}"
RECOVER_WAIT_SECS="${RECOVER_WAIT_SECS:-45}"
KEEP_UP="${KEEP_UP:-0}"
FASTFN_BIN="${FASTFN_BIN:-$ROOT_DIR/bin/fastfn}"
PYTHON_BIN="${PYTHON_BIN:-${FN_PYTHON_BIN:-}}"
RUNTIMES="${RUNTIMES:-node,python,php,rust}"
DAEMON_COUNTS="${DAEMON_COUNTS:-node=3,python=3,php=3,rust=3}"
FIXTURE_DIR="${FIXTURE_DIR:-$ROOT_DIR/tests/fixtures/worker-pool}"

if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
  else
    PYTHON_BIN=""
  fi
fi

STACK_PID=""
STACK_LOG=""
BASE_URL=""
NATIVE_PORT=""

pick_free_port() {
  "$PYTHON_BIN" - <<'PY'
import socket

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

kill_runtime_processes_from_log() {
  local log_file="$1"
  if [[ -z "$log_file" || ! -f "$log_file" ]]; then
    return 0
  fi

  local runtime_dir
  runtime_dir="$(grep -F 'Runtime extracted to:' "$log_file" | tail -n 1 | sed 's/.*Runtime extracted to: //')"
  if [[ -z "$runtime_dir" ]]; then
    return 0
  fi

  pkill -f "$runtime_dir/openresty" >/dev/null 2>&1 || true
  pkill -f "$runtime_dir/srv/fn/runtimes/python-daemon.py" >/dev/null 2>&1 || true
  pkill -f "$runtime_dir/srv/fn/runtimes/node-daemon.js" >/dev/null 2>&1 || true
  pkill -f "$runtime_dir/srv/fn/runtimes/php-daemon.py" >/dev/null 2>&1 || true
  pkill -f "$runtime_dir/srv/fn/runtimes/rust-daemon.py" >/dev/null 2>&1 || true
  pkill -f "$runtime_dir/srv/fn/runtimes/go-daemon.py" >/dev/null 2>&1 || true
}

cleanup() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  kill_runtime_processes_from_log "$STACK_LOG"
  if [[ "$KEEP_UP" != "1" ]]; then
    (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  fi
}

trap cleanup EXIT

require_native_prereqs_or_skip() {
  local missing=()

  if [[ -z "$PYTHON_BIN" ]]; then
    missing+=("python")
  fi
  for cmd in openresty node php cargo lsof; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ ! -x "$FASTFN_BIN" ]]; then
    missing+=("bin/fastfn")
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    if [[ "${FN_REQUIRE_NATIVE_DEPS:-0}" == "1" || "${CI:-}" == "true" ]]; then
      echo "FAIL test-runtime-daemon-failover.sh (missing native deps: ${missing[*]})"
      exit 1
    fi
    echo "SKIP test-runtime-daemon-failover.sh (missing native deps: ${missing[*]})"
    exit 0
  fi
}

health_fetch() {
  curl -sS "${BASE_URL}/_fn/health" > /tmp/fastfn-runtime-daemon-failover-health.json
}

wait_for_health_ready() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    if [[ -n "$STACK_PID" ]] && ! kill -0 "$STACK_PID" >/dev/null 2>&1; then
      echo "FAIL native fastfn exited before health became ready"
      [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
      exit 1
    fi

    local code
    code="$(curl -sS -o /tmp/fastfn-runtime-daemon-failover-health.json -w '%{http_code}' "${BASE_URL}/_fn/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      if HEALTH_JSON=/tmp/fastfn-runtime-daemon-failover-health.json RUNTIMES="$RUNTIMES" "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import json
import os
import sys
from pathlib import Path

obj = json.loads(Path(os.environ["HEALTH_JSON"]).read_text(encoding="utf-8"))
runtimes = obj.get("runtimes") or {}
required = [part.strip() for part in os.environ["RUNTIMES"].split(",") if part.strip()]
for name in required:
    entry = runtimes.get(name) or {}
    health = entry.get("health") or {}
    if health.get("up") is not True:
        sys.exit(1)
    sockets = entry.get("sockets") or []
    if len(sockets) < 3:
        sys.exit(1)
sys.exit(0)
PY
      then
        ready=1
        break
      fi
    fi
    sleep 1
  done

  if [[ "$ready" != "1" ]]; then
    echo "FAIL runtime daemon stack did not become ready"
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
    exit 1
  fi
}

start_native() {
  STACK_LOG="$(mktemp -t fastfn-runtime-daemon-failover.XXXXXX.log)"
  (
    cd "$ROOT_DIR"
    env \
      FN_ADMIN_TOKEN=test-admin-token \
      FN_UI_ENABLED=0 \
      FN_CONSOLE_WRITE_ENABLED=0 \
      FN_OPENAPI_INCLUDE_INTERNAL=0 \
      FN_RUNTIMES="$RUNTIMES" \
      FN_RUNTIME_DAEMONS="$DAEMON_COUNTS" \
      FN_HOST_PORT="$NATIVE_PORT" \
      "$FASTFN_BIN" dev --native "$FIXTURE_DIR" >"$STACK_LOG" 2>&1
  ) &
  STACK_PID="$!"
  wait_for_health_ready
}

runtime_socket_path() {
  local runtime_name="$1"
  local socket_index="${2:-1}"
  HEALTH_JSON=/tmp/fastfn-runtime-daemon-failover-health.json RUNTIME_NAME="$runtime_name" SOCKET_INDEX="$socket_index" "$PYTHON_BIN" - <<'PY'
import json
import os
from pathlib import Path

obj = json.loads(Path(os.environ["HEALTH_JSON"]).read_text(encoding="utf-8"))
runtime_name = os.environ["RUNTIME_NAME"]
socket_index = int(os.environ["SOCKET_INDEX"])
sockets = ((obj.get("runtimes") or {}).get(runtime_name) or {}).get("sockets") or []
for item in sockets:
    if int(item.get("index") or 0) == socket_index:
        uri = str(item.get("uri") or "")
        print(uri[5:] if uri.startswith("unix:") else uri)
        break
else:
    raise SystemExit(f"missing socket index {socket_index} for runtime {runtime_name}")
PY
}

runtime_socket_pid() {
  local socket_path="$1"
  lsof -t "$socket_path" 2>/dev/null | head -n 1
}

assert_parallel_200() {
  local path="$1"
  if ! "$PYTHON_BIN" "$ROOT_DIR/tests/stress/load-runner.py" \
    --base-url "$BASE_URL" \
    --path "$path" \
    --total 6 \
    --concurrency 6 \
    --timeout 12 \
    --expect 200 >/tmp/fastfn-runtime-daemon-failover-load.json 2>/tmp/fastfn-runtime-daemon-failover-load.err; then
    echo "FAIL parallel request check failed for $path"
    cat /tmp/fastfn-runtime-daemon-failover-load.json 2>/dev/null || true
    cat /tmp/fastfn-runtime-daemon-failover-load.err 2>/dev/null || true
    health_fetch || true
    cat /tmp/fastfn-runtime-daemon-failover-health.json 2>/dev/null || true
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
    exit 1
  fi
}

wait_for_degraded_socket() {
  local runtime_name="$1"
  local route_path="$2"
  local degraded=0

  for _ in $(seq 1 30); do
    assert_parallel_200 "$route_path"
    health_fetch
    if HEALTH_JSON=/tmp/fastfn-runtime-daemon-failover-health.json RUNTIME_NAME="$runtime_name" "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import json
import os
import sys
from pathlib import Path

obj = json.loads(Path(os.environ["HEALTH_JSON"]).read_text(encoding="utf-8"))
entry = ((obj.get("runtimes") or {}).get(os.environ["RUNTIME_NAME"]) or {})
health = entry.get("health") or {}
sockets = entry.get("sockets") or []
if health.get("up") is not True:
    sys.exit(1)
if not any(item.get("up") is False for item in sockets):
    sys.exit(1)
if sum(1 for item in sockets if item.get("up") is True) < 2:
    sys.exit(1)
sys.exit(0)
PY
    then
      degraded=1
      break
    fi
    sleep 0.35
  done

  if [[ "$degraded" != "1" ]]; then
    echo "FAIL runtime $runtime_name never exposed a degraded socket while traffic stayed healthy"
    cat /tmp/fastfn-runtime-daemon-failover-load.json || true
    cat /tmp/fastfn-runtime-daemon-failover-health.json || true
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
    exit 1
  fi
}

wait_for_runtime_recovered() {
  local runtime_name="$1"
  local recovered=0

  for _ in $(seq 1 "$RECOVER_WAIT_SECS"); do
    health_fetch
    if HEALTH_JSON=/tmp/fastfn-runtime-daemon-failover-health.json RUNTIME_NAME="$runtime_name" "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import json
import os
import sys
from pathlib import Path

obj = json.loads(Path(os.environ["HEALTH_JSON"]).read_text(encoding="utf-8"))
entry = ((obj.get("runtimes") or {}).get(os.environ["RUNTIME_NAME"]) or {})
health = entry.get("health") or {}
sockets = entry.get("sockets") or []
if health.get("up") is not True:
    sys.exit(1)
if not sockets or not all(item.get("up") is True for item in sockets):
    sys.exit(1)
sys.exit(0)
PY
    then
      recovered=1
      break
    fi
    sleep 1
  done

  if [[ "$recovered" != "1" ]]; then
    echo "FAIL runtime $runtime_name did not recover all daemon sockets"
    cat /tmp/fastfn-runtime-daemon-failover-health.json || true
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
    exit 1
  fi
}

inject_socket_block() {
  local socket_path="$1"
  local daemon_pid="$2"

  kill -9 "$daemon_pid"
  rm -f "$socket_path"
  : > "$socket_path"
}

exercise_runtime_failover() {
  local runtime_name="$1"
  local route_path="$2"

  echo "== failover runtime: ${runtime_name} (${route_path}) =="
  assert_parallel_200 "$route_path"
  health_fetch
  local socket_path
  socket_path="$(runtime_socket_path "$runtime_name" 1)"
  local daemon_pid
  daemon_pid="$(runtime_socket_pid "$socket_path")"
  if [[ -z "$daemon_pid" ]]; then
    echo "FAIL unable to resolve PID for $runtime_name socket $socket_path"
    exit 1
  fi

  inject_socket_block "$socket_path" "$daemon_pid"
  wait_for_degraded_socket "$runtime_name" "$route_path"

  rm -f "$socket_path"
  wait_for_runtime_recovered "$runtime_name"
  assert_parallel_200 "$route_path"
}

require_native_prereqs_or_skip

NATIVE_PORT="$(pick_free_port)"
BASE_URL="http://127.0.0.1:${NATIVE_PORT}"

echo "refs:"
echo "  feature: multi-daemon runtime routing"
echo "  fixture: tests/fixtures/worker-pool"
echo "  base-url: ${BASE_URL}"

start_native

exercise_runtime_failover "node" "/slow-node"
exercise_runtime_failover "python" "/slow-python"
exercise_runtime_failover "php" "/slow-php"
exercise_runtime_failover "rust" "/slow-rust"

echo "PASS runtime daemon failover preserved traffic across node/python/php/rust"
