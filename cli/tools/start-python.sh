#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SOCKET_DIR="${FN_SOCKET_DIR:-/tmp/fastfn}"

mkdir -p "$SOCKET_DIR"

export FN_PY_SOCKET="${FN_PY_SOCKET:-$SOCKET_DIR/fn-python.sock}"
exec python3 "$ROOT_DIR/srv/fn/runtimes/python-daemon.py"
