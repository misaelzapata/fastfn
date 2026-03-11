#!/bin/sh
set -eu

mkdir -p /tmp/fastfn
chmod 1777 /tmp/fastfn 2>/dev/null || true

# Ensure the functions root is writable by the nginx worker (which runs as nobody).
# Docker named volumes are created with root ownership, so fix permissions at startup.
FN_FUNCTIONS_ROOT="${FN_FUNCTIONS_ROOT:-/app/srv/fn/functions}"
chmod -R a+rwX "$FN_FUNCTIONS_ROOT" 2>/dev/null || true

# Optional Lua coverage for request/integration flows.
if [ "${FN_LUA_COVERAGE:-0}" = "1" ]; then
  : "${FN_LUA_COVERAGE_STATS:=/tmp/luacov.stats.out}"
  : "${FN_LUA_COVERAGE_REPORT:=/tmp/luacov.report.out}"
  : "${LUACOV_CONFIG:=/tmp/.luacov}"
  export FN_LUA_COVERAGE_STATS FN_LUA_COVERAGE_REPORT LUACOV_CONFIG
  cat >"$LUACOV_CONFIG" <<EOF
statsfile = "${FN_LUA_COVERAGE_STATS}"
reportfile = "${FN_LUA_COVERAGE_REPORT}"
delete_stats = true
include = {
  "fastfn.core",
  "fastfn.http",
  "fastfn.console",
}
exclude = {
  "fastfn.console.asset",
}
tick = true
savestepsize = 10
EOF
  rm -f "$FN_LUA_COVERAGE_STATS" "$FN_LUA_COVERAGE_REPORT"
fi

# When the container runs as an arbitrary UID (dev default), tools that rely on
# $HOME/.cache (Go, npm, cargo, etc.) can fall back to unwritable paths like
# /.cache or /.cargo. Keep all caches under /tmp/fastfn so builds work as non-root.
HOME="/tmp/fastfn/home"
XDG_CACHE_HOME="/tmp/fastfn/cache"
GOPATH="/tmp/fastfn/go"
GOCACHE="/tmp/fastfn/go-build-cache"
NPM_CONFIG_CACHE="/tmp/fastfn/npm-cache"
CARGO_HOME="/tmp/fastfn/cargo"
RUSTUP_HOME="/tmp/fastfn/rustup"
export HOME XDG_CACHE_HOME GOPATH GOCACHE NPM_CONFIG_CACHE CARGO_HOME RUSTUP_HOME
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$GOPATH" "$GOCACHE" "$NPM_CONFIG_CACHE" "$CARGO_HOME" "$RUSTUP_HOME"

RUNTIMES="${FN_RUNTIMES:-python,node,php,lua}"
PY_SOCKET="${FN_PY_SOCKET:-/tmp/fastfn/fn-python.sock}"
NODE_SOCKET="${FN_NODE_SOCKET:-/tmp/fastfn/fn-node.sock}"
PHP_SOCKET="${FN_PHP_SOCKET:-/tmp/fastfn/fn-php.sock}"
RUST_SOCKET="${FN_RUST_SOCKET:-/tmp/fastfn/fn-rust.sock}"
GO_SOCKET="${FN_GO_SOCKET:-/tmp/fastfn/fn-go.sock}"

has_runtime() {
  echo ",${RUNTIMES}," | grep -qi ",$1,"
}

supervisor_pids=""
SUPERVISOR_STOP_FILE="/tmp/fastfn/runtime-supervisor.stop"
rm -f "$SUPERVISOR_STOP_FILE"

check_runtime_daemon() {
  daemon="$1"
  if [ ! -f "$daemon" ]; then
    echo "missing runtime daemon: $daemon" >&2
    exit 1
  fi
}

ensure_socket_absent() {
  socket_path="$1"
  if [ ! -e "$socket_path" ]; then
    return 0
  fi
  if [ ! -S "$socket_path" ]; then
    echo "runtime socket path exists and is not a unix socket: $socket_path" >&2
    exit 1
  fi

  if python3 - "$socket_path" <<'PY'
import socket
import sys

path = sys.argv[1]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(0.2)
try:
    sock.connect(path)
except Exception:
    sys.exit(1)
else:
    sock.close()
    sys.exit(0)
PY
  then
    echo "runtime socket already in use: $socket_path" >&2
    exit 1
  fi

  rm -f "$socket_path"
}

run_supervised() {
  runtime_name="$1"
  shift
  (
    child_pid=""
    on_signal() {
      if [ -n "$child_pid" ]; then
        kill "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
      fi
      exit 0
    }
    trap on_signal INT TERM

    backoff=1
    while true; do
      if [ -f "$SUPERVISOR_STOP_FILE" ]; then
        exit 0
      fi

      "$@" &
      child_pid=$!
      if wait "$child_pid"; then
        exit_code=0
      else
        exit_code=$?
      fi
      child_pid=""

      if [ -f "$SUPERVISOR_STOP_FILE" ]; then
        exit 0
      fi

      echo "[$runtime_name] runtime exited (code=$exit_code), restarting in ${backoff}s" >&2
      sleep "$backoff" || true
      if [ "$backoff" -lt 8 ]; then
        backoff=$((backoff * 2))
      fi
    done
  ) &
  supervisor_pids="$supervisor_pids $!"
}

start_py() {
  daemon="/app/srv/fn/runtimes/python-daemon.py"
  check_runtime_daemon "$daemon"
  ensure_socket_absent "$PY_SOCKET"
  run_supervised "python" python3 "$daemon"
}

start_node() {
  daemon="/app/srv/fn/runtimes/node-daemon.js"
  check_runtime_daemon "$daemon"
  ensure_socket_absent "$NODE_SOCKET"
  run_supervised "node" node "$daemon"
}

start_php() {
  daemon="/app/srv/fn/runtimes/php-daemon.py"
  check_runtime_daemon "$daemon"
  ensure_socket_absent "$PHP_SOCKET"
  run_supervised "php" python3 "$daemon"
}

start_rust() {
  daemon="/app/srv/fn/runtimes/rust-daemon.py"
  check_runtime_daemon "$daemon"
  ensure_socket_absent "$RUST_SOCKET"
  run_supervised "rust" python3 "$daemon"
}

start_go() {
  daemon="/app/srv/fn/runtimes/go-daemon.py"
  check_runtime_daemon "$daemon"
  ensure_socket_absent "$GO_SOCKET"
  run_supervised "go" python3 "$daemon"
}

if has_runtime python; then
  start_py
fi
if has_runtime node; then
  start_node
fi
if has_runtime php; then
  start_php
fi
if has_runtime rust; then
  start_rust
fi
if has_runtime go; then
  start_go
fi

cleanup() {
  touch "$SUPERVISOR_STOP_FILE"
  for pid in $supervisor_pids; do
    kill "$pid" 2>/dev/null || true
  done
  wait $supervisor_pids 2>/dev/null || true
  rm -f "$SUPERVISOR_STOP_FILE"
}

trap cleanup INT TERM EXIT

exec openresty -e /dev/stderr -g "daemon off;" -p /app/openresty -c nginx.conf
