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

TEST_HOST="${TEST_HOST:-127.0.0.1}"
TEST_PORT="${TEST_PORT:-${FN_HOST_PORT:-8080}}"
BASE_URL="${BASE_URL:-http://${TEST_HOST}:${TEST_PORT}}"
BASE_HOSTPORT="${BASE_HOSTPORT:-${TEST_HOST}:${TEST_PORT}}"
CURL_CONNECT_TIMEOUT_SECS="${CURL_CONNECT_TIMEOUT_SECS:-2}"
CURL_MAX_TIME_SECS="${CURL_MAX_TIME_SECS:-30}"

export FN_HOST_PORT="${FN_HOST_PORT:-$TEST_PORT}"
export FASTFN_TEST_BASE_URL="$BASE_URL"
HELPER_PY="$ROOT_DIR/scripts/ci/fastfn_shell_helpers.py"

curl_fastfn() {
  curl --connect-timeout "$CURL_CONNECT_TIMEOUT_SECS" --max-time "$CURL_MAX_TIME_SECS" "$@"
}

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
    code="$(curl_fastfn -sS -o /tmp/fastfn-openapi-system-health.out -w '%{http_code}' "${BASE_URL}/_fn/health" 2>/dev/null || true)"
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

assert_container_runs_as_host_user() {
  local host_uid host_gid
  host_uid="$(id -u)"
  host_gid="$(id -g)"

  local c_uid c_gid
  c_uid="$(cd "$ROOT_DIR" && COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" docker compose exec -T openresty sh -lc 'id -u' 2>/dev/null | tr -d '\r' || true)"
  c_gid="$(cd "$ROOT_DIR" && COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" docker compose exec -T openresty sh -lc 'id -g' 2>/dev/null | tr -d '\r' || true)"

  if [[ -z "$c_uid" || -z "$c_gid" ]]; then
    echo "FAIL could not determine container uid/gid"
    exit 1
  fi

  if [[ "$c_uid" != "$host_uid" || "$c_gid" != "$host_gid" ]]; then
    echo "FAIL container must run as host uid:gid for bind-mount permissions (regression guard)"
    echo "  host uid:gid=$host_uid:$host_gid"
    echo "  container uid:gid=$c_uid:$c_gid"
    exit 1
  fi
}

wait_for_runtime_up() {
  local runtime="$1"
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    local health_json
    health_json="$(curl_fastfn -sS "${BASE_URL}/_fn/health" 2>/dev/null || true)"
    if python3 "$HELPER_PY" health-runtime-up --json "$health_json" --runtime "$runtime" >/dev/null 2>&1
    then
      ready=1
      break
    fi
    sleep 1
  done

  if [[ "$ready" != "1" ]]; then
    echo "FAIL runtime did not become healthy: $runtime"
    curl_fastfn -sS "${BASE_URL}/_fn/health" || true
    return 1
  fi
}

assert_experimental_runtimes_off_by_default() {
  local health_json
  health_json="$(curl_fastfn -sS "${BASE_URL}/_fn/health")"
  python3 "$HELPER_PY" health-missing-runtimes --json "$health_json" rust go
}

assert_no_wizard_temp_artifacts

start_stack() {
  local cmd
  (cd "$ROOT_DIR" && COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" docker compose down --remove-orphans >/dev/null 2>&1) || true

  STACK_LOG="$(mktemp -t fastfn-openapi-system.XXXXXX.log)"
  STACK_EXIT_FILE="$(mktemp -t fastfn-openapi-system.exit.XXXXXX)"
  cmd=(env COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" FN_ADMIN_TOKEN="$FN_ADMIN_TOKEN" FN_UI_ENABLED=0 FN_OPENAPI_INCLUDE_INTERNAL=0 FN_CONSOLE_RATE_LIMIT_MAX=1000 FN_CONSOLE_WRITE_RATE_LIMIT_MAX=1000)
  if [[ "$#" -gt 0 ]]; then
    cmd+=("$@")
  fi
  cmd+=(./bin/fastfn dev --build "$FIXTURES_DIR")
  (
    cd "$ROOT_DIR"
    "${cmd[@]}" >"$STACK_LOG" 2>&1
    echo "$?" >"$STACK_EXIT_FILE"
  ) &
  STACK_PID="$!"
  wait_for_health
  assert_container_runs_as_host_user
}

start_stack_with_config() {
  local config_path="$1"
  shift || true

  local cmd
  (cd "$ROOT_DIR" && COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" docker compose down --remove-orphans >/dev/null 2>&1) || true

  STACK_LOG="$(mktemp -t fastfn-openapi-system.XXXXXX.log)"
  STACK_EXIT_FILE="$(mktemp -t fastfn-openapi-system.exit.XXXXXX)"
  cmd=(env -u FN_OPENAPI_INCLUDE_INTERNAL COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" FN_ADMIN_TOKEN="$FN_ADMIN_TOKEN" FN_UI_ENABLED=0 FN_CONSOLE_RATE_LIMIT_MAX=1000 FN_CONSOLE_WRITE_RATE_LIMIT_MAX=1000)
  if [[ "$#" -gt 0 ]]; then
    cmd+=("$@")
  fi
  cmd+=(./bin/fastfn --config "$config_path" dev --build)
  (
    cd "$ROOT_DIR"
    "${cmd[@]}" >"$STACK_LOG" 2>&1
    echo "$?" >"$STACK_EXIT_FILE"
  ) &
  STACK_PID="$!"
  wait_for_health
  assert_container_runs_as_host_user
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
  code="$(curl_fastfn -sS -o /tmp/fastfn-openapi-fastfn-json.out -w '%{http_code}' "${BASE_URL}/fastfn.json")"
  if [[ "$code" != "404" ]]; then
    echo "FAIL GET /fastfn.json expected=404 got=$code"
    cat /tmp/fastfn-openapi-fastfn-json.out || true
    exit 1
  fi

  code="$(curl_fastfn -sS -o /tmp/fastfn-openapi-fastfn-toml.out -w '%{http_code}' "${BASE_URL}/fastfn.toml")"
  if [[ "$code" != "404" ]]; then
    echo "FAIL GET /fastfn.toml expected=404 got=$code"
    cat /tmp/fastfn-openapi-fastfn-toml.out || true
    exit 1
  fi
}

assert_home_quick_invoke_is_live_openapi_based() {
  local home_html='/tmp/openapi-system-home.out'
  curl_fastfn -sS "${BASE_URL}/" >"$home_html"

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
  openapi_json="$(curl_fastfn -sS "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-functions-default-admin --openapi-json "$openapi_json" --require-path /users

  local health_code catalog_code
  health_code="$(curl_fastfn -sS -o /tmp/openapi-system-default-health.out -w '%{http_code}' "${BASE_URL}/_fn/health")"
  if [[ "$health_code" != "200" ]]; then
    echo "FAIL /_fn/health should stay functional while hidden from OpenAPI"
    cat /tmp/openapi-system-default-health.out || true
    exit 1
  fi

  catalog_code="$(curl_fastfn -sS -o /tmp/openapi-system-default-catalog.out -w '%{http_code}' "${BASE_URL}/_fn/catalog")"
  if [[ "$catalog_code" != "200" ]]; then
    echo "FAIL /_fn/catalog should stay functional while hidden from OpenAPI"
    cat /tmp/openapi-system-default-catalog.out || true
    exit 1
  fi
}

assert_openapi_internal_contract() {
  local openapi_json
  local catalog_json
  openapi_json="$(curl_fastfn -sS "${BASE_URL}/_fn/openapi.json")"
  catalog_json="$(curl_fastfn -sS "${BASE_URL}/_fn/catalog")"
  python3 "$HELPER_PY" openapi-internal-contract --openapi-json "$openapi_json" --catalog-json "$catalog_json"
}

assert_ad_hoc_route_exported() {
  local fn_name route_base route_catchall openapi_route openapi_catchall
  fn_name="openapi_probe_${TEST_SUFFIX}"
  route_base="/openapi-probe-${TEST_SUFFIX}/:id"
  route_catchall="/openapi-probe-${TEST_SUFFIX}/:id/*"
  openapi_route="/openapi-probe-${TEST_SUFFIX}/{id}"
  openapi_catchall="/openapi-probe-${TEST_SUFFIX}/{id}/{wildcard}"

  local create_code cfg_code code_code reload_code delete_code probe_get_code probe_post_code

  create_code="$(curl_fastfn -sS -o /tmp/openapi-system-create.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"OpenAPI ad-hoc probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create ad-hoc function expected=201 got=$create_code"
    cat /tmp/openapi-system-create.out || true
    exit 1
  fi

  cfg_code="$(curl_fastfn -sS -o /tmp/openapi-system-cfg.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-config?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"invoke\":{\"methods\":[\"GET\",\"POST\"],\"routes\":[\"${route_base}\",\"${route_catchall}\"],\"allow_hosts\":[\"api.allowed.test\"]}}")"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure ad-hoc function expected=200 got=$cfg_code"
    cat /tmp/openapi-system-cfg.out || true
    exit 1
  fi

  code_code="$(curl_fastfn -sS -o /tmp/openapi-system-code.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-code?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async (event) => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ ok: true, params: event.path_params || {} }) });\n"}')"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write ad-hoc function code expected=200 got=$code_code"
    cat /tmp/openapi-system-code.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload expected=200 got=$reload_code"
    cat /tmp/openapi-system-reload.out || true
    exit 1
  fi
  # Ensure the target runtime is actually healthy before probing the new route.
  wait_for_runtime_up "node"

  probe_get_code="$(curl_fastfn -sS -o /tmp/openapi-system-probe-get.out -w '%{http_code}' \
    -H 'Host: api.allowed.test' \
    "${BASE_URL}/openapi-probe-${TEST_SUFFIX}/42")"
  if [[ "$probe_get_code" != "200" ]]; then
    echo "FAIL ad-hoc probe GET expected=200 got=$probe_get_code"
    cat /tmp/openapi-system-probe-get.out || true
    exit 1
  fi

  probe_post_code="$(curl_fastfn -sS -o /tmp/openapi-system-probe-post.out -w '%{http_code}' -X POST \
    -H 'Host: api.allowed.test' \
    "${BASE_URL}/openapi-probe-${TEST_SUFFIX}/42/extra/segments" \
    -H 'Content-Type: application/json' \
    --data '{"probe":true}')"
  if [[ "$probe_post_code" != "200" ]]; then
    echo "FAIL ad-hoc probe POST expected=200 got=$probe_post_code"
    cat /tmp/openapi-system-probe-post.out || true
    exit 1
  fi

  local probe_blocked_code
  probe_blocked_code="$(curl_fastfn -sS -o /tmp/openapi-system-probe-blocked.out -w '%{http_code}' \
    -H 'Host: denied.test' \
    "${BASE_URL}/openapi-probe-${TEST_SUFFIX}/42")"
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
  openapi_json="$(curl_fastfn -sS "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-route-present --json "$openapi_json" --route "$openapi_route" --method GET
  python3 "$HELPER_PY" openapi-route-present --json "$openapi_json" --route "$openapi_route" --method POST
  python3 "$HELPER_PY" openapi-route-param --json "$openapi_json" --route "$openapi_route" --method GET --name id
  python3 "$HELPER_PY" openapi-route-present --json "$openapi_json" --route "$openapi_catchall" --method GET
  python3 "$HELPER_PY" openapi-route-present --json "$openapi_json" --route "$openapi_catchall" --method POST

  delete_code="$(curl_fastfn -sS -o /tmp/openapi-system-delete.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete ad-hoc function expected=200 got=$delete_code"
    cat /tmp/openapi-system-delete.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-reload-delete.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after delete expected=200 got=$reload_code"
    cat /tmp/openapi-system-reload-delete.out || true
    exit 1
  fi

  openapi_json="$(curl_fastfn -sS "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-route-absent --json "$openapi_json" --route "$openapi_route"
  python3 "$HELPER_PY" openapi-route-absent --json "$openapi_json" --route "$openapi_catchall"
}

assert_edge-proxy_denies_control_plane_paths() {
  local fn_name route
  fn_name="edge_ssrf_${TEST_SUFFIX}"
  route="/edge-ssrf-${TEST_SUFFIX}"

  local create_code cfg_code code_code reload_code call_code delete_code

  create_code="$(curl_fastfn -sS -o /tmp/openapi-system-edge-ssrf-create.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"Edge SSRF control-plane probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create edge ssrf function expected=201 got=$create_code"
    cat /tmp/openapi-system-edge-ssrf-create.out || true
    exit 1
  fi

  cfg_code="$(curl_fastfn -sS -o /tmp/openapi-system-edge-ssrf-cfg.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-config?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"${route}\"]},\"edge\":{\"base_url\":\"${BASE_URL}\",\"allow_hosts\":[\"${BASE_HOSTPORT}\"],\"allow_private\":true}}")"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure edge ssrf function expected=200 got=$cfg_code"
    cat /tmp/openapi-system-edge-ssrf-cfg.out || true
    exit 1
  fi

  code_code="$(curl_fastfn -sS -o /tmp/openapi-system-edge-ssrf-code.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-code?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async () => ({ proxy: { path: \"/_fn/health\", method: \"GET\", headers: { \"x-edge\": \"1\" } } });\n"}')"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write edge ssrf function code expected=200 got=$code_code"
    cat /tmp/openapi-system-edge-ssrf-code.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-edge-ssrf-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after edge ssrf update expected=200 got=$reload_code"
    cat /tmp/openapi-system-edge-ssrf-reload.out || true
    exit 1
  fi

  call_code="$(curl_fastfn -sS -o /tmp/openapi-system-edge-ssrf-call.out -w '%{http_code}' \
    "${BASE_URL}${route}")"
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

  delete_code="$(curl_fastfn -sS -o /tmp/openapi-system-edge-ssrf-delete.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete edge ssrf function expected=200 got=$delete_code"
    cat /tmp/openapi-system-edge-ssrf-delete.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-edge-ssrf-reload-delete.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
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

  create_code="$(curl_fastfn -sS -o /tmp/openapi-system-force-url-create.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"force-url policy override probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create force-url function expected=201 got=$create_code"
    cat /tmp/openapi-system-force-url-create.out || true
    exit 1
  fi

  cfg_code="$(curl_fastfn -sS -o /tmp/openapi-system-force-url-cfg.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-config?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"${route}\"]}}")"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure force-url function expected=200 got=$cfg_code"
    cat /tmp/openapi-system-force-url-cfg.out || true
    exit 1
  fi

  code_code="$(curl_fastfn -sS -o /tmp/openapi-system-force-url-code.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-code?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async () => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ ok: true, source: \"policy\" }) });\n"}')"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write force-url function code expected=200 got=$code_code"
    cat /tmp/openapi-system-force-url-code.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-force-url-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after force-url update expected=200 got=$reload_code"
    cat /tmp/openapi-system-force-url-reload.out || true
    exit 1
  fi

  call_code="$(curl_fastfn -sS -o /tmp/openapi-system-force-url-call.out -w '%{http_code}' \
    "${BASE_URL}${route}")"
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

  delete_code="$(curl_fastfn -sS -o /tmp/openapi-system-force-url-delete.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete force-url function expected=200 got=$delete_code"
    cat /tmp/openapi-system-force-url-delete.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-force-url-reload-delete.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
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

  create_code="$(curl_fastfn -sS -o /tmp/openapi-system-go-create.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=go&name=${fn_name}" \
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
  cfg_code="$(curl_fastfn -sS -o /tmp/openapi-system-go-cfg.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-config?runtime=go&name=${fn_name}" \
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
  code_code="$(curl_fastfn -sS -o /tmp/openapi-system-go-code.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-code?runtime=go&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data @"$code_payload")"
  rm -f "$code_payload"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write go ad-hoc function code expected=200 got=$code_code"
    cat /tmp/openapi-system-go-code.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-go-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after go update expected=200 got=$reload_code"
    cat /tmp/openapi-system-go-reload.out || true
    exit 1
  fi

  ok_code="$(curl_fastfn -sS -o /tmp/openapi-system-go-ok.out -w '%{http_code}' \
    -H 'Host: go.allowed.test' \
    "${BASE_URL}${route}")"
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

  denied_code="$(curl_fastfn -sS -o /tmp/openapi-system-go-denied.out -w '%{http_code}' \
    -H 'Host: denied-go.test' \
    "${BASE_URL}${route}")"
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
  openapi_json="$(curl_fastfn -sS "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-route-present --json "$openapi_json" --route "$openapi_route" --method GET

  delete_code="$(curl_fastfn -sS -o /tmp/openapi-system-go-delete.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=go&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete go ad-hoc function expected=200 got=$delete_code"
    cat /tmp/openapi-system-go-delete.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-go-reload-delete.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
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

  create_code="$(curl_fastfn -sS -o /tmp/openapi-system-lua-create.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=lua&name=${fn_name}" \
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
  cfg_code="$(curl_fastfn -sS -o /tmp/openapi-system-lua-cfg.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-config?runtime=lua&name=${fn_name}" \
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
  code_code="$(curl_fastfn -sS -o /tmp/openapi-system-lua-code.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-code?runtime=lua&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data @"$code_payload")"
  rm -f "$code_payload"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write lua ad-hoc function code expected=200 got=$code_code"
    cat /tmp/openapi-system-lua-code.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-lua-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after lua update expected=200 got=$reload_code"
    cat /tmp/openapi-system-lua-reload.out || true
    exit 1
  fi

  ok_code="$(curl_fastfn -sS -o /tmp/openapi-system-lua-ok.out -w '%{http_code}' \
    -H 'Host: lua.allowed.test' \
    "${BASE_URL}${route}")"
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

  denied_code="$(curl_fastfn -sS -o /tmp/openapi-system-lua-denied.out -w '%{http_code}' \
    -H 'Host: denied-lua.test' \
    "${BASE_URL}${route}")"
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
  openapi_json="$(curl_fastfn -sS "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-route-present --json "$openapi_json" --route "$openapi_route" --method GET

  delete_code="$(curl_fastfn -sS -o /tmp/openapi-system-lua-delete.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=lua&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete lua ad-hoc function expected=200 got=$delete_code"
    cat /tmp/openapi-system-lua-delete.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-lua-reload-delete.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
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

  create_code="$(curl_fastfn -sS -o /tmp/openapi-system-shared-create.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"Node shared_deps pack probe"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create node shared_deps function expected=201 got=$create_code"
    cat /tmp/openapi-system-shared-create.out || true
    exit 1
  fi

  cfg_code="$(curl_fastfn -sS -o /tmp/openapi-system-shared-cfg.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-config?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"shared_deps\":[\"${pack_name}\"],\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"${route}\"]}}")"
  if [[ "$cfg_code" != "200" ]]; then
    echo "FAIL configure shared_deps function expected=200 got=$cfg_code"
    cat /tmp/openapi-system-shared-cfg.out || true
    exit 1
  fi

  code_code="$(curl_fastfn -sS -o /tmp/openapi-system-shared-code.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-code?runtime=node&name=${fn_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"code\":\"exports.handler = async () => { const fromPack = require('${pack_name}'); return { status: 200, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(fromPack()) }; };\\n\"}")"
  if [[ "$code_code" != "200" ]]; then
    echo "FAIL write shared_deps function code expected=200 got=$code_code"
    cat /tmp/openapi-system-shared-code.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-shared-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after shared_deps update expected=200 got=$reload_code"
    cat /tmp/openapi-system-shared-reload.out || true
    exit 1
  fi

  invoke_code="$(curl_fastfn -sS -o /tmp/openapi-system-shared-invoke.out -w '%{http_code}' \
    "${BASE_URL}${route}")"
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

  delete_code="$(curl_fastfn -sS -o /tmp/openapi-system-shared-delete.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_name}" \
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

  create_a_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-create-a.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_alpha}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"Virtual host alpha"}')"
  if [[ "$create_a_code" != "201" ]]; then
    echo "FAIL create vhost_alpha expected=201 got=$create_a_code"
    cat /tmp/openapi-system-vhost-create-a.out || true
    exit 1
  fi

  create_b_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-create-b.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_beta}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"methods":["GET"],"summary":"Virtual host beta"}')"
  if [[ "$create_b_code" != "201" ]]; then
    echo "FAIL create vhost_beta expected=201 got=$create_b_code"
    cat /tmp/openapi-system-vhost-create-b.out || true
    exit 1
  fi

  cfg_a_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-cfg-a.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-config?runtime=node&name=${fn_alpha}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"${shared_route}\"],\"allow_hosts\":[\"alpha.example.test\"]}}")"
  if [[ "$cfg_a_code" != "200" ]]; then
    echo "FAIL configure vhost_alpha expected=200 got=$cfg_a_code"
    cat /tmp/openapi-system-vhost-cfg-a.out || true
    exit 1
  fi

  cfg_b_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-cfg-b.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-config?runtime=node&name=${fn_beta}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"invoke\":{\"methods\":[\"GET\"],\"routes\":[\"${shared_route}\"],\"allow_hosts\":[\"beta.example.test\"]}}")"
  if [[ "$cfg_b_code" != "200" ]]; then
    echo "FAIL configure vhost_beta expected=200 got=$cfg_b_code"
    cat /tmp/openapi-system-vhost-cfg-b.out || true
    exit 1
  fi

  code_a_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-code-a.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-code?runtime=node&name=${fn_alpha}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async () => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ tenant: \"alpha\" }) });\n"}')"
  if [[ "$code_a_code" != "200" ]]; then
    echo "FAIL code vhost_alpha expected=200 got=$code_a_code"
    cat /tmp/openapi-system-vhost-code-a.out || true
    exit 1
  fi

  code_b_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-code-b.out -w '%{http_code}' -X PUT \
    "${BASE_URL}/_fn/function-code?runtime=node&name=${fn_beta}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async () => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ tenant: \"beta\" }) });\n"}')"
  if [[ "$code_b_code" != "200" ]]; then
    echo "FAIL code vhost_beta expected=200 got=$code_b_code"
    cat /tmp/openapi-system-vhost-code-b.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload vhost expected=200 got=$reload_code"
    cat /tmp/openapi-system-vhost-reload.out || true
    exit 1
  fi

  local alpha_code
  alpha_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-alpha.out -w '%{http_code}' \
    -H 'Host: alpha.example.test' \
    "${BASE_URL}${shared_route}")"
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
  beta_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-beta.out -w '%{http_code}' \
    -H 'Host: beta.example.test' \
    "${BASE_URL}${shared_route}")"
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
  denied_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-denied.out -w '%{http_code}' \
    -H 'Host: denied.example.test' \
    "${BASE_URL}${shared_route}")"
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
  catalog_json="$(curl_fastfn -sS "${BASE_URL}/_fn/catalog")"
  python3 "$HELPER_PY" catalog-route-no-conflicts --json "$catalog_json" --route "$shared_route" --min-entries 2

  delete_a_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-delete-a.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_alpha}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_a_code" != "200" ]]; then
    echo "FAIL delete vhost_alpha expected=200 got=$delete_a_code"
    cat /tmp/openapi-system-vhost-delete-a.out || true
    exit 1
  fi

  delete_b_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-delete-b.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=node&name=${fn_beta}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_b_code" != "200" ]]; then
    echo "FAIL delete vhost_beta expected=200 got=$delete_b_code"
    cat /tmp/openapi-system-vhost-delete-b.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-vhost-reload-delete.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after vhost delete expected=200 got=$reload_code"
    cat /tmp/openapi-system-vhost-reload-delete.out || true
    exit 1
  fi
}

assert_openapi_server_url_resolution() {
  local openapi_json

  openapi_json="$(curl_fastfn -sS -H 'Host: api.local.test' "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-server-url --json "$openapi_json" --expected "http://api.local.test"

  openapi_json="$(curl_fastfn -sS \
    -H 'Host: ignored.local' \
    -H 'X-Forwarded-Proto: https' \
    -H 'X-Forwarded-Host: api.proxy.test' \
    "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-server-url --json "$openapi_json" --expected "https://api.proxy.test"
}

assert_openapi_server_url_override() {
  local openapi_json
  openapi_json="$(curl_fastfn -sS -H 'Host: random.local' "${BASE_URL}/_fn/openapi.json")"
  python3 "$HELPER_PY" openapi-server-url --json "$openapi_json" --expected "https://api.fastfn.example"
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
stop_stack

assert_namespaced_function_crud() {
  local ns_name ns_deep_name create_code reload_code get_code invoke_code delete_code

  # ---- 1-level namespace (team/hello) ----
  ns_name="team_${TEST_SUFFIX}/ns-hello"

  create_code="$(curl_fastfn -sS -o /tmp/openapi-system-ns-create.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=node&name=${ns_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async (event) => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ ns: true, name: \"ns-hello\" }) });\n"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create namespaced function expected=201 got=$create_code"
    cat /tmp/openapi-system-ns-create.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-ns-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after ns create expected=200 got=$reload_code"
    cat /tmp/openapi-system-ns-reload.out || true
    exit 1
  fi
  wait_for_runtime_up "node"

  # Verify the function is in catalog
  get_code="$(curl_fastfn -sS -o /tmp/openapi-system-ns-get.out -w '%{http_code}' \
    "${BASE_URL}/_fn/function?runtime=node&name=${ns_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$get_code" != "200" ]]; then
    echo "FAIL get namespaced function expected=200 got=$get_code"
    cat /tmp/openapi-system-ns-get.out || true
    exit 1
  fi

  # Verify the route preserves slashes: /team_<suffix>/ns-hello
  invoke_code="$(curl_fastfn -sS -o /tmp/openapi-system-ns-invoke.out -w '%{http_code}' \
    "${BASE_URL}/team-${TEST_SUFFIX}/ns-hello")"
  if [[ "$invoke_code" != "200" ]]; then
    echo "FAIL invoke namespaced function at slash route expected=200 got=$invoke_code"
    cat /tmp/openapi-system-ns-invoke.out || true
    exit 1
  fi
  if ! grep -q '"ns":true' /tmp/openapi-system-ns-invoke.out; then
    echo "FAIL invoke namespaced function response body mismatch"
    cat /tmp/openapi-system-ns-invoke.out || true
    exit 1
  fi

  # ---- 2-level namespace (api/v1/resource) ----
  ns_deep_name="api_${TEST_SUFFIX}/v1/resource"

  create_code="$(curl_fastfn -sS -o /tmp/openapi-system-nsdeep-create.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/function?runtime=node&name=${ns_deep_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"code":"exports.handler = async (event) => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ deep: true, path: \"api/v1/resource\" }) });\n"}')"
  if [[ "$create_code" != "201" ]]; then
    echo "FAIL create deep namespaced function expected=201 got=$create_code"
    cat /tmp/openapi-system-nsdeep-create.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-nsdeep-reload.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after deep ns create expected=200 got=$reload_code"
    cat /tmp/openapi-system-nsdeep-reload.out || true
    exit 1
  fi
  wait_for_runtime_up "node"

  # Verify the deep namespaced route preserves slashes: /api-<suffix>/v1/resource
  invoke_code="$(curl_fastfn -sS -o /tmp/openapi-system-nsdeep-invoke.out -w '%{http_code}' \
    "${BASE_URL}/api-${TEST_SUFFIX}/v1/resource")"
  if [[ "$invoke_code" != "200" ]]; then
    echo "FAIL invoke deep namespaced function at slash route expected=200 got=$invoke_code"
    cat /tmp/openapi-system-nsdeep-invoke.out || true
    exit 1
  fi
  if ! grep -q '"deep":true' /tmp/openapi-system-nsdeep-invoke.out; then
    echo "FAIL invoke deep namespaced function response body mismatch"
    cat /tmp/openapi-system-nsdeep-invoke.out || true
    exit 1
  fi

  # Verify catalog lists both
  local catalog_json
  catalog_json="$(curl_fastfn -sS "${BASE_URL}/_fn/catalog" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  python3 "$HELPER_PY" catalog-has-functions --json "$catalog_json" --runtime node "$ns_name" "$ns_deep_name"

  # Cleanup: delete both
  delete_code="$(curl_fastfn -sS -o /tmp/openapi-system-ns-delete.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=node&name=${ns_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete namespaced function expected=200 got=$delete_code"
    cat /tmp/openapi-system-ns-delete.out || true
    exit 1
  fi

  delete_code="$(curl_fastfn -sS -o /tmp/openapi-system-nsdeep-delete.out -w '%{http_code}' -X DELETE \
    "${BASE_URL}/_fn/function?runtime=node&name=${ns_deep_name}" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$delete_code" != "200" ]]; then
    echo "FAIL delete deep namespaced function expected=200 got=$delete_code"
    cat /tmp/openapi-system-nsdeep-delete.out || true
    exit 1
  fi

  reload_code="$(curl_fastfn -sS -o /tmp/openapi-system-ns-reload-final.out -w '%{http_code}' -X POST \
    "${BASE_URL}/_fn/reload" \
    -H "x-fn-admin-token: $FN_ADMIN_TOKEN")"
  if [[ "$reload_code" != "200" ]]; then
    echo "FAIL reload after ns cleanup expected=200 got=$reload_code"
    cat /tmp/openapi-system-ns-reload-final.out || true
    exit 1
  fi
}

echo "== namespaced function CRUD =="
start_stack
assert_namespaced_function_crud
stop_stack

echo "PASS test-openapi-system.sh"
