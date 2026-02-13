#!/bin/sh
set -eu

mkdir -p /tmp/fastfn

python3 /app/srv/fn/runtimes/python_daemon.py &
PY_PID=$!

node /app/srv/fn/runtimes/node_daemon.js &
NODE_PID=$!

python3 /app/srv/fn/runtimes/php_daemon.py &
PHP_PID=$!

python3 /app/srv/fn/runtimes/rust_daemon.py &
RUST_PID=$!

cleanup() {
  kill "$PY_PID" "$NODE_PID" "$PHP_PID" "$RUST_PID" 2>/dev/null || true
}

trap cleanup INT TERM EXIT

exec openresty -g "daemon off;" -p /app/openresty -c nginx.conf
