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
#   - either in <FN_FUNCTIONS_ROOT>/node/telegram-send/fn.env.json (recommended for non-dev)
#   - or via docker compose env var TELEGRAM_BOT_TOKEN (dev)

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BASE_URL_IN_CONTAINER="${BASE_URL_IN_CONTAINER:-http://127.0.0.1:8080}"
CHAT_ID="${CHAT_ID:-}"
TEXT="${TEXT:-hello from fastfn}"
CHECK_PY="$ROOT_DIR/scripts/manual/telegram_e2e_check.py"

if [[ -z "$CHAT_ID" ]]; then
  echo "CHAT_ID is required (example: CHAT_ID=1160337817 $0)" >&2
  exit 2
fi

encoded_text="$(python3 "$CHECK_PY" encode --text "$TEXT")"

url="${BASE_URL_IN_CONTAINER}/telegram-send?chat_id=${CHAT_ID}&text=${encoded_text}&dry_run=false"

echo "Sending Telegram message via fastfn (inside container)..."
resp="$(
  docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T openresty sh -lc \
    "wget -qO- \"$url\""
)"

python3 "$CHECK_PY" validate --raw "$resp" --container-mode
