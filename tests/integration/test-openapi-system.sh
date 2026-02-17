#!/usr/bin/env bash
set -euo pipefail

# Related:
# - tests/integration/test-openapi-native.sh
# - docs/internal/STATUS_UPDATE.md

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-120}"
KEEP_UP="${KEEP_UP:-0}"
FN_ADMIN_TOKEN="${FN_ADMIN_TOKEN:-test-admin-token}"
TEST_SUFFIX="${TEST_SUFFIX:-$$}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fastfn-openapi-system-${TEST_SUFFIX}}"

STACK_PID=""
STACK_LOG=""
STACK_EXIT_FILE=""
WORK_DIR="$(mktemp -d "$ROOT_DIR/tests/results/openapi-system.${TEST_SUFFIX}.XXXXXX")"
FIXTURES_DIR="$WORK_DIR/nextstyle-clean"

# Never mutate the repo fixtures in-place; tests create/delete functions via the admin API.
cp -R "$ROOT_DIR/tests/fixtures/nextstyle-clean" "$FIXTURES_DIR"

cleanup() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$STACK_EXIT_FILE" ]]; then
    rm -f "$STACK_EXIT_FILE" >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_UP" != "1" ]]; then
    (cd "$ROOT_DIR" && COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" docker compose down --remove-orphans >/dev/null 2>&1) || true
  fi
  rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "refs:"
echo "  related-test: tests/integration/test-openapi-native.sh"
echo "  report: docs/internal/STATUS_UPDATE.md"
echo "  demo-link: /showcase -> /html?name=Designer"

assert_no_wizard_temp_artifacts() {
  local temp_dirs
  temp_dirs="$(find "$ROOT_DIR/examples/functions/next-style/node" -mindepth 1 -maxdepth 1 -type d -name 'wiz_*' 2>/dev/null || true)"
  if [[ -n "$temp_dirs" ]]; then
    echo "FAIL found temporary wizard artifacts under examples/functions/next-style/node"
    echo "$temp_dirs"
    exit 1
  fi
}

wait_for_health() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    if [[ -n "$STACK_EXIT_FILE" && -s "$STACK_EXIT_FILE" ]]; then
      echo "FAIL fastfn process exited before health became ready"
      if [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]]; then
        tail -n 220 "$STACK_LOG" || true
      fi
      exit 1
    fi

    if [[ -n "$STACK_PID" ]] && ! kill -0 "$STACK_PID" >/dev/null 2>&1; then
      echo "FAIL fastfn process exited before health became ready"
      if [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]]; then
        tail -n 220 "$STACK_LOG" || true
      fi
      exit 1
    fi

    local code
    code="$(curl -sS -o /tmp/fastfn-openapi-system-health.out -w '%{http_code}' 'http://127.0.0.1:8080/_fn/health' 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      ready=1
      break
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

wait_for_runtime_up() {
  local runtime="$1"
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    local health_json
    health_json="$(curl -sS 'http://127.0.0.1:8080/_fn/health' 2>/dev/null || true)"
    if HEALTH_JSON="$health_json" RUNTIME="$runtime" python3 - <<'PY' >/dev/null 2>&1
import json
import os

obj = json.loads(os.environ["HEALTH_JSON"] or "{}")
runtime = os.environ["RUNTIME"]
rt = ((obj.get("runtimes") or {}).get(runtime) or {})
health = rt.get("health") or {}
if health.get("up") is True:
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
    echo "FAIL runtime did not become healthy: $runtime"
    curl -sS 'http://127.0.0.1:8080/_fn/health' || true
    return 1
  fi
}

assert_experimental_runtimes_off_by_default() {
  local health_json
  health_json="$(curl -sS 'http://127.0.0.1:8080/_fn/health')"
  HEALTH_JSON="$health_json" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["HEALTH_JSON"])
runtimes = obj.get("runtimes") or {}
assert "rust" not in runtimes, f"rust should be disabled by default: {sorted(runtimes.keys())}"
assert "go" not in runtimes, f"go should be disabled by default: {sorted(runtimes.keys())}"
PY
}

assert_no_wizard_temp_artifacts

start_stack() {
  local cmd
  (cd "$ROOT_DIR" && COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" docker compose down --remove-orphans >/dev/null 2>&1) || true

  STACK_LOG="$(mktemp -t fastfn-openapi-system.XXXXXX.log)"
  STACK_EXIT_FILE="$(mktemp -t fastfn-openapi-system.exit.XXXXXX)"
  cmd=(env COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" FN_ADMIN_TOKEN="$FN_ADMIN_TOKEN" FN_UI_ENABLED=0 FN_OPENAPI_INCLUDE_INTERNAL=0)
  if [[ "$#" -gt 0 ]]; then
    cmd+=("$@")
  fi
  cmd+=(./bin/fastfn dev "$FIXTURES_DIR")
  (
    cd "$ROOT_DIR"
    "${cmd[@]}" >"$STACK_LOG" 2>&1
    echo "$?" >"$STACK_EXIT_FILE"
  ) &
  STACK_PID="$!"
  wait_for_health
}

start_stack_with_config() {
  local config_path="$1"
  shift || true

  local cmd
  (cd "$ROOT_DIR" && COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" docker compose down --remove-orphans >/dev/null 2>&1) || true

  STACK_LOG="$(mktemp -t fastfn-openapi-system.XXXXXX.log)"
  STACK_EXIT_FILE="$(mktemp -t fastfn-openapi-system.exit.XXXXXX)"
  cmd=(env -u FN_OPENAPI_INCLUDE_INTERNAL COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" FN_ADMIN_TOKEN="$FN_ADMIN_TOKEN" FN_UI_ENABLED=0)
  if [[ "$#" -gt 0 ]]; then
    cmd+=("$@")
  fi
  cmd+=(./bin/fastfn --config "$config_path" dev)
  (
    cd "$ROOT_DIR"
    "${cmd[@]}" >"$STACK_LOG" 2>&1
    echo "$?" >"$STACK_EXIT_FILE"
  ) &
  STACK_PID="$!"
  wait_for_health
}

stop_stack() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  STACK_PID=""
  if [[ -n "$STACK_EXIT_FILE" ]]; then
    rm -f "$STACK_EXIT_FILE" >/dev/null 2>&1 || true
    STACK_EXIT_FILE=""
  fi
  (cd "$ROOT_DIR" && COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" docker compose down --remove-orphans >/dev/null 2>&1) || true
}

assert_config_files_hidden() {
  local code
  code="$(curl -sS -o /tmp/fastfn-openapi-fastfn-json.out -w '%{http_code}' 'http://127.0.0.1:8080/fastfn.json')"
  if [[ "$code" != "404" ]]; then
    echo "FAIL GET /fastfn.json expected=404 got=$code"
    cat /tmp/fastfn-openapi-fastfn-json.out || true
    exit 1
  fi

  code="$(curl -sS -o /tmp/fastfn-openapi-fastfn-toml.out -w '%{http_code}' 'http://127.0.0.1:8080/fastfn.toml')"
  if [[ "$code" != "404" ]]; then
    echo "FAIL GET /fastfn.toml expected=404 got=$code"
    cat /tmp/fastfn-openapi-fastfn-toml.out || true
    exit 1
  fi
}

assert_home_quick_invoke_is_live_openapi_based() {
  local home_html='/tmp/openapi-system-home.out'
  curl -sS 'http://127.0.0.1:8080/' >"$home_html"

  if grep -q "Current demos (forms, polyglot SQLite, JSON, HTML/CSV/PNG, QR, WhatsApp, Gmail, Telegram)." "$home_html"; then
    echo "FAIL home quick invoke still shows stale static demo list"
    exit 1
  fi

  if ! grep -q "Loading live routes from OpenAPI" "$home_html"; then
    echo "FAIL home quick invoke missing live OpenAPI summary"
    exit 1
  fi
}

assert_openapi_functions_only_default_and_admin_functional() {
  local openapi_json
  openapi_json="$(curl -sS 'http://127.0.0.1:8080/_fn/openapi.json')"
  OPENAPI_JSON="$openapi_json" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["OPENAPI_JSON"])
paths = obj.get("paths") or {}
assert isinstance(paths, dict), "missing paths"
assert "/users" in paths, "expected real function path in OpenAPI"
internal = [p for p in paths if isinstance(p, str) and p.startswith("/_fn/")]
assert not internal, f"internal paths must be hidden by default: {internal[:10]}"
PY

  local health_code catalog_code
  health_code="$(curl -sS -o /tmp/openapi-system-default-health.out -w '%{http_code}' 'http://127.0.0.1:8080/_fn/health')"
  if [[ "$health_code" != "200" ]]; then
    echo "FAIL /_fn/health should stay functional while hidden from OpenAPI"
    cat /tmp/openapi-system-default-health.out || true
    exit 1
  fi

  catalog_code="$(curl -sS -o /tmp/openapi-system-default-catalog.out -w '%{http_code}' 'http://127.0.0.1:8080/_fn/catalog')"
  if [[ "$catalog_code" != "200" ]]; then
    echo "FAIL /_fn/catalog should stay functional while hidden from OpenAPI"
    cat /tmp/openapi-system-default-catalog.out || true
    exit 1
  fi
}

assert_openapi_internal_contract() {
  local openapi_json
  local catalog_json
  openapi_json="$(curl -sS 'http://127.0.0.1:8080/_fn/openapi.json')"
  catalog_json="$(curl -sS 'http://127.0.0.1:8080/_fn/catalog')"
  OPENAPI_JSON="$openapi_json" CATALOG_JSON="$catalog_json" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["OPENAPI_JSON"])
catalog = json.loads(os.environ["CATALOG_JSON"])
paths = obj.get("paths") or {}

required_paths = [
    "/_fn/function",
    "/_fn/function-config",
    "/_fn/function-env",
    "/_fn/function-code",
    "/_fn/invoke",
    "/_fn/jobs",
    "/_fn/jobs/{id}/result",
    "/_fn/logs",
    "/_fn/ui-state",
]
for p in required_paths:
    assert p in paths, f"missing internal path {p}"


def get_param(params, name):
    for p in params or []:
        if isinstance(p, dict) and p.get("name") == name:
            return p
    return None


fn_get = paths["/_fn/function"]["get"]
fn_params = fn_get.get("parameters") or []
runtime = get_param(fn_params, "runtime")
name = get_param(fn_params, "name")
version = get_param(fn_params, "version")
include_code = get_param(fn_params, "include_code")
assert runtime and runtime.get("in") == "query" and runtime.get("required") is True
assert name and name.get("in") == "query" and name.get("required") is True
assert version and version.get("in") == "query" and version.get("required") is False
assert include_code and include_code.get("schema", {}).get("default") == "1"

jobs_get = paths["/_fn/jobs"]["get"]
limit = get_param(jobs_get.get("parameters"), "limit")
assert limit and limit.get("schema", {}).get("default") == 50

jobs_post_schema = paths["/_fn/jobs"]["post"]["requestBody"]["content"]["application/json"]["schema"]
required = set(jobs_post_schema.get("required") or [])
assert {"runtime", "name"}.issubset(required)
props = jobs_post_schema.get("properties") or {}
assert props.get("method", {}).get("default") == "GET"
assert props.get("max_attempts", {}).get("default") == 1
assert props.get("retry_delay_ms", {}).get("default") == 1000
assert "route" in props
assert "params" in props
assert "202" in (paths["/_fn/jobs/{id}/result"]["get"].get("responses") or {})

invoke_schema = paths["/_fn/invoke"]["post"]["requestBody"]["content"]["application/json"]["schema"]
invoke_required = set(invoke_schema.get("required") or [])
assert {"runtime", "name"}.issubset(invoke_required)
invoke_props = invoke_schema.get("properties") or {}
assert invoke_props.get("method", {}).get("default") == "GET"
assert "route" in invoke_props
assert "params" in invoke_props

logs_get = paths["/_fn/logs"]["get"]
file_p = get_param(logs_get.get("parameters"), "file")
lines_p = get_param(logs_get.get("parameters"), "lines")
format_p = get_param(logs_get.get("parameters"), "format")
assert file_p and file_p.get("in") == "query" and file_p.get("schema", {}).get("default") == "error"
assert lines_p and lines_p.get("in") == "query" and lines_p.get("schema", {}).get("default") == 200
assert format_p and format_p.get("in") == "query" and format_p.get("schema", {}).get("default") == "text"

for path, ops in paths.items():
    assert ":" not in path, f"unexpected raw dynamic route token in path: {path}"
    if not isinstance(ops, dict):
        continue
    for op in ops.values():
        if not isinstance(op, dict):
            continue
        for p in op.get("parameters") or []:
            if isinstance(p, dict):
                assert "in" in p, f"parameter missing in on path {path}"
                assert "in_" not in p, f"invalid in_ key on path {path}"

assert "/blog/{slug}" in paths, "catch-all mapped path not exported"
assert "/fn/hello" not in paths, "/fn compat path leaked into OpenAPI"


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


mapped = catalog.get("mapped_routes") or {}
expected_paths = set()
expected_methods_by_path = {}
for route, entries in mapped.items():
    if not isinstance(route, str) or not route.startswith("/"):
        continue
    if route.startswith("/_fn/"):
        continue
    openapi_path = route_to_openapi_path(route)
    expected_paths.add(openapi_path)
    assert openapi_path in paths, f"catalog route missing from OpenAPI: {route} -> {openapi_path}"
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
            assert op in (paths.get(openapi_path) or {}), f"missing method {op.upper()} for {openapi_path}"

public_paths = {
    p for p in paths.keys()
    if isinstance(p, str) and p.startswith("/") and not p.startswith("/_fn/")
}
unexpected_paths = sorted(public_paths - expected_paths)
assert not unexpected_paths, f"unexpected extra OpenAPI paths not in catalog mapping: {unexpected_paths[:10]}"
missing_paths = sorted(expected_paths - public_paths)
assert not missing_paths, f"missing OpenAPI paths for mapped routes: {missing_paths[:10]}"

for openapi_path, expected_methods in expected_methods_by_path.items():
    ops = paths.get(openapi_path) or {}
    actual_methods = {k.upper() for k, v in ops.items() if isinstance(v, dict)}
    assert actual_methods == expected_methods, (
        f"method mismatch on {openapi_path}: expected={sorted(expected_methods)} actual={sorted(actual_methods)}"
    )
PY
}

assert_ad_hoc_route_exported() {
  local fn_name route_base route_catchall openapi_route openapi_catchall
  fn_name="openapi_probe_${TEST_SUFFIX}"
  route_base="/openapi-probe-${TEST_SUFFIX}/:id"
  route_catchall="/openapi-probe-${TEST_SUFFIX}/:id/*"
  openapi_route="/openapi-probe-${TEST_SUFFIX}/{id}"
  openapi_catchall="/openapi-probe-${TEST_SUFFIX}/{id}/{wildcard}"

  local create_code cfg_code code_code reload_code delete_code probe_get_code probe_post_code

  create_code="$(curl -sS -o /tmp/openapi-system-create.out -w '%{http_code}' -X POST \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"OpenAPI ad-hoc probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create ad-hoc function expected=201 got=$create_code"
    cat /tmp/openapi-system-create.out || true
    exit 1
  fi

  cfg_code="$(curl -sS -o /tmp/openapi-system-cfg.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-config?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"invoke\":{\"methods\":[\"GET\",\"POST\"],\"routes\":[\"${route_base}\",\"${route_catchall}\"],\"allow_hosts\":[\"api.allowed.test\"]}}")"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure ad-hoc function expected=200 got=$cfg_code"
    cat /tmp/openapi-system-cfg.out || true
    exit 1
  fi

  code_code="$(curl -sS -o /tmp/openapi-system-code.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-code?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async (event) => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ ok: true, params: event.path_params || {} }) });\n"}')"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write ad-hoc function code expected=200 got=$code_code"
    cat /tmp/openapi-system-code.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-reload.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload expected=200 got=$reload_code"
    cat /tmp/openapi-system-reload.out || true
    exit 1
  fi
  # Ensure the target runtime is actually healthy before probing the new route.
  wait_for_runtime_up "node"

  probe_get_code="$(curl -sS -o /tmp/openapi-system-probe-get.out -w '%{http_code}' \
    -H 'Host: api.allowed.test' \
    "http://127.0.0.1:8080/openapi-probe-${TEST_SUFFIX}/42")"
  if [[ "$probe_get_code" != "200" ]]; then
    echo "FAIL ad-hoc probe GET expected=200 got=$probe_get_code"
    cat /tmp/openapi-system-probe-get.out || true
    exit 1
  fi

  probe_post_code="$(curl -sS -o /tmp/openapi-system-probe-post.out -w '%{http_code}' -X POST \
    -H 'Host: api.allowed.test' \
    "http://127.0.0.1:8080/openapi-probe-${TEST_SUFFIX}/42/extra/segments" \
    -H 'Content-Type: application/json' \
    --data '{"probe":true}')"
  if [[ "$probe_post_code" != "200" ]]; then
    echo "FAIL ad-hoc probe POST expected=200 got=$probe_post_code"
    cat /tmp/openapi-system-probe-post.out || true
    exit 1
  fi

  local probe_blocked_code
  probe_blocked_code="$(curl -sS -o /tmp/openapi-system-probe-blocked.out -w '%{http_code}' \
    -H 'Host: denied.test' \
    "http://127.0.0.1:8080/openapi-probe-${TEST_SUFFIX}/42")"
  if [[ "$probe_blocked_code" != "421" ]]; then
    echo "FAIL ad-hoc probe host allowlist expected=421 got=$probe_blocked_code"
    cat /tmp/openapi-system-probe-blocked.out || true
    exit 1
  fi
  if ! grep -q '"error":"host not allowed"' /tmp/openapi-system-probe-blocked.out; then
    echo "FAIL ad-hoc probe host allowlist missing error body"
    cat /tmp/openapi-system-probe-blocked.out || true
    exit 1
  fi

  local openapi_json
  openapi_json="$(curl -sS 'http://127.0.0.1:8080/_fn/openapi.json')"
  OPENAPI_JSON="$openapi_json" OPENAPI_ROUTE="$openapi_route" OPENAPI_CATCHALL="$openapi_catchall" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["OPENAPI_JSON"])
paths = obj.get("paths") or {}
openapi_route = os.environ["OPENAPI_ROUTE"]
openapi_catchall = os.environ["OPENAPI_CATCHALL"]

assert openapi_route in paths, "ad-hoc dynamic route missing from openapi"
ops = paths[openapi_route]
assert "get" in ops and "post" in ops, "ad-hoc methods missing in openapi"
params = (ops.get("get") or {}).get("parameters") or []
assert any((p or {}).get("name") == "id" and (p or {}).get("in") == "path" for p in params), "ad-hoc path parameter missing"
assert openapi_catchall in paths, "ad-hoc catch-all route missing from openapi"
wild_ops = paths[openapi_catchall]
assert "get" in wild_ops and "post" in wild_ops, "ad-hoc catch-all methods missing in openapi"
PY

  delete_code="$(curl -sS -o /tmp/openapi-system-delete.out -w '%{http_code}' -X DELETE \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete ad-hoc function expected=200 got=$delete_code"
    cat /tmp/openapi-system-delete.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-reload-delete.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after delete expected=200 got=$reload_code"
    cat /tmp/openapi-system-reload-delete.out || true
    exit 1
  fi

  openapi_json="$(curl -sS 'http://127.0.0.1:8080/_fn/openapi.json')"
  OPENAPI_JSON="$openapi_json" OPENAPI_ROUTE="$openapi_route" OPENAPI_CATCHALL="$openapi_catchall" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["OPENAPI_JSON"])
paths = obj.get("paths") or {}
assert os.environ["OPENAPI_ROUTE"] not in paths, "deleted ad-hoc route still present in OpenAPI"
assert os.environ["OPENAPI_CATCHALL"] not in paths, "deleted ad-hoc catch-all route still present in OpenAPI"
PY
}

assert_edge-proxy_denies_control_plane_paths() {
  local fn_name route
  fn_name="edge_ssrf_${TEST_SUFFIX}"
  route="/edge-ssrf-${TEST_SUFFIX}"

  local create_code cfg_code code_code reload_code call_code delete_code

  create_code="$(curl -sS -o /tmp/openapi-system-edge-ssrf-create.out -w '%{http_code}' -X POST \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"Edge SSRF control-plane probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create edge ssrf function expected=201 got=$create_code"
    cat /tmp/openapi-system-edge-ssrf-create.out || true
    exit 1
  fi

  cfg_code="$(curl -sS -o /tmp/openapi-system-edge-ssrf-cfg.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-config?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"${route}\"]},\"edge\":{\"base_url\":\"http://127.0.0.1:8080\",\"allow_hosts\":[\"127.0.0.1:8080\"],\"allow_private\":true}}")"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure edge ssrf function expected=200 got=$cfg_code"
    cat /tmp/openapi-system-edge-ssrf-cfg.out || true
    exit 1
  fi

  code_code="$(curl -sS -o /tmp/openapi-system-edge-ssrf-code.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-code?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async () => ({ proxy: { path: \"/_fn/health\", method: \"GET\", headers: { \"x-edge\": \"1\" } } });\n"}')"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write edge ssrf function code expected=200 got=$code_code"
    cat /tmp/openapi-system-edge-ssrf-code.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-edge-ssrf-reload.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after edge ssrf update expected=200 got=$reload_code"
    cat /tmp/openapi-system-edge-ssrf-reload.out || true
    exit 1
  fi

  call_code="$(curl -sS -o /tmp/openapi-system-edge-ssrf-call.out -w '%{http_code}' \
    "http://127.0.0.1:8080${route}")"
  if [[ "$call_code" != "502" ]]; then
    echo "FAIL edge ssrf call expected=502 got=$call_code"
    cat /tmp/openapi-system-edge-ssrf-call.out || true
    exit 1
  fi
  if ! grep -q "control-plane path not allowed" /tmp/openapi-system-edge-ssrf-call.out; then
    echo "FAIL edge ssrf denial missing control-plane reason"
    cat /tmp/openapi-system-edge-ssrf-call.out || true
    exit 1
  fi

  delete_code="$(curl -sS -o /tmp/openapi-system-edge-ssrf-delete.out -w '%{http_code}' -X DELETE \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete edge ssrf function expected=200 got=$delete_code"
    cat /tmp/openapi-system-edge-ssrf-delete.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-edge-ssrf-reload-delete.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after edge ssrf delete expected=200 got=$reload_code"
    cat /tmp/openapi-system-edge-ssrf-reload-delete.out || true
    exit 1
  fi
}

assert_force_url_global_controls_policy_override() {
  local fn_name route create_code cfg_code code_code reload_code call_code delete_code
  fn_name="conflict_policy_${TEST_SUFFIX}"
  route="/conflict-route"

  create_code="$(curl -sS -o /tmp/openapi-system-force-url-create.out -w '%{http_code}' -X POST \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"force-url policy override probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create force-url function expected=201 got=$create_code"
    cat /tmp/openapi-system-force-url-create.out || true
    exit 1
  fi

  cfg_code="$(curl -sS -o /tmp/openapi-system-force-url-cfg.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-config?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"${route}\"]}}")"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure force-url function expected=200 got=$cfg_code"
    cat /tmp/openapi-system-force-url-cfg.out || true
    exit 1
  fi

  code_code="$(curl -sS -o /tmp/openapi-system-force-url-code.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-code?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async () => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ ok: true, source: \"policy\" }) });\n"}')"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write force-url function code expected=200 got=$code_code"
    cat /tmp/openapi-system-force-url-code.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-force-url-reload.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after force-url update expected=200 got=$reload_code"
    cat /tmp/openapi-system-force-url-reload.out || true
    exit 1
  fi

  call_code="$(curl -sS -o /tmp/openapi-system-force-url-call.out -w '%{http_code}' \
    "http://127.0.0.1:8080${route}")"
  if [[ "$call_code" != "200" ]]; then
    echo "FAIL force-url call expected=200 got=$call_code"
    cat /tmp/openapi-system-force-url-call.out || true
    exit 1
  fi

  local expected_source
  expected_source="${1:-}"
  if [[ "$expected_source" == "policy" ]]; then
    if ! grep -q '\"source\":\"policy\"' /tmp/openapi-system-force-url-call.out; then
      echo "FAIL force-url expected policy source"
      cat /tmp/openapi-system-force-url-call.out || true
      exit 1
    fi
  else
    if ! grep -q '\"source\":\"file\"' /tmp/openapi-system-force-url-call.out; then
      echo "FAIL force-url expected file source"
      cat /tmp/openapi-system-force-url-call.out || true
      exit 1
    fi
  fi

  delete_code="$(curl -sS -o /tmp/openapi-system-force-url-delete.out -w '%{http_code}' -X DELETE \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete force-url function expected=200 got=$delete_code"
    cat /tmp/openapi-system-force-url-delete.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-force-url-reload-delete.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after force-url delete expected=200 got=$reload_code"
    cat /tmp/openapi-system-force-url-reload-delete.out || true
    exit 1
  fi
}

assert_go_runtime_ad_hoc_route_exported() {
  local fn_name route openapi_route
  fn_name="go_probe_${TEST_SUFFIX}"
  route="/go-probe-${TEST_SUFFIX}"
  openapi_route="$route"

  local create_code cfg_code code_code reload_code delete_code ok_code denied_code
  local cfg_payload code_payload

  wait_for_runtime_up "go"

  create_code="$(curl -sS -o /tmp/openapi-system-go-create.out -w '%{http_code}' -X POST \
    "http://127.0.0.1:8080/_fn/function?runtime=go&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"OpenAPI Go runtime probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create go ad-hoc function expected=201 got=$create_code"
    cat /tmp/openapi-system-go-create.out || true
    exit 1
  fi

  cfg_payload="$(mktemp -t openapi-system-go-cfg.XXXXXX.json)"
  cat >"$cfg_payload" <<JSON
{"invoke":{"methods":["GET"],"routes":["${route}"],"allow_hosts":["go.allowed.test"]}}
JSON
  cfg_code="$(curl -sS -o /tmp/openapi-system-go-cfg.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-config?runtime=go&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data @"$cfg_payload")"
  rm -f "$cfg_payload"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure go ad-hoc function expected=200 got=$cfg_code"
    cat /tmp/openapi-system-go-cfg.out || true
    exit 1
  fi

  code_payload="$(mktemp -t openapi-system-go-code.XXXXXX.json)"
  cat >"$code_payload" <<'JSON'
{"code":"package main\n\nimport \"encoding/json\"\n\nfunc handler(event map[string]interface{}) map[string]interface{} {\n  body, _ := json.Marshal(map[string]interface{}{\"ok\": true, \"runtime\": \"go\"})\n  return map[string]interface{}{\n    \"status\": 200,\n    \"headers\": map[string]interface{}{\"Content-Type\": \"application/json\"},\n    \"body\": string(body),\n  }\n}\n"}
JSON
  code_code="$(curl -sS -o /tmp/openapi-system-go-code.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-code?runtime=go&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data @"$code_payload")"
  rm -f "$code_payload"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write go ad-hoc function code expected=200 got=$code_code"
    cat /tmp/openapi-system-go-code.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-go-reload.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after go update expected=200 got=$reload_code"
    cat /tmp/openapi-system-go-reload.out || true
    exit 1
  fi

  ok_code="$(curl -sS -o /tmp/openapi-system-go-ok.out -w '%{http_code}' \
    -H 'Host: go.allowed.test' \
    "http://127.0.0.1:8080${route}")"
  if [[ "$ok_code" != "200" ]]; then
    echo "FAIL go ad-hoc route expected=200 got=$ok_code"
    cat /tmp/openapi-system-go-ok.out || true
    exit 1
  fi
  if ! grep -q '"runtime":"go"' /tmp/openapi-system-go-ok.out; then
    echo "FAIL go ad-hoc route body mismatch"
    cat /tmp/openapi-system-go-ok.out || true
    exit 1
  fi

  denied_code="$(curl -sS -o /tmp/openapi-system-go-denied.out -w '%{http_code}' \
    -H 'Host: denied-go.test' \
    "http://127.0.0.1:8080${route}")"
  if [[ "$denied_code" != "421" ]]; then
    echo "FAIL go ad-hoc allow_hosts denied request expected=421 got=$denied_code"
    cat /tmp/openapi-system-go-denied.out || true
    exit 1
  fi
  if ! grep -q '"error":"host not allowed"' /tmp/openapi-system-go-denied.out; then
    echo "FAIL go ad-hoc allow_hosts denied body missing error"
    cat /tmp/openapi-system-go-denied.out || true
    exit 1
  fi

  local openapi_json
  openapi_json="$(curl -sS 'http://127.0.0.1:8080/_fn/openapi.json')"
  OPENAPI_JSON="$openapi_json" OPENAPI_ROUTE="$openapi_route" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["OPENAPI_JSON"])
paths = obj.get("paths") or {}
route = os.environ["OPENAPI_ROUTE"]
assert route in paths, f"go ad-hoc route missing from openapi: {route}"
assert "get" in (paths.get(route) or {}), f"go ad-hoc GET missing from openapi: {route}"
PY

  delete_code="$(curl -sS -o /tmp/openapi-system-go-delete.out -w '%{http_code}' -X DELETE \
    "http://127.0.0.1:8080/_fn/function?runtime=go&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete go ad-hoc function expected=200 got=$delete_code"
    cat /tmp/openapi-system-go-delete.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-go-reload-delete.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after go delete expected=200 got=$reload_code"
    cat /tmp/openapi-system-go-reload-delete.out || true
    exit 1
  fi
}

assert_lua_runtime_ad_hoc_route_exported() {
  local fn_name route openapi_route
  fn_name="lua_probe_${TEST_SUFFIX}"
  route="/lua-probe-${TEST_SUFFIX}"
  openapi_route="$route"

  local create_code cfg_code code_code reload_code delete_code ok_code denied_code
  local cfg_payload code_payload

  create_code="$(curl -sS -o /tmp/openapi-system-lua-create.out -w '%{http_code}' -X POST \
    "http://127.0.0.1:8080/_fn/function?runtime=lua&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"OpenAPI Lua runtime probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create lua ad-hoc function expected=201 got=$create_code"
    cat /tmp/openapi-system-lua-create.out || true
    exit 1
  fi

  cfg_payload="$(mktemp -t openapi-system-lua-cfg.XXXXXX.json)"
  cat >"$cfg_payload" <<JSON
{"invoke":{"methods":["GET"],"routes":["${route}"],"allow_hosts":["lua.allowed.test"]}}
JSON
  cfg_code="$(curl -sS -o /tmp/openapi-system-lua-cfg.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-config?runtime=lua&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data @"$cfg_payload")"
  rm -f "$cfg_payload"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure lua ad-hoc function expected=200 got=$cfg_code"
    cat /tmp/openapi-system-lua-cfg.out || true
    exit 1
  fi

  code_payload="$(mktemp -t openapi-system-lua-code.XXXXXX.json)"
  cat >"$code_payload" <<'JSON'
{"code":"local cjson = require(\"cjson.safe\")\nfunction handler(event)\n  return {\n    status = 200,\n    headers = { [\"Content-Type\"] = \"application/json\" },\n    body = cjson.encode({ ok = true, runtime = \"lua\" }),\n  }\nend\n"}
JSON
  code_code="$(curl -sS -o /tmp/openapi-system-lua-code.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-code?runtime=lua&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data @"$code_payload")"
  rm -f "$code_payload"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write lua ad-hoc function code expected=200 got=$code_code"
    cat /tmp/openapi-system-lua-code.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-lua-reload.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after lua update expected=200 got=$reload_code"
    cat /tmp/openapi-system-lua-reload.out || true
    exit 1
  fi

  ok_code="$(curl -sS -o /tmp/openapi-system-lua-ok.out -w '%{http_code}' \
    -H 'Host: lua.allowed.test' \
    "http://127.0.0.1:8080${route}")"
  if [[ "$ok_code" != "200" ]]; then
    echo "FAIL lua ad-hoc route expected=200 got=$ok_code"
    cat /tmp/openapi-system-lua-ok.out || true
    exit 1
  fi
  if ! grep -q '"runtime":"lua"' /tmp/openapi-system-lua-ok.out; then
    echo "FAIL lua ad-hoc route body mismatch"
    cat /tmp/openapi-system-lua-ok.out || true
    exit 1
  fi

  denied_code="$(curl -sS -o /tmp/openapi-system-lua-denied.out -w '%{http_code}' \
    -H 'Host: denied-lua.test' \
    "http://127.0.0.1:8080${route}")"
  if [[ "$denied_code" != "421" ]]; then
    echo "FAIL lua ad-hoc allow_hosts denied request expected=421 got=$denied_code"
    cat /tmp/openapi-system-lua-denied.out || true
    exit 1
  fi
  if ! grep -q '"error":"host not allowed"' /tmp/openapi-system-lua-denied.out; then
    echo "FAIL lua ad-hoc allow_hosts denied body missing error"
    cat /tmp/openapi-system-lua-denied.out || true
    exit 1
  fi

  local openapi_json
  openapi_json="$(curl -sS 'http://127.0.0.1:8080/_fn/openapi.json')"
  OPENAPI_JSON="$openapi_json" OPENAPI_ROUTE="$openapi_route" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["OPENAPI_JSON"])
paths = obj.get("paths") or {}
route = os.environ["OPENAPI_ROUTE"]
assert route in paths, f"lua ad-hoc route missing from openapi: {route}"
assert "get" in (paths.get(route) or {}), f"lua ad-hoc GET missing from openapi: {route}"
PY

  delete_code="$(curl -sS -o /tmp/openapi-system-lua-delete.out -w '%{http_code}' -X DELETE \
    "http://127.0.0.1:8080/_fn/function?runtime=lua&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete lua ad-hoc function expected=200 got=$delete_code"
    cat /tmp/openapi-system-lua-delete.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-lua-reload-delete.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after lua delete expected=200 got=$reload_code"
    cat /tmp/openapi-system-lua-reload-delete.out || true
    exit 1
  fi
}

assert_shared_deps_node_pack_runtime() {
  local fn_name route pack_name pack_root delete_code create_code cfg_code code_code reload_code invoke_code
  fn_name="node_shared_pack_${TEST_SUFFIX}"
  route="/node-shared-pack-${TEST_SUFFIX}"
  pack_name="ci_shared_pack_${TEST_SUFFIX}"
  pack_root="$FIXTURES_DIR/.fastfn/packs/node/${pack_name}"

  mkdir -p "${pack_root}/node_modules/${pack_name}"
  cat >"${pack_root}/node_modules/${pack_name}/index.js" <<'JS'
module.exports = () => ({ ok: true, source: "shared_pack" });
JS

  create_code="$(curl -sS -o /tmp/openapi-system-shared-create.out -w '%{http_code}' -X POST \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"Node shared_deps pack probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create node shared_deps function expected=201 got=$create_code"
    cat /tmp/openapi-system-shared-create.out || true
    exit 1
  fi

  cfg_code="$(curl -sS -o /tmp/openapi-system-shared-cfg.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-config?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"shared_deps\":[\"${pack_name}\"],\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"${route}\"]}}")"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure shared_deps function expected=200 got=$cfg_code"
    cat /tmp/openapi-system-shared-cfg.out || true
    exit 1
  fi

  code_code="$(curl -sS -o /tmp/openapi-system-shared-code.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-code?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"code\":\"exports.handler = async () => { const fromPack = require('${pack_name}'); return { status: 200, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(fromPack()) }; };\\n\"}")"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write shared_deps function code expected=200 got=$code_code"
    cat /tmp/openapi-system-shared-code.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-shared-reload.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after shared_deps update expected=200 got=$reload_code"
    cat /tmp/openapi-system-shared-reload.out || true
    exit 1
  fi

  invoke_code="$(curl -sS -o /tmp/openapi-system-shared-invoke.out -w '%{http_code}' \
    "http://127.0.0.1:8080${route}")"
  if [[ "$invoke_code" != "200" ]]; then
    echo "FAIL shared_deps route expected=200 got=$invoke_code"
    cat /tmp/openapi-system-shared-invoke.out || true
    exit 1
  fi
  if ! grep -q '"source":"shared_pack"' /tmp/openapi-system-shared-invoke.out; then
    echo "FAIL shared_deps route body mismatch"
    cat /tmp/openapi-system-shared-invoke.out || true
    exit 1
  fi

  delete_code="$(curl -sS -o /tmp/openapi-system-shared-delete.out -w '%{http_code}' -X DELETE \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete shared_deps function expected=200 got=$delete_code"
    cat /tmp/openapi-system-shared-delete.out || true
    exit 1
  fi

  rm -rf "$pack_root"
}

assert_virtual_host_route_routing() {
  local fn_alpha fn_beta shared_route
  fn_alpha="vhost_alpha_${TEST_SUFFIX}"
  fn_beta="vhost_beta_${TEST_SUFFIX}"
  shared_route="/shared-vhost-${TEST_SUFFIX}"

  local create_a_code create_b_code cfg_a_code cfg_b_code code_a_code code_b_code reload_code delete_a_code delete_b_code

  create_a_code="$(curl -sS -o /tmp/openapi-system-vhost-create-a.out -w '%{http_code}' -X POST \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_alpha}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"Virtual host alpha"}')"
  if [[ "$create_a_code" != "201" ]]; then
    echo "FAIL create vhost_alpha expected=201 got=$create_a_code"
    cat /tmp/openapi-system-vhost-create-a.out || true
    exit 1
  fi

  create_b_code="$(curl -sS -o /tmp/openapi-system-vhost-create-b.out -w '%{http_code}' -X POST \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_beta}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"Virtual host beta"}')"
  if [[ "$create_b_code" != "201" ]]; then
    echo "FAIL create vhost_beta expected=201 got=$create_b_code"
    cat /tmp/openapi-system-vhost-create-b.out || true
    exit 1
  fi

  cfg_a_code="$(curl -sS -o /tmp/openapi-system-vhost-cfg-a.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-config?runtime=node&name=${fn_alpha}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"${shared_route}\"],\"allow_hosts\":[\"alpha.example.test\"]}}")"
  if [[ "$cfg_a_code" != "200" ]]; then
    echo "FAIL configure vhost_alpha expected=200 got=$cfg_a_code"
    cat /tmp/openapi-system-vhost-cfg-a.out || true
    exit 1
  fi

  cfg_b_code="$(curl -sS -o /tmp/openapi-system-vhost-cfg-b.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-config?runtime=node&name=${fn_beta}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"${shared_route}\"],\"allow_hosts\":[\"beta.example.test\"]}}")"
  if [[ "$cfg_b_code" != "200" ]]; then
    echo "FAIL configure vhost_beta expected=200 got=$cfg_b_code"
    cat /tmp/openapi-system-vhost-cfg-b.out || true
    exit 1
  fi

  code_a_code="$(curl -sS -o /tmp/openapi-system-vhost-code-a.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-code?runtime=node&name=${fn_alpha}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async () => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ tenant: \"alpha\" }) });\n"}')"
  if [[ "$code_a_code" != "200" ]]; then
    echo "FAIL code vhost_alpha expected=200 got=$code_a_code"
    cat /tmp/openapi-system-vhost-code-a.out || true
    exit 1
  fi

  code_b_code="$(curl -sS -o /tmp/openapi-system-vhost-code-b.out -w '%{http_code}' -X PUT \
    "http://127.0.0.1:8080/_fn/function-code?runtime=node&name=${fn_beta}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async () => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ tenant: \"beta\" }) });\n"}')"
  if [[ "$code_b_code" != "200" ]]; then
    echo "FAIL code vhost_beta expected=200 got=$code_b_code"
    cat /tmp/openapi-system-vhost-code-b.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-vhost-reload.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload vhost expected=200 got=$reload_code"
    cat /tmp/openapi-system-vhost-reload.out || true
    exit 1
  fi

  local alpha_code
  alpha_code="$(curl -sS -o /tmp/openapi-system-vhost-alpha.out -w '%{http_code}' \
    -H 'Host: alpha.example.test' \
    "http://127.0.0.1:8080${shared_route}")"
  if [[ "$alpha_code" != "200" ]]; then
    echo "FAIL vhost alpha expected=200 got=$alpha_code"
    cat /tmp/openapi-system-vhost-alpha.out || true
    exit 1
  fi
  if ! grep -q '"tenant":"alpha"' /tmp/openapi-system-vhost-alpha.out; then
    echo "FAIL vhost alpha body mismatch"
    cat /tmp/openapi-system-vhost-alpha.out || true
    exit 1
  fi

  local beta_code
  beta_code="$(curl -sS -o /tmp/openapi-system-vhost-beta.out -w '%{http_code}' \
    -H 'Host: beta.example.test' \
    "http://127.0.0.1:8080${shared_route}")"
  if [[ "$beta_code" != "200" ]]; then
    echo "FAIL vhost beta expected=200 got=$beta_code"
    cat /tmp/openapi-system-vhost-beta.out || true
    exit 1
  fi
  if ! grep -q '"tenant":"beta"' /tmp/openapi-system-vhost-beta.out; then
    echo "FAIL vhost beta body mismatch"
    cat /tmp/openapi-system-vhost-beta.out || true
    exit 1
  fi

  local denied_code
  denied_code="$(curl -sS -o /tmp/openapi-system-vhost-denied.out -w '%{http_code}' \
    -H 'Host: denied.example.test' \
    "http://127.0.0.1:8080${shared_route}")"
  if [[ "$denied_code" != "421" ]]; then
    echo "FAIL vhost denied expected=421 got=$denied_code"
    cat /tmp/openapi-system-vhost-denied.out || true
    exit 1
  fi
  if ! grep -q '"error":"host not allowed"' /tmp/openapi-system-vhost-denied.out; then
    echo "FAIL vhost denied missing error body"
    cat /tmp/openapi-system-vhost-denied.out || true
    exit 1
  fi

  local catalog_json
  catalog_json="$(curl -sS 'http://127.0.0.1:8080/_fn/catalog')"
  CATALOG_JSON="$catalog_json" SHARED_ROUTE="$shared_route" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["CATALOG_JSON"])
mapped = obj.get("mapped_routes") or {}
route = os.environ["SHARED_ROUTE"]
entries = mapped.get(route) or []
if isinstance(entries, dict):
    entries = [entries]
assert isinstance(entries, list) and len(entries) >= 2, entries
conflicts = obj.get("mapped_route_conflicts") or {}
assert route not in conflicts, conflicts
PY

  delete_a_code="$(curl -sS -o /tmp/openapi-system-vhost-delete-a.out -w '%{http_code}' -X DELETE \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_alpha}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_a_code" != "200" ]]; then
    echo "FAIL delete vhost_alpha expected=200 got=$delete_a_code"
    cat /tmp/openapi-system-vhost-delete-a.out || true
    exit 1
  fi

  delete_b_code="$(curl -sS -o /tmp/openapi-system-vhost-delete-b.out -w '%{http_code}' -X DELETE \
    "http://127.0.0.1:8080/_fn/function?runtime=node&name=${fn_beta}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_b_code" != "200" ]]; then
    echo "FAIL delete vhost_beta expected=200 got=$delete_b_code"
    cat /tmp/openapi-system-vhost-delete-b.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/openapi-system-vhost-reload-delete.out -w '%{http_code}' -X POST \
    'http://127.0.0.1:8080/_fn/reload' \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after vhost delete expected=200 got=$reload_code"
    cat /tmp/openapi-system-vhost-reload-delete.out || true
    exit 1
  fi
}

assert_openapi_server_url_resolution() {
  local openapi_json

  openapi_json="$(curl -sS -H 'Host: api.local.test' 'http://127.0.0.1:8080/_fn/openapi.json')"
  OPENAPI_JSON="$openapi_json" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["OPENAPI_JSON"])
servers = obj.get("servers") or []
assert servers and isinstance(servers[0], dict), "missing servers[0]"
assert servers[0].get("url") == "http://api.local.test", servers[0].get("url")
PY

  openapi_json="$(curl -sS \
    -H 'Host: ignored.local' \
    -H 'X-Forwarded-Proto: https' \
    -H 'X-Forwarded-Host: api.proxy.test' \
    'http://127.0.0.1:8080/_fn/openapi.json')"
  OPENAPI_JSON="$openapi_json" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["OPENAPI_JSON"])
servers = obj.get("servers") or []
assert servers and isinstance(servers[0], dict), "missing servers[0]"
assert servers[0].get("url") == "https://api.proxy.test", servers[0].get("url")
PY
}

assert_openapi_server_url_override() {
  local openapi_json
  openapi_json="$(curl -sS -H 'Host: random.local' 'http://127.0.0.1:8080/_fn/openapi.json')"
  OPENAPI_JSON="$openapi_json" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["OPENAPI_JSON"])
servers = obj.get("servers") or []
assert servers and isinstance(servers[0], dict), "missing servers[0]"
assert servers[0].get("url") == "https://api.fastfn.example", servers[0].get("url")
PY
}

echo "== openapi internal contract =="
start_stack
assert_experimental_runtimes_off_by_default
assert_config_files_hidden
assert_home_quick_invoke_is_live_openapi_based
assert_openapi_functions_only_default_and_admin_functional
assert_openapi_server_url_resolution
assert_ad_hoc_route_exported
assert_edge-proxy_denies_control_plane_paths
assert_force_url_global_controls_policy_override "file"
assert_shared_deps_node_pack_runtime
assert_virtual_host_route_routing
stop_stack

echo "== force-url global override (FN_FORCE_URL=1) =="
start_stack FN_FORCE_URL=1
assert_force_url_global_controls_policy_override "policy"
stop_stack

echo "== openapi go runtime opt-in =="
start_stack FN_RUNTIMES=python,node,php,go
assert_go_runtime_ad_hoc_route_exported
stop_stack

echo "== openapi lua runtime in-process =="
start_stack FN_RUNTIMES=python,node,php,lua
assert_lua_runtime_ad_hoc_route_exported
stop_stack

echo "== openapi internal contract (opt-in) =="
start_stack FN_OPENAPI_INCLUDE_INTERNAL=1
assert_openapi_internal_contract
stop_stack

echo "== openapi internal contract (config toggle) =="
CONFIG_DIR="$(mktemp -d -t fastfn-openapi-config.XXXXXX)"
CONFIG_INCLUDE_INTERNAL="$CONFIG_DIR/fastfn-openapi-config.json"
cat >"$CONFIG_INCLUDE_INTERNAL" <<'JSON'
{
  "functions-dir": "__FIXTURES_DIR__",
  "openapi-include-internal": true
}
JSON
sed -i.bak "s|__FIXTURES_DIR__|$FIXTURES_DIR|g" "$CONFIG_INCLUDE_INTERNAL"
rm -f "$CONFIG_INCLUDE_INTERNAL.bak" >/dev/null 2>&1 || true
start_stack_with_config "$CONFIG_INCLUDE_INTERNAL"
assert_openapi_internal_contract
stop_stack
rm -rf "$CONFIG_DIR"

echo "== openapi server_url override =="
start_stack FN_PUBLIC_BASE_URL=https://api.fastfn.example
assert_openapi_server_url_override

echo "PASS test-openapi-system.sh"
