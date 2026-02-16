#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SOCKET_DIR="${FN_SOCKET_DIR:-/tmp/fastfn}"

if [[ -n "${FORCE_COLOR:-}" && -n "${NO_COLOR:-}" ]]; then
  unset NO_COLOR
fi

mkdir -p "$SOCKET_DIR"

export FN_NODE_SOCKET="${FN_NODE_SOCKET:-$SOCKET_DIR/fn-node.sock}"
exec env -u NO_COLOR node "$ROOT_DIR/srv/fn/runtimes/node-daemon.js"
