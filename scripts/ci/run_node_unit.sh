#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_JEST=(bash "$ROOT_DIR/scripts/ci/run_jest.sh" --runInBand --bail --no-coverage)
mapfile -t GENERAL_NODE_TESTS < <(
  find "$ROOT_DIR/tests/unit/node" -type f -name '*.test.js' \
    ! -name 'node-daemon.test.js' \
    ! -name 'node-daemon-adapters.test.js' \
    | sort
)

run_stage() {
  local label="$1"
  shift
  echo "== $label =="
  "$@"
}

if [[ "${#GENERAL_NODE_TESTS[@]}" -gt 0 ]]; then
  run_stage "unit: node (general)" "${RUN_JEST[@]}" "${GENERAL_NODE_TESTS[@]}"
fi

run_stage "unit: node (daemon helpers)" \
  "${RUN_JEST[@]}" --silent "$ROOT_DIR/tests/unit/node/node-daemon.test.js" \
  --testNamePattern 'sanitizeWorkerEnv|internal helper guards|root assets directory'

run_stage "unit: node (daemon core)" \
  "${RUN_JEST[@]}" --silent "$ROOT_DIR/tests/unit/node/node-daemon.test.js" \
  --testNamePattern 'handleRequest validation|unknown function|invalid function names|collectHandlerPaths|magic responses|contract responses|csv responses|handler and adapter config|handleRequest resolves explicit functions through fn_source_dir|lambda adapter|cloudflare adapter|entrypoint discovery|hot reload|env features|misc features'

run_stage "unit: node (deps isolation)" \
  "${RUN_JEST[@]}" --silent "$ROOT_DIR/tests/unit/node/node-daemon.test.js" \
  --testNamePattern 'deps isolation between functions'

run_stage "unit: node (comprehensive)" \
  "${RUN_JEST[@]}" --silent "$ROOT_DIR/tests/unit/node/node-daemon.test.js" \
  --testNamePattern 'comprehensive coverage'

run_stage "unit: node (adapters)" \
  "${RUN_JEST[@]}" --silent "$ROOT_DIR/tests/unit/node/node-daemon-adapters.test.js"
