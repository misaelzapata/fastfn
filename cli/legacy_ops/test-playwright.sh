#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fastfn_e2e_${RANDOM}_$$}"
DC=(docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.yml")

export FN_UI_ENABLED="${FN_UI_ENABLED:-1}"
export FN_CONSOLE_API_ENABLED="${FN_CONSOLE_API_ENABLED:-1}"
export FN_CONSOLE_WRITE_ENABLED="${FN_CONSOLE_WRITE_ENABLED:-1}"
export FN_CONSOLE_LOCAL_ONLY="${FN_CONSOLE_LOCAL_ONLY:-1}"
export FN_ADMIN_TOKEN="${FN_ADMIN_TOKEN:-test-admin-token}"
export BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"

cleanup() {
  "${DC[@]}" down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "$ROOT_DIR"

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to run Playwright tests"
  exit 1
fi

npm install --no-fund --no-audit
npx playwright install --with-deps chromium

"${DC[@]}" up -d --build >/dev/null

for _ in $(seq 1 60); do
  if curl -fsS "$BASE_URL/_fn/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

npm run test:e2e:ui
