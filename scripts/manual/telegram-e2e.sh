#!/usr/bin/env bash
set -euo pipefail

# Manual E2E check: fastfn -> telegram-send -> Telegram API -> your phone.
#
# Prereqs:
# - fastfn running on http://127.0.0.1:8080
# - TELEGRAM_BOT_TOKEN set in fn.env.json for node/telegram-send
# - you know your CHAT_ID (send /start to your bot, then getUpdates)
#
# Usage:
#   CHAT_ID=123456789 TEXT="hello" ./scripts/manual/telegram-e2e.sh
#
# This script does NOT write any secrets. It only calls the fastfn HTTP endpoint.

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
CHAT_ID="${CHAT_ID:-}"
TEXT="${TEXT:-hello from fastfn}"

if [[ -z "$CHAT_ID" ]]; then
  echo "CHAT_ID is required (example: CHAT_ID=123456789 $0)" >&2
  exit 2
fi

echo "Sending Telegram message via fastfn (telegram-send)..."
resp="$(curl -sS "${BASE_URL}/fn/telegram-send?chat_id=${CHAT_ID}&text=$(python3 - <<PY
import urllib.parse, os
print(urllib.parse.quote(os.environ.get("TEXT","")))
PY
)&dry_run=false")"

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
    print("fastfn returned dry_run=true; did you configure TELEGRAM_BOT_TOKEN in node/telegram-send/fn.env.json?", file=sys.stderr)
    print(json.dumps(obj, indent=2), file=sys.stderr)
    sys.exit(1)

if not obj.get("sent"):
    print("fastfn did not confirm sent=true", file=sys.stderr)
    print(json.dumps(obj, indent=2), file=sys.stderr)
    sys.exit(1)

print("OK: telegram-send reports sent=true")
print(json.dumps(obj, indent=2))
PY
