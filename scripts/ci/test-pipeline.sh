#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_UI_E2E="${RUN_UI_E2E:-1}"
PIPELINE_STARTED_AT="$(date +%s)"
CURRENT_STAGE=""

if [ -n "${FORCE_COLOR:-}" ] && [ -n "${NO_COLOR:-}" ]; then
  unset NO_COLOR
fi

log() {
  printf '[pipeline] %s\n' "$1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

check_native_prereqs() {
  if [ -x "/usr/local/openresty/bin/openresty" ]; then
    PATH="/usr/local/openresty/bin:$PATH"
    export PATH
  fi

  if has_cmd openresty; then
    return 0
  fi
  if [ "${FN_REQUIRE_NATIVE_DEPS:-0}" = "1" ] || [ "${CI:-}" = "true" ]; then
    log "fail: native parity requires openresty in PATH (install it in CI runner before test-all.sh)"
    return 1
  fi
  log "warn: openresty not found; native parity test may skip"
  return 0
}

dump_debug_info() {
  exit_code="$1"
  log "failed at stage: ${CURRENT_STAGE:-unknown} (exit=${exit_code})"
  (cd "$ROOT_DIR" && docker compose ps) || true
  (cd "$ROOT_DIR" && docker compose logs --no-color --timestamps --tail=200) || true
}

on_exit() {
  exit_code="$1"
  if [ "$exit_code" -ne 0 ]; then
    dump_debug_info "$exit_code"
  fi
  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
}

trap 'on_exit $?' EXIT

run_stage() {
  label="$1"
  shift
  CURRENT_STAGE="$label"
  started_at=
  started_at="$(date +%s)"
  log "start: $label"
  "$@"
  ended_at=
  ended_at="$(date +%s)"
  log "ok: $label ($((ended_at-started_at))s)"
}

USE_BASH=0
if [ "${FN_FORCE_NO_BASH:-0}" != "1" ] && has_cmd bash; then
  USE_BASH=1
fi

if [ "$USE_BASH" = "1" ]; then
  run_stage "repo layout" "$ROOT_DIR/scripts/ci/check-repo-layout.sh"
  run_stage "docs path neutrality" python3 "$ROOT_DIR/scripts/docs/check_path_neutrality.py"
  run_stage "cli build" "$ROOT_DIR/cli/build.sh"
  run_stage "native deps preflight" check_native_prereqs
  run_stage "core suite (unit + integration)" "$ROOT_DIR/cli/test-all.sh"
  if [ "$RUN_UI_E2E" = "1" ]; then
    run_stage "ui e2e (playwright)" "$ROOT_DIR/cli/test-playwright.sh"
  else
    log "skip: ui e2e (RUN_UI_E2E=$RUN_UI_E2E)"
  fi
else
  log "bash not found: running no-bash CI subset"
  run_stage "repo layout" "$ROOT_DIR/scripts/ci/check-repo-layout.sh"
  run_stage "docs path neutrality" python3 "$ROOT_DIR/scripts/docs/check_path_neutrality.py"
  run_stage "go tests (cmd + process + embed)" sh -c "cd \"$ROOT_DIR/cli\" && go test ./cmd/... ./internal/process/... ./embed/runtime/..."
  run_stage "build fastfn binary" sh -c "cd \"$ROOT_DIR/cli\" && go build -o ../bin/fastfn"
  run_stage "python unit" python3 "$ROOT_DIR/tests/unit/test-python-handlers.py"
  run_stage "python daemon adapters" python3 "$ROOT_DIR/tests/unit/test-python-daemon-adapters.py"
  run_stage "go runtime unit" python3 "$ROOT_DIR/tests/unit/test-go-handler.py"
  if has_cmd node; then
    run_stage "node unit" node "$ROOT_DIR/tests/unit/test-node-handler.js"
    run_stage "node daemon adapters" node "$ROOT_DIR/tests/unit/test-node-daemon-adapters.js"
    run_stage "js sdk smoke" sh -c "cd \"$ROOT_DIR/sdk/js\" && node smoke.test.cjs"
  else
    log "warn: node not found, skipping node/js sdk checks"
  fi
  if has_cmd cargo && has_cmd rustc; then
    run_stage "rust sdk tests" sh -c "cd \"$ROOT_DIR/sdk/rust\" && cargo test --quiet"
  else
    log "warn: rust toolchain not found, skipping rust sdk checks"
  fi
  log "skip: bash-only integration suite (docker/openapi/native/playwright)"
fi

PIPELINE_FINISHED_AT="$(date +%s)"
log "pipeline passed in $((PIPELINE_FINISHED_AT-PIPELINE_STARTED_AT))s"
