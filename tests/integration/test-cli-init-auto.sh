#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK_DIR="$(mktemp -d -t fastfn-cli-init-auto.XXXXXX)"
STACK_PID=""
STACK_LOG=""
TEST_HOST="${TEST_HOST:-127.0.0.1}"
TEST_PORT="${TEST_PORT:-${FN_HOST_PORT:-8080}}"
BASE_URL="${BASE_URL:-http://${TEST_HOST}:${TEST_PORT}}"
CURL_CONNECT_TIMEOUT_SECS="${CURL_CONNECT_TIMEOUT_SECS:-2}"
CURL_MAX_TIME_SECS="${CURL_MAX_TIME_SECS:-30}"

export FN_HOST_PORT="${FN_HOST_PORT:-$TEST_PORT}"

curl_fastfn() {
  curl --connect-timeout "$CURL_CONNECT_TIMEOUT_SECS" --max-time "$CURL_MAX_TIME_SECS" "$@"
}

cleanup() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Ensure no previous stack leaks into this test run.
(cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true

wait_for_health() {
  local ready=0
  for _ in $(seq 1 90); do
    local code
    code="$(curl_fastfn -sS -o /tmp/fastfn-cli-init-health.out -w '%{http_code}' "${BASE_URL}/_fn/health" 2>/dev/null || true)"
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

wait_for_function_in_catalog() {
  local runtime="$1"
  local name="$2"
  local ready=0
  for _ in $(seq 1 30); do
    local catalog
    catalog="$(curl_fastfn -sS "${BASE_URL}/_fn/catalog" || true)"
    if CATALOG_JSON="$catalog" RUNTIME="$runtime" NAME="$name" python3 - <<'PY' >/dev/null 2>&1
import json
import os
obj = json.loads(os.environ.get("CATALOG_JSON") or "{}")
rt = obj.get("runtimes", {}).get(os.environ["RUNTIME"], {})
fns = rt.get("functions", {})
target = os.environ["NAME"]
if isinstance(fns, dict):
    raise SystemExit(0 if target in fns else 1)
if isinstance(fns, list):
    for item in fns:
        if isinstance(item, dict) and item.get("name") == target:
            raise SystemExit(0)
raise SystemExit(1)
PY
    then
      ready=1
      break
    fi
    sleep 1
  done

  if [[ "$ready" != "1" ]]; then
    echo "FAIL function not found in catalog runtime=${runtime} name=${name}"
    curl_fastfn -sS "${BASE_URL}/_fn/catalog" || true
    exit 1
  fi
}

wait_for_status() {
  local method="$1"
  local path="$2"
  local expected="${3:-200}"
  local ready=0
  for _ in $(seq 1 30); do
    local code
    code="$(curl_fastfn -sS -X "$method" -o /tmp/fastfn-cli-init-route.out -w '%{http_code}' "${BASE_URL}${path}" 2>/dev/null || true)"
    if [[ "$code" == "$expected" ]]; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" != "1" ]]; then
    echo "FAIL route not ready method=${method} path=${path} expected=${expected}"
    cat /tmp/fastfn-cli-init-route.out || true
    exit 1
  fi
}

assert_body_contains() {
  local method="$1"
  local path="$2"
  local needle="$3"
  local body
  body="$(curl_fastfn -sS -X "$method" "${BASE_URL}${path}")"
  if [[ "$body" != *"$needle"* ]]; then
    echo "FAIL $method $path missing body fragment: $needle"
    echo "Body: $body"
    exit 1
  fi
}

assert_status() {
  local method="$1"
  local path="$2"
  local expected="$3"
  local code
  code="$(curl_fastfn -sS -X "$method" -o /tmp/fastfn-cli-init-status.out -w '%{http_code}' "${BASE_URL}${path}")"
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL $method $path expected=$expected got=$code"
    cat /tmp/fastfn-cli-init-status.out || true
    exit 1
  fi
}

assert_invoke_hello_node() {
  local name="$1"
  local who="$2"
  local invoke
  invoke="$(curl_fastfn -sS -X POST "${BASE_URL}/_fn/invoke" \
    -H 'Content-Type: application/json' \
    --data "{\"runtime\":\"node\",\"name\":\"${name}\",\"method\":\"GET\",\"query\":{\"name\":\"${who}\"},\"body\":\"\"}")"

  INVOKE_JSON="$invoke" EXPECTED="$who" python3 - <<'PY'
import json
import os
obj = json.loads(os.environ["INVOKE_JSON"])
assert obj.get("status") == 200, obj
raw_body = obj.get("body") or ""
payload = json.loads(raw_body)
assert payload.get("message") == "Hello from FastFN Node!", payload
assert payload.get("input", {}).get("query", {}).get("name") == os.environ["EXPECTED"], payload
PY
}

if [[ ! -x "$ROOT_DIR/bin/fastfn" ]]; then
  "$ROOT_DIR/cli/build.sh"
elif find "$ROOT_DIR/cli" -type f -newer "$ROOT_DIR/bin/fastfn" -print -quit 2>/dev/null | grep -q .; then
  "$ROOT_DIR/cli/build.sh"
fi

echo "== cli init auto-discovery smoke =="
(
  cd "$WORK_DIR"
  "$ROOT_DIR/bin/fastfn" init alpha --template node >/tmp/fastfn-cli-init-alpha.log
)

STACK_LOG="$(mktemp -t fastfn-cli-init-stack.XXXXXX.log)"
(
  cd "$ROOT_DIR"
  FN_UI_ENABLED=0 FN_CONSOLE_WRITE_ENABLED=0 FN_ZERO_CONFIG_IGNORE_DIRS=dist,tmp ./bin/fastfn dev --build "$WORK_DIR" >"$STACK_LOG" 2>&1
) &
STACK_PID="$!"

wait_for_health
wait_for_function_in_catalog "node" "alpha"
assert_invoke_hello_node "alpha" "AutoOne"

echo "== create second function while dev is running =="
(
  cd "$WORK_DIR"
  "$ROOT_DIR/bin/fastfn" init beta --template node >/tmp/fastfn-cli-init-beta.log
  # Runtime can be omitted in fn.config.json; discovery should still work.
  python3 - <<'PY'
import json
from pathlib import Path
cfg = Path("node/beta/fn.config.json")
obj = json.loads(cfg.read_text(encoding="utf-8"))
obj.pop("runtime", None)
cfg.write_text(json.dumps(obj, indent=2) + "\n", encoding="utf-8")
PY
)

# No manual reload call here: watcher/discovery should pick up new function automatically.
wait_for_function_in_catalog "node" "beta"
assert_invoke_hello_node "beta" "AutoTwo"

echo "== create function without fn.config.json (file-only) =="
mkdir -p "$WORK_DIR/node/gamma"
cat > "$WORK_DIR/node/gamma/handler.js" <<'JS'
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ mode: "file-only", runtime: "node" }),
});
JS
wait_for_function_in_catalog "node" "gamma"
wait_for_status GET "/gamma" 200
assert_body_contains GET "/gamma" "\"mode\":\"file-only\""

echo "== create two files => two endpoints (no fn.config.json) =="
mkdir -p "$WORK_DIR/node/multi-endpoints"
cat > "$WORK_DIR/node/multi-endpoints/get.alpha.js" <<'JS'
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ endpoint: "alpha", runtime: "node" }),
});
JS
cat > "$WORK_DIR/node/multi-endpoints/get.beta.js" <<'JS'
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ endpoint: "beta", runtime: "node" }),
});
JS
wait_for_status GET "/node/multi-endpoints/alpha" 200
wait_for_status GET "/node/multi-endpoints/beta" 200
assert_body_contains GET "/node/multi-endpoints/alpha" "\"endpoint\":\"alpha\""
assert_body_contains GET "/node/multi-endpoints/beta" "\"endpoint\":\"beta\""

echo "== user-pasted noise cases (invalid config + ignored helper) =="
mkdir -p "$WORK_DIR/node/pasted"
cat > "$WORK_DIR/node/pasted/fn.config.json" <<'JSON'
{ invalid-json
JSON
cat > "$WORK_DIR/node/pasted/handler.js" <<'JS'
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ mode: "invalid-config-but-works" }),
});
JS
wait_for_status GET "/pasted" 200
assert_body_contains GET "/pasted" "\"mode\":\"invalid-config-but-works\""

mkdir -p "$WORK_DIR/node/ignored"
cat > "$WORK_DIR/node/ignored/_helper.js" <<'JS'
module.exports.handler = async () => ({ status: 200, headers: {}, body: "{}" });
JS
sleep 2
assert_status GET "/node/ignored/helper" 404

echo "== configurable ignored directories (env) =="
mkdir -p "$WORK_DIR/dist"
cat > "$WORK_DIR/dist/get.shadow.js" <<'JS'
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ shadowed: true }),
});
JS
sleep 2
assert_status GET "/dist/shadow" 404

echo "== fn.routes.json mapping override should win over file route =="
mkdir -p "$WORK_DIR/routes-override"
cat > "$WORK_DIR/routes-override/get.ping.js" <<'JS'
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ source: "file-route" }),
});
JS
cat > "$WORK_DIR/routes-override/manifest.js" <<'JS'
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ source: "manifest-route" }),
});
JS
cat > "$WORK_DIR/routes-override/fn.routes.json" <<'JSON'
{
  "routes": {
    "GET /routes-override/ping": "manifest.js"
  }
}
JSON
wait_for_status GET "/routes-override/ping" 200
assert_body_contains GET "/routes-override/ping" "\"source\":\"manifest-route\""

echo "== method-only file routes (simple style) =="
mkdir -p "$WORK_DIR/method-only"
cat > "$WORK_DIR/method-only/get.py" <<'PY'
def main(req):
    return {"ok": True, "mode": "method-only"}
PY
wait_for_status GET "/method-only" 200
assert_body_contains GET "/method-only" "\"mode\":\"method-only\""

echo "== fn.config.json overlay should not suppress file routes =="
mkdir -p "$WORK_DIR/config-overlay"
cat > "$WORK_DIR/config-overlay/fn.config.json" <<'JSON'
{
  "group": "integration",
  "timeout_ms": 1200,
  "invoke": { "methods": ["GET"] }
}
JSON
cat > "$WORK_DIR/config-overlay/get.js" <<'JS'
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ ok: true, mode: "config-overlay" }),
});
JS
wait_for_status GET "/config-overlay" 200
assert_body_contains GET "/config-overlay" "\"mode\":\"config-overlay\""

echo "PASS test-cli-init-auto.sh"
