#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-60}"
KEEP_UP="${KEEP_UP:-0}"
BUILD_IMAGES="${BUILD_IMAGES:-1}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fastfn_integration_${RANDOM}_$$}"
DC=(docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.integration.yml")

export FN_CONSOLE_API_ENABLED="${FN_CONSOLE_API_ENABLED:-1}"
export FN_UI_ENABLED="${FN_UI_ENABLED:-1}"
export FN_CONSOLE_WRITE_ENABLED="${FN_CONSOLE_WRITE_ENABLED:-1}"
export FN_ADMIN_TOKEN="${FN_ADMIN_TOKEN:-test-admin-token}"
export FN_OPENAPI_INCLUDE_FN_PATHS="${FN_OPENAPI_INCLUDE_FN_PATHS:-1}"

# This suite mutates files under the functions root (config/env and job artifacts).
# Always run against a throwaway copy so we never modify tracked examples.
TMP_FUNCTIONS_ROOT=""
if [[ -z "${FN_FUNCTIONS_ROOT:-}" ]]; then
  TMP_FUNCTIONS_ROOT="$(mktemp -d -t fastfn-functions.XXXXXX)"
  cp -R "$ROOT_DIR/examples/functions/." "$TMP_FUNCTIONS_ROOT"/
  export FN_FUNCTIONS_ROOT="$TMP_FUNCTIONS_ROOT"
fi

dc_request() {
  local path="$1"
  "${DC[@]}" exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080$path'"
}

dc_status() {
  local path="$1"
  "${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' 'http://127.0.0.1:8080$path'"
}

dc_status_post() {
  local path="$1"
  "${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080$path'"
}

cleanup() {
  if [[ "$KEEP_UP" == "1" ]]; then
    return
  fi
  "${DC[@]}" down --remove-orphans >/dev/null 2>&1 || true
  if [[ -n "$TMP_FUNCTIONS_ROOT" ]]; then
    rm -rf "$TMP_FUNCTIONS_ROOT" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

assert_status() {
  local path="$1"
  local expected="$2"
  local code
  code="$(dc_status "$path")"
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL status for $path expected=$expected got=$code"
    echo "Body:"
    "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
    exit 1
  fi
}

assert_json_field() {
  local json="$1"
  local field="$2"
  local expected="$3"
  python3 - "$json" "$field" "$expected" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
field = sys.argv[2]
expected = sys.argv[3]

parts = field.split('.')
cur = obj
for p in parts:
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        raise SystemExit(f"Missing field: {field}")

if str(cur).lower() != expected.lower():
    raise SystemExit(f"Field {field} expected {expected} got {cur}")
PY
}

echo "== docker compose up =="
if [[ "$BUILD_IMAGES" == "1" ]]; then
  "${DC[@]}" up -d --build >/dev/null
else
  "${DC[@]}" up -d >/dev/null
fi

echo "== reset mutable example files =="
"${DC[@]}" exec -T openresty sh -lc "python3 -c 'import json; p=\"/app/srv/fn/functions/python/hello/fn.env.json\"; open(p,\"w\",encoding=\"utf-8\").write(json.dumps({},separators=(\",\",\":\"))+\"\\n\")'"
"${DC[@]}" exec -T openresty sh -lc "python3 -c 'import json; p=\"/app/srv/fn/functions/python/hello/fn.config.json\"; obj={\"invoke\":{\"query\":{\"name\":\"World\"},\"body\":\"\",\"summary\":\"Simple greeting function\",\"methods\":[\"GET\"]},\"timeout_ms\":1300,\"max_concurrency\":11,\"max_body_bytes\":262144,\"include_debug_headers\":False,\"response\":{\"include_debug_headers\":False}}; open(p,\"w\",encoding=\"utf-8\").write(json.dumps(obj,separators=(\",\",\":\"))+\"\\n\")'"
"${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-code?runtime=node&name=hello&version=v2' -H 'Content-Type: application/json' --data '{\"code\":\"exports.handler = async (event) => { const q = event.query || {}; const env = event.env || {}; const ctx = event.context || {}; const name = q.name || \\\"world\\\"; const debugEnabled = !!(ctx.debug && ctx.debug.enabled === true); const payload = { hello: (env.NODE_GREETING || \\\"v2\\\") + \\\"-\\\" + name }; if (debugEnabled) { payload.debug = { request_id: event.id, runtime: \\\"node\\\", function: \\\"hello\\\", trace_id: (ctx.user || {}).trace_id }; } return { status: 200, headers: { \\\"Content-Type\\\": \\\"application/json\\\" }, body: JSON.stringify(payload) }; };\\n\"}' >/tmp/reset-node-code.out"
"${DC[@]}" exec -T openresty sh -lc "rm -f /app/srv/fn/functions/python/cron-tick/count.txt || true"

echo "== wait for health =="
ready=0
for _ in $(seq 1 "$WAIT_SECS"); do
  if body="$(dc_request "/_fn/health" 2>/dev/null)"; then
    if python3 - "$body" 2>/dev/null <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
runtimes = obj.get("runtimes", {})
assert runtimes.get("python", {}).get("health", {}).get("up") is True
assert runtimes.get("node", {}).get("health", {}).get("up") is True
assert runtimes.get("php", {}).get("health", {}).get("up") is True
assert runtimes.get("rust", {}).get("health", {}).get("up") is True
PY
    then
      ready=1
      break
    fi
  fi
  sleep 1
done

if [[ "$ready" != "1" ]]; then
  echo "FAIL health did not become ready"
  "${DC[@]}" logs --tail=200
  exit 1
fi

echo "== test: health and reload endpoints =="
assert_status "/_fn/health" "200"
status_reload="$(dc_status_post "/_fn/reload")"
if [[ "$status_reload" != "200" ]]; then
  echo "FAIL status for /_fn/reload expected=200 got=$status_reload"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

echo "== test: catalog endpoint =="
catalog_json="$(dc_request "/_fn/catalog")"
python3 - "$catalog_json" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
runtimes = obj.get("runtimes") or {}
assert "python" in runtimes, obj
assert "node" in runtimes, obj
assert "php" in runtimes, obj
assert "rust" in runtimes, obj
py_list = ((runtimes.get("python") or {}).get("functions") or [])
node_list = ((runtimes.get("node") or {}).get("functions") or [])
php_list = ((runtimes.get("php") or {}).get("functions") or [])
rust_list = ((runtimes.get("rust") or {}).get("functions") or [])
py_names = {x.get("name") for x in py_list if isinstance(x, dict)}
node_names = {x.get("name") for x in node_list if isinstance(x, dict)}
php_names = {x.get("name") for x in php_list if isinstance(x, dict)}
rust_names = {x.get("name") for x in rust_list if isinstance(x, dict)}
assert "hello" in py_names, obj
assert "cron-tick" in py_names, obj
assert "stripe-webhook-verify" in py_names, obj
assert "sendgrid-send" in py_names, obj
assert "sheets-webapp-append" in py_names, obj
assert "custom-handler-demo" in py_names, obj
assert ("hello" in node_names) or ("node-echo" in node_names), obj
assert "custom-handler-demo" in node_names, obj
assert "slack-webhook" in node_names, obj
assert "discord-webhook" in node_names, obj
assert "notion-create-page" in node_names, obj
assert "php-profile" in php_names, obj
assert "rust-profile" in rust_names, obj
PY

echo "== test: invoke.handler custom name (node/python) =="
node_custom_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"runtime\":\"node\",\"name\":\"custom-handler-demo\",\"method\":\"GET\",\"query\":{\"name\":\"Codex\"},\"body\":\"\"}'")"
python3 - "$node_custom_resp" <<'PY'
import json
import sys
outer = json.loads(sys.argv[1])
inner = json.loads(outer.get("body") or "{}")
assert inner.get("runtime") == "node", inner
assert inner.get("handler") == "main", inner
assert inner.get("hello") == "Codex", inner
PY

py_custom_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"runtime\":\"python\",\"name\":\"custom-handler-demo\",\"method\":\"GET\",\"query\":{\"name\":\"Codex\"},\"body\":\"\"}'")"
python3 - "$py_custom_resp" <<'PY'
import json
import sys
outer = json.loads(sys.argv[1])
inner = json.loads(outer.get("body") or "{}")
assert inner.get("runtime") == "python", inner
assert inner.get("handler") == "main", inner
assert inner.get("hello") == "Codex", inner
PY

echo "== test: packs endpoint =="
assert_status "/_fn/packs" "200"
packs_json="$(dc_request "/_fn/packs")"
python3 - "$packs_json" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert "packs_root" in obj, obj
assert "runtimes" in obj, obj
assert isinstance(obj["runtimes"], dict)
PY

echo "== test: ui state endpoint =="
ui_state_get="$("${DC[@]}" exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080/_fn/ui-state'")"
python3 - "$ui_state_get" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
for k in ("ui_enabled", "api_enabled", "write_enabled", "local_only"):
    assert k in obj, obj
PY

ui_state_put="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/ui-state' -H 'Content-Type: application/json' --data '{\"ui_enabled\":true,\"api_enabled\":true,\"write_enabled\":true,\"local_only\":true}'")"
python3 - "$ui_state_put" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("ui_enabled") is True
assert obj.get("api_enabled") is True
assert obj.get("write_enabled") is True
assert obj.get("local_only") is True
PY

ui_state_post="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/ui-state' -H 'Content-Type: application/json' --data '{\"write_enabled\":true}'")"
python3 - "$ui_state_post" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("write_enabled") is True
PY

ui_state_patch="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PATCH 'http://127.0.0.1:8080/_fn/ui-state' -H 'Content-Type: application/json' --data '{\"local_only\":true}'")"
python3 - "$ui_state_patch" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("local_only") is True
PY

ui_state_delete="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X DELETE 'http://127.0.0.1:8080/_fn/ui-state'")"
python3 - "$ui_state_delete" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
for k in ("ui_enabled", "api_enabled", "write_enabled", "local_only"):
    assert k in obj, obj
PY

echo "== test: ui-state write gate =="
ui_state_disable_write="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/ui-state' -H 'Content-Type: application/json' --data '{\"write_enabled\":false}'")"
python3 - "$ui_state_disable_write" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("write_enabled") is False, obj
PY

ui_state_put_without_write_status="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/ui-state-write-gate.out -w '%{http_code}' -X PUT 'http://127.0.0.1:8080/_fn/ui-state' -H 'Content-Type: application/json' --data '{\"write_enabled\":true}'")"
if [[ "$ui_state_put_without_write_status" != "403" ]]; then
  echo "FAIL expected 403 when write is disabled, got $ui_state_put_without_write_status"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/ui-state-write-gate.out || true"
  exit 1
fi

ui_state_put_with_token="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/ui-state' -H 'x-fn-admin-token: $FN_ADMIN_TOKEN' -H 'Content-Type: application/json' --data '{\"write_enabled\":true}'")"
python3 - "$ui_state_put_with_token" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("write_enabled") is True, obj
PY

assert_status "/console" "200"
assert_status "/console/node/node-echo" "200"
console_gateway_tab_ok="$("${DC[@]}" exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080/console/gateway' | grep -q 'Gateway Routes' && echo yes || echo no")"
if [[ "$console_gateway_tab_ok" != "yes" ]]; then
  echo "FAIL console gateway tab content missing"
  exit 1
fi

console_scheduler_tab_ok="$("${DC[@]}" exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080/console/scheduler' | grep -q 'Scheduler' && echo yes || echo no")"
if [[ "$console_scheduler_tab_ok" != "yes" ]]; then
  echo "FAIL console scheduler tab content missing"
  exit 1
fi

echo "== test: openapi methods by function policy =="
assert_status "/openapi.json" "200"
openapi_json="$(dc_request "/openapi.json")"
assert_json_field "$openapi_json" "openapi" "3.1.0"
python3 - "$openapi_json" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
paths = obj.get("paths", {})
assert "/fn/hello" in paths
assert "/fn/hello@v2" in paths
assert "/fn/risk-score" in paths
assert "/fn/echo" in paths
assert "/fn/node-echo" in paths
assert "/fn/qr" in paths
assert "/fn/qr@v2" in paths
assert "/fn/php-profile" in paths
assert "/fn/cron-tick" in paths
assert "/fn/stripe-webhook-verify" in paths
assert "/fn/slack-webhook" in paths
assert "/fn/discord-webhook" in paths
assert "/fn/sendgrid-send" in paths
assert "/fn/sheets-webapp-append" in paths
assert "/fn/notion-create-page" in paths
assert "/fn/rust-profile" in paths
assert "/fn/gmail-send" in paths
assert "/fn/telegram-send" in paths

hello_ops = paths["/fn/hello"]
assert "get" in hello_ops
assert "post" not in hello_ops

hello_v2_ops = paths["/fn/hello@v2"]
assert "get" in hello_v2_ops
assert "post" not in hello_v2_ops

risk_ops = paths["/fn/risk-score"]
assert "get" in risk_ops
assert "post" in risk_ops

echo_ops = paths["/fn/echo"]
assert "get" in echo_ops
assert "post" not in echo_ops

node_echo_ops = paths["/fn/node-echo"]
assert "get" in node_echo_ops
assert "post" in node_echo_ops

qr_py_ops = paths["/fn/qr"]
assert "get" in qr_py_ops
assert "post" not in qr_py_ops

qr_node_ops = paths["/fn/qr@v2"]
assert "get" in qr_node_ops
assert "post" not in qr_node_ops

php_ops = paths["/fn/php-profile"]
assert "get" in php_ops
assert "post" not in php_ops

rust_ops = paths["/fn/rust-profile"]
assert "get" in rust_ops
assert "post" not in rust_ops

gmail_ops = paths["/fn/gmail-send"]
assert "get" in gmail_ops
assert "post" in gmail_ops

telegram_ops = paths["/fn/telegram-send"]
assert "get" in telegram_ops
assert "post" in telegram_ops
PY

echo "== test: core routes =="
hello_py="$(dc_request "/fn/hello?name=Integration")"
assert_json_field "$hello_py" "hello" "Integration"

hello_node="$(dc_request "/fn/hello@v2?name=NodeWay")"
assert_json_field "$hello_node" "hello" "v2-NodeWay"

echo_node="$(dc_request "/fn/echo?key=test")"
assert_json_field "$echo_node" "key" "test"
assert_json_field "$echo_node" "query.key" "test"

hello_php="$(dc_request "/fn/php-profile?name=PhpWay")"
assert_json_field "$hello_php" "runtime" "php"
assert_json_field "$hello_php" "hello" "php-PhpWay"

hello_rust="$(dc_request "/fn/rust-profile?name=RustWay")"
assert_json_field "$hello_rust" "runtime" "rust"
assert_json_field "$hello_rust" "hello" "rust-RustWay"

gmail_dry_run="$(dc_request "/fn/gmail-send?to=demo@example.com&subject=Hi&text=Hello&dry_run=true")"
assert_json_field "$gmail_dry_run" "channel" "gmail"
assert_json_field "$gmail_dry_run" "dry_run" "true"

telegram_dry_run="$(dc_request "/fn/telegram-send?chat_id=123456&text=Hola&dry_run=true")"
assert_json_field "$telegram_dry_run" "channel" "telegram"
assert_json_field "$telegram_dry_run" "dry_run" "true"

"${DC[@]}" exec -T openresty sh -lc "rm -rf /app/srv/fn/functions/python/qr/.deps /app/srv/fn/functions/node/qr/v2/node_modules"

qr_py_content_type="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -D - -o /tmp/qr_py.out 'http://127.0.0.1:8080/fn/qr?text=PythonQR' | awk 'BEGIN{IGNORECASE=1}/^Content-Type:/{print \$2}' | tr -d '\r'")"
if [[ "$qr_py_content_type" != image/svg+xml* ]]; then
  echo "FAIL expected image/svg+xml for /fn/qr got=$qr_py_content_type"
  exit 1
fi
qr_py_has_svg="$("${DC[@]}" exec -T openresty sh -lc "grep -q '<svg' /tmp/qr_py.out && echo yes || echo no")"
if [[ "$qr_py_has_svg" != "yes" ]]; then
  echo "FAIL expected SVG payload in /fn/qr response"
  exit 1
fi

qr_node_png_sig="$("${DC[@]}" exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080/fn/qr@v2?text=NodeQR' | od -An -tx1 -N 8 | tr -d '[:space:]'")"
if [[ "$qr_node_png_sig" != "89504e470d0a1a0a" ]]; then
  echo "FAIL invalid PNG signature from /fn/qr@v2: $qr_node_png_sig"
  exit 1
fi

python_qr_dep="$("${DC[@]}" exec -T openresty sh -lc "[ -d /app/srv/fn/functions/python/qr/.deps/qrcode ] && echo yes || echo no")"
if [[ "$python_qr_dep" != "yes" ]]; then
  echo "FAIL expected python QR dependency in /app/srv/fn/functions/python/qr/.deps/qrcode"
  exit 1
fi

node_qr_dep="$("${DC[@]}" exec -T openresty sh -lc "[ -d /app/srv/fn/functions/node/qr/v2/node_modules/qrcode ] && echo yes || echo no")"
if [[ "$node_qr_dep" != "yes" ]]; then
  echo "FAIL expected node QR dependency in /app/srv/fn/functions/node/qr/v2/node_modules/qrcode"
  exit 1
fi

echo "== test: method enforcement 405/200 =="
status_hello_post="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/fn/hello' -H 'Content-Type: application/json' --data '{\"name\":\"Nope\"}'")"
if [[ "$status_hello_post" != "405" ]]; then
  echo "FAIL expected POST /fn/hello => 405 got $status_hello_post"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

status_risk_post="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/fn/risk-score' -H 'Content-Type: application/json' --data '{\"email\":\"user@example.com\"}'")"
if [[ "$status_risk_post" != "200" ]]; then
  echo "FAIL expected POST /fn/risk-score => 200 got $status_risk_post"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

status_php_post="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/fn/php-profile' -H 'Content-Type: application/json' --data '{}'")"
if [[ "$status_php_post" != "405" ]]; then
  echo "FAIL expected POST /fn/php-profile => 405 got $status_php_post"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

echo "== test: function-config methods update reflected in gateway/openapi =="
update_node_methods_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-config?runtime=node&name=node-echo' -H 'Content-Type: application/json' --data '{\"invoke\":{\"methods\":[\"GET\"]}}'")"
python3 - "$update_node_methods_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
methods = obj.get("policy", {}).get("methods") or []
assert methods == ["GET"], methods
PY

node_echo_post_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/fn/node-echo' -H 'Content-Type: application/json' --data '{\"name\":\"Nope\"}'")"
if [[ "$node_echo_post_code" != "405" ]]; then
  echo "FAIL expected POST /fn/node-echo => 405 got $node_echo_post_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

openapi_after_methods="$(dc_request "/openapi.json")"
python3 - "$openapi_after_methods" <<'PY'
import json
import sys
paths = json.loads(sys.argv[1]).get("paths", {})
ops = paths["/fn/node-echo"]
assert "get" in ops
assert "post" not in ops
PY

invoke_node_echo_post_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"name\":\"node-echo\",\"method\":\"POST\",\"query\":{\"name\":\"Node\"},\"body\":\"\"}'")"
if [[ "$invoke_node_echo_post_code" != "405" ]]; then
  echo "FAIL expected /_fn/invoke node-echo POST => 405 got $invoke_node_echo_post_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

update_node_put_delete_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-config?runtime=node&name=node-echo' -H 'Content-Type: application/json' --data '{\"invoke\":{\"methods\":[\"PUT\",\"DELETE\"]}}'")"
python3 - "$update_node_put_delete_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
methods = obj.get("policy", {}).get("methods") or []
assert methods == ["PUT", "DELETE"], methods
PY

openapi_put_delete="$(dc_request "/openapi.json")"
python3 - "$openapi_put_delete" <<'PY'
import json
import sys
paths = json.loads(sys.argv[1]).get("paths", {})
ops = paths["/fn/node-echo"]
assert "put" in ops
assert "delete" in ops
assert "get" not in ops
assert "post" not in ops
PY

node_echo_get_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' 'http://127.0.0.1:8080/fn/node-echo?name=Nope'")"
if [[ "$node_echo_get_code" != "405" ]]; then
  echo "FAIL expected GET /fn/node-echo => 405 got $node_echo_get_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

node_echo_put_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X PUT 'http://127.0.0.1:8080/fn/node-echo?name=PutWay' -H 'Content-Type: application/json' --data '{}'")"
if [[ "$node_echo_put_code" != "200" ]]; then
  echo "FAIL expected PUT /fn/node-echo => 200 got $node_echo_put_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

node_echo_delete_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X DELETE 'http://127.0.0.1:8080/fn/node-echo?name=DeleteWay'")"
if [[ "$node_echo_delete_code" != "200" ]]; then
  echo "FAIL expected DELETE /fn/node-echo => 200 got $node_echo_delete_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

invoke_node_echo_put_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"name\":\"node-echo\",\"method\":\"PUT\",\"query\":{\"name\":\"ViaInvokePut\"},\"body\":\"{}\"}'")"
if [[ "$invoke_node_echo_put_code" != "200" ]]; then
  echo "FAIL expected /_fn/invoke node-echo PUT => 200 got $invoke_node_echo_put_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

invoke_node_echo_delete_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"name\":\"node-echo\",\"method\":\"DELETE\",\"query\":{\"name\":\"ViaInvokeDelete\"},\"body\":\"\"}'")"
if [[ "$invoke_node_echo_delete_code" != "200" ]]; then
  echo "FAIL expected /_fn/invoke node-echo DELETE => 200 got $invoke_node_echo_delete_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

restore_node_methods_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-config?runtime=node&name=node-echo' -H 'Content-Type: application/json' --data '{\"invoke\":{\"methods\":[\"GET\",\"POST\"]}}'")"
python3 - "$restore_node_methods_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
methods = obj.get("policy", {}).get("methods") or []
assert methods == ["GET", "POST"], methods
PY

node_echo_post_ok_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/fn/node-echo?name=Back' -H 'Content-Type: application/json' --data '{}'")"
if [[ "$node_echo_post_ok_code" != "200" ]]; then
  echo "FAIL expected POST /fn/node-echo => 200 after restore got $node_echo_post_ok_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

echo "== test: mapped endpoint route config and matching =="
map_route_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-config?runtime=node&name=node-echo' -H 'Content-Type: application/json' --data '{\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"/api/node-echo\"]}}'")"
python3 - "$map_route_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
methods = obj.get("policy", {}).get("methods") or []
assert methods == ["GET"], methods
meta = obj.get("metadata", {})
routes = (((meta.get("invoke") or {}).get("mapped_routes")) or [])
assert "/api/node-echo" in routes, routes
PY

mapped_echo_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' 'http://127.0.0.1:8080/api/node-echo?name=Mapped'")"
if [[ "$mapped_echo_code" != "200" ]]; then
  echo "FAIL expected GET /api/node-echo => 200 got $mapped_echo_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi
mapped_echo_resp="$("${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out")"
python3 - "$mapped_echo_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("runtime") == "node", obj
assert obj.get("function") == "node-echo", obj
assert obj.get("hello") == "Mapped", obj
PY

mapped_openapi="$(dc_request "/openapi.json")"
python3 - "$mapped_openapi" <<'PY'
import json
import sys
paths = json.loads(sys.argv[1]).get("paths", {})
assert "/api/node-echo" in paths, paths.keys()
ops = paths["/api/node-echo"]
assert "get" in ops, ops
assert "post" not in ops, ops
PY

unmapped_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' 'http://127.0.0.1:8080/api/not-found'")"
if [[ "$unmapped_code" != "404" ]]; then
  echo "FAIL expected GET /api/not-found => 404 got $unmapped_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

restore_map_route_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-config?runtime=node&name=node-echo' -H 'Content-Type: application/json' --data '{\"invoke\":{\"methods\":[\"GET\",\"POST\"],\"routes\":[]}}'")"
python3 - "$restore_map_route_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
methods = obj.get("policy", {}).get("methods") or []
assert methods == ["GET", "POST"], methods
routes = (((obj.get("metadata", {}).get("invoke") or {}).get("mapped_routes")) or [])
assert routes == [], routes
PY

echo "== test: invoke endpoint method alignment =="
invoke_hello_post_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"name\":\"hello\",\"method\":\"POST\",\"body\":\"{}\"}'")"
if [[ "$invoke_hello_post_code" != "405" ]]; then
  echo "FAIL expected /_fn/invoke hello POST => 405 got $invoke_hello_post_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

invoke_node_echo_get_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"runtime\":\"node\",\"name\":\"node-echo\",\"version\":null,\"method\":\"GET\",\"query\":{\"name\":\"Node\"},\"body\":\"\"}'")"
python3 - "$invoke_node_echo_get_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("status") == 200, obj
body = json.loads(obj.get("body", "{}"))
assert body.get("runtime") == "node", body
assert body.get("function") == "node-echo", body
assert body.get("hello") == "Node", body
PY

invoke_php_get_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"runtime\":\"php\",\"name\":\"php-profile\",\"method\":\"GET\",\"query\":{\"name\":\"InvokePHP\"}}'")"
python3 - "$invoke_php_get_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("status") == 200, obj
body = json.loads(obj.get("body", "{}"))
assert body.get("runtime") == "php", body
assert body.get("hello") == "php-InvokePHP", body
PY

invoke_rust_get_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"runtime\":\"rust\",\"name\":\"rust-profile\",\"method\":\"GET\",\"query\":{\"name\":\"InvokeRust\"}}'")"
python3 - "$invoke_rust_get_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("status") == 200, obj
body = json.loads(obj.get("body", "{}"))
assert body.get("runtime") == "rust", body
assert body.get("hello") == "rust-InvokeRust", body
PY

echo "== test: async jobs enqueue + result =="
job_create="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/jobs' -H 'Content-Type: application/json' --data '{\"name\":\"hello\",\"method\":\"GET\",\"query\":{\"name\":\"Job\"},\"body\":\"\"}'")"
job_id="$(python3 -c 'import json,sys; obj=json.loads(sys.argv[1]); print(obj.get("id") or "")' "$job_create")"
if [[ -z "$job_id" ]]; then
  echo "FAIL job id missing from create response"
  echo "$job_create"
  exit 1
fi

status=""
job_meta=""
for _ in $(seq 1 60); do
  job_meta="$("${DC[@]}" exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080/_fn/jobs/$job_id'")"
  status="$(python3 -c 'import json,sys; obj=json.loads(sys.argv[1]); print(obj.get("status") or "")' "$job_meta")"
  if [[ "$status" == "done" || "$status" == "failed" || "$status" == "canceled" ]]; then
    break
  fi
  sleep 1
done

if [[ "$status" != "done" ]]; then
  echo "FAIL expected job done, got status=$status"
  echo "$job_meta"
  exit 1
fi

job_result="$("${DC[@]}" exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080/_fn/jobs/$job_id/result'")"
python3 - "$job_result" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
assert obj.get("status") == 200, obj
assert isinstance(obj.get("headers") or {}, dict)
assert isinstance(obj.get("body") or "", str)
PY

job_method_not_allowed_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -D /tmp/jobs-hdr.out -o /tmp/jobs-body.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/_fn/jobs' -H 'Content-Type: application/json' --data '{\"name\":\"hello\",\"method\":\"POST\",\"body\":\"{}\"}'")"
if [[ "$job_method_not_allowed_code" != "405" ]]; then
  echo "FAIL expected /_fn/jobs hello POST => 405 got $job_method_not_allowed_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/jobs-body.out || true"
  exit 1
fi
allow_hdr="$("${DC[@]}" exec -T openresty sh -lc "awk 'BEGIN{IGNORECASE=1}/^Allow:/{print \$2}' /tmp/jobs-hdr.out | tr -d '\\r' | head -n1")"
if [[ "$allow_hdr" == "" ]]; then
  echo "FAIL expected Allow header for method not allowed in jobs"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/jobs-hdr.out || true"
  exit 1
fi

echo "== test: code edit API (versioned function) =="
code_update_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-code?runtime=node&name=hello&version=v2' -H 'Content-Type: application/json' --data '{\"code\":\"exports.handler = async (event) => { const q = event.query || {}; const name = q.name || \\\"world\\\"; return { status: 200, headers: { \\\"Content-Type\\\": \\\"application/json\\\" }, body: JSON.stringify({ hello: \\\"edited-\\\" + name }) }; };\\n\"}'")"
python3 - "$code_update_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("version") == "v2"
assert "edited-" in obj.get("code", "")
PY

hello_node_edited="$(dc_request "/fn/hello@v2?name=NodeWay")"
assert_json_field "$hello_node_edited" "hello" "edited-NodeWay"

# restore baseline code after edit check
"${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-code?runtime=node&name=hello&version=v2' -H 'Content-Type: application/json' --data '{\"code\":\"exports.handler = async (event) => { const q = event.query || {}; const env = event.env || {}; const ctx = event.context || {}; const name = q.name || \\\"world\\\"; const debugEnabled = !!(ctx.debug && ctx.debug.enabled === true); const payload = { hello: (env.NODE_GREETING || \\\"v2\\\") + \\\"-\\\" + name }; if (debugEnabled) { payload.debug = { request_id: event.id, runtime: \\\"node\\\", function: \\\"hello\\\", trace_id: (ctx.user || {}).trace_id }; } return { status: 200, headers: { \\\"Content-Type\\\": \\\"application/json\\\" }, body: JSON.stringify(payload) }; };\\n\"}' >/tmp/restore-node-code.out"

invoke_risk_post_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"name\":\"risk-score\",\"method\":\"POST\",\"body\":\"{}\"}'")"
if [[ "$invoke_risk_post_code" != "200" ]]; then
  echo "FAIL expected /_fn/invoke risk-score POST => 200 got $invoke_risk_post_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

echo "== test: html/csv/png demos =="
assert_status "/fn/html-demo" "200"
assert_status "/fn/csv-demo" "200"
assert_status "/fn/png-demo" "200"

content_type_html="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -D - -o /tmp/body.out 'http://127.0.0.1:8080/fn/html-demo' | awk 'BEGIN{IGNORECASE=1}/^Content-Type:/{print \$2}' | tr -d '\\r'")"
if [[ "$content_type_html" != text/html* ]]; then
  echo "FAIL expected text/html content-type for html-demo got=$content_type_html"
  exit 1
fi

content_type_csv="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -D - -o /tmp/body.out 'http://127.0.0.1:8080/fn/csv-demo' | awk 'BEGIN{IGNORECASE=1}/^Content-Type:/{print \$2}' | tr -d '\\r'")"
if [[ "$content_type_csv" != text/csv* ]]; then
  echo "FAIL expected text/csv content-type for csv-demo got=$content_type_csv"
  exit 1
fi

png_sig="$("${DC[@]}" exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080/fn/png-demo' | od -An -tx1 -N 8 | tr -d '[:space:]'")"
if [[ "$png_sig" != "89504e470d0a1a0a" ]]; then
  echo "FAIL invalid PNG signature: $png_sig"
  exit 1
fi

echo "== test: edge proxy (passthrough) =="
edge_out="$(dc_request "/fn/edge-proxy?key=test")"
python3 - "$edge_out" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("ok") is True, obj
assert obj.get("method") == "GET", obj
assert obj.get("path") == "/request-inspector", obj
assert (obj.get("query") or {}).get("via") == "edge-proxy", obj
hdrs = obj.get("headers") or {}
assert hdrs.get("x-fastfn-edge") == "1", hdrs
PY

echo "== test: shared_deps packs (python/node) =="
# Python pack providing qrcode
"${DC[@]}" exec -T openresty sh -lc "python3 -c 'import os; p=\"/app/srv/fn/functions/.fastfn/packs/python/qrcode_pack/requirements.txt\"; os.makedirs(os.path.dirname(p), exist_ok=True); open(p, \"w\", encoding=\"utf-8\").write(\"qrcode>=7.4\\n\")'"

# Python function uses pack (no local requirements.txt)
"${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/function?runtime=python&name=pack-qr' -H 'Content-Type: application/json' --data '{\"methods\":[\"GET\"],\"summary\":\"Pack QR\"}' >/tmp/pack-qr_create.out"
"${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=pack-qr' -H 'Content-Type: application/json' --data '{\"shared_deps\":[\"qrcode_pack\"],\"invoke\":{\"methods\":[\"GET\"],\"summary\":\"Pack QR (python)\"}}' >/tmp/pack-qr_cfg.out"
"${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-code?runtime=python&name=pack-qr' -H 'Content-Type: application/json' --data '{\"code\":\"import io\\nimport qrcode\\nimport qrcode.image.svg\\n\\n\\ndef handler(event):\\n    q = event.get(\\\"query\\\") or {}\\n    text = q.get(\\\"text\\\") or \\\"pack-qr\\\"\\n    img = qrcode.make(text, image_factory=qrcode.image.svg.SvgImage)\\n    buf = io.BytesIO()\\n    img.save(buf)\\n    svg = buf.getvalue().decode(\\\"utf-8\\\")\\n    return {\\n        \\\"status\\\": 200,\\n        \\\"headers\\\": {\\\"Content-Type\\\": \\\"image/svg+xml; charset=utf-8\\\"},\\n        \\\"body\\\": svg,\\n    }\\n\"}' >/tmp/pack-qr_code.out"
assert_status "/fn/pack-qr?text=hello" "200"

ct_pack_py="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -D - -o /tmp/body.out 'http://127.0.0.1:8080/fn/pack-qr?text=hi' | awk 'BEGIN{IGNORECASE=1}/^Content-Type:/{print \$2}' | tr -d '\\r'")"
if [[ "$ct_pack_py" != image/svg+xml* ]]; then
  echo "FAIL expected image/svg+xml content-type for pack-qr got=$ct_pack_py"
  exit 1
fi

# Node pack providing qrcode
"${DC[@]}" exec -T openresty sh -lc "python3 -c 'import json,os; p=\"/app/srv/fn/functions/.fastfn/packs/node/qrcode_pack/package.json\"; os.makedirs(os.path.dirname(p), exist_ok=True); obj={\"name\":\"fastfn-pack-qrcode\",\"version\":\"1.0.0\",\"private\":True,\"dependencies\":{\"qrcode\":\"^1.5.4\"}}; open(p,\"w\",encoding=\"utf-8\").write(json.dumps(obj, indent=2)+\"\\n\")'"

# Node function uses pack (no local package.json)
"${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/function?runtime=node&name=pack-qr-node' -H 'Content-Type: application/json' --data '{\"methods\":[\"GET\"],\"summary\":\"Pack QR Node\"}' >/tmp/pack-qr-node_create.out"
"${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-config?runtime=node&name=pack-qr-node' -H 'Content-Type: application/json' --data '{\"shared_deps\":[\"qrcode_pack\"],\"invoke\":{\"methods\":[\"GET\"],\"summary\":\"Pack QR (node)\"}}' >/tmp/pack-qr-node_cfg.out"
"${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-code?runtime=node&name=pack-qr-node' -H 'Content-Type: application/json' --data '{\"code\":\"const QRCode = require(\\\"qrcode\\\");\\n\\nexports.handler = async (event) => {\\n  const q = event.query || {};\\n  const text = q.text || \\\"pack-qr-node\\\";\\n  const png = await QRCode.toBuffer(text, { type: \\\"png\\\", width: 220, margin: 2 });\\n  return {\\n    status: 200,\\n    headers: { \\\"Content-Type\\\": \\\"image/png\\\" },\\n    is_base64: true,\\n    body_base64: png.toString(\\\"base64\\\"),\\n  };\\n};\\n\"}' >/tmp/pack-qr-node_code.out"
assert_status "/fn/pack-qr-node?text=hello" "200"

png_sig_pack="$("${DC[@]}" exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080/fn/pack-qr-node?text=hi' | od -An -tx1 -N 8 | tr -d '[:space:]'")"
if [[ "$png_sig_pack" != "89504e470d0a1a0a" ]]; then
  echo "FAIL invalid PNG signature from pack-qr-node: $png_sig_pack"
  exit 1
fi

echo "== test: console metadata + env/config updates =="
fn_py_meta="$(dc_request "/_fn/function?runtime=python&name=requirements-demo&include_code=0")"
python3 - "$fn_py_meta" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
meta = obj.get("metadata", {})
assert "requests" in (meta.get("python", {}).get("requirements", {}).get("inline") or [])
assert "requests" in (meta.get("python", {}).get("requirements", {}).get("file_entries") or [])
PY

echo "== test: popular integrations (dry_run by default) =="
slack_dry="$(dc_request "/fn/slack-webhook?text=Hello")"
python3 - "$slack_dry" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
assert obj.get("function") == "slack-webhook", obj
assert obj.get("dry_run") is True, obj
PY

discord_dry="$(dc_request "/fn/discord-webhook?content=Hello")"
python3 - "$discord_dry" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
assert obj.get("function") == "discord-webhook", obj
assert obj.get("dry_run") is True, obj
PY

sendgrid_dry="$(dc_request "/fn/sendgrid-send?to=demo@example.com&subject=Hi&text=Hello&dry_run=true")"
python3 - "$sendgrid_dry" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
assert obj.get("function") == "sendgrid-send", obj
assert obj.get("dry_run") is True, obj
PY

sheets_dry="$(dc_request "/fn/sheets-webapp-append?sheet=Sheet1&values=a,b,c&dry_run=true")"
python3 - "$sheets_dry" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
assert obj.get("function") == "sheets-webapp-append", obj
assert obj.get("dry_run") is True, obj
PY

notion_dry="$(dc_request "/fn/notion-create-page?title=Hello&content=World&dry_run=true")"
python3 - "$notion_dry" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
assert obj.get("function") == "notion-create-page", obj
assert obj.get("dry_run") is True, obj
PY

echo "== test: stripe webhook signature verify (enforced) =="
stripe_secret="whsec_test_secret"
"${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-env?runtime=python&name=stripe-webhook-verify' -H 'Content-Type: application/json' --data '{\"STRIPE_WEBHOOK_SECRET\":{\"value\":\"$stripe_secret\",\"is_secret\":true}}' >/tmp/stripe-env-set.out"

stripe_body='{"id":"evt_test","type":"payment_intent.succeeded"}'
stripe_ts="$(python3 -c 'import time; print(int(time.time()))')"
stripe_sig="$(python3 -c 'import hmac,hashlib,sys; secret=sys.argv[1]; ts=sys.argv[2]; body=sys.argv[3]; base=(ts+"."+body).encode("utf-8"); print(hmac.new(secret.encode("utf-8"), base, hashlib.sha256).hexdigest())' "$stripe_secret" "$stripe_ts" "$stripe_body")"

"${DC[@]}" exec -T openresty sh -lc "printf '%s' '$stripe_body' > /tmp/stripe-webhook.json"
stripe_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/fn/stripe-webhook-verify?dry_run=false&tolerance_s=300' -H 'Content-Type: application/json' -H 'Stripe-Signature: t=$stripe_ts,v1=$stripe_sig' --data-binary @/tmp/stripe-webhook.json")"
python3 - "$stripe_resp" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
assert obj.get("ok") is True, obj
PY

echo "== test: function detail does not expose raw config content ==" 
fn_hello_detail="$(dc_request "/_fn/function?runtime=python&name=hello&include_code=0")"
python3 - "$fn_hello_detail" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert "fn_config" not in obj
meta = obj.get("metadata", {})
env = meta.get("env", {})
assert "path" not in env
assert "meta_path" not in env
PY

update_env_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-env?runtime=python&name=hello' -H 'Content-Type: application/json' --data '{\"GREETING_PREFIX\":{\"value\":\"saludos\",\"is_secret\":false},\"DEMO_SECRET\":{\"value\":\"top-secret\",\"is_secret\":true}}'")"
python3 - "$update_env_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
entry = obj.get("fn_env", {}).get("GREETING_PREFIX") or {}
assert entry.get("value") == "saludos"
assert entry.get("is_secret") is False
secret = obj.get("fn_env", {}).get("DEMO_SECRET") or {}
assert secret.get("value") == "<hidden>"
assert secret.get("is_secret") is True
PY

env_file_after_update="$("${DC[@]}" exec -T openresty sh -lc "cat /app/srv/fn/functions/python/hello/fn.env.json")"
python3 - "$env_file_after_update" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("GREETING_PREFIX", {}).get("value") == "saludos", obj
assert obj.get("DEMO_SECRET", {}).get("is_secret") is True, obj
PY

hello_after_env="$(dc_request "/fn/hello?name=Ctx")"
assert_json_field "$hello_after_env" "hello" "saludos Ctx"

update_cfg_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=hello' -H 'Content-Type: application/json' --data '{\"timeout_ms\":1300,\"max_concurrency\":11,\"response\":{\"include_debug_headers\":true}}'")"
python3 - "$update_cfg_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
meta = obj.get("metadata", {})
assert obj.get("policy", {}).get("timeout_ms") == 1300
assert obj.get("policy", {}).get("max_concurrency") == 11
PY

echo "== test: schedules (every_seconds) =="
assert_status "/_fn/schedules" "200"

enable_sched_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=cron-tick' -H 'Content-Type: application/json' --data '{\"schedule\":{\"enabled\":true,\"every_seconds\":1,\"method\":\"GET\",\"query\":{\"action\":\"inc\"},\"headers\":{},\"body\":\"\",\"context\":{}}}'")"
python3 - "$enable_sched_resp" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
assert obj.get("name") == "cron-tick", obj
PY

status_reload2="$(dc_status_post "/_fn/reload")"
if [[ "$status_reload2" != "200" ]]; then
  echo "FAIL status for /_fn/reload expected=200 got=$status_reload2"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

seen=0
for _ in $(seq 1 8); do
  cron_body="$(dc_request "/fn/cron-tick?action=read")"
  if python3 - "$cron_body" 2>/dev/null <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
assert int(obj.get("count", 0)) >= 1
PY
  then
    seen=1
    break
  fi
  sleep 1
done
if [[ "$seen" != "1" ]]; then
  echo "FAIL schedule did not tick cron-tick (count>=1) within timeout"
  echo "$cron_body"
  exit 1
fi

hello_headers="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -D - -o /tmp/body.out 'http://127.0.0.1:8080/fn/hello?name=WithHeaders' | tr -d '\\r'")"
if ! printf '%s' "$hello_headers" | grep -qi '^X-Fn-Request-Id:'; then
  echo "FAIL expected X-Fn-Request-Id after include_debug_headers=true"
  echo "$hello_headers"
  exit 1
fi

echo "== test: invoke context forwarding =="
invoke_ctx_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"name\":\"hello\",\"method\":\"GET\",\"query\":{\"name\":\"CtxViaInvoke\"},\"context\":{\"trace_id\":\"abc-123\"}}'")"
python3 - "$invoke_ctx_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
body = json.loads(obj.get("body", "{}"))
assert body.get("hello") == "saludos CtxViaInvoke"
assert body.get("debug", {}).get("trace_id") == "abc-123"
assert body.get("debug", {}).get("request_id")
PY

invoke_echo_ctx_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data '{\"name\":\"echo\",\"method\":\"GET\",\"query\":{\"key\":\"ctx\"},\"context\":{\"trace_id\":\"trace-echo\"}}'")"
python3 - "$invoke_echo_ctx_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
body = json.loads(obj.get("body", "{}"))
assert body.get("key") == "ctx"
assert body.get("context", {}).get("user", {}).get("trace_id") == "trace-echo"
PY

echo "== test: 404 unknown function =="
assert_status "/fn/nope" "404"

echo "== test: 413 payload too large =="
status_413="$("${DC[@]}" exec -T openresty sh -lc "dd if=/dev/zero bs=1 count=1200000 2>/dev/null | tr '\\\\000' 'a' > /tmp/large_payload.txt && curl -sS -o /tmp/resp.out -w '%{http_code}' -X POST 'http://127.0.0.1:8080/fn/risk-score' --data-binary @/tmp/large_payload.txt")"
if [[ "$status_413" != "413" ]]; then
  echo "FAIL expected 413 got $status_413"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

echo "== test: runtime timeout 504 =="
timeout_cfg_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=slow' -H 'Content-Type: application/json' --data '{\"timeout_ms\":80,\"max_concurrency\":1,\"invoke\":{\"methods\":[\"GET\"]}}'")"
python3 - "$timeout_cfg_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("policy", {}).get("timeout_ms") == 80
assert obj.get("policy", {}).get("max_concurrency") == 1
PY

slow_timeout_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/resp.out -w '%{http_code}' 'http://127.0.0.1:8080/fn/slow?sleep_ms=220'")"
if [[ "$slow_timeout_code" != "504" ]]; then
  echo "FAIL expected /fn/slow timeout => 504 got $slow_timeout_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
  exit 1
fi

echo "== test: max_concurrency gate 429 =="
conc_cfg_resp="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=slow' -H 'Content-Type: application/json' --data '{\"timeout_ms\":1500,\"max_concurrency\":1,\"invoke\":{\"methods\":[\"GET\"]}}'")"
python3 - "$conc_cfg_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("policy", {}).get("timeout_ms") == 1500
assert obj.get("policy", {}).get("max_concurrency") == 1
PY

concurrency_codes="$("${DC[@]}" exec -T openresty sh -lc "(curl -sS -o /tmp/slow1.out -w '%{http_code}' 'http://127.0.0.1:8080/fn/slow?sleep_ms=800' > /tmp/slow1.code) & sleep 0.10; curl -sS -o /tmp/slow2.out -w '%{http_code}' 'http://127.0.0.1:8080/fn/slow?sleep_ms=800' > /tmp/slow2.code; wait; printf '%s %s' \"\$(cat /tmp/slow1.code)\" \"\$(cat /tmp/slow2.code)\"")"
python3 - "$concurrency_codes" <<'PY'
import sys
codes = sys.argv[1].split()
assert "200" in codes, codes
assert "429" in codes, codes
PY

echo "== test: strict fs sandbox defaults (python/node) =="
"${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/strict_del_py.out -w '%{http_code}' -X DELETE 'http://127.0.0.1:8080/_fn/function?runtime=python&name=strict_fs_py' >/dev/null || true"
"${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/strict_del_node.out -w '%{http_code}' -X DELETE 'http://127.0.0.1:8080/_fn/function?runtime=node&name=strict_fs_node' >/dev/null || true"

strict_py_create="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/function?runtime=python&name=strict_fs_py' -H 'Content-Type: application/json' --data '{\"methods\":[\"GET\"],\"summary\":\"strict fs python probe\"}'")"
python3 - "$strict_py_create" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("name") == "strict_fs_py", obj
PY

strict_py_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-code?runtime=python&name=strict_fs_py' -H 'Content-Type: application/json' --data '{\"code\":\"import json\\nimport os\\n\\ndef handler(event):\\n    out = {}\\n    here = os.path.dirname(__file__)\\n    try:\\n        with open(os.path.join(here, \\\"app.py\\\"), \\\"r\\\", encoding=\\\"utf-8\\\") as f:\\n            f.read(1)\\n        out[\\\"self_read\\\"] = True\\n    except Exception as e:\\n        out[\\\"self_read\\\"] = False\\n        out[\\\"self_err\\\"] = str(e)\\n    try:\\n        with open(\\\"/app/openresty/nginx.conf\\\", \\\"r\\\", encoding=\\\"utf-8\\\") as f:\\n            f.read(1)\\n        out[\\\"outside_read\\\"] = True\\n    except Exception as e:\\n        out[\\\"outside_read\\\"] = False\\n        out[\\\"outside_err\\\"] = str(e)\\n    try:\\n        with open(os.path.join(here, \\\"fn.config.json\\\"), \\\"r\\\", encoding=\\\"utf-8\\\") as f:\\n            f.read(1)\\n        out[\\\"config_read\\\"] = True\\n    except Exception as e:\\n        out[\\\"config_read\\\"] = False\\n        out[\\\"config_err\\\"] = str(e)\\n    return {\\\"status\\\": 200, \\\"headers\\\": {\\\"Content-Type\\\": \\\"application/json\\\"}, \\\"body\\\": json.dumps(out)}\\n\"}'")"
python3 - "$strict_py_code" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("name") == "strict_fs_py", obj
PY

strict_py_resp="$(dc_request "/fn/strict_fs_py")"
python3 - "$strict_py_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("self_read") is True, obj
assert obj.get("outside_read") is False, obj
assert obj.get("config_read") is False, obj
assert "path outside strict function sandbox" in (obj.get("outside_err") or ""), obj
assert "access to protected function config/env file denied" in (obj.get("config_err") or ""), obj
PY

strict_node_create="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/function?runtime=node&name=strict_fs_node' -H 'Content-Type: application/json' --data '{\"methods\":[\"GET\"],\"summary\":\"strict fs node probe\"}'")"
python3 - "$strict_node_create" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("name") == "strict_fs_node", obj
PY

strict_node_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-code?runtime=node&name=strict_fs_node' -H 'Content-Type: application/json' --data '{\"code\":\"const fs = require(\\\"fs\\\");\\nconst path = require(\\\"path\\\");\\nexports.handler = async () => {\\n  const out = {};\\n  try { fs.readFileSync(path.join(__dirname, \\\"app.js\\\"), \\\"utf8\\\"); out.self_read = true; } catch (e) { out.self_read = false; out.self_err = String(e); }\\n  try { fs.readFileSync(\\\"/app/openresty/nginx.conf\\\", \\\"utf8\\\"); out.outside_read = true; } catch (e) { out.outside_read = false; out.outside_err = String(e); }\\n  try { fs.readFileSync(path.join(__dirname, \\\"fn.config.json\\\"), \\\"utf8\\\"); out.config_read = true; } catch (e) { out.config_read = false; out.config_err = String(e); }\\n  return { status: 200, headers: { \\\"Content-Type\\\": \\\"application/json\\\" }, body: JSON.stringify(out) };\\n};\\n\"}'")"
python3 - "$strict_node_code" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("name") == "strict_fs_node", obj
PY

strict_node_resp="$(dc_request "/fn/strict_fs_node")"
python3 - "$strict_node_resp" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("self_read") is True, obj
assert obj.get("outside_read") is False, obj
assert obj.get("config_read") is False, obj
assert "path outside strict function sandbox" in (obj.get("outside_err") or ""), obj
assert "access to protected function config/env file denied" in (obj.get("config_err") or ""), obj
PY

"${DC[@]}" exec -T openresty sh -lc "curl -sS -X DELETE 'http://127.0.0.1:8080/_fn/function?runtime=python&name=strict_fs_py' >/tmp/strict_cleanup_py.out"
"${DC[@]}" exec -T openresty sh -lc "curl -sS -X DELETE 'http://127.0.0.1:8080/_fn/function?runtime=node&name=strict_fs_node' >/tmp/strict_cleanup_node.out"

echo "== test: docs recipes smoke (create/edit/invoke/delete) =="
"${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/demo_recipe_del.out -w '%{http_code}' -X DELETE 'http://127.0.0.1:8080/_fn/function?runtime=python&name=demo_recipe' >/dev/null || true"

demo_recipe_create="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X POST 'http://127.0.0.1:8080/_fn/function?runtime=python&name=demo_recipe' -H 'Content-Type: application/json' --data '{\"methods\":[\"GET\"],\"summary\":\"Demo creada por API\"}'")"
python3 - "$demo_recipe_create" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("name") == "demo_recipe", obj
PY

demo_recipe_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -X PUT 'http://127.0.0.1:8080/_fn/function-code?runtime=python&name=demo_recipe' -H 'Content-Type: application/json' --data '{\"code\":\"import json\\n\\ndef handler(event):\\n    q = event.get(\\\"query\\\") or {}\\n    return {\\\"status\\\":200,\\\"headers\\\":{\\\"Content-Type\\\":\\\"application/json\\\"},\\\"body\\\":json.dumps({\\\"demo\\\":q.get(\\\"name\\\",\\\"ok\\\")})}\\n\"}'")"
python3 - "$demo_recipe_code" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj.get("name") == "demo_recipe", obj
PY

demo_recipe_invoke="$(dc_request "/fn/demo_recipe?name=RecipeOK")"
assert_json_field "$demo_recipe_invoke" "demo" "RecipeOK"

demo_recipe_delete_code="$("${DC[@]}" exec -T openresty sh -lc "curl -sS -o /tmp/demo_recipe_del2.out -w '%{http_code}' -X DELETE 'http://127.0.0.1:8080/_fn/function?runtime=python&name=demo_recipe'")"
if [[ "$demo_recipe_delete_code" != "200" ]]; then
  echo "FAIL expected delete demo_recipe => 200 got $demo_recipe_delete_code"
  "${DC[@]}" exec -T openresty sh -lc "cat /tmp/demo_recipe_del2.out || true"
  exit 1
fi

echo "== test: stress smoke =="
stress_smoke() {
  local path="$1"
  local total="$2"
  local conc="$3"
  local allowed_csv="$4"
  # Run inside the container (integration compose intentionally does not publish host ports).
  "${DC[@]}" exec -T openresty sh -lc "
    set -euo pipefail
    PATH_REQ='$path'
    TOTAL='$total'
    CONC='$conc'
    ALLOWED='$allowed_csv'
    seq 1 \"\$TOTAL\" | xargs -P \"\$CONC\" -I{} sh -lc \"curl -sS -o /dev/null -w '%{http_code}\\n' 'http://127.0.0.1:8080'\$PATH_REQ || echo 0\" | sort | uniq -c > /tmp/stress_counts.out
    echo \"stress_counts for \$PATH_REQ:\"
    cat /tmp/stress_counts.out
    bad=\$(awk '{print \$2}' /tmp/stress_counts.out | tr -d '\\r' | grep -vE \"^(\${ALLOWED//,/|})\$\" || true)
    if [ -n \"\$bad\" ]; then
      echo \"unexpected statuses: \$(tr -d '\\n' </tmp/stress_counts.out | sed 's/  */ /g')\" >&2
      exit 1
    fi
  "
}

stress_smoke "/fn/hello?name=stress" 120 24 "200,429"
stress_smoke "/fn/slow?sleep_ms=120" 120 24 "200,429"

echo "== test: runtime down -> 503 =="
if "${DC[@]}" exec -T openresty sh -lc "pkill -f node-daemon.js >/dev/null 2>&1 || true"; then
  sleep 1
  status_503="$(dc_status "/fn/hello@v2?name=Down")"
  if [[ "$status_503" != "503" ]]; then
    echo "FAIL expected 503 got $status_503"
    "${DC[@]}" exec -T openresty sh -lc "cat /tmp/resp.out || true"
    exit 1
  fi
fi

echo "integration tests passed"
