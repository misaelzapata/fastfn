#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
TOTAL="${TOTAL:-400}"
CONCURRENCY="${CONCURRENCY:-40}"

echo "== stress: hello (expect 200 and possible 429 if concurrency exceeds policy) =="
python3 tests/stress/load-runner.py \
  --base-url "$BASE_URL" \
  --path '/hello?name=stress' \
  --total "$TOTAL" \
  --concurrency "$CONCURRENCY" \
  --expect 200 429

echo "== stress: slow (expect 200 and 429 under pressure) =="
python3 tests/stress/load-runner.py \
  --base-url "$BASE_URL" \
  --path '/slow?sleep_ms=120' \
  --total "$TOTAL" \
  --concurrency "$CONCURRENCY" \
  --expect 200 429

echo "stress tests completed"
