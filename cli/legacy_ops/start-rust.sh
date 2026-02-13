#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

export FN_RUST_SOCKET="${FN_RUST_SOCKET:-/tmp/fastfn/fn-rust.sock}"
exec python3 "$ROOT_DIR/srv/fn/runtimes/rust_daemon.py"
