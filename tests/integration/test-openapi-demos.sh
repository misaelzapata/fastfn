#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-120}"
KEEP_UP="${KEEP_UP:-0}"

STACK_PID=""
STACK_LOG=""

cleanup() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_UP" != "1" ]]; then
    (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  fi
}

trap cleanup EXIT

wait_for_health() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    local code
    code="$(curl -sS -o /tmp/fastfn-openapi-demos-health.out -w '%{http_code}' 'http://127.0.0.1:8080/_fn/health' 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      if python3 - <<'PY' >/dev/null 2>&1
import json
from pathlib import Path

obj = json.loads(Path("/tmp/fastfn-openapi-demos-health.out").read_text(encoding="utf-8"))
runtimes = obj.get("runtimes", {})
runtime_order = obj.get("runtime_order")

if isinstance(runtime_order, list) and runtime_order:
    required = [str(x) for x in runtime_order if isinstance(x, str) and x.strip()]
else:
    required = [str(x) for x in runtimes.keys() if isinstance(x, str)]

if not required:
    raise SystemExit(1)

for name in required:
    if runtimes.get(name, {}).get("health", {}).get("up") is not True:
        raise SystemExit(1)
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
    if [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]]; then
      tail -n 220 "$STACK_LOG" || true
    fi
    exit 1
  fi
}

start_stack() {
  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  STACK_LOG="$(mktemp -t fastfn-openapi-demos.XXXXXX.log)"
  (
    cd "$ROOT_DIR"
    env \
      FN_SCHEDULER_ENABLED=0 \
      FN_DEFAULT_TIMEOUT_MS="${FN_DEFAULT_TIMEOUT_MS:-90000}" \
      FN_RUNTIMES="${FN_RUNTIMES:-python,node,php,rust}" \
      EDGE_AUTH_TOKEN=dev-token \
      EDGE_FILTER_API_KEY=dev \
      GITHUB_WEBHOOK_SECRET=dev \
      ./bin/fastfn dev examples/functions >"$STACK_LOG" 2>&1
  ) &
  STACK_PID="$!"
  wait_for_health
}

warm_endpoint() {
  local path="$1"
  local expected="${2:-200}"
  local attempts="${3:-40}"
  local method="${4:-GET}"
  for _ in $(seq 1 "$attempts"); do
    local code
    code="$(curl -sS -X "$method" -o /tmp/fastfn-openapi-demos-warm.out -w '%{http_code}' "http://127.0.0.1:8080$path" 2>/dev/null || true)"
    if [[ "$code" == "$expected" ]]; then
      return 0
    fi
    if [[ "$code" == "400" || "$code" == "401" || "$code" == "404" || "$code" == "405" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "FAIL warm-up endpoint did not stabilize: $path"
  cat /tmp/fastfn-openapi-demos-warm.out || true
  exit 1
}

warm_heavy_endpoints() {
  warm_endpoint "/ts-hello?name=warm"
  warm_endpoint "/pack-qr-node?text=warm"
  warm_endpoint "/pack-qr?text=warm"
  warm_endpoint "/rust-profile?name=warm"
  warm_endpoint "/polyglot-tutorial/step-4"
  warm_endpoint "/polyglot-tutorial/step-5?name=warm"
  warm_endpoint "/polyglot-db-demo/items/demo" "404" "80" "DELETE"
}

assert_openapi_examples() {
  local openapi_json
  openapi_json="$(curl -sS 'http://127.0.0.1:8080/_fn/openapi.json')"
  OPENAPI_JSON="$openapi_json" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["OPENAPI_JSON"])
paths = obj.get("paths") or {}

assert "/node/fastfn-types/d" not in paths, "must not expose .d.ts helper files as API routes"

def query_param_map(op):
    out = {}
    for p in op.get("parameters") or []:
        if isinstance(p, dict) and p.get("in") == "query" and isinstance(p.get("name"), str):
            out[p["name"]] = p
    return out

telegram_send_get = ((paths.get("/telegram-send") or {}).get("get") or {})
q = query_param_map(telegram_send_get)
for required in ("chat_id", "text", "dry_run"):
    assert required in q, f"telegram-send GET missing query example param: {required}"

telegram_send_post = ((paths.get("/telegram-send") or {}).get("post") or {})
rb = (((telegram_send_post.get("requestBody") or {}).get("content") or {}).get("application/json") or {})
examples = rb.get("examples") or {}
example_values = [v.get("value") for v in examples.values() if isinstance(v, dict)]
has_chat = any(isinstance(v, dict) and ("chat_id" in v) for v in example_values)
assert has_chat, "telegram-send POST must expose chat_id example payload"

telegram_ai_reply_post = ((paths.get("/telegram-ai-reply") or {}).get("post") or {})
rb = (((telegram_ai_reply_post.get("requestBody") or {}).get("content") or {}).get("application/json") or {})
examples = rb.get("examples") or {}
example_values = [v.get("value") for v in examples.values() if isinstance(v, dict)]
has_update = False
for value in example_values:
    if isinstance(value, dict):
        msg = value.get("message")
        chat = (msg or {}).get("chat") if isinstance(msg, dict) else None
        if isinstance(chat, dict) and "id" in chat:
            has_update = True
            break
assert has_update, "telegram-ai-reply POST must expose webhook body example"

edge_get = ((paths.get("/edge-header-inject") or {}).get("get") or {})
edge_q = query_param_map(edge_get)
assert "tenant" in edge_q, "edge-header-inject GET missing tenant query example"

ip_remote = ((paths.get("/ip-intel/remote") or {}).get("get") or {})
ip_q = query_param_map(ip_remote)
for required in ("ip", "mock"):
    assert required in ip_q, f"ip-intel remote missing query param example: {required}"
PY
}

run_public_sweep() {
  python3 - <<'PY'
import hashlib
import hmac
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from copy import deepcopy

BASE = "http://127.0.0.1:8080"
openapi = json.load(urllib.request.urlopen(BASE + "/_fn/openapi.json"))
paths = openapi.get("paths", {})
METHODS = ["get", "post", "put", "patch", "delete", "options", "head"]
WEBHOOK_SECRET = "dev"
PRINT_EACH = os.getenv("SWEEP_PRINT_EACH", "1").strip() not in ("0", "false", "False")


def schema_example(schema):
    if not isinstance(schema, dict):
        return None
    if "example" in schema:
        return deepcopy(schema["example"])
    if "default" in schema:
        return deepcopy(schema["default"])
    if "enum" in schema and schema["enum"]:
        return deepcopy(schema["enum"][0])
    st = schema.get("type")
    if st == "string":
        fmt = schema.get("format")
        if fmt == "email":
            return "demo@example.com"
        return "demo"
    if st in ("integer", "number"):
        return 1
    if st == "boolean":
        return True
    if st == "array":
        return []
    if st == "object":
        out = {}
        props = schema.get("properties") or {}
        for key, prop in props.items():
            ex = schema_example(prop)
            if ex is not None:
                out[key] = ex
        return out
    for key in ("oneOf", "anyOf", "allOf"):
        opts = schema.get(key)
        if isinstance(opts, list) and opts:
            ex = schema_example(opts[0])
            if ex is not None:
                return ex
    return None


def param_value(param):
    if "example" in param:
        return deepcopy(param["example"])
    ex = schema_example(param.get("schema") or {})
    if ex is not None:
        return ex
    name = str(param.get("name") or "").lower()
    if "id" in name:
        return "123"
    if "slug" in name or "path" in name or "wildcard" in name:
        return "demo/path"
    return "demo"


def path_with_params(path, params):
    out = path
    for p in params:
        if p.get("in") != "path":
            continue
        key = p.get("name")
        val = str(param_value(p))
        out = out.replace("{" + key + "}", urllib.parse.quote(val, safe=""))
    return out


def query_pairs(params):
    out = []
    for p in params:
        if p.get("in") != "query":
            continue
        val = param_value(p)
        if val is None:
            continue
        if isinstance(val, (dict, list)):
            val = json.dumps(val, separators=(",", ":"))
        out.append((p.get("name"), str(val)))
    return out


def request_body(op):
    rb = op.get("requestBody")
    if not isinstance(rb, dict):
        return None, None
    content = rb.get("content") or {}
    if "application/json" in content:
        entry = content["application/json"]
        if "example" in entry:
            return "application/json", deepcopy(entry["example"])
        examples = entry.get("examples") or {}
        if isinstance(examples, dict):
            for _, candidate in examples.items():
                if isinstance(candidate, dict) and "value" in candidate:
                    return "application/json", deepcopy(candidate["value"])
        schema = entry.get("schema") or {}
        ex = schema_example(schema)
        if ex is not None:
            return "application/json", ex
        return "application/json", {}
    if "text/plain" in content:
        return "text/plain", "hello"
    return None, None


def sign_github(payload):
    return "sha256=" + hmac.new(WEBHOOK_SECRET.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256).hexdigest()


results = []
counter = 0
for path in sorted(paths.keys()):
    if path.startswith("/_fn/"):
        continue
    spec = paths[path]
    if not isinstance(spec, dict):
        continue
    common_params = spec.get("parameters") or []
    for method in METHODS:
        if method not in spec:
            continue
        op = spec[method]
        params = list(common_params) + list(op.get("parameters") or [])
        route = path_with_params(path, params)
        query = query_pairs(params)
        url = BASE + route
        if query:
            url += "?" + urllib.parse.urlencode(query)

        headers = {"accept": "application/json"}
        body_data = None
        if method in ("post", "put", "patch", "delete"):
            ctype, payload = request_body(op)
            if ctype == "application/json":
                headers["content-type"] = "application/json"
                body_data = json.dumps(payload).encode("utf-8")
            elif ctype:
                headers["content-type"] = ctype
                if isinstance(payload, str):
                    body_data = payload.encode("utf-8")
                else:
                    body_data = b""

        # Provide stable bodies for polyglot DB routes so the sweep validates behavior
        # rather than failing on placeholder payloads from generic schema synthesis.
        if path == "/polyglot-db-demo/items" and method == "post":
            headers["content-type"] = "application/json"
            body_data = json.dumps({"name": "demo-item", "source": "openapi-sweep"}).encode("utf-8")
        if path in ("/polyglot-db-demo/internal/items/{id}", "/polyglot-db-demo/items/{id}") and method == "put":
            headers["content-type"] = "application/json"
            body_data = json.dumps({"name": "demo-item-updated"}).encode("utf-8")

        if route.startswith("/edge-auth-gateway"):
            headers["authorization"] = "Bearer dev-token"
        if route.startswith("/edge-filter"):
            headers["x-api-key"] = "dev"
        if route.startswith("/github-webhook-guard") and method == "post":
            payload = json.dumps({"zen": "Keep it logically awesome.", "hook_id": 123}, separators=(",", ":"))
            headers["content-type"] = "application/json"
            headers["x-hub-signature-256"] = sign_github(payload)
            headers["x-github-event"] = "ping"
            headers["x-github-delivery"] = "sweep-1"
            body_data = payload.encode("utf-8")

        req = urllib.request.Request(url=url, method=method.upper(), headers=headers, data=body_data)
        try:
            with urllib.request.urlopen(req, timeout=25) as resp:
                code = resp.getcode()
                body = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            code = e.code
            body = e.read().decode("utf-8", "replace")
        except Exception as e:
            code = 0
            body = str(e)

        results.append({
            "path": path,
            "method": method.upper(),
            "code": code,
            "url": url,
            "body": body[:300],
        })
        if PRINT_EACH:
            print(f"run {method.upper()} {path} => {code}", flush=True)
        counter += 1
        if counter % 25 == 0:
            print(f"progress {counter}", flush=True)

ok = [r for r in results if 200 <= r["code"] < 300]
warn = [r for r in results if r["code"] in (400, 401, 403, 404, 405, 409, 422)]
fail = [r for r in results if r["code"] == 0 or r["code"] >= 500]


def is_expected_warn(item):
    path = item["path"]
    method = item["method"]
    code = item["code"]

    # WhatsApp "status" flow is GET-only by design.
    if path.startswith("/whatsapp") and method in ("POST", "DELETE") and code == 405:
        return True

    # Polyglot item update/delete can return not-found for synthetic ids from OpenAPI examples.
    if path == "/polyglot-db-demo/internal/items/{id}" and method in ("PUT", "DELETE") and code == 404:
        return True
    if path == "/polyglot-db-demo/items/{id}" and method in ("PUT", "DELETE") and code == 404:
        return True

    return False


warn_expected = [r for r in warn if is_expected_warn(r)]
warn_unexpected = [r for r in warn if not is_expected_warn(r)]

print(json.dumps({
    "total": len(results),
    "ok": len(ok),
    "warn": len(warn),
    "warn_expected": len(warn_expected),
    "warn_unexpected": len(warn_unexpected),
    "fail": len(fail),
}, indent=2))

if fail:
    print("-- FAILURES --")
    for item in fail:
        print(f"{item['method']} {item['path']} => {item['code']} | {item['body'][:200]}")
    raise SystemExit(1)

if warn_unexpected:
    print("-- UNEXPECTED WARNINGS --")
    for item in warn_unexpected:
        print(f"{item['method']} {item['path']} => {item['code']} | {item['body'][:200]}")
    raise SystemExit(1)
PY
}

echo "== openapi demo examples =="
start_stack
assert_openapi_examples
warm_heavy_endpoints

echo "== openapi demo public sweep (all methods) =="
if ! run_public_sweep; then
  if [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]]; then
    echo "-- stack log tail --"
    tail -n 220 "$STACK_LOG" || true
  fi
  exit 1
fi

echo "PASS test-openapi-demos.sh"
