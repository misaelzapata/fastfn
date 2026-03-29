#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-default}"          # default | no-throttle
TOTAL="${TOTAL:-160}"
CONCURRENCY_SET="${CONCURRENCY_SET:-1,2,4,6,8}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
AUTO_STACK="${AUTO_STACK:-1}" # 1 => docker compose up/down in this script
FIXTURE_ROOT="${FIXTURE_ROOT:-}" # optional explicit functions root for the benchmark

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_PY="$ROOT_DIR/scripts/ci/benchmark_qr.py"

if [[ "$MODE" != "default" && "$MODE" != "no-throttle" ]]; then
  echo "usage: $0 [default|no-throttle]"
  exit 1
fi

cleanup() {
  if [[ "$AUTO_STACK" == "1" ]]; then
    docker compose -f "$ROOT_DIR/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
  fi
  if [[ -n "${FIXTURE_ROOT:-}" && "${FIXTURE_ROOT}" == /tmp/fastfn-bench-qr-* ]]; then
    rm -rf "$FIXTURE_ROOT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "$AUTO_STACK" == "1" ]]; then
  if [[ -z "$FIXTURE_ROOT" ]]; then
    FIXTURE_ROOT="$(mktemp -d -t fastfn-bench-qr.XXXXXX)"
    mkdir -p "$FIXTURE_ROOT/.fastfn/packs/python" "$FIXTURE_ROOT/.fastfn/packs/node" "$FIXTURE_ROOT/python" "$FIXTURE_ROOT/node"

    # Only copy what this benchmark needs to keep fixture creation fast and deterministic.
    cp -R "$ROOT_DIR/examples/functions/python/pack-qr" "$FIXTURE_ROOT/python/"
    cp -R "$ROOT_DIR/examples/functions/node/pack-qr-node" "$FIXTURE_ROOT/node/"

    mkdir -p "$FIXTURE_ROOT/.fastfn/packs/python/qrcode_pack"
    cp "$ROOT_DIR/examples/functions/.fastfn/packs/python/qrcode_pack/requirements.txt" \
      "$FIXTURE_ROOT/.fastfn/packs/python/qrcode_pack/requirements.txt"

    mkdir -p "$FIXTURE_ROOT/.fastfn/packs/node/qrcode_pack"
    cp "$ROOT_DIR/examples/functions/.fastfn/packs/node/qrcode_pack/package.json" \
      "$FIXTURE_ROOT/.fastfn/packs/node/qrcode_pack/package.json"
    if [[ -f "$ROOT_DIR/examples/functions/.fastfn/packs/node/qrcode_pack/package-lock.json" ]]; then
      cp "$ROOT_DIR/examples/functions/.fastfn/packs/node/qrcode_pack/package-lock.json" \
        "$FIXTURE_ROOT/.fastfn/packs/node/qrcode_pack/package-lock.json"
    fi
  fi

  FN_FUNCTIONS_ROOT="$FIXTURE_ROOT" docker compose -f "$ROOT_DIR/docker-compose.yml" up -d --build >/dev/null
fi

python3 "$BENCH_PY" wait-health --base-url "$BASE_URL"

if [[ "$MODE" == "no-throttle" ]]; then
  curl -sS -X PUT "$BASE_URL/_fn/function-config?runtime=python&name=pack-qr" \
    -H 'Content-Type: application/json' \
    --data '{"max_concurrency":512,"timeout_ms":60000,"invoke":{"methods":["GET"]}}' >/dev/null

  curl -sS -X PUT "$BASE_URL/_fn/function-config?runtime=node&name=pack-qr-node" \
    -H 'Content-Type: application/json' \
    --data '{"max_concurrency":512,"timeout_ms":60000,"invoke":{"methods":["GET"]}}' >/dev/null
fi

python3 "$BENCH_PY" run \
  --base-url "$BASE_URL" \
  --mode "$MODE" \
  --total "$TOTAL" \
  --concurrency-set "$CONCURRENCY_SET" \
  --root-dir "$ROOT_DIR" \
  --endpoints "/pack-qr,/pack-qr-node"
