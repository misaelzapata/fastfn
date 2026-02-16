#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WAIT_SECS="${WAIT_SECS:-120}"
PORT="${ASSISTANT_LIVE_PORT:-18120}"
BASE_URL="${ASSISTANT_LIVE_BASE_URL:-http://127.0.0.1:${PORT}}"
TARGET_DIR="${ASSISTANT_LIVE_TARGET:-examples/functions/next-style}"
LOG_FILE="${ASSISTANT_LIVE_LOG:-/tmp/fastfn-assistant-live.log}"
PROJECT_NAME="${ASSISTANT_LIVE_PROJECT:-fastfn-assistant-live-${RANDOM}-$$}"
REQUEST_PROVIDER="${1:-auto}"

FASTFN_PID=""
FN_NAME="assistant-live-$(date +%s)"
RUN_MODE="docker"

has_openai_key=0
has_claude_key=0
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  has_openai_key=1
fi
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  has_claude_key=1
fi

provider="$REQUEST_PROVIDER"
if [[ "$provider" == "auto" ]]; then
  if [[ "$has_openai_key" -eq 1 ]]; then
    provider="openai"
  elif [[ "$has_claude_key" -eq 1 ]]; then
    provider="claude"
  else
    echo "SKIP assistant live test: no OPENAI_API_KEY or ANTHROPIC_API_KEY configured"
    exit 0
  fi
fi

if [[ "$provider" == "openai" && "$has_openai_key" -ne 1 ]]; then
  echo "SKIP assistant live test: provider=openai but OPENAI_API_KEY is not configured"
  exit 0
fi
if [[ "$provider" == "claude" && "$has_claude_key" -ne 1 ]]; then
  echo "SKIP assistant live test: provider=claude but ANTHROPIC_API_KEY is not configured"
  exit 0
fi
if [[ "$provider" != "openai" && "$provider" != "claude" ]]; then
  echo "FAIL unsupported provider: $provider"
  exit 1
fi

cleanup() {
  curl -sS -X DELETE "${BASE_URL}/_fn/function?runtime=node&name=${FN_NAME}" >/dev/null 2>&1 || true
  if [[ -n "$FASTFN_PID" ]] && kill -0 "$FASTFN_PID" >/dev/null 2>&1; then
    kill "$FASTFN_PID" >/dev/null 2>&1 || true
    wait "$FASTFN_PID" >/dev/null 2>&1 || true
  fi
  (cd "$ROOT_DIR" && COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose down --remove-orphans >/dev/null 2>&1) || true
}
trap cleanup EXIT INT TERM

(cd "$ROOT_DIR" && COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose down --remove-orphans >/dev/null 2>&1) || true

forced_mode="${ASSISTANT_LIVE_MODE:-auto}"
if [[ "$forced_mode" == "native" ]]; then
  RUN_MODE="native"
elif [[ "$forced_mode" == "docker" ]]; then
  RUN_MODE="docker"
elif ! docker info >/dev/null 2>&1; then
  RUN_MODE="native"
fi

echo "assistant live smoke mode: ${RUN_MODE} (provider=${provider})"

(
  cd "$ROOT_DIR"
  if [[ "$RUN_MODE" == "native" ]]; then
    FN_UI_ENABLED=1 \
    FN_CONSOLE_API_ENABLED=1 \
    FN_CONSOLE_WRITE_ENABLED=1 \
    FN_ADMIN_API_ENABLED=1 \
    FN_ASSISTANT_ENABLED=1 \
    FN_ASSISTANT_PROVIDER="$provider" \
    FN_HOST_PORT="$PORT" \
    ./bin/fastfn dev --native "$TARGET_DIR" >"$LOG_FILE" 2>&1
  else
    FN_UI_ENABLED=1 \
    FN_CONSOLE_API_ENABLED=1 \
    FN_CONSOLE_WRITE_ENABLED=1 \
    FN_ADMIN_API_ENABLED=1 \
    FN_ASSISTANT_ENABLED=1 \
    FN_ASSISTANT_PROVIDER="$provider" \
    FN_HOST_PORT="$PORT" \
    COMPOSE_PROJECT_NAME="$PROJECT_NAME" \
    ./bin/fastfn dev "$TARGET_DIR" >"$LOG_FILE" 2>&1
  fi
) &
FASTFN_PID="$!"

for _ in $(seq 1 "$WAIT_SECS"); do
  if ! kill -0 "$FASTFN_PID" >/dev/null 2>&1; then
    echo "FAIL fastfn dev exited before health became ready"
    tail -n 200 "$LOG_FILE" || true
    exit 1
  fi
  if curl -sS -o /dev/null "${BASE_URL}/_fn/health"; then
    break
  fi
  sleep 1
done

if ! curl -sS -o /dev/null "${BASE_URL}/_fn/health"; then
  echo "FAIL health did not become ready at ${BASE_URL}"
  tail -n 200 "$LOG_FILE" || true
  exit 1
fi

status_json="$(curl -sS "${BASE_URL}/_fn/assistant/status")"
STATUS_JSON="$status_json" python3 - "$provider" <<'PY'
import json
import os
import sys

expected = sys.argv[1]
obj = json.loads(os.environ.get("STATUS_JSON", "{}") or "{}")
if obj.get("enabled") is not True:
    raise SystemExit(f"assistant not enabled: {obj}")
if obj.get("provider") != expected:
    raise SystemExit(f"assistant provider mismatch expected={expected} got={obj.get('provider')} payload={obj}")
if expected == "openai" and obj.get("openai_key_configured") is not True:
    raise SystemExit(f"openai key not configured according to status endpoint: {obj}")
if expected == "claude" and obj.get("anthropic_key_configured") is not True:
    raise SystemExit(f"anthropic key not configured according to status endpoint: {obj}")
PY

gen_payload="$(python3 - "$FN_NAME" "$provider" <<'PY'
import json
import sys

name = sys.argv[1]
provider = sys.argv[2]
prompt = (
    "Return ONLY JavaScript code (no markdown). "
    "Implement exports.handler async function. "
    "It must return status 200 with Content-Type application/json and body JSON.stringify(...) "
    f"containing ok=true, function='{name}', provider='{provider}', "
    "and echo=(event.query && event.query.name) || 'World'."
)
print(json.dumps({
    "runtime": "node",
    "name": name,
    "template": "hello_json",
    "mode": "generate",
    "prompt": prompt,
    "timeout_ms": 12000,
}))
PY
)"

gen_code_file="/tmp/assistant-live-generate-${RANDOM}-$$.json"
gen_status="$(curl -sS -o "$gen_code_file" -w '%{http_code}' -X POST "${BASE_URL}/_fn/assistant/generate" -H 'Content-Type: application/json' --data "$gen_payload")"
if [[ "$gen_status" != "200" ]]; then
  echo "FAIL assistant generate expected=200 got=$gen_status"
  cat "$gen_code_file" || true
  tail -n 200 "$LOG_FILE" || true
  exit 1
fi

generated_code="$(python3 - "$gen_code_file" <<'PY'
import json
import sys

path = sys.argv[1]
obj = json.load(open(path, "r", encoding="utf-8"))
code = obj.get("code")
if not isinstance(code, str) or not code.strip():
    raise SystemExit(f"assistant returned empty code: {obj}")
if "handler" not in code:
    raise SystemExit(f"assistant code missing handler symbol: {code[:220]}")
print(code)
PY
)"

create_payload="$(CODE="$generated_code" python3 - "$FN_NAME" <<'PY'
import json
import os
import sys

name = sys.argv[1]
code = os.environ.get("CODE", "")
print(json.dumps({
    "summary": "assistant live generated",
    "methods": ["GET", "POST"],
    "query_example": {"name": "Live"},
    "body_example": "",
    "code": code,
}))
PY
)"

create_status="$(curl -sS -o /tmp/assistant-live-create.json -w '%{http_code}' -X POST "${BASE_URL}/_fn/function?runtime=node&name=${FN_NAME}" -H 'Content-Type: application/json' --data "$create_payload")"
if [[ "$create_status" != "201" ]]; then
  echo "FAIL create function expected=201 got=$create_status"
  cat /tmp/assistant-live-create.json || true
  tail -n 200 "$LOG_FILE" || true
  exit 1
fi

cfg_payload="$(python3 - "$FN_NAME" <<'PY'
import json
import sys

name = sys.argv[1]
print(json.dumps({
    "invoke": {
        "methods": ["GET", "POST"],
        "routes": [f"/{name}"],
        "summary": "assistant live route",
    }
}))
PY
)"

cfg_status="$(curl -sS -o /tmp/assistant-live-config.json -w '%{http_code}' -X PUT "${BASE_URL}/_fn/function-config?runtime=node&name=${FN_NAME}" -H 'Content-Type: application/json' --data "$cfg_payload")"
if [[ "$cfg_status" != "200" ]]; then
  echo "FAIL configure function expected=200 got=$cfg_status"
  cat /tmp/assistant-live-config.json || true
  tail -n 200 "$LOG_FILE" || true
  exit 1
fi

reload_status="$(curl -sS -o /tmp/assistant-live-reload.json -w '%{http_code}' -X POST "${BASE_URL}/_fn/reload")"
if [[ "$reload_status" != "200" ]]; then
  echo "FAIL reload expected=200 got=$reload_status"
  cat /tmp/assistant-live-reload.json || true
  exit 1
fi

route_status="$(curl -sS -o /tmp/assistant-live-route.json -w '%{http_code}' "${BASE_URL}/${FN_NAME}?name=Live")"
if [[ "$route_status" != "200" ]]; then
  echo "FAIL route invoke expected=200 got=$route_status"
  cat /tmp/assistant-live-route.json || true
  tail -n 200 "$LOG_FILE" || true
  exit 1
fi

ROUTE_JSON="$(cat /tmp/assistant-live-route.json)"
ROUTE_JSON="$ROUTE_JSON" python3 - "$FN_NAME" "$provider" <<'PY'
import json
import os
import sys

name = sys.argv[1]
provider = sys.argv[2]
obj = json.loads(os.environ.get("ROUTE_JSON", "{}") or "{}")
if obj.get("ok") is not True:
    raise SystemExit(f"expected ok=true from generated route, got {obj}")
if obj.get("function") != name:
    raise SystemExit(f"function mismatch expected={name} got={obj.get('function')} payload={obj}")
if obj.get("provider") != provider:
    raise SystemExit(f"provider mismatch expected={provider} got={obj.get('provider')} payload={obj}")
PY

echo "PASS assistant live provider smoke (${provider})"
