#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_PY="$ROOT_DIR/scripts/ci/coverage_helpers.py"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/coverage}"
PYTHON_BIN="python3"
PHP_BIN="${PHP_BIN:-php}"
PY_SOURCE_DIR="$ROOT_DIR/examples/functions/python"
PY_TEST_DIR="$ROOT_DIR/tests/unit/python"
NODE_TEST_DIR="$ROOT_DIR/tests/unit/node"
PHP_DAEMON_TEST_FILE="$ROOT_DIR/tests/unit/test-php-daemon.php"
RUST_HANDLER_TEST_FILE="$ROOT_DIR/tests/unit/test-rust-handler.py"
PYTEST_WARNING_FLAGS=(
  "-W" "error::RuntimeWarning"
  "-W" "error::pytest.PytestUnraisableExceptionWarning"
)
MIN_PYTHON="${COVERAGE_MIN_PYTHON:-100}"
MIN_PYTHON_FILE="${COVERAGE_MIN_PYTHON_FILE:-$MIN_PYTHON}"
MIN_NODE="${COVERAGE_MIN_NODE:-100}"
MIN_NODE_FILE="${COVERAGE_MIN_NODE_FILE:-$MIN_NODE}"
MIN_COMBINED="${COVERAGE_MIN_COMBINED:-100}"
MIN_LUA="${COVERAGE_MIN_LUA:-100}"
MIN_LUA_FILE="${COVERAGE_MIN_LUA_FILE:-$MIN_LUA}"
MIN_PHP="${COVERAGE_MIN_PHP:-100}"
MIN_PHP_FILE="${COVERAGE_MIN_PHP_FILE:-$MIN_PHP}"
MIN_RUST="${COVERAGE_MIN_RUST:-100}"
MIN_RUST_FILE="${COVERAGE_MIN_RUST_FILE:-$MIN_RUST}"
MIN_GO_RT="${COVERAGE_MIN_GO_RT:-100}"
MIN_GO_RT_FILE="${COVERAGE_MIN_GO_RT_FILE:-$MIN_GO_RT}"
ENFORCE_LUA="${COVERAGE_ENFORCE_LUA:-1}"
ENFORCE_LUA_PER_FILE="${COVERAGE_ENFORCE_LUA_PER_FILE:-1}"

if [[ -n "${FORCE_COLOR:-}" && -n "${NO_COLOR:-}" ]]; then
  unset NO_COLOR
fi

# Run from cli/ to avoid shadowing installed python modules with repo root folders
# (for example, root-level ./coverage can shadow the coverage package).
cd "$ROOT_DIR/cli"
export PATH="$ROOT_DIR/node_modules/.bin:$PATH"

if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
  export PATH="$ROOT_DIR/.venv/bin:$PATH"
  PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
fi

mkdir -p "$OUT_DIR/node"

echo "== hygiene checks =="
if rg -n "(__private|FASTFN_EXPOSE_INTERNALS)" "$ROOT_DIR/examples/functions/node" >/dev/null 2>&1; then
  echo "error: internal exports are forbidden in examples/functions/node" >&2
  rg -n "(__private|FASTFN_EXPOSE_INTERNALS)" "$ROOT_DIR/examples/functions/node" >&2 || true
  exit 1
fi

if ! "$PYTHON_BIN" -m coverage --version >/dev/null 2>&1; then
  echo "error: coverage.py is required (pip install coverage)" >&2
  exit 1
fi

if ! "$PYTHON_BIN" -c "import pytest" >/dev/null 2>&1; then
  echo "error: pytest is required for cli/coverage.sh (pip install pytest)" >&2
  exit 1
fi

REQUIRED_NODE_MAJOR="${FASTFN_COVERAGE_NODE_MAJOR:-20}"
if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required for cli/coverage.sh" >&2
  exit 1
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
NODE_VERSION="$(node -v)"
if [[ "$NODE_MAJOR" != "$REQUIRED_NODE_MAJOR" ]]; then
  echo "error: cli/coverage.sh must run with Node ${REQUIRED_NODE_MAJOR}.x to match CI c8 coverage mapping (found ${NODE_VERSION})" >&2
  echo "hint: run 'nvm use ${REQUIRED_NODE_MAJOR}' (see $ROOT_DIR/.nvmrc) before validating coverage locally" >&2
  exit 1
fi

C8_CMD=(c8)
if ! command -v c8 >/dev/null 2>&1; then
  C8_CMD=(npx --yes c8)
fi

echo "== python coverage =="
"$PYTHON_BIN" -m coverage erase
"$PYTHON_BIN" -m coverage run --branch --source="$PY_SOURCE_DIR,$ROOT_DIR/srv/fn/runtimes" -m pytest "$PY_TEST_DIR" -v "${PYTEST_WARNING_FLAGS[@]}"
"$PYTHON_BIN" -m coverage xml -o "$OUT_DIR/python-coverage.xml"
"$PYTHON_BIN" -m coverage json -o "$OUT_DIR/python-coverage.json"
"$PYTHON_BIN" -m coverage report > "$OUT_DIR/python-coverage.txt"

echo "== node coverage =="
rm -rf "$OUT_DIR/node"
mkdir -p "$OUT_DIR/node"
(
  cd "$ROOT_DIR"
  echo "[node] running unit tests with V8 coverage in stable batches..."
  export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096}"
  export NODE_V8_COVERAGE="$OUT_DIR/node/tmp"
  : > "$OUT_DIR/node-test-output.txt"

  run_node_batch() {
    local label="$1"
    shift
    echo "[node] batch: $label" | tee -a "$OUT_DIR/node-test-output.txt"
    env -u NO_COLOR bash "$ROOT_DIR/scripts/ci/run_jest.sh" "$@" --runInBand --silent 2>&1 | tee -a "$OUT_DIR/node-test-output.txt"
  }

  run_node_batch "node-daemon helpers" \
    tests/unit/node/node-daemon.test.js \
    --testNamePattern 'sanitizeWorkerEnv|internal helper guards|root assets directory'

  run_node_batch "node-daemon core" \
    tests/unit/node/node-daemon.test.js \
    --testNamePattern 'handleRequest validation|unknown function|invalid function names|collectHandlerPaths|magic responses|contract responses|csv responses|handler and adapter config|handleRequest resolves explicit functions through fn_source_dir|lambda adapter|cloudflare adapter|entrypoint discovery|hot reload|env features|misc features'

  run_node_batch "node-daemon deps isolation" \
    tests/unit/node/node-daemon.test.js \
    --testNamePattern 'deps isolation between functions'

  run_node_batch "node-daemon comprehensive" \
    tests/unit/node/node-daemon.test.js \
    --testNamePattern 'comprehensive coverage'

  run_node_batch "remaining node suites" \
    tests/unit/node/node-daemon-adapters.test.js \
    tests/unit/node/ai-tool-agent.test.js \
    tests/unit/node/echo.test.js \
    tests/unit/node/edge-auth-gateway.test.js \
    tests/unit/node/edge-filter.test.js \
    tests/unit/node/edge-header-inject.test.js \
    tests/unit/node/edge-proxy.test.js \
    tests/unit/node/hello.test.js \
    tests/unit/node/ip-intel.test.js \
    tests/unit/node/request-inspector.test.js \
    tests/unit/node/telegram-ai-digest.test.js \
    tests/unit/node/telegram-ai-reply.test.js \
    tests/unit/node/telegram-send.test.js \
    tests/unit/node/toolbox-bot.test.js \
    tests/unit/node/whatsapp.test.js

  env -u NO_COLOR "${C8_CMD[@]}" report --reporter=text --temp-directory "$OUT_DIR/node/tmp" --report-dir "$OUT_DIR/node" \
    | tee "$OUT_DIR/node-coverage.txt"
  env -u NO_COLOR "${C8_CMD[@]}" report --reporter=json-summary --temp-directory "$OUT_DIR/node/tmp" --report-dir "$OUT_DIR/node" >/dev/null
  env -u NO_COLOR "${C8_CMD[@]}" report --reporter=lcov --temp-directory "$OUT_DIR/node/tmp" --report-dir "$OUT_DIR/node" >/dev/null
)

echo "== lua coverage =="
rm -rf "$OUT_DIR/lua"
mkdir -p "$OUT_DIR/lua"
if command -v docker >/dev/null 2>&1; then
  echo "[lua] running Lua coverage suite via Docker..."
  if ! LUA_COVERAGE=1 COVERAGE_DIR="$OUT_DIR/lua" "$ROOT_DIR/cli/test-lua.sh" 2>&1 | tee "$OUT_DIR/lua-coverage.txt"; then
    echo "lua coverage failed; see $OUT_DIR/lua-coverage.txt" >&2
    exit 1
  fi
else
  echo "lua coverage skipped (docker not found)" | tee "$OUT_DIR/lua-coverage.txt"
fi

# Convert luacov text report to lcov so Codecov can ingest Lua line coverage.
"$PYTHON_BIN" "$HELPER_PY" lua-report-to-lcov --report "$OUT_DIR/lua/luacov.report.out" --output "$OUT_DIR/lua/lcov.info" --root-dir "$ROOT_DIR"

echo "== php runtime coverage =="
if ! command -v "$PHP_BIN" >/dev/null 2>&1; then
  echo "error: php is required for cli/coverage.sh" >&2
  exit 1
fi
if ! "$PHP_BIN" -m | grep -qi '^xdebug$'; then
  echo "error: php xdebug extension is required for php runtime coverage" >&2
  exit 1
fi
XDEBUG_MODE=coverage "$PHP_BIN" "$PHP_DAEMON_TEST_FILE" \
  --coverage-json "$OUT_DIR/php-runtime-coverage.json" \
  --coverage-xml "$OUT_DIR/php-runtime-coverage.xml" \
  2>&1 | tee "$OUT_DIR/php-runtime-coverage.txt"

echo "== rust runtime coverage =="
"$PYTHON_BIN" -m coverage erase
"$PYTHON_BIN" -m coverage run --branch --source="$ROOT_DIR/srv/fn/runtimes" -m pytest "$PY_TEST_DIR/test_rust_daemon.py" -v "${PYTEST_WARNING_FLAGS[@]}"
if [[ -f "$RUST_HANDLER_TEST_FILE" ]] && command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
  "$PYTHON_BIN" -m coverage run -a --branch --source="$ROOT_DIR/srv/fn/runtimes" "$RUST_HANDLER_TEST_FILE"
fi
"$PYTHON_BIN" -m coverage xml --include="$ROOT_DIR/srv/fn/runtimes/rust-daemon.py" -o "$OUT_DIR/rust-runtime-coverage.xml"
"$PYTHON_BIN" -m coverage json --include="$ROOT_DIR/srv/fn/runtimes/rust-daemon.py" -o "$OUT_DIR/rust-runtime-coverage.json"
"$PYTHON_BIN" -m coverage report --include="$ROOT_DIR/srv/fn/runtimes/rust-daemon.py" > "$OUT_DIR/rust-runtime-coverage.txt"

echo "== go runtime coverage =="
"$PYTHON_BIN" -m coverage erase
"$PYTHON_BIN" -m coverage run --branch --source="$ROOT_DIR/srv/fn/runtimes" -m pytest "$PY_TEST_DIR/test_go_daemon.py" -v "${PYTEST_WARNING_FLAGS[@]}"
"$PYTHON_BIN" -m coverage xml --include="$ROOT_DIR/srv/fn/runtimes/go-daemon.py" -o "$OUT_DIR/go-runtime-coverage.xml"
"$PYTHON_BIN" -m coverage json --include="$ROOT_DIR/srv/fn/runtimes/go-daemon.py" -o "$OUT_DIR/go-runtime-coverage.json"
"$PYTHON_BIN" -m coverage report --include="$ROOT_DIR/srv/fn/runtimes/go-daemon.py" > "$OUT_DIR/go-runtime-coverage.txt"

echo "== coverage summary =="
COVERAGE_ENFORCE_LUA="$ENFORCE_LUA" "$PYTHON_BIN" "$HELPER_PY" write-summary --out-dir "$OUT_DIR"

echo "== coverage gates =="
"$PYTHON_BIN" "$ROOT_DIR/scripts/ci/check_line_coverage.py" \
  --format coveragepy \
  --input "$OUT_DIR/python-coverage.json" \
  --min-total "$MIN_PYTHON" \
  --min-file "$MIN_PYTHON_FILE" \
  --include-prefix "$PY_SOURCE_DIR/" \
  --output-json "$OUT_DIR/python-coverage-by-file.json"

"$PYTHON_BIN" "$ROOT_DIR/scripts/ci/check_line_coverage.py" \
  --format coveragepy \
  --input "$OUT_DIR/python-coverage.json" \
  --min-total "$MIN_PYTHON" \
  --min-file "$MIN_PYTHON_FILE" \
  --include-suffix "/srv/fn/runtimes/python-daemon.py" \
  --include-suffix "/srv/fn/runtimes/python-function-worker.py" \
  --output-json "$OUT_DIR/python-runtime-coverage-by-file.json"

"$PYTHON_BIN" "$ROOT_DIR/scripts/ci/check_line_coverage.py" \
  --format c8 \
  --input "$OUT_DIR/node/coverage-summary.json" \
  --min-total "$MIN_NODE" \
  --min-file "$MIN_NODE_FILE" \
  --include-prefix "$ROOT_DIR/examples/functions/" \
  --output-json "$OUT_DIR/node/coverage-by-file.json"

"$PYTHON_BIN" "$ROOT_DIR/scripts/ci/check_line_coverage.py" \
  --format coveragepy \
  --input "$OUT_DIR/php-runtime-coverage.json" \
  --min-total "$MIN_PHP" \
  --min-file "$MIN_PHP_FILE" \
  --include-suffix "/srv/fn/runtimes/php-daemon.php" \
  --output-json "$OUT_DIR/php-runtime-coverage-by-file.json"

"$PYTHON_BIN" "$ROOT_DIR/scripts/ci/check_line_coverage.py" \
  --format coveragepy \
  --input "$OUT_DIR/rust-runtime-coverage.json" \
  --min-total "$MIN_RUST" \
  --min-file "$MIN_RUST_FILE" \
  --include-suffix "/srv/fn/runtimes/rust-daemon.py" \
  --output-json "$OUT_DIR/rust-runtime-coverage-by-file.json"

"$PYTHON_BIN" "$ROOT_DIR/scripts/ci/check_line_coverage.py" \
  --format coveragepy \
  --input "$OUT_DIR/go-runtime-coverage.json" \
  --min-total "$MIN_GO_RT" \
  --min-file "$MIN_GO_RT_FILE" \
  --include-suffix "/srv/fn/runtimes/go-daemon.py" \
  --output-json "$OUT_DIR/go-runtime-coverage-by-file.json"

if [[ "$ENFORCE_LUA_PER_FILE" == "1" || "$MIN_LUA_FILE" != "0" || "$MIN_LUA" != "0" ]]; then
  if [[ -f "$OUT_DIR/lua/luacov.report.out" ]]; then
    "$PYTHON_BIN" "$ROOT_DIR/scripts/ci/check_lua_coverage.py" \
      --report "$OUT_DIR/lua/luacov.report.out" \
      --min-total "$MIN_LUA" \
      --min-file "$MIN_LUA_FILE" \
      --output-json "$OUT_DIR/lua/coverage-by-file.json"
  elif [[ "$ENFORCE_LUA" == "1" || "$ENFORCE_LUA_PER_FILE" == "1" ]]; then
    echo "error: lua coverage report required but not found" >&2
    exit 1
  fi
fi

COVERAGE_MIN_PYTHON="$MIN_PYTHON" \
COVERAGE_MIN_NODE="$MIN_NODE" \
COVERAGE_MIN_COMBINED="$MIN_COMBINED" \
COVERAGE_MIN_LUA="$MIN_LUA" \
COVERAGE_MIN_PHP="$MIN_PHP" \
COVERAGE_MIN_RUST="$MIN_RUST" \
COVERAGE_ENFORCE_LUA="$ENFORCE_LUA" \
"$PYTHON_BIN" "$HELPER_PY" verify-summary --out-dir "$OUT_DIR"
