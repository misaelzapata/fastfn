#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${DOCS_SCREENSHOT_DIR:-$ROOT_DIR/docs/assets/screenshots}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
FN_ROOT="${FN_DOCS_FIXTURE_DIR:-$ROOT_DIR/tests/fixtures/nextstyle-clean}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command '$1' not found" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd node

mkdir -p "$OUT_DIR"

FASTFN_PID=""
cleanup() {
  if [[ -n "$FASTFN_PID" ]] && kill -0 "$FASTFN_PID" >/dev/null 2>&1; then
    kill "$FASTFN_PID" >/dev/null 2>&1 || true
    wait "$FASTFN_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

(
  cd "$ROOT_DIR"
  FN_UI_ENABLED=1 FN_CONSOLE_API_ENABLED=1 FN_CONSOLE_WRITE_ENABLED=1 ./bin/fastfn dev --build "$FN_ROOT" >/tmp/fastfn-docs-capture.log 2>&1
) &
FASTFN_PID="$!"

for _ in $(seq 1 120); do
  if curl -fsS "$BASE_URL/_fn/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "$BASE_URL/_fn/health" >/dev/null 2>&1; then
  echo "error: fastfn did not become healthy" >&2
  tail -n 200 /tmp/fastfn-docs-capture.log || true
  exit 1
fi

(
  cd "$ROOT_DIR"
  node scripts/docs/capture-ui.mjs
)

if command -v vhs >/dev/null 2>&1; then
  mkdir -p "$OUT_DIR"
  vhs "$ROOT_DIR/tests/manual/vhs/01-node-create-live.tape"
  vhs "$ROOT_DIR/tests/manual/vhs/04-python-create-live.tape"
  vhs "$ROOT_DIR/tests/manual/vhs/03-rust-health.tape"
else
  echo "warn: vhs not found; skipping terminal gif capture"
fi

(
  cd "$ROOT_DIR"
  python3 scripts/docs/visual_manifest.py update
)

echo "visual evidence generated in $OUT_DIR"
