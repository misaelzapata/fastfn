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
CHECK_PY="$(cd "$(dirname "$0")" && pwd)/telegram_e2e_check.py"

if [[ -z "$CHAT_ID" ]]; then
  echo "CHAT_ID is required (example: CHAT_ID=123456789 $0)" >&2
  exit 2
fi

echo "Sending Telegram message via fastfn (telegram-send)..."
encoded_text="$(python3 "$CHECK_PY" encode --text "$TEXT")"
resp="$(curl -sS "${BASE_URL}/telegram-send?chat_id=${CHAT_ID}&text=${encoded_text}&dry_run=false")"
python3 "$CHECK_PY" validate --raw "$resp"
