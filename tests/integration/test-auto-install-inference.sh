#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER_PY="$ROOT_DIR/scripts/ci/fastfn_shell_helpers.py"
WORK_DIR="$(mktemp -d -t fastfn-auto-install-infer.XXXXXX)"
STACK_PID=""
STACK_LOG=""
TEST_HOST="${TEST_HOST:-127.0.0.1}"
TEST_PORT="${TEST_PORT:-${FN_HOST_PORT:-8080}}"
BASE_URL="${BASE_URL:-http://${TEST_HOST}:${TEST_PORT}}"

cleanup() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_health() {
  local ready=0
  for _ in $(seq 1 90); do
    local code
    code="$(curl -sS -o /tmp/fastfn-auto-infer-health.out -w '%{http_code}' "${BASE_URL}/_fn/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" != "1" ]]; then
    echo "FAIL health did not become ready"
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 200 "$STACK_LOG" || true
    exit 1
  fi
}

assert_status_and_contains() {
  local method="$1"
  local path="$2"
  local expected="$3"
  local needle="$4"
  local code
  code="$(curl -sS -X "$method" -o /tmp/fastfn-auto-infer-route.out -w '%{http_code}' "${BASE_URL}${path}")"
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL $method $path expected=$expected got=$code"
    cat /tmp/fastfn-auto-infer-route.out || true
    exit 1
  fi
  if ! grep -qi "$needle" /tmp/fastfn-auto-infer-route.out; then
    echo "FAIL $method $path missing fragment: $needle"
    cat /tmp/fastfn-auto-infer-route.out || true
    exit 1
  fi
}

assert_dependency_resolution_error() {
  local runtime="$1"
  local name="$2"
  local expected_fragment="$3"
  local payload
  payload="$(curl -sS "${BASE_URL}/_fn/function?runtime=${runtime}&name=${name}")"
  python3 "$HELPER_PY" dependency-resolution-error --json "$payload" --runtime "$runtime" --expected "$expected_fragment"
}

mkdir -p "$WORK_DIR/python/infer-py-fail"
cat > "$WORK_DIR/python/infer-py-fail/handler.py" <<'PY'
import json

def _deps_marker():
    import MyInternalSDK
    return MyInternalSDK

def handler(event):
    return {"status": 200, "body": json.dumps({"ok": True})}
PY

mkdir -p "$WORK_DIR/node/infer-node-fail"
cat > "$WORK_DIR/node/infer-node-fail/handler.js" <<'JS'
import broken from "@bad/";
export function handler() {
  return { status: 200, body: "ok" };
}
JS

STACK_LOG="$(mktemp -t fastfn-auto-infer-stack.XXXXXX.log)"
(
  cd "$ROOT_DIR"
  exec env FN_UI_ENABLED=0 \
  FN_CONSOLE_WRITE_ENABLED=0 \
  FN_AUTO_REQUIREMENTS=1 \
  FN_AUTO_NODE_DEPS=1 \
  FN_AUTO_INFER_PY_DEPS=1 \
  FN_AUTO_INFER_NODE_DEPS=1 \
  FN_AUTO_INFER_WRITE_MANIFEST=1 \
  FN_AUTO_INFER_STRICT=1 \
  ./bin/fastfn dev --build "$WORK_DIR" >"$STACK_LOG" 2>&1
) &
STACK_PID="$!"

wait_for_health

assert_status_and_contains GET "/infer-py-fail" "500" "unresolved imports"
assert_status_and_contains GET "/infer-node-fail" "500" "unresolved imports"

assert_dependency_resolution_error "python" "infer-py-fail" "MyInternalSDK"
assert_dependency_resolution_error "node" "infer-node-fail" "@bad/"

echo "auto-install inference integration checks passed"
