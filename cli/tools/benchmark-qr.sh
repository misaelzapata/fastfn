#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-default}"          # default | no-throttle
TOTAL="${TOTAL:-160}"
CONCURRENCY_SET="${CONCURRENCY_SET:-1,2,4,6,8}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
AUTO_STACK="${AUTO_STACK:-1}" # 1 => docker compose up/down in this script

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BENCH_PY="$ROOT_DIR/scripts/ci/benchmark_qr.py"

if [[ "$MODE" != "default" && "$MODE" != "no-throttle" ]]; then
  echo "usage: $0 [default|no-throttle]"
  exit 1
fi

cleanup() {
  if [[ "$AUTO_STACK" == "1" ]]; then
    docker compose -f "$ROOT_DIR/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "$AUTO_STACK" == "1" ]]; then
  docker compose -f "$ROOT_DIR/docker-compose.yml" up -d --build >/dev/null
fi

python3 "$BENCH_PY" wait-health --base-url "$BASE_URL"

if [[ "$MODE" == "no-throttle" ]]; then
  curl -sS -X PUT "$BASE_URL/_fn/function-config?runtime=python&name=qr" \
    -H 'Content-Type: application/json' \
    --data '{"max_concurrency":512,"timeout_ms":60000,"invoke":{"methods":["GET"]}}' >/dev/null

  curl -sS -X PUT "$BASE_URL/_fn/function-config?runtime=node&name=qr&version=v2" \
    -H 'Content-Type: application/json' \
    --data '{"max_concurrency":512,"timeout_ms":60000,"invoke":{"methods":["GET"]}}' >/dev/null
fi

python3 "$BENCH_PY" run \
  --base-url "$BASE_URL" \
  --mode "$MODE" \
  --total "$TOTAL" \
  --concurrency-set "$CONCURRENCY_SET" \
  --root-dir "$ROOT_DIR" \
  --endpoints "/qr,/qr@v2"
