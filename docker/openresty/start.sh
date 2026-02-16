#!/bin/sh
set -eu

mkdir -p /tmp/fastfn
chmod 1777 /tmp/fastfn 2>/dev/null || true

RUNTIMES="${FN_RUNTIMES:-python,node,php,lua}"

has_runtime() {
  echo ",${RUNTIMES}," | grep -qi ",$1,"
}

pids=""

start_py() {
  local daemon="/app/srv/fn/runtimes/python-daemon.py"
  if [ ! -f "$daemon" ]; then
    echo "missing runtime daemon: $daemon" >&2
    exit 1
  fi
  python3 "$daemon" &
  pids="$pids $!"
}

start_node() {
  local daemon="/app/srv/fn/runtimes/node-daemon.js"
  if [ ! -f "$daemon" ]; then
    echo "missing runtime daemon: $daemon" >&2
    exit 1
  fi
  node "$daemon" &
  pids="$pids $!"
}

start_php() {
  local daemon="/app/srv/fn/runtimes/php-daemon.py"
  if [ ! -f "$daemon" ]; then
    echo "missing runtime daemon: $daemon" >&2
    exit 1
  fi
  python3 "$daemon" &
  pids="$pids $!"
}

start_rust() {
  local daemon="/app/srv/fn/runtimes/rust-daemon.py"
  if [ ! -f "$daemon" ]; then
    echo "missing runtime daemon: $daemon" >&2
    exit 1
  fi
  python3 "$daemon" &
  pids="$pids $!"
}

start_go() {
  local daemon="/app/srv/fn/runtimes/go-daemon.py"
  if [ ! -f "$daemon" ]; then
    echo "missing runtime daemon: $daemon" >&2
    exit 1
  fi
  python3 "$daemon" &
  pids="$pids $!"
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
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
}

trap cleanup INT TERM EXIT

exec openresty -g "daemon off;" -p /app/openresty -c nginx.conf
