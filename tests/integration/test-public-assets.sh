#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-150}"
KEEP_UP="${KEEP_UP:-0}"
TEST_HOST="${TEST_HOST:-127.0.0.1}"
TEST_PORT="${TEST_PORT:-${FN_HOST_PORT:-8080}}"
BASE_URL="${BASE_URL:-http://${TEST_HOST}:${TEST_PORT}}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-20}"
HELPER_PY="$ROOT_DIR/scripts/ci/fastfn_shell_helpers.py"

STACK_PID=""
STACK_LOG=""
DEV_MODE=""
SNAPSHOT_DIR=""
NATIVE_SOCKET_BASE=""

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

cleanup() {
  terminate_stack_pid "$STACK_PID"

  if [[ "$DEV_MODE" == "docker" && "$KEEP_UP" != "1" ]]; then
    (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  fi

  if [[ "$DEV_MODE" == "native" && -n "$STACK_LOG" && -f "$STACK_LOG" ]]; then
    local runtime_dir
    runtime_dir="$(grep -F 'Runtime extracted to:' "$STACK_LOG" | tail -n 1 | sed 's/.*Runtime extracted to: //' || true)"
    if [[ -n "$runtime_dir" ]]; then
      pkill -f "$runtime_dir/openresty" >/dev/null 2>&1 || true
      pkill -f "$runtime_dir/srv/fn/runtimes/python-daemon.py" >/dev/null 2>&1 || true
      pkill -f "$runtime_dir/srv/fn/runtimes/node-daemon.js" >/dev/null 2>&1 || true
      pkill -f "$runtime_dir/srv/fn/runtimes/php-daemon.php" >/dev/null 2>&1 || true
      pkill -f "$runtime_dir/srv/fn/runtimes/php-worker.php" >/dev/null 2>&1 || true
      pkill -f "$runtime_dir/srv/fn/runtimes/rust-daemon.py" >/dev/null 2>&1 || true
      pkill -f "$runtime_dir/srv/fn/runtimes/go-daemon.py" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -n "$SNAPSHOT_DIR" && -d "$SNAPSHOT_DIR" ]]; then
    rm -rf "$SNAPSHOT_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$NATIVE_SOCKET_BASE" && -d "$NATIVE_SOCKET_BASE" ]]; then
    rm -rf "$NATIVE_SOCKET_BASE" >/dev/null 2>&1 || true
  fi
  if [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]]; then
    rm -f "$STACK_LOG" >/dev/null 2>&1 || true
  fi
  STACK_PID=""
  STACK_LOG=""
  SNAPSHOT_DIR=""
  NATIVE_SOCKET_BASE=""
}
trap cleanup EXIT

pick_mode() {
  if [[ "${FASTFN_DEV_MODE:-}" == "docker" || "${FASTFN_DEV_MODE:-}" == "native" ]]; then
    DEV_MODE="$FASTFN_DEV_MODE"
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    DEV_MODE="docker"
    return 0
  fi

  DEV_MODE="native"
}

curl_common() {
  curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$@"
}

wait_for_health() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    if [[ -n "$STACK_PID" ]] && ! kill -0 "$STACK_PID" >/dev/null 2>&1; then
      echo "FAIL fastfn process exited before health became ready"
      [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 200 "$STACK_LOG" || true
      exit 1
    fi
    local code
    code="$(curl_common -o /tmp/fastfn-public-assets-health.out -w '%{http_code}' "${BASE_URL}/_fn/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" != "1" ]]; then
    echo "FAIL health did not become ready"
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
    exit 1
  fi
}

wait_for_catalog_ready() {
  local allow_empty="${1:-0}"
  local ready=0
  local prev_signature=""
  local stable_hits=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    local body_file code signature
    body_file="$(mktemp)"
    code="$(curl_common -o "$body_file" -w '%{http_code}' "${BASE_URL}/_fn/catalog" 2>/dev/null || true)"

    if [[ "$code" == "200" ]]; then
      signature="$(python3 "$HELPER_PY" catalog-signature --file "$body_file" 2>/dev/null || true)"
      if [[ -n "$signature" ]]; then
        if [[ "$signature" == "$prev_signature" ]]; then
          stable_hits=$((stable_hits + 1))
        else
          prev_signature="$signature"
          stable_hits=1
        fi
      elif [[ "$allow_empty" == "1" ]]; then
        signature="empty:$(tr -d '\r\n' < "$body_file")"
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
    [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
    exit 1
  fi
}

start_stack() {
  local target_dir="$1"
  local runtimes="$2"
  local allow_empty_catalog="${3:-0}"
  local snapshot_base="/tmp/fastfn-public-assets"

  cleanup
  pick_mode
  mkdir -p "$snapshot_base"
  SNAPSHOT_DIR="$(mktemp -d "$snapshot_base/fastfn-public-assets.XXXXXX")"
  cp -a "$target_dir/." "$SNAPSHOT_DIR/"
  STACK_LOG="$(mktemp -t fastfn-public-assets.XXXXXX.log)"
  NATIVE_SOCKET_BASE=""

  if [[ "$DEV_MODE" == "docker" ]]; then
    (
      cd "$ROOT_DIR"
      exec env \
        FN_UI_ENABLED=0 \
        FN_CONSOLE_WRITE_ENABLED=0 \
        FN_HOST_PORT="$TEST_PORT" \
        FN_RUNTIMES="$runtimes" \
        ./bin/fastfn dev --build "$SNAPSHOT_DIR" >"$STACK_LOG" 2>&1
    ) &
  else
    local missing=()
    command -v openresty >/dev/null 2>&1 || missing+=("openresty")
    command -v node >/dev/null 2>&1 || missing+=("node")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v php >/dev/null 2>&1 || missing+=("php")
    command -v cargo >/dev/null 2>&1 || missing+=("cargo")
    command -v go >/dev/null 2>&1 || missing+=("go")
    if [[ "${#missing[@]}" -gt 0 ]]; then
      echo "SKIP public-assets integration (native deps missing: ${missing[*]})"
      exit 0
    fi
    NATIVE_SOCKET_BASE="$(mktemp -d /tmp/fastfn-public-assets-sock.XXXXXX)"

    (
      cd "$ROOT_DIR"
      exec env \
        FN_UI_ENABLED=0 \
        FN_CONSOLE_WRITE_ENABLED=0 \
        FN_HOST_PORT="$TEST_PORT" \
        FN_RUNTIMES="$runtimes" \
        FN_SOCKET_BASE_DIR="$NATIVE_SOCKET_BASE" \
        ./bin/fastfn dev --native "$SNAPSHOT_DIR" >"$STACK_LOG" 2>&1
    ) &
  fi

  STACK_PID="$!"
  wait_for_health
  wait_for_catalog_ready "$allow_empty_catalog"
}

assert_status_and_contains() {
  local method="$1"
  local path="$2"
  local expected="$3"
  local needle="$4"
  local body_file err_file
  body_file="$(mktemp)"
  err_file="$(mktemp)"
  local code
  code="$(curl_common -X "$method" -o "$body_file" -w '%{http_code}' "${BASE_URL}${path}" 2>"$err_file" || true)"
  if [[ ! "$code" =~ ^[0-9]{3}$ ]]; then
    echo "FAIL $method $path curl request failed"
    cat "$err_file" || true
    rm -f "$body_file" "$err_file"
    exit 1
  fi
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL $method $path expected=$expected got=$code"
    cat "$body_file" || true
    cat "$err_file" || true
    rm -f "$body_file" "$err_file"
    exit 1
  fi
  if [[ -n "$needle" ]] && ! grep -q "$needle" "$body_file"; then
    echo "FAIL $method $path missing fragment: $needle"
    cat "$body_file" || true
    cat "$err_file" || true
    rm -f "$body_file" "$err_file"
    exit 1
  fi
  rm -f "$body_file" "$err_file"
}

assert_header_contains() {
  local method="$1"
  local path="$2"
  local expected="$3"
  local header_name="$4"
  local header_fragment="$5"
  local body_file headers_file err_file code
  local -a curl_args
  body_file="$(mktemp)"
  headers_file="$(mktemp)"
  err_file="$(mktemp)"
  curl_args=(-D "$headers_file" -o "$body_file" -w '%{http_code}')
  if [[ "$method" == "HEAD" ]]; then
    curl_args+=(-I)
  else
    curl_args+=(-X "$method")
  fi
  code="$(curl_common "${curl_args[@]}" "${BASE_URL}${path}" 2>"$err_file" || true)"
  if [[ ! "$code" =~ ^[0-9]{3}$ ]]; then
    echo "FAIL $method $path curl request failed"
    cat "$err_file" || true
    rm -f "$body_file" "$headers_file" "$err_file"
    exit 1
  fi
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL $method $path expected=$expected got=$code"
    cat "$body_file" || true
    cat "$err_file" || true
    rm -f "$body_file" "$headers_file" "$err_file"
    exit 1
  fi
  if ! grep -i "^${header_name}:" "$headers_file" | grep -qi "$header_fragment"; then
    echo "FAIL $method $path missing header ${header_name}: ${header_fragment}"
    cat "$headers_file" || true
    cat "$err_file" || true
    rm -f "$body_file" "$headers_file" "$err_file"
    exit 1
  fi
  rm -f "$body_file" "$headers_file" "$err_file"
}

assert_status_and_contains_with_header() {
  local method="$1"
  local path="$2"
  local header_name="$3"
  local header_value="$4"
  local expected="$5"
  local needle="$6"
  local body_file err_file
  body_file="$(mktemp)"
  err_file="$(mktemp)"
  local code
  code="$(curl_common -H "${header_name}: ${header_value}" -X "$method" -o "$body_file" -w '%{http_code}' "${BASE_URL}${path}" 2>"$err_file" || true)"
  if [[ ! "$code" =~ ^[0-9]{3}$ ]]; then
    echo "FAIL $method $path curl request failed"
    cat "$err_file" || true
    rm -f "$body_file" "$err_file"
    exit 1
  fi
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL $method $path expected=$expected got=$code"
    cat "$body_file" || true
    cat "$err_file" || true
    rm -f "$body_file" "$err_file"
    exit 1
  fi
  if [[ -n "$needle" ]] && ! grep -q "$needle" "$body_file"; then
    echo "FAIL $method $path missing fragment: $needle"
    cat "$body_file" || true
    cat "$err_file" || true
    rm -f "$body_file" "$err_file"
    exit 1
  fi
  rm -f "$body_file" "$err_file"
}

echo "== static-first demo =="
start_stack "$ROOT_DIR/examples/functions/assets-static-first" "node,python"
assert_status_and_contains GET "/" "200" "Static-First Demo"
assert_status_and_contains GET "/api-node" "200" "\"runtime\":\"node\""
assert_status_and_contains GET "/api-python" "200" "\"runtime\":\"python\""
assert_status_and_contains GET "/missing/path" "404" "not found"
assert_status_and_contains GET "/.env" "404" "not found"
assert_status_and_contains GET "/%2e%2e/api-node/handler.js" "400" "Bad Request"
assert_header_contains HEAD "/app.js" "200" "Cache-Control" "must-revalidate"
assert_header_contains HEAD "/app.js" "200" "ETag" "W/"

echo "== spa fallback demo =="
start_stack "$ROOT_DIR/examples/functions/assets-spa-fallback" "php,lua"
assert_status_and_contains GET "/" "200" "SPA Fallback Demo"
assert_status_and_contains_with_header GET "/dashboard/team" "Accept" "text/html" "200" "SPA Fallback Demo"
assert_status_and_contains_with_header GET "/settings" "Sec-Fetch-Mode" "navigate" "200" "SPA Fallback Demo"
assert_status_and_contains_with_header GET "/dashboard/team" "Accept" "*/*" "200" "SPA Fallback Demo"
assert_status_and_contains_with_header GET "/api/unknown" "Accept" "*/*" "404" "not found"
assert_status_and_contains GET "/missing.js" "404" "not found"
assert_status_and_contains GET "/api-profile" "200" "\"runtime\":\"php\""
assert_status_and_contains GET "/api-flags" "200" "\"runtime\":\"lua\""

echo "== worker-first demo =="
start_stack "$ROOT_DIR/examples/functions/assets-worker-first" "rust,go"
assert_status_and_contains GET "/" "200" "Worker-First Demo"
assert_status_and_contains GET "/catalog/overview" "200" "Worker-First Demo"
assert_status_and_contains GET "/hello" "200" "hello from rust runtime"
assert_status_and_contains GET "/api-go" "200" "\"runtime\":\"go\""
assert_status_and_contains GET "/hello" "200" "rust runtime"

hello_err_file="$(mktemp)"
hello_body="$(curl_common "${BASE_URL}/hello" 2>"$hello_err_file" || true)"
if [[ -z "$hello_body" ]]; then
  echo "FAIL GET /hello curl request failed"
  cat "$hello_err_file" || true
  rm -f "$hello_err_file"
  exit 1
fi
if grep -q "asset shadow" <<<"$hello_body"; then
  echo "FAIL /hello returned the asset shadow instead of the runtime handler"
  rm -f "$hello_err_file"
  exit 1
fi
rm -f "$hello_err_file"

assert_header_contains HEAD "/app.js" "200" "ETag" "W/"
assert_header_contains HEAD "/app.js" "200" "Cache-Control" "must-revalidate"

echo "== empty assets config does not mint routes =="
empty_assets_dir="$(mktemp -d /tmp/fastfn-empty-assets.XXXXXX)"
mkdir -p "$empty_assets_dir/public"
cat > "$empty_assets_dir/fn.config.json" <<'JSON'
{
  "assets": {
    "directory": "public",
    "not_found_handling": "404",
    "run_worker_first": false
  }
}
JSON
start_stack "$empty_assets_dir" "node" "1"
assert_status_and_contains GET "/" "404" "not found"
assert_status_and_contains GET "/dashboard" "404" "not found"
rm -rf "$empty_assets_dir"

echo "== config-only folder without handler does not mint routes =="
no_handler_dir="$(mktemp -d /tmp/fastfn-no-handler-assets.XXXXXX)"
mkdir -p "$no_handler_dir/public" "$no_handler_dir/ghost"
cat > "$no_handler_dir/fn.config.json" <<'JSON'
{
  "assets": {
    "directory": "public",
    "not_found_handling": "404",
    "run_worker_first": false
  }
}
JSON
cat > "$no_handler_dir/ghost/fn.config.json" <<'JSON'
{
  "invoke": {
    "routes": ["/ghost"]
  }
}
JSON
start_stack "$no_handler_dir" "node" "1"
assert_status_and_contains GET "/ghost" "404" "not found"
catalog_body="$(curl_common "${BASE_URL}/_fn/catalog")"
if grep -q '"ghost"' <<<"$catalog_body"; then
  echo "FAIL config-only folder without handler leaked into catalog"
  printf '%s\n' "$catalog_body"
  rm -rf "$no_handler_dir"
  exit 1
fi
rm -rf "$no_handler_dir"

echo "PASS test-public-assets.sh"
