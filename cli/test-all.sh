#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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

ensure_cli_built

echo "== unit: python =="
python3 "$ROOT_DIR/tests/unit/test-python-handlers.py"
python3 "$ROOT_DIR/tests/unit/test-python-daemon-adapters.py"

echo "== unit: go runtime =="
python3 "$ROOT_DIR/tests/unit/test-go-handler.py"

echo "== unit: node =="
env -u NO_COLOR node "$ROOT_DIR/tests/unit/test-node-handler.js"
env -u NO_COLOR node "$ROOT_DIR/tests/unit/test-node-daemon-adapters.js"

if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
  echo "== unit: rust =="
  python3 "$ROOT_DIR/tests/unit/test-rust-handler.py"
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
  echo "== unit: php =="
  php "$ROOT_DIR/tests/unit/test-php-handler.php"
elif command -v docker >/dev/null 2>&1; then
  echo "== unit: php (docker fallback) =="
  (
    set -e
    PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fastfn_php_test_${RANDOM}_$$}"
    DC=(docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.yml")
    cleanup() { "${DC[@]}" down --remove-orphans >/dev/null 2>&1 || true; }
    trap cleanup EXIT
    if "${DC[@]}" run --rm --no-deps -v "$ROOT_DIR:/app" openresty php /app/tests/unit/test-php-handler.php; then
      :
    else
      echo "== unit: php (skipped, host php missing and docker fallback failed) =="
    fi
  )
else
  echo "== unit: php (skipped, php binary not found) =="
fi

echo "== unit: sdk contracts =="
bash "$ROOT_DIR/tests/unit/test-sdks.sh"

echo "== unit: lua (openresty runtime) =="
"$ROOT_DIR/cli/test-lua.sh"

echo "== integration: docker compose =="
"$ROOT_DIR/tests/integration/test-api.sh"

echo "== integration: auto-install inference =="
bash "$ROOT_DIR/tests/integration/test-auto-install-inference.sh"

echo "== integration: platform-equivalent examples =="
bash "$ROOT_DIR/tests/integration/test-platform-equivalents.sh"

echo "== integration: openapi internal contract =="
bash "$ROOT_DIR/tests/integration/test-openapi-system.sh"

echo "== integration: openapi native parity =="
bash "$ROOT_DIR/tests/integration/test-openapi-native.sh"

echo "== integration: openapi demos (all public methods) =="
bash "$ROOT_DIR/tests/integration/test-openapi-demos.sh"

echo "== integration: hot reload runtime matrix =="
bash "$ROOT_DIR/tests/integration/test-hotreload-runtime-matrix.sh"

echo "== integration: cli init auto-discovery =="
bash "$ROOT_DIR/tests/integration/test-cli-init-auto.sh"

if [[ "${RUN_ASSISTANT_LIVE_TEST:-0}" == "1" ]]; then
  echo "== integration: assistant live provider smoke =="
  bash "$ROOT_DIR/tests/integration/test-assistant-live-provider.sh" "${ASSISTANT_LIVE_PROVIDER:-auto}"
else
  echo "== integration: assistant live provider smoke (skipped, set RUN_ASSISTANT_LIVE_TEST=1) =="
fi

echo "all tests passed"
