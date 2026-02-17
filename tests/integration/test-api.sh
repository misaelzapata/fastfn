#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-240}"
KEEP_UP="${KEEP_UP:-0}"
KEEP_FIXTURE_ARTIFACTS="${KEEP_FIXTURE_ARTIFACTS:-0}"
RUNTIMES_WITH_RUST="${RUNTIMES_WITH_RUST:-python,node,php,rust}"

if [[ -n "${FORCE_COLOR:-}" && -n "${NO_COLOR:-}" ]]; then
  unset NO_COLOR
fi

STACK_PID=""
STACK_LOG=""

cleanup_fixture_artifacts() {
  local fixtures_dir="$ROOT_DIR/tests/fixtures"
  if [[ ! -d "$fixtures_dir" ]]; then
    return 0
  fi

  # Remove runtime-generated caches from fixtures to keep repo clean between runs.
  find "$fixtures_dir" -type d \( -name ".fastfn" -o -name "__pycache__" -o -name ".rust-build" \) \
    -prune -exec rm -rf {} + >/dev/null 2>&1 || true
  find "$fixtures_dir" -type f \( -name "*.pyc" -o -name "*.pyo" \) \
    -delete >/dev/null 2>&1 || true
}

cleanup() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_UP" != "1" ]]; then
    (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  fi
  if [[ "$KEEP_FIXTURE_ARTIFACTS" != "1" ]]; then
    cleanup_fixture_artifacts
  fi
}

trap cleanup EXIT

if [[ "$KEEP_FIXTURE_ARTIFACTS" != "1" ]]; then
  cleanup_fixture_artifacts
fi

wait_for_health() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    local code
    code="$(curl -sS -o /tmp/fastfn-health.out -w '%{http_code}' 'http://127.0.0.1:8080/_fn/health' 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      if python3 - <<'PY' >/dev/null 2>&1
import json
from pathlib import Path

obj = json.loads(Path("/tmp/fastfn-health.out").read_text(encoding="utf-8"))
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
      tail -n 200 "$STACK_LOG" || true
    fi
    exit 1
  fi
}

wait_for_catalog_ready() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    local body_file code
    body_file="$(mktemp)"
    code="$(curl -sS -o "$body_file" -w '%{http_code}' 'http://127.0.0.1:8080/_fn/catalog' 2>/dev/null || true)"

    if [[ "$code" == "404" ]]; then
      rm -f "$body_file"
      ready=1
      break
    fi

    if [[ "$code" == "200" ]]; then
      if CATALOG_FILE="$body_file" python3 - <<'PY' >/dev/null 2>&1
import json
import os
import sys
from pathlib import Path

obj = json.loads(Path(os.environ["CATALOG_FILE"]).read_text(encoding="utf-8"))
mapped = obj.get("mapped_routes")
runtimes = obj.get("runtimes")
if not isinstance(mapped, dict) or not isinstance(runtimes, dict):
    sys.exit(1)
if not runtimes:
    sys.exit(1)

fn_total = 0
for entry in runtimes.values():
    if not isinstance(entry, dict):
        continue
    fns = entry.get("functions")
    if isinstance(fns, list):
        fn_total += len(fns)

if len(mapped) > 0 or fn_total > 0:
    sys.exit(0)
sys.exit(1)
PY
      then
        rm -f "$body_file"
        ready=1
        break
      fi
    fi

    rm -f "$body_file"
    sleep 1
  done

  if [[ "$ready" != "1" ]]; then
    echo "FAIL catalog did not become ready"
    if [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]]; then
      tail -n 200 "$STACK_LOG" || true
    fi
    exit 1
  fi
}

start_stack() {
  local target_dir="$1"
  shift

  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true

  STACK_LOG="$(mktemp -t fastfn-integration.XXXXXX.log)"
  if [[ "$#" -gt 0 ]]; then
    (
      cd "$ROOT_DIR"
      env FN_HOT_RELOAD=0 "$@" ./bin/fastfn dev --build "$target_dir" >"$STACK_LOG" 2>&1
    ) &
  else
    (
      cd "$ROOT_DIR"
      env FN_HOT_RELOAD=0 ./bin/fastfn dev --build "$target_dir" >"$STACK_LOG" 2>&1
    ) &
  fi
  STACK_PID="$!"

  wait_for_health
  wait_for_catalog_ready
}

stop_stack() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  STACK_PID=""
  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
}

assert_status() {
  local method="$1"
  local path="$2"
  local expected="$3"
  local body_file
  body_file="$(mktemp)"
  local code
  code="$(curl -sS -X "$method" -o "$body_file" -w '%{http_code}' "http://127.0.0.1:8080$path")"
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL $method $path expected=$expected got=$code"
    cat "$body_file" || true
    rm -f "$body_file"
    exit 1
  fi
  rm -f "$body_file"
}

assert_status_extra() {
  local method="$1"
  local path="$2"
  local expected="$3"
  shift 3
  local body_file
  body_file="$(mktemp)"
  local code
  code="$(curl -sS -X "$method" "$@" -o "$body_file" -w '%{http_code}' "http://127.0.0.1:8080$path")"
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL $method $path expected=$expected got=$code"
    cat "$body_file" || true
    rm -f "$body_file"
    exit 1
  fi
  rm -f "$body_file"
}

assert_config_files_hidden() {
  assert_status GET "/fastfn.json" "404"
  assert_status GET "/fastfn.toml" "404"
}

assert_body_contains() {
  local method="$1"
  local path="$2"
  local needle="$3"
  local body
  body="$(curl -sS -X "$method" "http://127.0.0.1:8080$path")"
  if [[ "$body" != *"$needle"* ]]; then
    echo "FAIL $method $path missing body fragment: $needle"
    echo "Body: $body"
    exit 1
  fi
}

assert_download_attachment() {
  local path="$1"
  local expected_content_type="$2"
  local expected_disposition="$3"
  local expected_body_fragment="$4"

  local headers_file body_file code
  headers_file="$(mktemp)"
  body_file="$(mktemp)"
  code="$(curl -sS -D "$headers_file" -o "$body_file" -w '%{http_code}' "http://127.0.0.1:8080$path")"
  if [[ "$code" != "200" ]]; then
    echo "FAIL GET $path expected=200 got=$code"
    cat "$body_file" || true
    rm -f "$headers_file" "$body_file"
    exit 1
  fi

  if ! grep -qi "content-type: .*${expected_content_type}" "$headers_file"; then
    echo "FAIL GET $path missing expected Content-Type fragment: $expected_content_type"
    cat "$headers_file" || true
    rm -f "$headers_file" "$body_file"
    exit 1
  fi

  if ! grep -qi "content-disposition: .*${expected_disposition}" "$headers_file"; then
    echo "FAIL GET $path missing expected Content-Disposition fragment: $expected_disposition"
    cat "$headers_file" || true
    rm -f "$headers_file" "$body_file"
    exit 1
  fi

  if [[ -n "$expected_body_fragment" ]] && ! grep -q "$expected_body_fragment" "$body_file"; then
    echo "FAIL GET $path missing expected body fragment: $expected_body_fragment"
    cat "$body_file" || true
    rm -f "$headers_file" "$body_file"
    exit 1
  fi

  rm -f "$headers_file" "$body_file"
}

assert_invoke_uses_mapped_route() {
  local catalog
  catalog="$(curl -sS 'http://127.0.0.1:8080/_fn/catalog')"
  local payload
  payload="$(CATALOG_JSON="$catalog" python3 - <<'PY'
import json, os, re

obj = json.loads(os.environ["CATALOG_JSON"])
mapped = obj.get("mapped_routes") or {}

chosen = None
routes = sorted(mapped.keys(), key=lambda r: (1 if ":" in r else 0, r))
for route in routes:
    if not route.startswith("/"):
        continue
    entries = mapped.get(route)
    if isinstance(entries, dict):
        entries = [entries]
    if not isinstance(entries, list):
        continue
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        runtime = entry.get("runtime")
        fn_name = entry.get("fn_name")
        methods = entry.get("methods") or ["GET"]
        if not runtime or not fn_name:
            continue
        method = "GET"
        upper = [str(m).upper() for m in methods]
        if "GET" in upper:
            method = "GET"
        elif upper:
            method = upper[0]
        params = {}
        expected = route
        if ":" in route:
            def repl(m):
                name = m.group(1)
                star = m.group(2) == "*"
                value = "a/b" if star else "123"
                params[name] = value
                return value
            expected = re.sub(r":([A-Za-z0-9_]+)(\*?)", repl, route)
        chosen = {
            "runtime": runtime,
            "name": fn_name,
            "version": entry.get("version"),
            "method": method,
            "query": {},
            "body": "",
            "route": route,
            "params": params,
            "__expected_route": expected,
        }
        break
    if chosen:
        break

if not chosen:
    raise SystemExit("no mapped route candidate for invoke test")

print(json.dumps(chosen, separators=(",", ":")))
PY
)"
  local body
  body="$(curl -sS -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data "$payload")"
  INVOKE_BODY="$body" INVOKE_PAYLOAD="$payload" python3 - <<'PY'
import json, os

obj = json.loads(os.environ["INVOKE_BODY"])
req = json.loads(os.environ["INVOKE_PAYLOAD"])
assert isinstance(obj.get("status"), int), obj
assert obj.get("route") == req.get("__expected_route"), obj
PY
}

assert_reload_methods() {
  assert_status GET "/_fn/reload" "200"
  assert_status POST "/_fn/reload" "200"
}

build_dynamic_invoke_payload() {
  local catalog="$1"
  CATALOG_JSON="$catalog" python3 - <<'PY'
import json, os, re

obj = json.loads(os.environ["CATALOG_JSON"])
mapped = obj.get("mapped_routes") or {}
chosen = None

def route_priority(route):
    if route == "/users/:id":
        return (0, route)
    if route.endswith("/users/:id"):
        return (1, route)
    return (2, route)

for route in sorted(mapped.keys(), key=route_priority):
    if ":" not in route or not route.startswith("/"):
        continue
    entries = mapped.get(route)
    if isinstance(entries, dict):
        entries = [entries]
    if not isinstance(entries, list):
        continue
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        runtime = entry.get("runtime")
        fn_name = entry.get("fn_name")
        methods = [str(m).upper() for m in (entry.get("methods") or ["GET"])]
        if not runtime or not fn_name or "GET" not in methods:
            continue
        params = {}

        def repl(m):
            name = m.group(1)
            star = m.group(2) == "*"
            val = "a/b" if star else "123"
            params[name] = val
            return val

        expected = re.sub(r":([A-Za-z0-9_]+)(\*?)", repl, route)
        if not params:
            continue
        chosen = {
            "runtime": runtime,
            "name": fn_name,
            "version": entry.get("version"),
            "method": "GET",
            "query": {},
            "body": "",
            "route": route,
            "params": params,
            "__expected_route": expected,
        }
        break
    if chosen:
        break

if not chosen:
    raise SystemExit("no dynamic mapped route candidate")

print(json.dumps(chosen, separators=(",", ":")))
PY
}

assert_invoke_with_route_params() {
  local catalog
  catalog="$(curl -sS 'http://127.0.0.1:8080/_fn/catalog')"
  local payload
  payload="$(build_dynamic_invoke_payload "$catalog")"
  local body
  body="$(curl -sS -X POST 'http://127.0.0.1:8080/_fn/invoke' -H 'Content-Type: application/json' --data "$payload")"
  INVOKE_BODY="$body" INVOKE_PAYLOAD="$payload" python3 - <<'PY'
import json, os

obj = json.loads(os.environ["INVOKE_BODY"])
req = json.loads(os.environ["INVOKE_PAYLOAD"])
assert isinstance(obj.get("status"), int), {"response": obj, "request": req}
assert obj.get("route_template") == req.get("route"), {"response": obj, "request": req}
assert obj.get("route") == req.get("__expected_route"), {"response": obj, "request": req}
raw_body = obj.get("body") or ""
parsed = json.loads(raw_body)
params = parsed.get("params") or {}
for k, v in (req.get("params") or {}).items():
    assert params.get(k) == v, {"param": k, "response_params": params, "request": req}
PY
}

assert_enqueue_with_route_params() {
  local catalog
  catalog="$(curl -sS 'http://127.0.0.1:8080/_fn/catalog')"
  local payload
  payload="$(build_dynamic_invoke_payload "$catalog")"

  local enqueue_body
  enqueue_body="$(curl -sS -X POST 'http://127.0.0.1:8080/_fn/jobs' -H 'Content-Type: application/json' --data "$payload")"
  local job_id
  job_id="$(ENQUEUE_BODY="$enqueue_body" python3 - <<'PY'
import json, os
obj = json.loads(os.environ["ENQUEUE_BODY"])
jid = obj.get("id")
if not jid:
    raise SystemExit("missing job id in enqueue response")
print(jid)
PY
)"

  local status="queued"
  for _ in $(seq 1 25); do
    local meta
    meta="$(curl -sS "http://127.0.0.1:8080/_fn/jobs/$job_id")"
    status="$(JOB_META="$meta" python3 - <<'PY'
import json, os
obj = json.loads(os.environ["JOB_META"])
print(obj.get("status") or "")
PY
)"
    if [[ "$status" == "done" || "$status" == "failed" || "$status" == "canceled" ]]; then
      break
    fi
    sleep 1
  done

  if [[ "$status" != "done" ]]; then
    echo "FAIL enqueue job did not complete successfully (status=$status)"
    curl -sS "http://127.0.0.1:8080/_fn/jobs/$job_id" || true
    exit 1
  fi

  local result
  result="$(curl -sS "http://127.0.0.1:8080/_fn/jobs/$job_id/result")"
  JOB_RESULT="$result" JOB_PAYLOAD="$payload" python3 - <<'PY'
import json, os

obj = json.loads(os.environ["JOB_RESULT"])
req = json.loads(os.environ["JOB_PAYLOAD"])
assert obj.get("status") == 200, obj
body = obj.get("body") or ""
parsed = json.loads(body)
params = parsed.get("params") or {}
for k, v in (req.get("params") or {}).items():
    assert params.get(k) == v, (k, params, req)
PY
}

assert_openapi_paths() {
  local mode="$1"
  local openapi
  local catalog
  openapi="$(curl -sS 'http://127.0.0.1:8080/_fn/openapi.json')"
  catalog="$(curl -sS 'http://127.0.0.1:8080/_fn/catalog')"
  OPENAPI_JSON="$openapi" CATALOG_JSON="$catalog" OPENAPI_MODE="$mode" python3 - <<'PY'
import json, os, sys

obj = json.loads(os.environ["OPENAPI_JSON"])
catalog = json.loads(os.environ["CATALOG_JSON"])
paths = obj.get("paths", {})
mode = os.environ["OPENAPI_MODE"]

if mode == "next-style":
    required = ["/users", "/users/{id}", "/hello", "/html", "/showcase", "/showcase/form", "/blog/{slug}", "/php/profile/{id}", "/rust/health", "/admin/users/{id}", "/hello-demo/{name}"]
elif mode == "multi_root":
    required = ["/nextstyle-clean/users", "/nextstyle-clean/api/orders/{id}", "/items", "/items/{id}"]
else:
    raise SystemExit(f"unknown mode: {mode}")

missing = [p for p in required if p not in paths]
if missing:
    raise SystemExit(f"missing OpenAPI paths: {missing}")

internal_paths = [p for p in paths if isinstance(p, str) and p.startswith("/_fn/")]
if internal_paths:
    raise SystemExit(f"internal API paths must be hidden by default: {internal_paths[:10]}")

fn_prefixed_paths = [p for p in paths if p.startswith("/fn/")]
if fn_prefixed_paths:
    raise SystemExit(f"unexpected /fn OpenAPI paths still present: {fn_prefixed_paths[:10]}")

def get_param(params, name):
    for p in params or []:
        if isinstance(p, dict) and p.get("name") == name:
            return p
    return None

if mode == "next-style":
    if "/hello_demo/{wildcard}" in paths:
        raise SystemExit("unexpected wildcard underscore path still present: /hello_demo/{wildcard}")
    hello_demo = (paths.get("/hello-demo/{name}") or {}).get("get") or {}
    hello_demo_name = get_param(hello_demo.get("parameters"), "name")
    if not isinstance(hello_demo_name, dict) or hello_demo_name.get("in") != "path":
        raise SystemExit("missing required path parameter 'name' on /hello-demo/{name}")

def route_to_openapi_path(route):
    raw = str(route or "")
    if raw == "":
        return None
    if raw == "/":
        return "/"
    out = []
    used = set()
    for seg in [s for s in raw.split("/") if s]:
        if seg.startswith(":"):
            name = seg[1:]
            if name.endswith("*"):
                name = name[:-1]
            if not name:
                name = "wildcard"
            out.append("{" + name + "}")
            used.add(name)
        elif seg == "*":
            name = "wildcard"
            i = 2
            while name in used:
                name = f"wildcard{i}"
                i += 1
            used.add(name)
            out.append("{" + name + "}")
        else:
            out.append(seg)
    return "/" + "/".join(out) if out else "/"

for path, ops in paths.items():
    if ":" in path:
        raise SystemExit(f"unexpected raw ':' token in OpenAPI path: {path}")
    if not isinstance(ops, dict):
        continue
    for op_name, op in ops.items():
        if not isinstance(op, dict):
            continue
        for param in op.get("parameters") or []:
            if isinstance(param, dict):
                if "in_" in param:
                    raise SystemExit(f"invalid parameter key in_ on {path} {op_name}")
                if "in" not in param:
                    raise SystemExit(f"missing parameter in on {path} {op_name}")
        summary = str(op.get("summary") or "")
        if "unknown/unknown" in summary:
            raise SystemExit(f"unexpected unknown OpenAPI summary on {path} {op_name}: {summary}")

# Runtime parity: mapped catalog routes must be reflected in OpenAPI with methods.
mapped = catalog.get("mapped_routes") or {}
expected_paths = set()
expected_methods_by_path = {}
for route, entries in mapped.items():
    if not isinstance(route, str) or not route.startswith("/"):
        continue
    if route.startswith("/_fn/"):
        continue
    openapi_path = route_to_openapi_path(route)
    if not openapi_path:
        continue
    expected_paths.add(openapi_path)
    if openapi_path not in paths:
        raise SystemExit(f"catalog mapped route missing in OpenAPI: {route} -> {openapi_path}")
    if isinstance(entries, dict):
        entries = [entries]
    if not isinstance(entries, list):
        continue
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        methods = entry.get("methods") or ["GET"]
        if not isinstance(methods, list) or not methods:
            methods = ["GET"]
        for m in methods:
            op = str(m or "GET").lower()
            expected_methods_by_path.setdefault(openapi_path, set()).add(str(m or "GET").upper())
            if op not in (paths.get(openapi_path) or {}):
                raise SystemExit(f"missing OpenAPI method {op.upper()} on {openapi_path} for mapped route {route}")

public_paths = {
    p for p in paths.keys()
    if isinstance(p, str) and p.startswith("/") and not p.startswith("/_fn/")
}
unexpected_paths = sorted(public_paths - expected_paths)
if unexpected_paths:
    raise SystemExit(f"unexpected extra OpenAPI paths not present in catalog mapping: {unexpected_paths[:10]}")
missing_paths = sorted(expected_paths - public_paths)
if missing_paths:
    raise SystemExit(f"missing OpenAPI paths for mapped catalog routes: {missing_paths[:10]}")

for openapi_path, expected_methods in expected_methods_by_path.items():
    ops = paths.get(openapi_path) or {}
    actual_methods = {k.upper() for k, v in ops.items() if isinstance(v, dict)}
    if actual_methods != expected_methods:
        raise SystemExit(
            f"method mismatch on {openapi_path}: expected={sorted(expected_methods)} actual={sorted(actual_methods)}"
        )

if mode == "multi_root":
    for bad in ("/polyglot-demo/handlers/list", "/polyglot-demo/handlers/create", "/polyglot-demo/src/delete"):
        if bad in paths:
            raise SystemExit(f"unexpected nested manifest path still present: {bad}")
PY
}

assert_scheduler_nonblocking() {
  local ready=0
  local snapshot=""
  for _ in $(seq 1 40); do
    snapshot="$(curl -sS 'http://127.0.0.1:8080/_fn/schedules')"
    if SNAPSHOT_JSON="$snapshot" python3 - <<'PY' >/dev/null 2>&1
import json
import os
import sys

obj = json.loads(os.environ["SNAPSHOT_JSON"])
target = None
for item in (obj.get("schedules") or []):
    if item.get("runtime") == "node" and item.get("name") == "slow-task":
        target = item
        break

if target is None:
    sys.exit(1)

state = target.get("state") or {}
last = state.get("last")
status = int(state.get("last_status") or 0)
if last and status == 200:
    sys.exit(0)
sys.exit(1)
PY
    then
      ready=1
      break
    fi
    sleep 1
  done

  if [[ "$ready" != "1" ]]; then
    echo "FAIL scheduler target slow-task did not complete successfully"
    echo "$snapshot"
    exit 1
  fi

  local threshold_ms="${SCHED_NONBLOCK_MAX_MS:-1200}"
  local max_ms=0
  for _ in $(seq 1 12); do
    local body_file out code secs ms
    body_file="$(mktemp)"
    out="$(curl -sS -o "$body_file" -w '%{http_code} %{time_total}' 'http://127.0.0.1:8080/health')"
    code="${out%% *}"
    secs="${out##* }"
    if [[ "$code" != "200" ]]; then
      echo "FAIL GET /health expected=200 got=$code during scheduler non-blocking check"
      cat "$body_file" || true
      rm -f "$body_file"
      exit 1
    fi
    rm -f "$body_file"

    ms="$(TIME_TOTAL_SECS="$secs" python3 - <<'PY'
import os
print(int(float(os.environ["TIME_TOTAL_SECS"]) * 1000))
PY
)"
    if (( ms > max_ms )); then
      max_ms="$ms"
    fi
    sleep 0.2
  done

  if (( max_ms > threshold_ms )); then
    echo "FAIL scheduler blocked public calls: max /health latency ${max_ms}ms exceeds ${threshold_ms}ms"
    curl -sS 'http://127.0.0.1:8080/_fn/schedules' || true
    exit 1
  fi

  local probe_file="$ROOT_DIR/tests/fixtures/scheduler-nonblocking/node/slow-task/.fastfn/scheduler-worker-pool.json"
  local probe_ready=0
  local probe=""
  for _ in $(seq 1 20); do
    if [[ -f "$probe_file" ]]; then
      probe="$(cat "$probe_file" 2>/dev/null || true)"
      if [[ -n "$probe" ]] && SCHED_PROBE_JSON="$probe" python3 - <<'PY' >/dev/null 2>&1
import json
import os
import sys

obj = json.loads(os.environ["SCHED_PROBE_JSON"])
trigger = obj.get("trigger") or {}
pool = obj.get("worker_pool") or {}

if trigger.get("type") != "schedule":
    sys.exit(1)
if pool.get("enabled") is not True:
    sys.exit(1)
if int(pool.get("max_workers") or 0) != 3:
    sys.exit(1)
if int(pool.get("max_queue") or 0) != 2:
    sys.exit(1)
if int(pool.get("queue_timeout_ms") or 0) != 1500:
    sys.exit(1)
if int(pool.get("queue_poll_ms") or 0) != 15:
    sys.exit(1)
if int(pool.get("overflow_status") or 0) != 503:
    sys.exit(1)
PY
      then
        probe_ready=1
        break
      fi
    fi
    sleep 0.5
  done

  if [[ "$probe_ready" != "1" ]]; then
    echo "FAIL scheduler worker_pool context probe did not become valid"
    echo "---- probe file: $probe_file ----"
    if [[ -f "$probe_file" ]]; then
      cat "$probe_file" || true
    else
      echo "(missing)"
    fi
    echo "---- /_fn/schedules ----"
    curl -sS 'http://127.0.0.1:8080/_fn/schedules' || true
    exit 1
  fi

  echo "scheduler non-blocking latency check max_ms=$max_ms threshold_ms=$threshold_ms"
}

assert_keep_warm_visibility() {
  local ready=0
  local snapshot=""
  local health=""
  local catalog=""
  for _ in $(seq 1 30); do
    snapshot="$(curl -sS 'http://127.0.0.1:8080/_fn/schedules')"
    health="$(curl -sS 'http://127.0.0.1:8080/_fn/health')"
    catalog="$(curl -sS 'http://127.0.0.1:8080/_fn/catalog')"
    if SNAPSHOT_JSON="$snapshot" HEALTH_JSON="$health" CATALOG_JSON="$catalog" python3 - <<'PY' >/dev/null 2>&1
import json
import os
import sys

snap = json.loads(os.environ["SNAPSHOT_JSON"])
health = json.loads(os.environ["HEALTH_JSON"])
catalog = json.loads(os.environ["CATALOG_JSON"])

keep_items = snap.get("keep_warm") or []
target = None
for item in keep_items:
    if item.get("runtime") == "node" and item.get("name") == "ping" and item.get("version") in (None, "", "default"):
        target = item
        break
if target is None:
    sys.exit(1)

state = target.get("state") or {}
if int(state.get("last_status") or 0) != 200:
    sys.exit(1)
if state.get("warm_state") not in ("warm", "stale"):
    sys.exit(1)

summary = ((health.get("functions") or {}).get("summary") or {})
if int(summary.get("keep_warm_enabled") or 0) < 1:
    sys.exit(1)

states = ((health.get("functions") or {}).get("states") or [])
h_target = None
for row in states:
    if row.get("key") == "node/ping@default":
        h_target = row
        break
if h_target is None:
    sys.exit(1)
if h_target.get("state") not in ("warm", "stale"):
    sys.exit(1)

runtimes = catalog.get("runtimes") or {}
node_rt = runtimes.get("node") or {}
functions = node_rt.get("functions") or []
c_target = None
for fn in functions:
    if fn.get("name") == "ping":
        c_target = fn
        break
if c_target is None:
    sys.exit(1)
default_state = c_target.get("default_state") or {}
keep_cfg = default_state.get("keep_warm") or {}
if keep_cfg.get("enabled") is not True:
    sys.exit(1)
if default_state.get("state") not in ("warm", "stale"):
    sys.exit(1)
PY
    then
      ready=1
      break
    fi
    sleep 1
  done

  if [[ "$ready" != "1" ]]; then
    echo "FAIL keep_warm visibility did not become ready"
    echo "---- /_fn/schedules ----"
    echo "$snapshot"
    echo "---- /_fn/health ----"
    echo "$health"
    echo "---- /_fn/catalog ----"
    echo "$catalog"
    exit 1
  fi
}

assert_worker_pool_runtime_fn_version() {
  local summary
  summary="$(python3 - <<'PY'
import concurrent.futures
import json
import time
import urllib.error
import urllib.request

URL = "http://127.0.0.1:8080/slow"

def one_call():
    req = urllib.request.Request(url=URL, method="GET", headers={"Accept": "application/json"})
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=6) as resp:
            code = int(resp.getcode() or 0)
            headers = dict(resp.headers.items())
            body = resp.read().decode("utf-8", "ignore")
    except urllib.error.HTTPError as err:
        code = int(err.code or 0)
        headers = dict(err.headers.items()) if err.headers else {}
        body = err.read().decode("utf-8", "ignore") if hasattr(err, "read") else ""
    except Exception as err:
        return {"ok": False, "status": 0, "error": str(err), "ms": int((time.time() - started) * 1000)}

    return {
        "ok": True,
        "status": code,
        "queued": str(headers.get("X-FastFn-Queued", "")).lower() == "true",
        "ms": int((time.time() - started) * 1000),
        "body": body,
    }

with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    results = list(pool.map(lambda _: one_call(), range(3)))

errors = [r for r in results if not r.get("ok")]
if errors:
    raise SystemExit("worker_pool request error: " + json.dumps(errors, ensure_ascii=False))

status_counts = {}
for row in results:
    status_counts[row["status"]] = status_counts.get(row["status"], 0) + 1

if status_counts.get(200, 0) != 2 or status_counts.get(429, 0) != 1:
    raise SystemExit("unexpected status distribution: " + json.dumps({"counts": status_counts, "results": results}, ensure_ascii=False))

queued_success = [r for r in results if r["status"] == 200 and r.get("queued")]
if len(queued_success) < 1:
    raise SystemExit("expected at least one queued successful request: " + json.dumps(results, ensure_ascii=False))

max_ms = max(r["ms"] for r in results)
if max_ms > 2800:
    raise SystemExit("worker_pool latency budget exceeded: " + json.dumps({"max_ms": max_ms, "results": results}, ensure_ascii=False))

print(json.dumps({"counts": status_counts, "max_ms": max_ms}, separators=(",", ":")))
PY
)"
  echo "worker pool check: $summary"

  local isolation
  isolation="$(python3 - <<'PY'
import json
import urllib.request

BASE = "http://127.0.0.1:8080"

def call(path):
    req = urllib.request.Request(url=BASE + path, method="GET", headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=6) as resp:
        status = int(resp.getcode() or 0)
        body = json.loads(resp.read().decode("utf-8"))
        return status, body

s1, b1 = call("/state-a")
s2, b2 = call("/state-a")
s3, b3 = call("/state-b")

if s1 != 200 or s2 != 200 or s3 != 200:
    raise SystemExit(f"unexpected statuses: {s1},{s2},{s3}")

v1 = int(b1.get("value") or 0)
v2 = int(b2.get("value") or 0)
vb = int(b3.get("value") or 0)
if v1 < 1 or v2 != (v1 + 1):
    raise SystemExit(f"state-a warm worker sequence invalid: v1={v1}, v2={v2}")
if vb != 0:
    raise SystemExit(f"state-b should not see state-a global data: vb={vb}")

print(json.dumps({"state_a_first": v1, "state_a_second": v2, "state_b": vb}, separators=(",", ":")))
PY
)"
  echo "worker pool isolation check: $isolation"
}

assert_worker_pool_parallel_multiruntime() {
  local summary
  summary="$(python3 - <<'PY'
import concurrent.futures
import json
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8080"
TARGETS = [
    {"runtime": "node", "path": "/slow-node"},
    {"runtime": "python", "path": "/slow-python"},
    {"runtime": "php", "path": "/slow-php"},
    {"runtime": "rust", "path": "/slow-rust"},
]
PARALLEL_CALLS = 2
MAX_TOTAL_MS = 1500


def one_call(path: str):
    req = urllib.request.Request(url=BASE + path, method="GET", headers={"Accept": "application/json"})
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            code = int(resp.getcode() or 0)
            body = resp.read().decode("utf-8", "ignore")
            return {"ok": True, "status": code, "body": body, "ms": int((time.time() - started) * 1000)}
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore") if hasattr(err, "read") else ""
        return {"ok": False, "status": int(err.code or 0), "body": body, "ms": int((time.time() - started) * 1000)}
    except Exception as err:
        return {"ok": False, "status": 0, "body": str(err), "ms": int((time.time() - started) * 1000)}


def run_parallel(path: str):
    started = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=PARALLEL_CALLS) as pool:
        futures = [pool.submit(one_call, path) for _ in range(PARALLEL_CALLS)]
        results = [f.result() for f in futures]
    total_ms = int((time.time() - started) * 1000)
    return total_ms, results


report = []
for target in TARGETS:
    warm = one_call(target["path"])
    if warm.get("status") != 200:
        raise SystemExit("warmup failed for " + target["runtime"] + ": " + json.dumps(warm, ensure_ascii=False))

    total_ms, results = run_parallel(target["path"])
    failures = [r for r in results if r.get("status") != 200]
    if failures:
        raise SystemExit("parallel status failure for " + target["runtime"] + ": " + json.dumps(failures, ensure_ascii=False))
    if total_ms > MAX_TOTAL_MS:
        raise SystemExit(
            "parallel budget exceeded for "
            + target["runtime"]
            + ": "
            + json.dumps({"total_ms": total_ms, "results": results, "max_total_ms": MAX_TOTAL_MS}, ensure_ascii=False)
        )

    report.append(
        {
            "runtime": target["runtime"],
            "path": target["path"],
            "parallel_calls": PARALLEL_CALLS,
            "total_ms": total_ms,
            "max_single_ms": max(r["ms"] for r in results),
        }
    )

print(json.dumps(report, separators=(",", ":")))
PY
)"
  echo "worker pool multiruntime parallel check: $summary"
}

assert_worker_pool_health_observability() {
  local summary
  summary="$(python3 - <<'PY'
import json
import urllib.request

with urllib.request.urlopen("http://127.0.0.1:8080/_fn/health", timeout=8) as resp:
    health = json.loads(resp.read().decode("utf-8"))

functions = health.get("functions") or {}
agg = functions.get("summary") or {}
states = functions.get("states") or []

target = None
for row in states:
    if row.get("key") == "node/slow@default":
        target = row
        break
if target is None:
    raise SystemExit("node/slow@default not found in /_fn/health")

pool = target.get("worker_pool") or {}
drops = pool.get("queue_drops") or {}
overflow = int(drops.get("overflow") or 0)
timeout = int(drops.get("timeout") or 0)
total = int(drops.get("total") or 0)

if pool.get("enabled") is not True:
    raise SystemExit("node/slow worker_pool.enabled expected true")
if overflow < 1:
    raise SystemExit("expected node/slow queue overflow drops >= 1")
if total < overflow:
    raise SystemExit("node/slow queue_drops.total should be >= overflow")
if int(agg.get("pool_enabled") or 0) < 1:
    raise SystemExit("summary.pool_enabled expected >= 1")
if int(agg.get("pool_queue_drops") or 0) < 1:
    raise SystemExit("summary.pool_queue_drops expected >= 1")
if int(agg.get("pool_queue_overflow_drops") or 0) < 1:
    raise SystemExit("summary.pool_queue_overflow_drops expected >= 1")

print(json.dumps({
    "summary_pool_enabled": int(agg.get("pool_enabled") or 0),
    "summary_pool_queue_drops": int(agg.get("pool_queue_drops") or 0),
    "summary_pool_queue_overflow_drops": int(agg.get("pool_queue_overflow_drops") or 0),
    "summary_pool_queue_timeout_drops": int(agg.get("pool_queue_timeout_drops") or 0),
    "node_slow_overflow": overflow,
    "node_slow_timeout": timeout,
    "node_slow_total": total,
}, separators=(",", ":")))
PY
)"
  echo "worker pool observability check: $summary"
}

assert_python_dep_worker_persistent() {
  local summary
  summary="$(python3 - <<'PY'
import json
import time
import urllib.error
import urllib.request

URL = "http://127.0.0.1:8080/py-persistent"

def call_once():
    req = urllib.request.Request(url=URL, method="GET", headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as resp:
        code = int(resp.getcode() or 0)
        body = json.loads(resp.read().decode("utf-8"))
    if code != 200:
        raise SystemExit(f"py-persistent unexpected status: {code}")
    if body.get("runtime") != "python":
        raise SystemExit("py-persistent expected runtime=python")
    pid = int(body.get("pid") or 0)
    hits = int(body.get("hits") or 0)
    if pid <= 0 or hits <= 0:
        raise SystemExit("py-persistent missing pid/hits")
    return {"pid": pid, "hits": hits}

first = call_once()
second = call_once()

if second["pid"] != first["pid"]:
    raise SystemExit(
        "python deps worker is not persistent (pid changed): "
        + json.dumps({"first": first, "second": second}, ensure_ascii=False)
    )
if second["hits"] != first["hits"] + 1:
    raise SystemExit(
        "python deps worker counter did not increment: "
        + json.dumps({"first": first, "second": second}, ensure_ascii=False)
    )

print(json.dumps({"first": first, "second": second}, separators=(",", ":")))
PY
)"
  echo "python deps persistent worker check: $summary"
}

assert_python_with_deps_available() {
  local summary
  summary="$(python3 - <<'PY'
import json
import time
import urllib.error
import urllib.request

URL = "http://127.0.0.1:8080/py-with-deps"
deadline = time.time() + 180
last_err = None

while time.time() < deadline:
    req = urllib.request.Request(url=URL, method="GET", headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            code = int(resp.getcode() or 0)
            body = json.loads(resp.read().decode("utf-8"))
        if code == 200 and body.get("runtime") == "python" and body.get("has_requests") is True:
            print(json.dumps({"status": code, "requests_version": body.get("requests_version")}, separators=(",", ":")))
            raise SystemExit(0)
        last_err = {"status": code, "body": body}
    except urllib.error.HTTPError as err:
        payload = err.read().decode("utf-8", "ignore") if hasattr(err, "read") else ""
        last_err = {"status": int(err.code or 0), "body": payload}
    except Exception as err:
        last_err = {"error": str(err)}
    time.sleep(2)

raise SystemExit("py-with-deps unavailable after retries: " + json.dumps(last_err, ensure_ascii=False))
PY
)"
  echo "python with-deps availability check: $summary"
}

assert_parallel_mapped_routes_nonblocking() {
  local threshold_ms="${PARALLEL_MAX_LATENCY_MS:-3500}"
  local summary
  summary="$(PARALLEL_THRESHOLD_MS="$threshold_ms" python3 - <<'PY'
import concurrent.futures
import json
import os
import re
import time
import urllib.error
import urllib.request

BASE_URL = "http://127.0.0.1:8080"
THRESHOLD_MS = int(os.environ.get("PARALLEL_THRESHOLD_MS", "3500"))
WARM_TIMEOUT_SEC = float(os.environ.get("PARALLEL_WARM_TIMEOUT_SEC", "45"))
WARM_TIMEOUT_RUST_SEC = float(os.environ.get("PARALLEL_WARM_TIMEOUT_RUST_SEC", "180"))

def sample_path(route):
    path = re.sub(r":([A-Za-z0-9_]+)\*", "a/b", route)
    path = re.sub(r":([A-Za-z0-9_]+)", "123", path)
    return path

def pick_method(methods):
    preferred = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    if not isinstance(methods, list) or not methods:
        return "GET"
    normalized = [str(m).upper() for m in methods]
    for m in preferred:
        if m in normalized:
            return m
    return normalized[0]

def request_one(spec, timeout=8):
    method = spec["method"]
    url = BASE_URL + spec["path"]
    headers = {"Accept": "application/json"}
    data = None
    if method in ("POST", "PUT", "PATCH"):
        headers["Content-Type"] = "application/json"
        data = b"{}"

    req = urllib.request.Request(url=url, method=method, headers=headers, data=data)
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code = int(resp.getcode() or 0)
            body = resp.read()
    except urllib.error.HTTPError as err:
        code = int(err.code or 0)
        body = err.read() if hasattr(err, "read") else b""
    except Exception as err:
        return {
            "ok": False,
            "spec": spec,
            "status": 0,
            "error": str(err),
            "ms": int((time.time() - started) * 1000),
        }

    return {
        "ok": 200 <= code < 400,
        "spec": spec,
        "status": code,
        "body": body.decode("utf-8", "ignore"),
        "ms": int((time.time() - started) * 1000),
    }

with urllib.request.urlopen(BASE_URL + "/_fn/catalog", timeout=8) as resp:
    catalog = json.loads(resp.read().decode("utf-8"))

mapped = catalog.get("mapped_routes") or {}
specs = []
for route, entries in mapped.items():
    if not isinstance(route, str) or not route.startswith("/"):
        continue
    if route.startswith("/_fn/"):
        continue
    if isinstance(entries, dict):
        entries = [entries]
    if not isinstance(entries, list):
        continue
    picked = None
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        methods = entry.get("methods") or ["GET"]
        runtime = entry.get("runtime") if isinstance(entry.get("runtime"), str) else ""
        picked = {
            "route": route,
            "path": sample_path(route),
            "method": pick_method(methods),
            "runtime": runtime,
        }
        break
    if picked:
        specs.append(picked)

uniq = []
seen = set()
for spec in specs:
    key = (spec["method"], spec["path"])
    if key in seen:
        continue
    seen.add(key)
    uniq.append(spec)

if not uniq:
    raise SystemExit("no mapped routes found for parallel check")

# Warm-up: avoid counting cold starts as blocking regressions.
for spec in uniq:
    timeout = WARM_TIMEOUT_SEC
    if spec.get("runtime") == "rust":
        timeout = max(timeout, WARM_TIMEOUT_RUST_SEC)
    warm = request_one(spec, timeout=timeout)
    if not warm["ok"]:
        raise SystemExit("warm-up failed: " + json.dumps(warm, ensure_ascii=False))

max_ms = 0
rounds = 3
workers = min(16, max(4, len(uniq)))
for _ in range(rounds):
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(request_one, uniq))
    bad = [item for item in results if not item["ok"]]
    if bad:
        raise SystemExit("parallel requests failed: " + json.dumps(bad[:3], ensure_ascii=False))
    max_ms = max(max_ms, max(item["ms"] for item in results))

if max_ms > THRESHOLD_MS:
    raise SystemExit(f"parallel max latency too high: {max_ms}ms > {THRESHOLD_MS}ms")

print(json.dumps({"routes": len(uniq), "max_ms": max_ms}, separators=(",", ":")))
PY
)"
  echo "parallel mapped routes non-blocking check: $summary"
}

echo "== Phase 1: Next-style single app =="
start_stack "examples/functions/next-style" "FN_UI_ENABLED=0" "FN_CONSOLE_WRITE_ENABLED=0" "FN_RUNTIMES=$RUNTIMES_WITH_RUST" "FN_DEFAULT_TIMEOUT_MS=10000"
assert_config_files_hidden
assert_reload_methods
assert_status GET "/users" "200"
assert_status GET "/users/123" "200"
assert_status GET "/hello" "200"
assert_status GET "/html?name=api" "200"
assert_status GET "/showcase" "200"
assert_status GET "/showcase/form" "200"
assert_status GET "/hello-demo/Juan" "200"
assert_download_attachment "/downloads/report" "text/csv" "filename=\"report.csv\"" "id,name,score"
assert_download_attachment "/downloads/image" "image/svg+xml" "filename=\"badge.svg\"" "<svg"
assert_download_attachment "/php/export" "text/csv" "filename=\"php-export.csv\"" "id,source"
assert_status_extra POST "/showcase/form" "200" \
  -H 'Content-Type: application/json' \
  --data '{"name":"API","accent":"#38bdf8","message":"from post"}'
assert_status_extra PUT "/showcase/form" "200" \
  -H 'Content-Type: application/json' \
  --data '{"name":"API2","accent":"#f59e0b","message":"from put"}'
assert_status GET "/blog/a/b/c" "200"
assert_status POST "/admin/users/123" "200"
assert_status GET "/php/profile/123" "200"
assert_status GET "/rust/health" "200"
assert_body_contains GET "/users" "\"runtime\":\"node\""
assert_body_contains GET "/users/123" "\"id\":\"123\""
assert_body_contains GET "/hello" "\"message\":\"hello works\""
assert_body_contains GET "/html?name=api" "<title>FastFn HTML Demo</title>"
assert_body_contains GET "/html?name=api" "Hello api"
assert_body_contains GET "/showcase" "<title>FastFn Visual Showcase</title>"
assert_body_contains GET "/showcase/form" "\"route\":\"GET /showcase/form\""
assert_body_contains GET "/showcase/form" "\"name\":\"API2\""
assert_body_contains GET "/hello-demo/Juan" "\"route\":\"GET /hello-demo/:name\""
assert_body_contains GET "/hello-demo/Juan" "\"name\":\"Juan\""
assert_body_contains GET "/hello-demo/Juan" "\"message\":\"Hello Juan\""
assert_body_contains GET "/blog/a/b/c" "\"runtime\": \"python\""
assert_body_contains GET "/blog/a/b/c" "\"slug\": \"a/b/c\""
assert_body_contains GET "/php/profile/123" "\"runtime\":\"php\""
assert_body_contains GET "/php/profile/123" "\"id\":\"123\""
assert_body_contains POST "/admin/users/123" "\"id\": \"123\""
assert_body_contains GET "/rust/health" "\"runtime\":\"rust\""
assert_openapi_paths "next-style"
assert_invoke_uses_mapped_route
assert_invoke_with_route_params
assert_parallel_mapped_routes_nonblocking
assert_status GET "/console" "404"
assert_status GET "/_fn/ui-state" "200"
assert_status_extra PUT "/_fn/ui-state" "403" \
  -H 'Content-Type: application/json' \
  --data '{"write_enabled":true}'
env -u NO_COLOR node "$ROOT_DIR/tests/integration/test-multilang-e2e.js"
stop_stack

echo "== Phase 2: Multi-directory / multi-runtime =="
start_stack "tests/fixtures/multi-root" "FN_RUNTIMES=$RUNTIMES_WITH_RUST"
assert_reload_methods
assert_status GET "/nextstyle-clean/users" "200"
assert_status GET "/nextstyle-clean/users/123" "200"
assert_status GET "/nextstyle-clean/blog/a/b" "200"
assert_status POST "/nextstyle-clean/admin/users/123" "200"
assert_status GET "/nextstyle-clean/api/orders/123" "200"
assert_status POST "/nextstyle-clean/api/orders/123" "200"
assert_status PUT "/nextstyle-clean/api/orders/123" "200"
assert_status PATCH "/nextstyle-clean/api/orders/123" "200"
assert_status DELETE "/nextstyle-clean/api/orders/123" "200"
assert_status GET "/items" "200"
assert_status POST "/items" "200"
assert_status GET "/items/123" "200"
assert_status DELETE "/items/123" "200"
assert_openapi_paths "multi_root"
assert_parallel_mapped_routes_nonblocking
stop_stack

echo "== Phase 3: Internal docs/admin toggles =="
start_stack "tests/fixtures/nextstyle-clean" "FN_DOCS_ENABLED=0" "FN_ADMIN_API_ENABLED=0" "FN_UI_ENABLED=0"
assert_status GET "/_fn/docs" "404"
assert_status GET "/_fn/openapi.json" "404"
assert_status GET "/_fn/catalog" "404"
assert_status GET "/_fn/ui-state" "404"
assert_status GET "/console" "404"
assert_status GET "/docs/a/b" "200"
stop_stack

echo "== Phase 4: Console UI/API matrix =="
start_stack "examples/functions/next-style" "FN_UI_ENABLED=1" "FN_CONSOLE_WRITE_ENABLED=1"
assert_status GET "/console" "200"
assert_status GET "/console/gateway" "200"
assert_status GET "/console/scheduler" "200"
assert_status GET "/_fn/ui-state" "200"
assert_enqueue_with_route_params
stop_stack

start_stack "examples/functions/next-style" "FN_UI_ENABLED=1" "FN_ADMIN_API_ENABLED=0"
assert_status GET "/console" "200"
assert_status GET "/_fn/ui-state" "404"
assert_status GET "/_fn/catalog" "404"
stop_stack

echo "== Phase 5: Polyglot tutorial demo =="
start_stack "examples/functions" "FN_RUNTIMES=$RUNTIMES_WITH_RUST" "FN_DEFAULT_TIMEOUT_MS=90000"
assert_status GET "/polyglot-tutorial/step-1" "200"
assert_status GET "/polyglot-tutorial/step-2?name=Ana" "200"
assert_status GET "/polyglot-tutorial/step-3?name=Ana" "200"
assert_status GET "/polyglot-tutorial/step-4" "200"
assert_status GET "/polyglot-tutorial/step-4/status" "200"
assert_status GET "/polyglot-tutorial/step-5?name=Ana" "200"
assert_body_contains GET "/polyglot-tutorial/step-4" "\"runtime\":\"rust\""
assert_body_contains GET "/polyglot-tutorial/step-5?name=Ana" "\"step\":5"
assert_body_contains GET "/polyglot-tutorial/step-5?name=Ana" "\"summary\":\"Polyglot pipeline completed for Ana\""
assert_body_contains GET "/polyglot-tutorial/step-5?name=Ana" "\"runtime\":\"rust\""
assert_status GET "/ip-intel/maxmind?ip=8.8.8.8&mock=1" "200"
assert_body_contains GET "/ip-intel/maxmind?ip=8.8.8.8&mock=1" "\"provider\":\"maxmind-mock\""
assert_status GET "/ip-intel/remote?ip=8.8.8.8&mock=1" "200"
assert_body_contains GET "/ip-intel/remote?ip=8.8.8.8&mock=1" "\"provider\":\"ipapi-mock\""
stop_stack

echo "== Phase 6: Scheduler non-blocking =="
start_stack "tests/fixtures/scheduler-nonblocking" "FN_UI_ENABLED=0" "FN_CONSOLE_WRITE_ENABLED=0"
assert_status GET "/health" "200"
assert_status GET "/_fn/schedules" "200"
assert_scheduler_nonblocking
stop_stack

echo "== Phase 7: keep_warm visibility =="
start_stack "tests/fixtures/keep-warm" "FN_UI_ENABLED=0" "FN_CONSOLE_WRITE_ENABLED=0"
assert_status GET "/ping" "200"
assert_status GET "/_fn/schedules" "200"
assert_keep_warm_visibility
stop_stack

echo "== Phase 8: worker pool runtime/function/version =="
start_stack "tests/fixtures/worker-pool" "FN_UI_ENABLED=0" "FN_CONSOLE_WRITE_ENABLED=0" "FN_RUNTIMES=$RUNTIMES_WITH_RUST" "FN_DEFAULT_TIMEOUT_MS=10000"
assert_status GET "/slow" "200"
assert_status GET "/slow-node" "200"
assert_status GET "/slow-python" "200"
assert_status GET "/slow-php" "200"
assert_status GET "/slow-rust" "200"
assert_status GET "/state-a" "200"
assert_status GET "/state-b" "200"
assert_worker_pool_runtime_fn_version
assert_worker_pool_parallel_multiruntime
assert_worker_pool_health_observability
stop_stack

echo "== Phase 9: per-function dependency isolation =="
start_stack "tests/fixtures/dep-isolation" \
  "FN_UI_ENABLED=0" "FN_CONSOLE_WRITE_ENABLED=0" \
  "FN_PREINSTALL_PY_DEPS_ON_START=0" "FN_PREINSTALL_NODE_DEPS_ON_START=0" \
  "FN_DEFAULT_TIMEOUT_MS=90000" \
  "FN_RUNTIMES=$RUNTIMES_WITH_RUST"

# ---- Node isolation ----
# node-with-deps has package.json with lodash → should resolve
assert_status GET "/node-with-deps" "200"
assert_body_contains GET "/node-with-deps" "\"has_lodash\":true"
assert_body_contains GET "/node-with-deps" "\"runtime\":\"node\""

# node-no-deps has NO package.json → require('lodash') should fail
assert_status GET "/node-no-deps" "200"
assert_body_contains GET "/node-no-deps" "\"has_lodash\":false"
assert_body_contains GET "/node-no-deps" "\"isolation_ok\":true"

# ---- Python: deps work + sys.path isolation ----
# py-persistent uses an empty .deps dir (no network install) and must
# reuse the same worker process across requests.
assert_python_dep_worker_persistent

# py-with-deps installs requests and must eventually become available.
assert_python_with_deps_available

# Call py-no-deps AFTER — sys.path must be clean, import requests must fail
assert_status GET "/py-no-deps" "200"
assert_body_contains GET "/py-no-deps" "\"has_requests\":false"
assert_body_contains GET "/py-no-deps" "\"isolation_ok\":true"

# ---- PHP isolation ----
# php-no-deps has no composer.json → Monolog class should not exist
assert_status GET "/php-no-deps" "200"
assert_body_contains GET "/php-no-deps" "\"runtime\":\"php\""
assert_body_contains GET "/php-no-deps" "\"isolation_ok\":true"

# ---- Rust basic ----
# rust-basic uses only serde_json (built-in) → should compile and run
assert_status GET "/rust-basic" "200"
assert_body_contains GET "/rust-basic" "\"runtime\":\"rust\""
assert_body_contains GET "/rust-basic" "\"ok\":true"

stop_stack

echo "PASS test-api.sh (routing/admin/polyglot integration)"
