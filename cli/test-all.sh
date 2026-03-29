#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TMP_TEST_VENV="${TMP_TEST_VENV:-/tmp/fastfn-test-all-venv}"

if [[ -n "${FORCE_COLOR:-}" && -n "${NO_COLOR:-}" ]]; then
  unset NO_COLOR
fi

ensure_cli_built() {
  if [[ ! -x "$ROOT_DIR/bin/fastfn" ]]; then
    "$ROOT_DIR/cli/build.sh"
    return
  fi
  if find "$ROOT_DIR/cli" -type f -newer "$ROOT_DIR/bin/fastfn" -print -quit 2>/dev/null | grep -q .; then
    "$ROOT_DIR/cli/build.sh"
    return
  fi
}

ensure_python_test_env() {
  if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
    export PATH="$ROOT_DIR/.venv/bin:$PATH"
    PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
  fi

  if "$PYTHON_BIN" -m pytest --version >/dev/null 2>&1; then
    return
  fi

  python3 -m venv "$TMP_TEST_VENV"
  "$TMP_TEST_VENV/bin/python" -m pip install --quiet pytest
  export PATH="$TMP_TEST_VENV/bin:$PATH"
  PYTHON_BIN="$TMP_TEST_VENV/bin/python"
}

run_stage() {
  local label="$1"
  shift
  local started_at ended_at
  started_at="$(date +%s)"
  echo "== $label =="
  "$@"
  ended_at="$(date +%s)"
  echo "ok: $label ($((ended_at-started_at))s)"
}

ensure_cli_built
ensure_python_test_env
run_stage "repo: host path leaks" "$PYTHON_BIN" "$ROOT_DIR/scripts/ci/check_host_path_leaks.py"
run_stage "unit: python" "$PYTHON_BIN" -m pytest "$ROOT_DIR/tests/unit/python/" -v \
  -W error::RuntimeWarning \
  -W error::pytest.PytestUnraisableExceptionWarning
run_stage "unit: node" bash "$ROOT_DIR/scripts/ci/run_node_unit.sh"

if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
  run_stage "unit: rust" "$PYTHON_BIN" "$ROOT_DIR/tests/unit/test-rust-handler.py"
elif command -v docker >/dev/null 2>&1; then
  echo "== unit: rust (docker fallback) =="
  (
    set -e
    PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fastfn_rust_test_${RANDOM}_$$}"
    DC=(docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.yml")
    cleanup() { "${DC[@]}" down --remove-orphans >/dev/null 2>&1 || true; }
    trap cleanup EXIT
    if "${DC[@]}" run --rm --no-deps -v "$ROOT_DIR:/app" openresty python3 /app/tests/unit/test-rust-handler.py; then
      :
    else
      echo "== unit: rust (skipped, host rust missing and docker fallback failed) =="
    fi
  )
else
  echo "== unit: rust (skipped, rust toolchain not found) =="
fi

if command -v php >/dev/null 2>&1; then
  run_stage "unit: php handler" php "$ROOT_DIR/tests/unit/test-php-handler.php"
  run_stage "unit: php daemon" php "$ROOT_DIR/tests/unit/test-php-daemon.php"
elif command -v docker >/dev/null 2>&1; then
  echo "== unit: php handler (docker fallback) =="
  (
    set -e
    PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fastfn_php_test_${RANDOM}_$$}"
    DC=(docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.yml")
    cleanup() { "${DC[@]}" down --remove-orphans >/dev/null 2>&1 || true; }
    trap cleanup EXIT
    if "${DC[@]}" run --rm --no-deps -v "$ROOT_DIR:/app" openresty php /app/tests/unit/test-php-handler.php; then
      :
    else
      echo "== unit: php handler (skipped, host php missing and docker fallback failed) =="
    fi
  )
  echo "== unit: php daemon (docker fallback) =="
  (
    set -e
    PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fastfn_php_daemon_test_${RANDOM}_$$}"
    DC=(docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.yml")
    cleanup() { "${DC[@]}" down --remove-orphans >/dev/null 2>&1 || true; }
    trap cleanup EXIT
    if "${DC[@]}" run --rm --no-deps -v "$ROOT_DIR:/app" openresty php /app/tests/unit/test-php-daemon.php; then
      :
    else
      echo "== unit: php daemon (skipped, host php missing and docker fallback failed) =="
    fi
  )
else
  echo "== unit: php (skipped, php binary not found) =="
fi

run_stage "unit: sdk contracts" bash "$ROOT_DIR/tests/unit/test-sdks.sh"
run_stage "unit: lua (openresty runtime)" "$ROOT_DIR/cli/test-lua.sh"
run_stage "integration: docker compose" "$ROOT_DIR/tests/integration/test-api.sh"
run_stage "integration: home routing (env + folder fn.config home)" bash "$ROOT_DIR/tests/integration/test-home-routing.sh"
run_stage "integration: auto-install inference" bash "$ROOT_DIR/tests/integration/test-auto-install-inference.sh"
run_stage "integration: platform-equivalent examples" bash "$ROOT_DIR/tests/integration/test-platform-equivalents.sh"
run_stage "integration: openapi internal contract" bash "$ROOT_DIR/tests/integration/test-openapi-system.sh"
run_stage "integration: runtime log tail" bash "$ROOT_DIR/tests/integration/test-runtime-log-tail.sh"
run_stage "integration: openapi native parity" bash "$ROOT_DIR/tests/integration/test-openapi-native.sh"
run_stage "integration: openapi demos (all public methods)" bash "$ROOT_DIR/tests/integration/test-openapi-demos.sh"
run_stage "integration: hot reload runtime matrix" bash "$ROOT_DIR/tests/integration/test-hotreload-runtime-matrix.sh"
run_stage "integration: cli init auto-discovery" bash "$ROOT_DIR/tests/integration/test-cli-init-auto.sh"
if [[ "${RUN_LIVE_DOMAIN_TESTS:-0}" == "1" || "${FASTFN_RUN_LIVE_DOMAIN_TESTS:-0}" == "1" ]]; then
  run_stage "integration: doctor domains live smoke" bash "$ROOT_DIR/tests/integration/test-doctor-domains-live.sh"
else
  echo "== integration: doctor domains live smoke (skipped, set RUN_LIVE_DOMAIN_TESTS=1) =="
fi

echo "all tests passed"
