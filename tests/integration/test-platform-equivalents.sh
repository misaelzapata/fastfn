#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-150}"
KEEP_UP="${KEEP_UP:-0}"
TEST_HOST="${TEST_HOST:-127.0.0.1}"
TEST_PORT="${TEST_PORT:-${FN_HOST_PORT:-8080}}"
BASE_URL="${BASE_URL:-http://${TEST_HOST}:${TEST_PORT}}"
TARGET_DIR="$ROOT_DIR/examples/functions/platform-equivalents"
HELPER_PY="$ROOT_DIR/scripts/ci/fastfn_shell_helpers.py"

STACK_PID=""
STACK_LOG=""
DEV_MODE=""

cleanup() {
  if [[ -n "$STACK_PID" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi

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
}
trap cleanup EXIT

wait_for_health() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    if [[ -n "$STACK_PID" ]] && ! kill -0 "$STACK_PID" >/dev/null 2>&1; then
      echo "FAIL fastfn process exited before health became ready"
      [[ -n "$STACK_LOG" && -f "$STACK_LOG" ]] && tail -n 200 "$STACK_LOG" || true
      exit 1
    fi
    local code
    code="$(curl -sS -o /tmp/fastfn-platform-eq-health.out -w '%{http_code}' "${BASE_URL}/_fn/health" 2>/dev/null || true)"
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

start_stack() {
  STACK_LOG="$(mktemp -t fastfn-platform-eq.XXXXXX.log)"
  pick_mode

  if [[ "$DEV_MODE" == "docker" ]]; then
    (
      cd "$ROOT_DIR"
      exec env \
        FN_UI_ENABLED=0 \
        FN_CONSOLE_WRITE_ENABLED=0 \
        FN_HOST_PORT="$TEST_PORT" \
        ./bin/fastfn dev --build "$TARGET_DIR" >"$STACK_LOG" 2>&1
    ) &
  else
    local missing=()
    command -v openresty >/dev/null 2>&1 || missing+=("openresty")
    command -v node >/dev/null 2>&1 || missing+=("node")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v php >/dev/null 2>&1 || missing+=("php")
    if [[ "${#missing[@]}" -gt 0 ]]; then
      echo "SKIP platform-equivalents integration (native deps missing: ${missing[*]})"
      exit 0
    fi

    (
      cd "$ROOT_DIR"
      exec env \
        FN_UI_ENABLED=0 \
        FN_CONSOLE_WRITE_ENABLED=0 \
        FN_HOST_PORT="$TEST_PORT" \
        ./bin/fastfn dev --native "$TARGET_DIR" >"$STACK_LOG" 2>&1
    ) &
  fi

  STACK_PID="$!"
  wait_for_health
}

assert_status_and_contains() {
  local method="$1"
  local url_path="$2"
  local expected="$3"
  local needle="$4"
  local body_file
  body_file="$(mktemp)"
  local code
  code="$(curl -sS -X "$method" -o "$body_file" -w '%{http_code}' "${BASE_URL}${url_path}")"
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL $method $url_path expected=$expected got=$code"
    cat "$body_file" || true
    rm -f "$body_file"
    exit 1
  fi
  if [[ -n "$needle" ]] && ! grep -qi "$needle" "$body_file"; then
    echo "FAIL $method $url_path missing fragment: $needle"
    cat "$body_file" || true
    rm -f "$body_file"
    exit 1
  fi
  rm -f "$body_file"
}

extract_json_field() {
  local field="$1"
  python3 "$HELPER_PY" extract-json-field --stdin --field "$field"
}

start_stack

echo "mode: ${DEV_MODE}"

login_body="$(curl -sS -X POST "${BASE_URL}/auth/login" \
  -H 'content-type: application/json' \
  --data '{"username":"demo-admin","role":"admin"}')"
token="$(printf '%s' "$login_body" | extract_json_field "token")"
if [[ -z "$token" ]]; then
  echo "FAIL auth/login did not return token"
  echo "$login_body"
  exit 1
fi

assert_status_and_contains GET "/auth/profile" "401" "Missing Authorization"

profile_file="$(mktemp)"
profile_code="$(curl -sS -o "$profile_file" -w '%{http_code}' "${BASE_URL}/auth/profile" \
  -H "authorization: Bearer ${token}")"
if [[ "$profile_code" != "200" ]]; then
  echo "FAIL GET /auth/profile expected=200 got=$profile_code"
  cat "$profile_file" || true
  rm -f "$profile_file"
  exit 1
fi
if ! grep -qiE '"role"\s*:\s*"admin"' "$profile_file"; then
  echo "FAIL GET /auth/profile expected role admin"
  cat "$profile_file" || true
  rm -f "$profile_file"
  exit 1
fi
rm -f "$profile_file"

payload='{"action":"opened","repository":"fastfn"}'
signature="$(python3 "$HELPER_PY" hmac-sha256 --secret "fastfn-webhook-secret" --body "$payload")"

webhook_body="$(mktemp)"
webhook_code="$(curl -sS -X POST -o "$webhook_body" -w '%{http_code}' "${BASE_URL}/webhooks/github-signed" \
  -H "x-hub-signature-256: ${signature}" \
  -H "x-github-delivery: demo-delivery-1" \
  -H "x-github-event: issues" \
  -H 'content-type: application/json' \
  --data "$payload")"
if [[ "$webhook_code" != "202" ]]; then
  echo "FAIL webhook first delivery expected=202 got=$webhook_code"
  cat "$webhook_body" || true
  rm -f "$webhook_body"
  exit 1
fi
rm -f "$webhook_body"

bad_sig_body="$(mktemp)"
bad_sig_code="$(curl -sS -X POST -o "$bad_sig_body" -w '%{http_code}' "${BASE_URL}/webhooks/github-signed" \
  -H "x-hub-signature-256: sha256=bad" \
  -H "x-github-delivery: demo-bad-signature" \
  -H 'content-type: application/json' \
  --data "$payload")"
if [[ "$bad_sig_code" != "401" ]]; then
  echo "FAIL webhook invalid signature expected=401 got=$bad_sig_code"
  cat "$bad_sig_body" || true
  rm -f "$bad_sig_body"
  exit 1
fi
if ! grep -qiE 'invalid_signature|signature mismatch' "$bad_sig_body"; then
  echo "FAIL webhook invalid signature missing expected error marker"
  cat "$bad_sig_body" || true
  rm -f "$bad_sig_body"
  exit 1
fi
rm -f "$bad_sig_body"

dup_body="$(mktemp)"
dup_code="$(curl -sS -X POST -o "$dup_body" -w '%{http_code}' "${BASE_URL}/webhooks/github-signed" \
  -H "x-hub-signature-256: ${signature}" \
  -H "x-github-delivery: demo-delivery-1" \
  -H "x-github-event: issues" \
  -H 'content-type: application/json' \
  --data "$payload")"
if [[ "$dup_code" != "202" ]]; then
  echo "FAIL webhook repeated delivery expected=202 got=$dup_code"
  cat "$dup_body" || true
  rm -f "$dup_body"
  exit 1
fi
if ! grep -qiE '"ok"\s*:\s*true' "$dup_body"; then
  echo "FAIL webhook repeated delivery missing ok=true"
  cat "$dup_body" || true
  rm -f "$dup_body"
  exit 1
fi
rm -f "$dup_body"

create_order_body="$(curl -sS -X POST "${BASE_URL}/api/v1/orders" \
  -H 'content-type: application/json' \
  --data '{"customer":"acme","items":[{"sku":"SKU-1","qty":2},{"sku":"SKU-2","qty":1}]}')"
order_id="$(printf '%s' "$create_order_body" | extract_json_field "order.id")"
if [[ -z "$order_id" ]]; then
  echo "FAIL create order missing order.id"
  echo "$create_order_body"
  exit 1
fi

assert_status_and_contains GET "/api/v1/orders" "200" "${order_id}"
assert_status_and_contains GET "/api/v1/orders/${order_id}" "200" "${order_id}"

update_file="$(mktemp)"
update_code="$(curl -sS -X PUT -o "$update_file" -w '%{http_code}' "${BASE_URL}/api/v1/orders/${order_id}" \
  -H 'content-type: application/json' \
  --data '{"status":"shipped","tracking_number":"TRK-1001"}')"
if [[ "$update_code" != "200" ]]; then
  echo "FAIL PUT /api/v1/orders/${order_id} expected=200 got=$update_code"
  cat "$update_file" || true
  rm -f "$update_file"
  exit 1
fi
if ! grep -qiE '"status"\s*:\s*"shipped"' "$update_file"; then
  echo "FAIL order update missing shipped status"
  cat "$update_file" || true
  rm -f "$update_file"
  exit 1
fi
rm -f "$update_file"

job_create_body="$(curl -sS -X POST "${BASE_URL}/jobs/render-report" \
  -H 'content-type: application/json' \
  --data '{"report_type":"sales","items":[1,2,3,4]}')"
poll_url="$(printf '%s' "$job_create_body" | extract_json_field "poll_url")"
if [[ -z "$poll_url" ]]; then
  echo "FAIL jobs/render-report missing poll_url"
  echo "$job_create_body"
  exit 1
fi

assert_status_and_contains GET "$poll_url" "200" "queued\\|running"
sleep 3
assert_status_and_contains GET "$poll_url" "200" "succeeded"

echo "platform-equivalents integration checks passed"
