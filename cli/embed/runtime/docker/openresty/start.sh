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
PYTHON_BIN="${FN_PYTHON_BIN:-python3}"
NODE_BIN="${FN_NODE_BIN:-node}"
PHP_BIN="${FN_PHP_BIN:-php}"
OPENRESTY_BIN="${FN_OPENRESTY_BIN:-openresty}"
FN_RUNTIME_LOG_FILE="${FN_RUNTIME_LOG_FILE:-/app/openresty/logs/runtime.log}"
START_HELPER="/app/docker/openresty/start_helper.py"
export FN_RUNTIME_LOG_FILE
mkdir -p "$(dirname "$FN_RUNTIME_LOG_FILE")"
touch "$FN_RUNTIME_LOG_FILE" 2>/dev/null || true

has_runtime() {
  echo ",${RUNTIMES}," | grep -qi ",$1,"
}

resolve_runtime_sockets() {
  "$PYTHON_BIN" "$START_HELPER" resolve-runtime-sockets --format json
}

runtime_socket_env_json="$(resolve_runtime_sockets)"

get_runtime_socket_env() {
  key="$1"
  printf '%s' "$runtime_socket_env_json" | "$PYTHON_BIN" -c '
import json
import sys

data = json.load(sys.stdin)
value = data.get(sys.argv[1], "")
if value is None:
    value = ""
print(value)
' "$key"
}

FN_RUNTIME_SOCKETS_RESOLVED="$(get_runtime_socket_env FN_RUNTIME_SOCKETS_RESOLVED)"
RT_PYTHON_COUNT="$(get_runtime_socket_env RT_PYTHON_COUNT)"
RT_NODE_COUNT="$(get_runtime_socket_env RT_NODE_COUNT)"
RT_PHP_COUNT="$(get_runtime_socket_env RT_PHP_COUNT)"
RT_RUST_COUNT="$(get_runtime_socket_env RT_RUST_COUNT)"
RT_GO_COUNT="$(get_runtime_socket_env RT_GO_COUNT)"
RT_PYTHON_SOCKET_1="$(get_runtime_socket_env RT_PYTHON_SOCKET_1)"
RT_NODE_SOCKET_1="$(get_runtime_socket_env RT_NODE_SOCKET_1)"
RT_PHP_SOCKET_1="$(get_runtime_socket_env RT_PHP_SOCKET_1)"
RT_RUST_SOCKET_1="$(get_runtime_socket_env RT_RUST_SOCKET_1)"
RT_GO_SOCKET_1="$(get_runtime_socket_env RT_GO_SOCKET_1)"
RT_PYTHON_URI_1="$(get_runtime_socket_env RT_PYTHON_URI_1)"
RT_NODE_URI_1="$(get_runtime_socket_env RT_NODE_URI_1)"
RT_PHP_URI_1="$(get_runtime_socket_env RT_PHP_URI_1)"
RT_RUST_URI_1="$(get_runtime_socket_env RT_RUST_URI_1)"
RT_GO_URI_1="$(get_runtime_socket_env RT_GO_URI_1)"
export FN_RUNTIME_SOCKETS_RESOLVED RT_PYTHON_COUNT RT_NODE_COUNT RT_PHP_COUNT RT_RUST_COUNT RT_GO_COUNT
export RT_PYTHON_SOCKET_1 RT_NODE_SOCKET_1 RT_PHP_SOCKET_1 RT_RUST_SOCKET_1 RT_GO_SOCKET_1
export RT_PYTHON_URI_1 RT_NODE_URI_1 RT_PHP_URI_1 RT_RUST_URI_1 RT_GO_URI_1
FN_RUNTIME_SOCKETS="$FN_RUNTIME_SOCKETS_RESOLVED"
export FN_RUNTIME_SOCKETS
PY_SOCKET="${RT_PYTHON_SOCKET_1:-${FN_PY_SOCKET:-/tmp/fastfn/fn-python.sock}}"
NODE_SOCKET="${RT_NODE_SOCKET_1:-${FN_NODE_SOCKET:-/tmp/fastfn/fn-node.sock}}"
PHP_SOCKET="${RT_PHP_SOCKET_1:-${FN_PHP_SOCKET:-/tmp/fastfn/fn-php.sock}}"
RUST_SOCKET="${RT_RUST_SOCKET_1:-${FN_RUST_SOCKET:-/tmp/fastfn/fn-rust.sock}}"
GO_SOCKET="${RT_GO_SOCKET_1:-${FN_GO_SOCKET:-/tmp/fastfn/fn-go.sock}}"
export FN_PY_SOCKET="$PY_SOCKET" FN_NODE_SOCKET="$NODE_SOCKET" FN_PHP_SOCKET="$PHP_SOCKET" FN_RUST_SOCKET="$RUST_SOCKET" FN_GO_SOCKET="$GO_SOCKET"

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

  if "$PYTHON_BIN" "$START_HELPER" socket-in-use --path "$socket_path"
  then
    echo "runtime socket already in use: $socket_path" >&2
    exit 1
  fi

  rm -f "$socket_path"
}

run_supervised() {
  service_label="$1"
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

      echo "[$service_label] runtime exited (code=$exit_code), restarting in ${backoff}s" >&2
      sleep "$backoff" || true
      if [ "$backoff" -lt 8 ]; then
        backoff=$((backoff * 2))
      fi
    done
  ) &
  supervisor_pids="$supervisor_pids $!"
}

runtime_count() {
  runtime_name="$1"
  upper_name="$(printf "%s" "$runtime_name" | tr '[:lower:]' '[:upper:]')"
  var_name="RT_${upper_name}_COUNT"
  value="$(printenv "$var_name" 2>/dev/null || true)"
  if [ -z "$value" ]; then
    printf '0\n'
  else
    printf '%s\n' "$value"
  fi
}

runtime_socket_path() {
  runtime_name="$1"
  index="$2"
  upper_name="$(printf "%s" "$runtime_name" | tr '[:lower:]' '[:upper:]')"
  var_name="RT_${upper_name}_SOCKET_${index}"
  value="$(printenv "$var_name" 2>/dev/null || true)"
  printf '%s\n' "$value"
}

start_runtime_instances() {
  runtime_name="$1"
  launcher="$2"
  daemon="$3"

  check_runtime_daemon "$daemon"
  count="$(runtime_count "$runtime_name")"
  if [ -z "$count" ] || [ "$count" -lt 1 ] 2>/dev/null; then
    count=1
  fi

  i=1
  while [ "$i" -le "$count" ]; do
    socket_path="$(runtime_socket_path "$runtime_name" "$i")"
    if [ -z "$socket_path" ]; then
      echo "missing socket path for $runtime_name instance $i" >&2
      exit 1
    fi
    ensure_socket_absent "$socket_path"
    service_name="$runtime_name"
    if [ "$count" -gt 1 ]; then
      service_name="${runtime_name}#${i}"
    fi
    run_supervised "$service_name" env \
      "FN_RUNTIME_INSTANCE_INDEX=$i" \
      "FN_RUNTIME_INSTANCE_COUNT=$count" \
      "$(case "$runtime_name" in
          python) printf 'FN_PY_SOCKET=%s' "$socket_path" ;;
          node) printf 'FN_NODE_SOCKET=%s' "$socket_path" ;;
          php) printf 'FN_PHP_SOCKET=%s' "$socket_path" ;;
          rust) printf 'FN_RUST_SOCKET=%s' "$socket_path" ;;
          go) printf 'FN_GO_SOCKET=%s' "$socket_path" ;;
        esac)" \
      "$launcher" "$daemon"
    i=$((i + 1))
  done
}

start_py() {
  daemon="/app/srv/fn/runtimes/python-daemon.py"
  start_runtime_instances "python" "$PYTHON_BIN" "$daemon"
}

start_node() {
  daemon="/app/srv/fn/runtimes/node-daemon.js"
  start_runtime_instances "node" "$NODE_BIN" "$daemon"
}

start_php() {
  daemon="/app/srv/fn/runtimes/php-daemon.php"
  start_runtime_instances "php" "$PHP_BIN" "$daemon"
}

start_rust() {
  daemon="/app/srv/fn/runtimes/rust-daemon.py"
  start_runtime_instances "rust" "$PYTHON_BIN" "$daemon"
}

start_go() {
  daemon="/app/srv/fn/runtimes/go-daemon.py"
  start_runtime_instances "go" "$PYTHON_BIN" "$daemon"
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

exec "$OPENRESTY_BIN" -e /dev/stderr -g "daemon off;" -p /app/openresty -c nginx.conf
