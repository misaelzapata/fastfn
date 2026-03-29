#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
JEST_BIN="$ROOT_DIR/node_modules/.bin/jest"

if [[ -n "${FORCE_COLOR:-}" && -n "${NO_COLOR:-}" ]]; then
  unset NO_COLOR
fi

if [[ ! -x "$JEST_BIN" ]]; then
  echo "error: local Jest is required at $JEST_BIN" >&2
  echo "hint: run 'npm ci' in $ROOT_DIR before running Node tests" >&2
  exit 1
fi

exec env -u NO_COLOR "$JEST_BIN" "$@"
