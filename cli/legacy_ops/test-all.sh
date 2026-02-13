#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "== unit: python =="
python3 "$ROOT_DIR/tests/unit/test_python_handlers.py"

echo "== unit: node =="
node "$ROOT_DIR/tests/unit/test_node_handler.js"

echo "== unit: rust handler shape =="
python3 "$ROOT_DIR/tests/unit/test_rust_handler.py"

if command -v php >/dev/null 2>&1; then
  echo "== unit: php =="
  php "$ROOT_DIR/tests/unit/test_php_handler.php"
else
  echo "== unit: php (skipped, php binary not found) =="
fi

echo "== unit: lua (openresty runtime) =="
"$ROOT_DIR/scripts/test-lua.sh"

echo "== integration: docker compose =="
"$ROOT_DIR/tests/integration/test_api.sh"

echo "all tests passed"
