#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${FASTFN_PREPUSH_DRY_RUN:-0}"
RUN_UI_E2E="${FASTFN_PREPUSH_UI_E2E:-1}"

if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
  export PATH="$ROOT_DIR/.venv/bin:$PATH"
fi

log() {
  printf '[pre-push] %s\n' "$1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_here() {
  local timeout_seconds="$1"
  shift
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run (${timeout_seconds}s): $*"
    return 0
  fi
  if has_cmd timeout; then
    timeout "${timeout_seconds}s" "$@"
    return
  fi
  "$@"
}

main() {
  log "Running full test gate before push"
  run_here 7200 env RUN_UI_E2E="$RUN_UI_E2E" bash scripts/ci/test-pipeline.sh
  log "Full suite passed"
}

main "$@"
