#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-240}"
KEEP_UP="${KEEP_UP:-0}"
KEEP_FIXTURE_ARTIFACTS="${KEEP_FIXTURE_ARTIFACTS:-0}"
RUNTIMES_WITH_RUST="${RUNTIMES_WITH_RUST:-python,node,php,rust}"

TEST_HOST="${TEST_HOST:-127.0.0.1}"
TEST_PORT="${TEST_PORT:-${FN_HOST_PORT:-8080}}"
BASE_URL="${BASE_URL:-http://${TEST_HOST}:${TEST_PORT}}"
CURL_CONNECT_TIMEOUT_SECS="${CURL_CONNECT_TIMEOUT_SECS:-2}"
CURL_MAX_TIME_SECS="${CURL_MAX_TIME_SECS:-30}"

export FASTFN_TEST_BASE_URL="$BASE_URL"
export FN_HOST_PORT="${FN_HOST_PORT:-$TEST_PORT}"
HELPER_PY="$ROOT_DIR/scripts/ci/fastfn_shell_helpers.py"
WORKER_POOL_PY="$ROOT_DIR/scripts/ci/worker_pool_checks.py"

curl_fastfn() {
  curl --connect-timeout "$CURL_CONNECT_TIMEOUT_SECS" --max-time "$CURL_MAX_TIME_SECS" "$@"
}

if [[ -n "${FORCE_COLOR:-}" && -n "${NO_COLOR:-}" ]]; then
  unset NO_COLOR
fi

STACK_PID=""
STACK_LOG=""

terminate_stack_pid() {
  local pid="${1:-}"
  if [[ -z "$pid" ]]; then
    return 0
  fi

  if kill -0 "$pid" >/dev/null 2>&1; then
    pkill -P "$pid" >/dev/null 2>&1 || true
    kill "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
  fi

  if kill -0 "$pid" >/dev/null 2>&1; then
    pkill -9 -P "$pid" >/dev/null 2>&1 || true
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi

  wait "$pid" >/dev/null 2>&1 || true
  pkill -P "$pid" >/dev/null 2>&1 || true
}

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

  # Remove dependency state files created by runtime auto-install/inference.
  find "$fixtures_dir" -type f -name ".fastfn-deps-state.json" -delete >/dev/null 2>&1 || true
}

reset_dep_isolation_fixture() {
  local no_deps_dir="$ROOT_DIR/tests/fixtures/dep-isolation/node/node-no-deps"
  if [[ ! -d "$no_deps_dir" ]]; then
    return 0
  fi

  # Keep this fixture intentionally manifest-free for isolation assertions.
  rm -rf "$no_deps_dir/node_modules" \
         "$no_deps_dir/package.json" \
         "$no_deps_dir/package-lock.json" \
         "$no_deps_dir/.fastfn-deps-state.json"
}

cleanup() {
  terminate_stack_pid "$STACK_PID"
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
  reset_dep_isolation_fixture
fi

wait_for_health() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    local code
    code="$(curl_fastfn -sS -o /tmp/fastfn-health.out -w '%{http_code}' "${BASE_URL}/_fn/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      if python3 "$HELPER_PY" health-all-up --file /tmp/fastfn-health.out >/dev/null 2>&1
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
  local prev_signature=""
  local stable_hits=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    local body_file code
    body_file="$(mktemp)"
    code="$(curl_fastfn -sS -o "$body_file" -w '%{http_code}' "${BASE_URL}/_fn/catalog" 2>/dev/null || true)"

    if [[ "$code" == "404" ]]; then
      rm -f "$body_file"
      ready=1
      break
    fi

    if [[ "$code" == "200" ]]; then
      local signature=""
      signature="$(python3 "$HELPER_PY" catalog-signature --file "$body_file" 2>/dev/null || true)"
      if [[ -n "$signature" ]]; then
        if [[ "$signature" == "$prev_signature" ]]; then
          stable_hits=$((stable_hits + 1))
        else
          prev_signature="$signature"
          stable_hits=1
        fi
      else
        prev_signature=""
        stable_hits=0
      fi

      if [[ "$stable_hits" -ge 2 ]]; then
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
      exec env FN_HOT_RELOAD=0 "$@" ./bin/fastfn dev --build "$target_dir" >"$STACK_LOG" 2>&1
    ) &
  else
    (
      cd "$ROOT_DIR"
      exec env FN_HOT_RELOAD=0 ./bin/fastfn dev --build "$target_dir" >"$STACK_LOG" 2>&1
    ) &
  fi
  STACK_PID="$!"

  wait_for_health
  wait_for_catalog_ready
}

stop_stack() {
  terminate_stack_pid "$STACK_PID"
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
  code="$(curl_fastfn -sS -X "$method" -o "$body_file" -w '%{http_code}' "${BASE_URL}$path")"
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL $method $path expected=$expected got=$code"
    cat "$body_file" || true
    rm -f "$body_file"
    exit 1
  fi
  rm -f "$body_file"
}

assert_status_eventually() {
  local method="$1"
  local path="$2"
  local expected="$3"
  local max_wait_secs="${4:-60}"
  local started_at now elapsed
  started_at="$(date +%s)"

  while true; do
    local body_file code
    body_file="$(mktemp)"
    code="$(curl_fastfn -sS -X "$method" -o "$body_file" -w '%{http_code}' "${BASE_URL}$path" 2>/dev/null || true)"
    if [[ "$code" == "$expected" ]]; then
      rm -f "$body_file"
      return 0
    fi

    now="$(date +%s)"
    elapsed="$((now - started_at))"
    if (( elapsed >= max_wait_secs )); then
      echo "FAIL $method $path expected=$expected within=${max_wait_secs}s got=$code"
      cat "$body_file" || true
      rm -f "$body_file"
      exit 1
    fi

    rm -f "$body_file"
    sleep 1
  done
}

assert_status_extra() {
  local method="$1"
  local path="$2"
  local expected="$3"
  shift 3
  local body_file
  body_file="$(mktemp)"
  local code
  code="$(curl_fastfn -sS -X "$method" "$@" -o "$body_file" -w '%{http_code}' "${BASE_URL}$path")"
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
  body="$(curl_fastfn -sS -X "$method" "${BASE_URL}$path")"
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
  code="$(curl_fastfn -sS -D "$headers_file" -o "$body_file" -w '%{http_code}' "${BASE_URL}$path")"
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

assert_redirect_location() {
  local path="$1"
  local expected_status="$2"
  local expected_location="$3"

  local headers_file body_file code
  headers_file="$(mktemp)"
  body_file="$(mktemp)"
  code="$(curl_fastfn -sS -D "$headers_file" -o "$body_file" -w '%{http_code}' "${BASE_URL}$path")"
  if [[ "$code" != "$expected_status" ]]; then
    echo "FAIL GET $path expected redirect status=$expected_status got=$code"
    cat "$body_file" || true
    cat "$headers_file" || true
    rm -f "$headers_file" "$body_file"
    exit 1
  fi

  if ! tr -d '\r' <"$headers_file" | grep -qi "^location: ${expected_location}$"; then
    echo "FAIL GET $path expected Location: $expected_location"
    cat "$headers_file" || true
    rm -f "$headers_file" "$body_file"
    exit 1
  fi

  rm -f "$headers_file" "$body_file"
}

assert_invoke_uses_mapped_route() {
  local catalog
  catalog="$(curl_fastfn -sS "${BASE_URL}/_fn/catalog")"
  local payload
  payload="$(python3 "$HELPER_PY" mapped-invoke-payload --catalog-json "$catalog" --variant generic)"
  local body
  body="$(curl_fastfn -sS -X POST "${BASE_URL}/_fn/invoke" -H 'Content-Type: application/json' -H 'X-Fn-Request: 1' --data "$payload")"
  python3 "$HELPER_PY" assert-invoke-mapped-route --response-json "$body" --request-json "$payload"
}

assert_reload_methods() {
  assert_status GET "/_fn/reload" "200"
  assert_status_extra POST "/_fn/reload" "200" \
    -H "X-Fn-Request: 1"
}

build_dynamic_invoke_payload() {
  local catalog="$1"
  python3 "$HELPER_PY" mapped-invoke-payload --catalog-json "$catalog" --variant dynamic
}

assert_invoke_with_route_params() {
  local catalog
  catalog="$(curl_fastfn -sS "${BASE_URL}/_fn/catalog")"
  local payload
  payload="$(build_dynamic_invoke_payload "$catalog")"
  local body
  body="$(curl_fastfn -sS -X POST "${BASE_URL}/_fn/invoke" -H 'Content-Type: application/json' -H 'X-Fn-Request: 1' --data "$payload")"
  python3 "$HELPER_PY" assert-invoke-route-params --response-json "$body" --request-json "$payload"
}

assert_enqueue_with_route_params() {
  local catalog
  catalog="$(curl_fastfn -sS "${BASE_URL}/_fn/catalog")"
  local payload
  payload="$(build_dynamic_invoke_payload "$catalog")"

  local enqueue_body
  enqueue_body="$(curl_fastfn -sS -X POST "${BASE_URL}/_fn/jobs" -H 'Content-Type: application/json' -H 'X-Fn-Request: 1' --data "$payload")"
  local job_id
  job_id="$(python3 "$HELPER_PY" job-id --response-json "$enqueue_body")"

  local status="queued"
  for _ in $(seq 1 25); do
    local meta
    meta="$(curl_fastfn -sS "${BASE_URL}/_fn/jobs/$job_id")"
    status="$(python3 "$HELPER_PY" job-status --response-json "$meta")"
    if [[ "$status" == "done" || "$status" == "failed" || "$status" == "canceled" ]]; then
      break
    fi
    sleep 1
  done

  if [[ "$status" != "done" ]]; then
    echo "FAIL enqueue job did not complete successfully (status=$status)"
    curl_fastfn -sS "${BASE_URL}/_fn/jobs/$job_id" || true
    exit 1
  fi

  local result
  result="$(curl_fastfn -sS "${BASE_URL}/_fn/jobs/$job_id/result")"
  python3 "$HELPER_PY" assert-job-result-params --result-json "$result" --request-json "$payload"
}

assert_openapi_paths() {
  local mode="$1"
  local openapi
  local catalog
  openapi="$(curl_fastfn -sS "${BASE_URL}/_fn/openapi.json")"
  catalog="$(curl_fastfn -sS "${BASE_URL}/_fn/catalog")"
  python3 "$HELPER_PY" openapi-assert-paths --mode "$mode" --openapi-json "$openapi" --catalog-json "$catalog"
}

assert_scheduler_nonblocking() {
  local ready=0
  local snapshot=""
  for _ in $(seq 1 40); do
    snapshot="$(curl_fastfn -sS "${BASE_URL}/_fn/schedules")"
    if python3 "$HELPER_PY" schedule-has-success --json "$snapshot" --runtime node --name slow-task >/dev/null 2>&1
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
    out="$(curl_fastfn -sS -o "$body_file" -w '%{http_code} %{time_total}' "${BASE_URL}/health")"
    code="${out%% *}"
    secs="${out##* }"
    if [[ "$code" != "200" ]]; then
      echo "FAIL GET /health expected=200 got=$code during scheduler non-blocking check"
      cat "$body_file" || true
      rm -f "$body_file"
      exit 1
    fi
    rm -f "$body_file"

    ms="$(python3 "$HELPER_PY" seconds-to-ms --value "$secs")"
    if (( ms > max_ms )); then
      max_ms="$ms"
    fi
    sleep 0.2
  done

  if (( max_ms > threshold_ms )); then
    echo "FAIL scheduler blocked public calls: max /health latency ${max_ms}ms exceeds ${threshold_ms}ms"
    curl_fastfn -sS "${BASE_URL}/_fn/schedules" || true
    exit 1
  fi

  local probe_file="$ROOT_DIR/tests/fixtures/scheduler-nonblocking/node/slow-task/.fastfn/scheduler-worker-pool.json"
  local probe_ready=0
  local probe=""
  for _ in $(seq 1 20); do
    if [[ -f "$probe_file" ]]; then
      probe="$(cat "$probe_file" 2>/dev/null || true)"
      if [[ -n "$probe" ]] && python3 "$HELPER_PY" scheduler-probe-valid --json "$probe" >/dev/null 2>&1
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
    curl_fastfn -sS "${BASE_URL}/_fn/schedules" || true
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
    snapshot="$(curl_fastfn -sS "${BASE_URL}/_fn/schedules")"
    health="$(curl_fastfn -sS "${BASE_URL}/_fn/health")"
    catalog="$(curl_fastfn -sS "${BASE_URL}/_fn/catalog")"
    if python3 "$HELPER_PY" keep-warm-visible --snapshot-json "$snapshot" --health-json "$health" --catalog-json "$catalog" >/dev/null 2>&1
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
  summary="$(python3 "$WORKER_POOL_PY" runtime-fn-version)"
  echo "worker pool check: $summary"

  local isolation
  isolation="$(python3 "$WORKER_POOL_PY" runtime-fn-version | tail -n 1)"
  echo "worker pool isolation check: $isolation"
}

assert_worker_pool_parallel_multiruntime() {
  local summary
summary="$(python3 "$WORKER_POOL_PY" parallel-multiruntime)"
  echo "worker pool multiruntime parallel check: $summary"
}

assert_worker_pool_health_observability() {
  local summary
  summary="$(python3 "$WORKER_POOL_PY" health-observability)"
  echo "worker pool observability check: $summary"
}

assert_python_dep_worker_persistent() {
  local summary
  summary="$(python3 "$WORKER_POOL_PY" python-dep-worker-persistent)"
  echo "python deps persistent worker check: $summary"
}

assert_python_with_deps_available() {
  local summary
  summary="$(python3 "$WORKER_POOL_PY" python-with-deps-available)"
  echo "python with-deps availability check: $summary"
}

assert_parallel_mapped_routes_nonblocking() {
  local threshold_ms="${PARALLEL_MAX_LATENCY_MS:-3500}"
  local summary
  summary="$(python3 "$WORKER_POOL_PY" parallel-mapped-routes-nonblocking --threshold-ms "$threshold_ms")"
  echo "parallel mapped routes non-blocking check: $summary"
}

assert_cloudflare_v1_router_fixture() {
  local body_file code

  body_file="$(mktemp)"
  code="$(curl_fastfn -sS -o "$body_file" -w '%{http_code}' "${BASE_URL}/api/v1/status")"
  if [[ "$code" != "200" ]]; then
    echo "FAIL GET /api/v1/status expected=200 got=$code"
    cat "$body_file" || true
    rm -f "$body_file"
    exit 1
  fi
  python3 "$HELPER_PY" cloudflare-status-body --file "$body_file"
  rm -f "$body_file"

  assert_status_extra POST "/api/v1/messages" "415" \
    -H 'Content-Type: text/plain' \
    --data 'not-json'
  assert_body_contains POST "/api/v1/messages" "\"message\":\"Content-Type must be application/json\""

  body_file="$(mktemp)"
  code="$(curl_fastfn -sS -X POST -H 'Content-Type: application/json' --data '{"message":"hola"}' \
    -o "$body_file" -w '%{http_code}' "${BASE_URL}/api/v1/messages")"
  if [[ "$code" != "201" ]]; then
    echo "FAIL POST /api/v1/messages expected=201 got=$code"
    cat "$body_file" || true
    rm -f "$body_file"
    exit 1
  fi
  python3 "$HELPER_PY" cloudflare-message-body --file "$body_file"
  rm -f "$body_file"

  assert_status GET "/api/v1/unknown" "404"
  assert_body_contains GET "/api/v1/unknown" "\"message\":\"Not Found\""

  assert_status GET "/api/v2/status" "400"
  assert_body_contains GET "/api/v2/status" "\"message\":\"Invalid API version\""
}

echo "== Phase 1: Next-style single app =="
start_stack "examples/functions/next-style" "FN_UI_ENABLED=0" "FN_CONSOLE_WRITE_ENABLED=0" "FN_RUNTIMES=$RUNTIMES_WITH_RUST" "FN_DEFAULT_TIMEOUT_MS=10000"
assert_config_files_hidden
assert_reload_methods
assert_status_eventually GET "/users" "200" 60
assert_status_eventually GET "/blog" "200" 60
assert_status_eventually GET "/php/profile/123" "200" 60
assert_status_eventually GET "/rust/health" "200" 60
assert_status GET "/users" "200"
assert_status GET "/users/123" "200"
assert_status GET "/hello" "200"
assert_status GET "/html?name=api" "200"
assert_status GET "/showcase" "200"
assert_status GET "/showcase/form" "200"
assert_status GET "/hello-demo/Juan" "200"
assert_status GET "/blog" "200"
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
assert_status GET "/rust/version" "200"
assert_body_contains GET "/users" "\"runtime\":\"node\""
assert_body_contains GET "/users/123" "\"id\":\"123\""
assert_body_contains GET "/hello" "\"message\":\"hello works\""
assert_body_contains GET "/html?name=api" "<title>FastFN HTML Demo</title>"
assert_body_contains GET "/html?name=api" "Hello api"
assert_body_contains GET "/showcase" "<title>FastFN Visual Showcase</title>"
assert_body_contains GET "/showcase/form" "\"route\":\"GET /showcase/form\""
assert_body_contains GET "/showcase/form" "\"name\":\"API2\""
assert_body_contains GET "/hello-demo/Juan" "\"route\":\"GET /hello-demo/:name\""
assert_body_contains GET "/hello-demo/Juan" "\"name\":\"Juan\""
assert_body_contains GET "/hello-demo/Juan" "\"message\":\"Hello Juan\""
assert_body_contains GET "/blog" "\"helper\": \"blog/_shared.py\""
assert_body_contains GET "/blog/a/b/c" "\"runtime\": \"python\""
assert_body_contains GET "/blog/a/b/c" "\"slug\": \"a/b/c\""
assert_body_contains GET "/php/profile/123" "\"runtime\":\"php\""
assert_body_contains GET "/php/profile/123" "\"id\":\"123\""
assert_body_contains POST "/admin/users/123" "\"id\": \"123\""
assert_body_contains GET "/rust/health" "\"runtime\":\"rust\""
assert_body_contains GET "/rust/version" "\"version\":\"v1\""
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

echo "== Phase 2b: Discovery conflict parity =="
routing_parity_fixture="$(mktemp -d -t fastfn-routing-parity.XXXXXX)"
cat > "${routing_parity_fixture}/get.ok.js" <<'EOF'
exports.handler = async () => ({ status: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ok: true }) });
EOF
cat > "${routing_parity_fixture}/get.conflict.js" <<'EOF'
exports.handler = async () => ({ status: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ runtime: "node" }) });
EOF
cat > "${routing_parity_fixture}/get.conflict.py" <<'EOF'
def handler(event):
    return {"status": 200, "headers": {"Content-Type": "application/json"}, "body": {"runtime": "python"}}
EOF
cat > "${routing_parity_fixture}/get.post.items.js" <<'EOF'
exports.handler = async () => ({ status: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ should_not_publish: true }) });
EOF
start_stack "$routing_parity_fixture" "FN_UI_ENABLED=0" "FN_CONSOLE_WRITE_ENABLED=0" "FN_RUNTIMES=node,python"
assert_status GET "/ok" "200"
assert_status GET "/conflict" "409"
assert_status GET "/post/items" "404"
stop_stack
rm -rf "$routing_parity_fixture"

echo "== Phase 3: Internal docs/admin toggles =="
start_stack "tests/fixtures/nextstyle-clean" "FN_DOCS_ENABLED=0" "FN_ADMIN_API_ENABLED=0" "FN_UI_ENABLED=0"
assert_status GET "/_fn/docs" "404"
assert_status GET "/_fn/openapi.json" "404"
assert_status GET "/_fn/catalog" "404"
assert_status GET "/_fn/ui-state" "404"
assert_status GET "/console" "404"
assert_status GET "/docs/a/b" "200"
stop_stack

echo "== Phase 3b: Home routing (env + fn.config) =="
start_stack "tests/fixtures/home-routing" "FN_RUNTIMES=node" "FN_HOME_FUNCTION=/welcome"
assert_status GET "/welcome" "200"
assert_body_contains GET "/" "\"endpoint\":\"welcome\""
assert_status GET "/portal/dashboard" "200"
assert_body_contains GET "/portal" "\"endpoint\":\"portal-dashboard\""
stop_stack

start_stack "tests/fixtures/home-routing" "FN_RUNTIMES=node" "FN_HOME_FUNCTION=/portal/dashboard"
assert_body_contains GET "/" "\"endpoint\":\"portal-dashboard\""
stop_stack

start_stack "tests/fixtures/home-routing" "FN_RUNTIMES=node" "FN_HOME_REDIRECT=/_fn/docs"
assert_redirect_location "/" "302" "/_fn/docs"
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
assert_status_eventually GET "/slow-rust" "200" "120"
assert_status GET "/state-a" "200"
assert_status GET "/state-b" "200"
assert_worker_pool_runtime_fn_version
assert_worker_pool_parallel_multiruntime
assert_worker_pool_health_observability
stop_stack

echo "== Phase 9: per-function dependency isolation =="
reset_dep_isolation_fixture
start_stack "tests/fixtures/dep-isolation" \
  "FN_UI_ENABLED=0" "FN_CONSOLE_WRITE_ENABLED=0" \
  "FN_PREINSTALL_PY_DEPS_ON_START=0" "FN_PREINSTALL_NODE_DEPS_ON_START=0" \
  "FN_AUTO_INFER_PY_DEPS=0" "FN_AUTO_INFER_NODE_DEPS=0" \
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
assert_status_eventually GET "/rust-basic" "200" "120"
assert_body_contains GET "/rust-basic" "\"runtime\":\"rust\""
assert_body_contains GET "/rust-basic" "\"ok\":true"

stop_stack

echo "== Phase 10: Cloudflare Worker compat fixture =="
if node -e 'process.exit((typeof Request === "function" && typeof Response === "function") ? 0 : 1)' >/dev/null 2>&1; then
  start_stack "tests/fixtures/compat" "FN_UI_ENABLED=0" "FN_CONSOLE_WRITE_ENABLED=0" "FN_RUNTIMES=node"
  assert_reload_methods
  assert_cloudflare_v1_router_fixture
  stop_stack
else
  echo "skip cloudflare compat fixture: Node Request/Response globals unavailable"
fi

echo "== Phase 11: Secrets vault injection =="
# Use the polyglot demo stack (Phase 5 left it up — restart with write enabled)
start_stack "examples/functions/next-style" "FN_CONSOLE_WRITE_ENABLED=1" "FN_RUNTIMES=python" "FN_DEFAULT_TIMEOUT_MS=5000"

# 11a. List secrets — initially empty
assert_body_contains GET "/_fn/secrets" "[]"

# 11b. Create a secret
body=$(curl_fastfn -s -X POST "${BASE_URL}/_fn/secrets" \
  -H 'Content-Type: application/json' \
  -H 'X-Fn-Request: 1' \
  -d '{"key":"TEST_SECRET","value":"s3cret-value-42"}')
echo "$body" | grep -q '"status":"created"' || { echo "FAIL: create secret"; echo "$body"; exit 1; }
echo "  ok: secret created"

# 11c. List secrets — should contain TEST_SECRET
body=$(curl_fastfn -s "${BASE_URL}/_fn/secrets")
echo "$body" | grep -q '"key":"TEST_SECRET"' || { echo "FAIL: secret not in list"; echo "$body"; exit 1; }
echo "  ok: secret listed"

# 11d. Create a Python function that reads event.secrets
mkdir -p /tmp/fastfn-secrets-test/python/secret-checker
cat > /tmp/fastfn-secrets-test/python/secret-checker/handler.py << 'PYEOF'
def handler(event):
    secrets = event.get("secrets") or {}
    val = secrets.get("TEST_SECRET", "")
    return {"status": 200, "body": {"has_secret": bool(val), "masked": val[:4] + "..." if val else ""}}
PYEOF
cat > /tmp/fastfn-secrets-test/python/secret-checker/fn.config.json << 'CFGEOF'
{"invoke":{"methods":["GET"],"routes":["/secret-checker","/secret-checker/*"]}}
CFGEOF

# Copy function into the running stack's functions directory (idempotent).
# Remove destination first to avoid nested copy (secret-checker/secret-checker),
# which can create version-route conflicts and hide /secret-checker.
docker compose exec -T openresty sh -lc \
  'rm -rf /app/srv/fn/functions/python/secret-checker && mkdir -p /app/srv/fn/functions/python/secret-checker'
docker compose cp /tmp/fastfn-secrets-test/python/secret-checker/. openresty:/app/srv/fn/functions/python/secret-checker
curl_fastfn -s -X POST -H 'X-Fn-Request: 1' "${BASE_URL}/_fn/reload" > /dev/null

# 11e. Call the function — should receive the secret
sleep 2
body=$(curl_fastfn -s "${BASE_URL}/secret-checker")
echo "$body" | grep -q '"has_secret":true' || { echo "FAIL: secret not injected into event"; echo "$body"; exit 1; }
echo "$body" | grep -q '"masked":"s3cr..."' || { echo "FAIL: secret value mismatch"; echo "$body"; exit 1; }
echo "  ok: secret injected into event.secrets"

# 11f. Delete the secret
body=$(curl_fastfn -s -X DELETE -H 'X-Fn-Request: 1' "${BASE_URL}/_fn/secrets?key=TEST_SECRET")
echo "$body" | grep -q '"status":"deleted"' || { echo "FAIL: delete secret"; echo "$body"; exit 1; }
echo "  ok: secret deleted"

# 11g. Call function again — secret should be gone
body=$(curl_fastfn -s "${BASE_URL}/secret-checker")
echo "$body" | grep -q '"has_secret":false' || { echo "FAIL: secret still present after delete"; echo "$body"; exit 1; }
echo "  ok: secret removed from event after deletion"

# Cleanup
rm -rf /tmp/fastfn-secrets-test
docker compose exec -T openresty sh -lc 'rm -rf /app/srv/fn/functions/python/secret-checker' >/dev/null 2>&1 || true
stop_stack

echo "PASS test-api.sh (routing/admin/polyglot integration)"
