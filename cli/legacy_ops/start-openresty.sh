#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$ROOT_DIR/openresty/logs"

export FN_FUNCTIONS_ROOT="${FN_FUNCTIONS_ROOT:-$ROOT_DIR/srv/fn/functions}"
export FN_SOCKET_BASE_DIR="${FN_SOCKET_BASE_DIR:-/tmp/fastfn}"
export FN_RUNTIMES="${FN_RUNTIMES:-python,node,php,rust}"
export FN_HOT_RELOAD="${FN_HOT_RELOAD:-1}"
export FN_HOT_RELOAD_INTERVAL="${FN_HOT_RELOAD_INTERVAL:-2}"

exec openresty -p "$ROOT_DIR/openresty" -c nginx.conf
