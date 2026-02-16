#!/bin/sh
set -eu

if [ -n "${FORCE_COLOR:-}" ] && [ -n "${NO_COLOR:-}" ]; then
  unset NO_COLOR
fi

mkdir -p /tmp/fastfn

PY_SOCKET="${FN_PY_SOCKET:-/tmp/fastfn/fn-python.sock}"
NODE_SOCKET="${FN_NODE_SOCKET:-/tmp/fastfn/fn-node.sock}"
PHP_SOCKET="${FN_PHP_SOCKET:-/tmp/fastfn/fn-php.sock}"
RUST_SOCKET="${FN_RUST_SOCKET:-/tmp/fastfn/fn-rust.sock}"
GO_SOCKET="${FN_GO_SOCKET:-/tmp/fastfn/fn-go.sock}"
WAIT_RUNTIME_READY="$(printf '%s' "${FN_WAIT_RUNTIME_READY_ON_START:-0}" | tr '[:upper:]' '[:lower:]')"
RUNTIMES_CSV="$(printf '%s' "${FN_RUNTIMES:-python,node,php,lua}" | tr '[:upper:]' '[:lower:]')"

runtime_enabled() {
  rt="$1"
  case ",$RUNTIMES_CSV," in
    *",$rt,"*) return 0 ;;
    *) return 1 ;;
  esac
}

wait_for_socket() {
  name="$1"
  socket_path="$2"
  pid="$3"
  attempts=200
  while [ "$attempts" -gt 0 ]; do
    if [ -S "$socket_path" ]; then
      if python3 -c 'import socket,sys;s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(0.2);s.connect(sys.argv[1]);s.close()' "$socket_path" >/dev/null 2>&1; then
        return 0
      fi
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[$name] daemon exited before creating socket: $socket_path" >&2
      return 1
    fi
    attempts=$((attempts - 1))
    sleep 0.05
  done
  echo "[$name] timed out waiting for runtime socket readiness: $socket_path" >&2
  return 1
}

PY_PID=""
NODE_PID=""
PHP_PID=""
RUST_PID=""
GO_PID=""

if runtime_enabled python; then
  python3 /app/srv/fn/runtimes/python-daemon.py &
  PY_PID=$!
fi

if runtime_enabled node; then
  env -u NO_COLOR node /app/srv/fn/runtimes/node-daemon.js &
  NODE_PID=$!
fi

if runtime_enabled php; then
  python3 /app/srv/fn/runtimes/php-daemon.py &
  PHP_PID=$!
fi

if runtime_enabled rust; then
  if command -v cargo >/dev/null 2>&1; then
    python3 /app/srv/fn/runtimes/rust-daemon.py &
    RUST_PID=$!
  else
    echo "[rust] disabled: cargo not found" >&2
  fi
fi

if runtime_enabled go; then
  if command -v go >/dev/null 2>&1; then
    python3 /app/srv/fn/runtimes/go-daemon.py &
    GO_PID=$!
  else
    echo "[go] disabled: go not found" >&2
  fi
fi

cleanup() {
  [ -n "$PY_PID" ] && kill "$PY_PID" 2>/dev/null || true
  [ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null || true
  [ -n "$PHP_PID" ] && kill "$PHP_PID" 2>/dev/null || true
  [ -n "$RUST_PID" ] && kill "$RUST_PID" 2>/dev/null || true
  [ -n "$GO_PID" ] && kill "$GO_PID" 2>/dev/null || true
}

trap cleanup INT TERM EXIT

if [ "$WAIT_RUNTIME_READY" = "1" ] || [ "$WAIT_RUNTIME_READY" = "true" ] || [ "$WAIT_RUNTIME_READY" = "yes" ] || [ "$WAIT_RUNTIME_READY" = "on" ]; then
  [ -n "$PY_PID" ] && wait_for_socket "python" "$PY_SOCKET" "$PY_PID"
  [ -n "$NODE_PID" ] && wait_for_socket "node" "$NODE_SOCKET" "$NODE_PID"
  [ -n "$PHP_PID" ] && wait_for_socket "php" "$PHP_SOCKET" "$PHP_PID"
  [ -n "$RUST_PID" ] && wait_for_socket "rust" "$RUST_SOCKET" "$RUST_PID"
  [ -n "$GO_PID" ] && wait_for_socket "go" "$GO_SOCKET" "$GO_PID"
fi

exec openresty -g "daemon off;" -p /app/openresty -c nginx.conf
