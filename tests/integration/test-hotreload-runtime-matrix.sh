#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-240}"
FN_HOST_PORT="${FN_HOST_PORT:-18088}"
KEEP_UP="${KEEP_UP:-0}"

STACK_PID=""
STACK_LOG=""
STACK_EXIT_FILE=""

cleanup() {
  if [[ -n "${STACK_PID:-}" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${STACK_EXIT_FILE:-}" ]]; then
    rm -f "$STACK_EXIT_FILE" >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_UP" != "1" ]]; then
    (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  fi
}

trap cleanup EXIT

wait_for_health() {
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    if [[ -n "${STACK_EXIT_FILE:-}" && -s "$STACK_EXIT_FILE" ]]; then
      echo "FAIL fastfn exited before health became ready"
      [[ -n "${STACK_LOG:-}" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
      exit 1
    fi
    if [[ -n "${STACK_PID:-}" ]] && ! kill -0 "$STACK_PID" >/dev/null 2>&1; then
      echo "FAIL fastfn exited before health became ready"
      [[ -n "${STACK_LOG:-}" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
      exit 1
    fi
    local code
    code="$(curl -sS -o /tmp/fastfn-hotreload-health.out -w '%{http_code}' "http://127.0.0.1:${FN_HOST_PORT}/_fn/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" != "1" ]]; then
    echo "FAIL health did not become ready"
    [[ -n "${STACK_LOG:-}" && -f "$STACK_LOG" ]] && tail -n 220 "$STACK_LOG" || true
    exit 1
  fi
}

wait_for_runtime_up() {
  local runtime="$1"
  local ready=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    local health_json
    health_json="$(curl -sS "http://127.0.0.1:${FN_HOST_PORT}/_fn/health" 2>/dev/null || true)"
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
    curl -sS "http://127.0.0.1:${FN_HOST_PORT}/_fn/health" || true
    exit 1
  fi
}

wait_for_openapi_path_state() {
  local path="$1"
  local want="$2" # present|absent
  local timeout="${3:-$WAIT_SECS}"
  local seen=0
  for _ in $(seq 1 "$timeout"); do
    local openapi_json
    openapi_json="$(curl -sS "http://127.0.0.1:${FN_HOST_PORT}/_fn/openapi.json" 2>/dev/null || true)"
    if OPENAPI_JSON="$openapi_json" TARGET_PATH="$path" WANT_STATE="$want" python3 - <<'PY' >/dev/null 2>&1
import json
import os

obj = json.loads(os.environ["OPENAPI_JSON"] or "{}")
paths = obj.get("paths") or {}
target = os.environ["TARGET_PATH"]
want = os.environ["WANT_STATE"]
present = target in paths
if (want == "present" and present) or (want == "absent" and (not present)):
    raise SystemExit(0)
raise SystemExit(1)
PY
    then
      seen=1
      break
    fi
    sleep 1
  done
  if [[ "$seen" != "1" ]]; then
    echo "FAIL openapi path state mismatch: path=$path want=$want"
    curl -sS "http://127.0.0.1:${FN_HOST_PORT}/_fn/openapi.json" || true
    exit 1
  fi
}

invoke_expect_runtime() {
  local path="$1"
  local runtime="$2"
  local code body
  body="/tmp/fastfn-hotreload-invoke-${runtime}.out"
  code="$(curl -sS -o "$body" -w '%{http_code}' "http://127.0.0.1:${FN_HOST_PORT}${path}" || true)"
  if [[ "$code" != "200" ]]; then
    echo "FAIL invoke status for ${path}: got=${code}"
    cat "$body" || true
    exit 1
  fi
  if ! grep -qi "\"runtime\"[[:space:]]*:[[:space:]]*\"${runtime}\"" "$body"; then
    echo "FAIL invoke body does not include runtime=${runtime} for ${path}"
    cat "$body" || true
    exit 1
  fi
}

write_runtime_function() {
  local root="$1"
  local runtime="$2"
  local name="$3"
  local dir="${root}/${runtime}/${name}"
  mkdir -p "$dir"
  case "$runtime" in
    node)
      cat >"${dir}/fn.config.json" <<JSON
{
  "runtime": "node",
  "name": "${name}",
  "entrypoint": "handler.js"
}
JSON
      cat >"${dir}/handler.js" <<'JS'
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ ok: true, runtime: "node" }),
});
JS
      ;;
    python)
      cat >"${dir}/fn.config.json" <<JSON
{
  "runtime": "python",
  "name": "${name}",
  "entrypoint": "main.py"
}
JSON
      cat >"${dir}/main.py" <<'PY'
import json

def handler(event):
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"ok": True, "runtime": "python"}),
    }
PY
      ;;
    php)
      cat >"${dir}/fn.config.json" <<JSON
{
  "runtime": "php",
  "name": "${name}",
  "entrypoint": "handler.php"
}
JSON
      cat >"${dir}/handler.php" <<'PHP'
<?php
function handler(array $event): array {
    return [
        "status" => 200,
        "headers" => ["Content-Type" => "application/json"],
        "body" => json_encode(["ok" => true, "runtime" => "php"]),
    ];
}
PHP
      ;;
    lua)
      cat >"${dir}/fn.config.json" <<JSON
{
  "runtime": "lua",
  "name": "${name}",
  "entrypoint": "handler.lua"
}
JSON
      cat >"${dir}/handler.lua" <<'LUA'
local cjson = require("cjson.safe")
function handler(event)
  return {
    status = 200,
    headers = { ["Content-Type"] = "application/json" },
    body = cjson.encode({ ok = true, runtime = "lua" }),
  }
end
LUA
      ;;
    *)
      echo "unsupported runtime: ${runtime}" >&2
      exit 1
      ;;
  esac
}

start_stack() {
  local functions_root="$1"
  local runtimes="$2"

  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true

  STACK_LOG="$(mktemp -t fastfn-hotreload-matrix.XXXXXX.log)"
  STACK_EXIT_FILE="$(mktemp -t fastfn-hotreload-matrix.exit.XXXXXX)"

  (
    cd "$ROOT_DIR"
    env \
      FN_HOST_PORT="$FN_HOST_PORT" \
      FN_RUNTIMES="$runtimes" \
      FN_UI_ENABLED=0 \
      FN_SCHEDULER_ENABLED=0 \
      FN_OPENAPI_INCLUDE_INTERNAL=0 \
      ./bin/fastfn dev --build "$functions_root" >"$STACK_LOG" 2>&1
    echo "$?" >"$STACK_EXIT_FILE"
  ) &
  STACK_PID="$!"

  wait_for_health
  IFS=',' read -r -a runtime_list <<<"$runtimes"
  for rt in "${runtime_list[@]}"; do
    wait_for_runtime_up "$rt"
  done
}

stop_stack() {
  if [[ -n "${STACK_PID:-}" ]] && kill -0 "$STACK_PID" >/dev/null 2>&1; then
    kill "$STACK_PID" >/dev/null 2>&1 || true
    wait "$STACK_PID" >/dev/null 2>&1 || true
  fi
  STACK_PID=""
  if [[ -n "${STACK_EXIT_FILE:-}" ]]; then
    rm -f "$STACK_EXIT_FILE" >/dev/null 2>&1 || true
    STACK_EXIT_FILE=""
  fi
  (cd "$ROOT_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
}

first_other_runtime() {
  local current="$1"
  for rt in node python php lua; do
    if [[ "$rt" != "$current" ]]; then
      echo "$rt"
      return 0
    fi
  done
  return 1
}

run_scenario() {
  local label="$1"
  local runtimes="$2"
  local tmp_root
  tmp_root="$(mktemp -d /tmp/fastfn-hotreload-matrix.XXXXXX)"
  echo "== Scenario ${label} (FN_RUNTIMES=${runtimes}) =="
  start_stack "$tmp_root" "$runtimes"

  local active=()
  if [[ "$label" == "all" ]]; then
    active=(node python php lua)
  else
    active=("$label")
  fi

  local last_rt=""
  local last_name=""
  for rt in "${active[@]}"; do
    local name="hot${label}${rt}"
    write_runtime_function "$tmp_root" "$rt" "$name"
    wait_for_openapi_path_state "/${name}" "present"
    invoke_expect_runtime "/${name}" "$rt"
    last_rt="$rt"
    last_name="$name"
  done

  if [[ "$label" != "all" ]]; then
    local disabled_rt
    disabled_rt="$(first_other_runtime "$label")"
    local disabled_name="hot${label}disabled${disabled_rt}"
    write_runtime_function "$tmp_root" "$disabled_rt" "$disabled_name"
    wait_for_openapi_path_state "/${disabled_name}" "absent" 8
  fi

  rm -rf "${tmp_root}/${last_rt}/${last_name}"
  wait_for_openapi_path_state "/${last_name}" "absent"

  stop_stack
  rm -rf "$tmp_root"
}

run_scenario "node" "node"
run_scenario "python" "python"
run_scenario "php" "php"
run_scenario "lua" "lua"
run_scenario "all" "node,python,php,lua"

echo "PASS hot-reload runtime matrix"
