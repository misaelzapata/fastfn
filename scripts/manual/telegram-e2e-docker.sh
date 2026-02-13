#!/usr/bin/env bash
set -euo pipefail

# Manual E2E check (docker-only): host -> docker exec -> fastfn -> Telegram API -> your Telegram app.
#
# This avoids relying on host port mapping. It performs the HTTP request from inside the openresty container.
#
# Usage:
#   CHAT_ID=1160337817 TEXT="hello" ./scripts/manual/telegram-e2e-docker.sh
#
# Requirements:
# - docker compose is running (service: openresty)
# - TELEGRAM_BOT_TOKEN must be available to the container:
#   - either in srv/fn/functions/node/telegram_send/fn.env.json (recommended for non-dev)
#   - or via docker compose env var TELEGRAM_BOT_TOKEN (dev)

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BASE_URL_IN_CONTAINER="${BASE_URL_IN_CONTAINER:-http://127.0.0.1:8080}"
CHAT_ID="${CHAT_ID:-}"
TEXT="${TEXT:-hello from fastfn}"

if [[ -z "$CHAT_ID" ]]; then
  echo "CHAT_ID is required (example: CHAT_ID=1160337817 $0)" >&2
  exit 2
fi

encoded_text="$(
  TEXT="$TEXT" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ.get("TEXT","")))
PY
)"

url="${BASE_URL_IN_CONTAINER}/fn/telegram_send?chat_id=${CHAT_ID}&text=${encoded_text}&dry_run=false"

echo "Sending Telegram message via fastfn (inside container)..."
resp="$(
  docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T openresty sh -lc \
    "wget -qO- \"$url\""
)"

export RESP="$resp"
python3 - <<'PY'
import json, os, sys

raw = os.environ.get("RESP","")
try:
    obj = json.loads(raw)
except Exception as e:
    print("Bad JSON response:", e, file=sys.stderr)
    print(raw, file=sys.stderr)
    sys.exit(1)

if obj.get("dry_run") is True:
    print("fastfn returned dry_run=true; TELEGRAM_BOT_TOKEN is likely missing in the container.", file=sys.stderr)
    print(json.dumps(obj, indent=2), file=sys.stderr)
    sys.exit(1)

if obj.get("sent") is not True:
    print("fastfn did not confirm sent=true", file=sys.stderr)
    print(json.dumps(obj, indent=2), file=sys.stderr)
    sys.exit(1)

print("OK: telegram_send reports sent=true")
print(json.dumps(obj, indent=2))
PY

