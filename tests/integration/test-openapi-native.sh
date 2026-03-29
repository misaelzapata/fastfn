#!/usr/bin/env bash
set -euo pipefail

# Related:
# - tests/integration/test-openapi-system.sh
# - docs/internal/STATUS_UPDATE.md

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-120}"
KEEP_UP="${KEEP_UP:-0}"
FN_ADMIN_TOKEN="${FN_ADMIN_TOKEN:-test-admin-token}"
TEST_SUFFIX="${TEST_SUFFIX:-$RANDOM$$}"
NATIVE_PORT="${NATIVE_PORT:-}"
BASE_URL=""
WORK_DIR="$(mktemp -d -t fastfn-openapi-native.XXXXXX)"
HELPER_PY="$ROOT_DIR/scripts/ci/fastfn_shell_helpers.py"

STACK_PID=""
STACK_LOG=""

pick_free_port() {
  python3 "$HELPER_PY" pick-free-port
}

kill_runtime_processes_from_log() {
  local log_file="$1"
  if [[ -z "$log_file" || ! -f "$log_file" ]]; then
    return 0
  fi

  local runtime_dir
  runtime_dir="$(grep -F 'Runtime extracted to:' "$log_file" | tail -n 1 | sed 's/.*Runtime extracted to: //')"
  if [[ -z "$runtime_dir" ]]; then
    return 0
  fi

  pkill -f "$runtime_dir/openresty" >/dev/null 2>&1 || true
  pkill -f "$runtime_dir/srv/fn/runtimes/python-daemon.py" >/dev/null 2>&1 || true
  pkill -f "$runtime_dir/srv/fn/runtimes/node-daemon.js" >/dev/null 2>&1 || true
  pkill -f "$runtime_dir/srv/fn/runtimes/rust-daemon.py" >/dev/null 2>&1 || true
  pkill -f "$runtime_dir/srv/fn/runtimes/php-daemon.php" >/dev/null 2>&1 || true
  pkill -f "$runtime_dir/srv/fn/runtimes/php-worker.php" >/dev/null 2>&1 || true
  pkill -f "$runtime_dir/srv/fn/runtimes/go-daemon.py" >/dev/null 2>&1 || true
}

cleanup() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  kill_runtime_processes_from_log "$STACK_LOG"
  if [[ "$KEEP_UP" != "1" ]]; then
    (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  fi
  rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "refs:"
echo "  related-test: tests/integration/test-openapi-system.sh"
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

require_native_prereqs_or_skip() {
  local missing=()

  if ! command -v openresty >/dev/null 2>&1; then
    missing+=("openresty")
  fi
  if ! command -v node >/dev/null 2>&1; then
    missing+=("node")
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    if [[ "${FN_REQUIRE_NATIVE_DEPS:-0}" == "1" || "${CI:-}" == "true" ]]; then
      echo "FAIL test-openapi-native.sh (missing native deps: ${missing[*]})"
      exit 1
    fi
    echo "SKIP test-openapi-native.sh (missing native deps: ${missing[*]})"
    exit 0
  fi
}

wait_for_health() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    if [[ -n "$STACK_PID" ]] && ! kill -0 "$STACK_PID" >/dev/null 2>&1; then
      echo "FAIL native fastfn exited before health became ready"
      [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 200 "$STACK_LOG" || true
      exit 1
    fi

    local code
    code="$(curl -sS -o /tmp/fastfn-openapi-native-health.out -w '%{http_code}' "${BASE_URL}/_fn/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      if python3 "$HELPER_PY" health-runtime-up --file /tmp/fastfn-openapi-native-health.out --runtime node >/dev/null 2>&1
      then
        ready=1
        break
      fi
    fi
    sleep 1
  done

  if [[ "$ready" != "1" ]]; then
    echo "FAIL native health did not become ready"
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
    exit 1
  fi
}

start_native() {
  local target_dir="$1"
  shift

  STACK_LOG="$(mktemp -t fastfn-openapi-native.XXXXXX.log)"
  if [[ "$#" -gt 0 ]]; then
    (
      cd "$ROOT_DIR"
      exec env \
        FN_ADMIN_TOKEN="$FN_ADMIN_TOKEN" \
        FN_UI_ENABLED=0 \
        FN_CONSOLE_WRITE_ENABLED=0 \
        FN_CONSOLE_RATE_LIMIT_MAX=1000 \
        FN_CONSOLE_WRITE_RATE_LIMIT_MAX=1000 \
        FN_OPENAPI_INCLUDE_INTERNAL=0 \
        FN_HOST_PORT="$NATIVE_PORT" \
        "$@" \
        ./bin/fastfn dev --native "$target_dir" >"$STACK_LOG" 2>&1
    ) &
  else
    (
      cd "$ROOT_DIR"
      exec env \
        FN_ADMIN_TOKEN="$FN_ADMIN_TOKEN" \
        FN_UI_ENABLED=0 \
        FN_CONSOLE_WRITE_ENABLED=0 \
        FN_CONSOLE_RATE_LIMIT_MAX=1000 \
        FN_CONSOLE_WRITE_RATE_LIMIT_MAX=1000 \
        FN_OPENAPI_INCLUDE_INTERNAL=0 \
        FN_HOST_PORT="$NATIVE_PORT" \
        ./bin/fastfn dev --native "$target_dir" >"$STACK_LOG" 2>&1
    ) &
  fi
  STACK_PID="$!"

  wait_for_health
}

start_native_with_config() {
  local config_path="$1"

  STACK_LOG="$(mktemp -t fastfn-openapi-native.XXXXXX.log)"
  (
    cd "$ROOT_DIR"
    exec env -u FN_OPENAPI_INCLUDE_INTERNAL \
      FN_ADMIN_TOKEN="$FN_ADMIN_TOKEN" \
      FN_UI_ENABLED=0 \
      FN_CONSOLE_WRITE_ENABLED=0 \
      FN_CONSOLE_RATE_LIMIT_MAX=1000 \
      FN_CONSOLE_WRITE_RATE_LIMIT_MAX=1000 \
      FN_HOST_PORT="$NATIVE_PORT" \
      ./bin/fastfn --config "$config_path" dev --native >"$STACK_LOG" 2>&1
  ) &
  STACK_PID="$!"

  wait_for_health
}

stop_native() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  kill_runtime_processes_from_log "$STACK_LOG"
  STACK_PID=""
}

assert_config_files_hidden() {
  local code
  code="$(curl -sS -o /tmp/fastfn-openapi-native-fastfn-json.out -w '%{http_code}' "${BASE_URL}/fastfn.json")"
  if [[ "$code" != "404" ]]; then
    echo "FAIL GET /fastfn.json expected=404 got=$code"
    cat /tmp/fastfn-openapi-native-fastfn-json.out || true
    exit 1
  fi

  code="$(curl -sS -o /tmp/fastfn-openapi-native-fastfn-toml.out -w '%{http_code}' "${BASE_URL}/fastfn.toml")"
  if [[ "$code" != "404" ]]; then
    echo "FAIL GET /fastfn.toml expected=404 got=$code"
    cat /tmp/fastfn-openapi-native-fastfn-toml.out || true
    exit 1
  fi
}

assert_home_quick_invoke_is_live_openapi_based() {
  local home_html='/tmp/openapi-native-home.out'
  curl -sS "${BASE_URL}/" >"$home_html"

  if grep -q "Current demos (forms, polyglot SQLite, JSON, HTML/CSV/PNG, QR, WhatsApp, Gmail, Telegram)." "$home_html"; then
    echo "FAIL native home quick invoke still shows stale static demo list"
    exit 1
  fi

  if ! grep -q "Loading live routes from OpenAPI" "$home_html"; then
    echo "FAIL native home quick invoke missing live OpenAPI summary"
    exit 1
  fi
}

assert_openapi_default_functions_only_admin_functional() {
  local openapi_json catalog_json
  openapi_json="$(curl -sS "${BASE_URL}/_fn/openapi.json")"
  catalog_json="$(curl -sS "${BASE_URL}/_fn/catalog")"

  python3 "$HELPER_PY" openapi-native-default-admin --openapi-json "$openapi_json" --catalog-json "$catalog_json"

  local health_code catalog_code
  health_code="$(curl -sS -o /tmp/fastfn-openapi-native-health-code.out -w '%{http_code}' "${BASE_URL}/_fn/health")"
  catalog_code="$(curl -sS -o /tmp/fastfn-openapi-native-catalog-code.out -w '%{http_code}' "${BASE_URL}/_fn/catalog")"
  if [[ "$health_code" != "200" ]]; then
    echo "FAIL /_fn/health should stay functional in native while hidden from OpenAPI"
    cat /tmp/fastfn-openapi-native-health-code.out || true
    exit 1
  fi
  if [[ "$catalog_code" != "200" ]]; then
    echo "FAIL /_fn/catalog should stay functional in native while hidden from OpenAPI"
    cat /tmp/fastfn-openapi-native-catalog-code.out || true
    exit 1
  fi
}

assert_native_ad_hoc_allow_hosts() {
  local fn_name route_base openapi_route
  fn_name="native_openapi_probe_${TEST_SUFFIX}"
  route_base="/native-openapi-${TEST_SUFFIX}/:id"
  openapi_route="/native-openapi-${TEST_SUFFIX}/{id}"

  local create_code cfg_code code_code reload_code allowed_code denied_code delete_code

  create_code="$(curl -sS -o /tmp/fastfn-openapi-native-create.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"Native OpenAPI probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create native ad-hoc function expected=201 got=$create_code"
    cat /tmp/fastfn-openapi-native-create.out || true
    exit 1
  fi

  cfg_code="$(curl -sS -o /tmp/fastfn-openapi-native-cfg.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-config?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"${route_base}\"],\"allow_hosts\":[\"native.allowed.test\"]}}")"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure native ad-hoc function expected=200 got=$cfg_code"
    cat /tmp/fastfn-openapi-native-cfg.out || true
    exit 1
  fi

  code_code="$(curl -sS -o /tmp/fastfn-openapi-native-code.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-code?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async (event) => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ ok: true, id: (event.path_params || {}).id || null }) });\n"}')"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write native ad-hoc function code expected=200 got=$code_code"
    cat /tmp/fastfn-openapi-native-code.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/fastfn-openapi-native-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL native reload expected=200 got=$reload_code"
    cat /tmp/fastfn-openapi-native-reload.out || true
    exit 1
  fi

  allowed_code="$(curl -sS -o /tmp/fastfn-openapi-native-allowed.out -w '%{http_code}' \
    -H 'Host: native.allowed.test' \
    "${BASE_URL}/native-openapi-${TEST_SUFFIX}/42")"
  if [[ "$allowed_code" != "200" ]]; then
    echo "FAIL native allow_hosts allowed request expected=200 got=$allowed_code"
    cat /tmp/fastfn-openapi-native-allowed.out || true
    exit 1
  fi
  if ! grep -q '"ok":true' /tmp/fastfn-openapi-native-allowed.out; then
    echo "FAIL native allow_hosts allowed response body mismatch"
    cat /tmp/fastfn-openapi-native-allowed.out || true
    exit 1
  fi

  denied_code="$(curl -sS -o /tmp/fastfn-openapi-native-denied.out -w '%{http_code}' \
    -H 'Host: denied-native.test' \
    "${BASE_URL}/native-openapi-${TEST_SUFFIX}/42")"
  if [[ "$denied_code" != "421" ]]; then
    echo "FAIL native allow_hosts denied request expected=421 got=$denied_code"
    cat /tmp/fastfn-openapi-native-denied.out || true
    exit 1
  fi
  if ! grep -q '"error":"host not allowed"' /tmp/fastfn-openapi-native-denied.out; then
    echo "FAIL native allow_hosts denied body missing error"
    cat /tmp/fastfn-openapi-native-denied.out || true
    exit 1
  fi

  local openapi_json
  openapi_json="$(curl -sS "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-route-present --json "$openapi_json" --route "$openapi_route" --method GET

  delete_code="$(curl -sS -o /tmp/fastfn-openapi-native-delete.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete native ad-hoc function expected=200 got=$delete_code"
    cat /tmp/fastfn-openapi-native-delete.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/fastfn-openapi-native-reload-delete.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL native reload after delete expected=200 got=$reload_code"
    cat /tmp/fastfn-openapi-native-reload-delete.out || true
    exit 1
  fi
}

native_has_go_runtime() {
  local health_json
  health_json="$(curl -sS "${BASE_URL}/_fn/health")"
  python3 "$HELPER_PY" health-runtime-up --json "$health_json" --runtime go
}

assert_native_go_runtime_ad_hoc() {
  local fn_name route openapi_route
  fn_name="native_go_probe_${TEST_SUFFIX}"
  route="/native-go-probe-${TEST_SUFFIX}"
  openapi_route="$route"

  local create_code cfg_code code_code reload_code delete_code ok_code denied_code
  local cfg_payload code_payload

  create_code="$(curl -sS -o /tmp/fastfn-openapi-native-go-create.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=go&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"Native Go runtime probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create native go ad-hoc function expected=201 got=$create_code"
    cat /tmp/fastfn-openapi-native-go-create.out || true
    exit 1
  fi

  cfg_payload="$(mktemp -t fastfn-openapi-native-go-cfg.XXXXXX.json)"
  cat >"$cfg_payload" <<JSON
{"invoke":{"methods":["GET"],"routes":["${route}"],"allow_hosts":["native-go.allowed.test"]}}
JSON
  cfg_code="$(curl -sS -o /tmp/fastfn-openapi-native-go-cfg.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-config?runtime=go&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data @"$cfg_payload")"
  rm -f "$cfg_payload"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure native go ad-hoc function expected=200 got=$cfg_code"
    cat /tmp/fastfn-openapi-native-go-cfg.out || true
    exit 1
  fi

  code_payload="$(mktemp -t fastfn-openapi-native-go-code.XXXXXX.json)"
  cat >"$code_payload" <<'JSON'
{"code":"package main\n\nimport \"encoding/json\"\n\nfunc handler(event map[string]interface{}) map[string]interface{} {\n  body, _ := json.Marshal(map[string]interface{}{\"ok\": true, \"runtime\": \"go\"})\n  return map[string]interface{}{\n    \"status\": 200,\n    \"headers\": map[string]interface{}{\"Content-Type\": \"application/json\"},\n    \"body\": string(body),\n  }\n}\n"}
JSON
  code_code="$(curl -sS -o /tmp/fastfn-openapi-native-go-code.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-code?runtime=go&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data @"$code_payload")"
  rm -f "$code_payload"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write native go ad-hoc code expected=200 got=$code_code"
    cat /tmp/fastfn-openapi-native-go-code.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/fastfn-openapi-native-go-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL native go reload expected=200 got=$reload_code"
    cat /tmp/fastfn-openapi-native-go-reload.out || true
    exit 1
  fi

  ok_code="$(curl -sS -o /tmp/fastfn-openapi-native-go-ok.out -w '%{http_code}' \
    -H 'Host: native-go.allowed.test' \
    "${BASE_URL}${route}")"
  if [[ "$ok_code" != "200" ]]; then
    echo "FAIL native go route expected=200 got=$ok_code"
    cat /tmp/fastfn-openapi-native-go-ok.out || true
    exit 1
  fi
  if ! grep -q '"runtime":"go"' /tmp/fastfn-openapi-native-go-ok.out; then
    echo "FAIL native go route body mismatch"
    cat /tmp/fastfn-openapi-native-go-ok.out || true
    exit 1
  fi

  denied_code="$(curl -sS -o /tmp/fastfn-openapi-native-go-denied.out -w '%{http_code}' \
    -H 'Host: denied-native-go.test' \
    "${BASE_URL}${route}")"
  if [[ "$denied_code" != "421" ]]; then
    echo "FAIL native go allow_hosts denied expected=421 got=$denied_code"
    cat /tmp/fastfn-openapi-native-go-denied.out || true
    exit 1
  fi
  if ! grep -q '"error":"host not allowed"' /tmp/fastfn-openapi-native-go-denied.out; then
    echo "FAIL native go allow_hosts denied body missing error"
    cat /tmp/fastfn-openapi-native-go-denied.out || true
    exit 1
  fi

  local openapi_json
  openapi_json="$(curl -sS "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-route-present --json "$openapi_json" --route "$openapi_route" --method GET

  delete_code="$(curl -sS -o /tmp/fastfn-openapi-native-go-delete.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=go&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete native go ad-hoc function expected=200 got=$delete_code"
    cat /tmp/fastfn-openapi-native-go-delete.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/fastfn-openapi-native-go-reload-delete.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL native go reload after delete expected=200 got=$reload_code"
    cat /tmp/fastfn-openapi-native-go-reload-delete.out || true
    exit 1
  fi
}

assert_native_lua_runtime_ad_hoc() {
  local fn_name route openapi_route
  fn_name="native_lua_probe_${TEST_SUFFIX}"
  route="/native-lua-probe-${TEST_SUFFIX}"
  openapi_route="$route"

  local create_code cfg_code code_code reload_code delete_code ok_code denied_code
  local cfg_payload code_payload

  create_code="$(curl -sS -o /tmp/fastfn-openapi-native-lua-create.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=lua&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"Native Lua runtime probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL native lua create expected=201 got=$create_code"
    cat /tmp/fastfn-openapi-native-lua-create.out || true
    exit 1
  fi

  cfg_payload="$(mktemp -t fastfn-openapi-native-lua-cfg.XXXXXX.json)"
  cat >"$cfg_payload" <<JSON
{"invoke":{"methods":["GET"],"routes":["${route}"],"allow_hosts":["lua.native.allowed.test"]}}
JSON
  cfg_code="$(curl -sS -o /tmp/fastfn-openapi-native-lua-cfg.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-config?runtime=lua&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data @"$cfg_payload")"
  rm -f "$cfg_payload"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL native lua config expected=200 got=$cfg_code"
    cat /tmp/fastfn-openapi-native-lua-cfg.out || true
    exit 1
  fi

  code_payload="$(mktemp -t fastfn-openapi-native-lua-code.XXXXXX.json)"
  cat >"$code_payload" <<'JSON'
{"code":"local cjson = require(\"cjson.safe\")\nfunction handler(event)\n  return {\n    status = 200,\n    headers = { [\"Content-Type\"] = \"application/json\" },\n    body = cjson.encode({ ok = true, runtime = \"lua\" }),\n  }\nend\n"}
JSON
  code_code="$(curl -sS -o /tmp/fastfn-openapi-native-lua-code.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-code?runtime=lua&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data @"$code_payload")"
  rm -f "$code_payload"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL native lua code expected=200 got=$code_code"
    cat /tmp/fastfn-openapi-native-lua-code.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/fastfn-openapi-native-lua-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL native lua reload expected=200 got=$reload_code"
    cat /tmp/fastfn-openapi-native-lua-reload.out || true
    exit 1
  fi

  ok_code="$(curl -sS -o /tmp/fastfn-openapi-native-lua-ok.out -w '%{http_code}' \
    -H 'Host: lua.native.allowed.test' \
    "${BASE_URL}${route}")"
  if [[ "$ok_code" != "200" ]]; then
    echo "FAIL native lua route expected=200 got=$ok_code"
    cat /tmp/fastfn-openapi-native-lua-ok.out || true
    exit 1
  fi
  if ! grep -q '"runtime":"lua"' /tmp/fastfn-openapi-native-lua-ok.out; then
    echo "FAIL native lua response body mismatch"
    cat /tmp/fastfn-openapi-native-lua-ok.out || true
    exit 1
  fi

  denied_code="$(curl -sS -o /tmp/fastfn-openapi-native-lua-denied.out -w '%{http_code}' \
    -H 'Host: denied.native.test' \
    "${BASE_URL}${route}")"
  if [[ "$denied_code" != "421" ]]; then
    echo "FAIL native lua allow_hosts deny expected=421 got=$denied_code"
    cat /tmp/fastfn-openapi-native-lua-denied.out || true
    exit 1
  fi

  local openapi_json
  openapi_json="$(curl -sS "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-route-present --json "$openapi_json" --route "$openapi_route" --method GET

  delete_code="$(curl -sS -o /tmp/fastfn-openapi-native-lua-delete.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=lua&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL native lua delete expected=200 got=$delete_code"
    cat /tmp/fastfn-openapi-native-lua-delete.out || true
    exit 1
  fi

  reload_code="$(curl -sS -o /tmp/fastfn-openapi-native-lua-reload-delete.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL native lua reload after delete expected=200 got=$reload_code"
    cat /tmp/fastfn-openapi-native-lua-reload-delete.out || true
    exit 1
  fi
}

assert_openapi_internal_opt_in_native() {
  local openapi_json
  openapi_json="$(curl -sS "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-internal-paths-present --openapi-json "$openapi_json"
}

assert_experimental_runtimes_off_by_default_native() {
  local health_json
  health_json="$(curl -sS "${BASE_URL}/_fn/health")"
  python3 "$HELPER_PY" health-missing-runtimes --json "$health_json" rust go
}

require_native_prereqs_or_skip
assert_no_wizard_temp_artifacts

if [[ -z "$NATIVE_PORT" ]]; then
  NATIVE_PORT="$(pick_free_port)"
fi
BASE_URL="http://127.0.0.1:${NATIVE_PORT}"

if [[ ! -x "$ROOT_DIR/bin/fastfn" ]]; then
  "$ROOT_DIR/cli/build.sh"
fi

cp -R "$ROOT_DIR/tests/fixtures/nextstyle-clean/." "$WORK_DIR"/

echo "== openapi native default (functions-only + admin functional) =="
start_native "$WORK_DIR"
assert_experimental_runtimes_off_by_default_native
assert_config_files_hidden
assert_home_quick_invoke_is_live_openapi_based
assert_openapi_default_functions_only_admin_functional
assert_native_ad_hoc_allow_hosts
stop_native

echo "== openapi native go runtime opt-in =="
NATIVE_PORT="$(pick_free_port)"
BASE_URL="http://127.0.0.1:${NATIVE_PORT}"
start_native "$WORK_DIR" "FN_RUNTIMES=python,node,php,go"
if native_has_go_runtime; then
  assert_native_go_runtime_ad_hoc
else
  echo "SKIP native go ad-hoc check (go runtime unavailable)"
fi
stop_native

echo "== openapi native lua runtime in-process =="
NATIVE_PORT="$(pick_free_port)"
BASE_URL="http://127.0.0.1:${NATIVE_PORT}"
start_native "$WORK_DIR" "FN_RUNTIMES=python,node,php,lua"
assert_native_lua_runtime_ad_hoc
stop_native

echo "== openapi native opt-in internal =="
NATIVE_PORT="$(pick_free_port)"
BASE_URL="http://127.0.0.1:${NATIVE_PORT}"
start_native "$WORK_DIR" "FN_OPENAPI_INCLUDE_INTERNAL=1"
assert_openapi_internal_opt_in_native
stop_native

echo "== openapi native opt-in internal (config toggle) =="
NATIVE_PORT="$(pick_free_port)"
BASE_URL="http://127.0.0.1:${NATIVE_PORT}"
CONFIG_INCLUDE_INTERNAL="$WORK_DIR/fastfn-openapi-config.json"
cat >"$CONFIG_INCLUDE_INTERNAL" <<JSON
{
  "functions-dir": "$WORK_DIR",
  "openapi-include-internal": true
}
JSON
start_native_with_config "$CONFIG_INCLUDE_INTERNAL"
assert_openapi_internal_opt_in_native
stop_native

echo "PASS test-openapi-native.sh"
