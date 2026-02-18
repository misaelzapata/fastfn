#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/coverage}"
OUT_FILE="$OUT_DIR/go-cli-coverage.out"
OUT_TXT="$OUT_DIR/go-cli-coverage.txt"
MIN_GO="${COVERAGE_MIN_GO:-0}"

cd "$ROOT_DIR/cli"

# In some restricted environments (like sandboxes), the default Go cache path may be unwritable.
# Fall back to a temp cache only when needed (keeps CI/module caching behavior intact).
if [[ -z "${GOCACHE:-}" ]]; then
  default_cache="$(go env GOCACHE 2>/dev/null || true)"
  if [[ -n "$default_cache" && "$default_cache" != "off" ]]; then
    probe="$default_cache/.fastfn_write_probe_$$"
    if ! mkdir -p "$default_cache" 2>/dev/null || ! : 2>/dev/null >"$probe"; then
      export GOCACHE="${TMPDIR:-/tmp}/fastfn-gocache"
      mkdir -p "$GOCACHE"
    else
      rm -f "$probe" 2>/dev/null || true
    fi
  fi
fi

if [[ -z "${GOMODCACHE:-}" ]]; then
  default_modcache="$(go env GOMODCACHE 2>/dev/null || true)"
  if [[ -n "$default_modcache" ]]; then
    probe="$default_modcache/.fastfn_write_probe_$$"
    if ! mkdir -p "$default_modcache" 2>/dev/null || ! : 2>/dev/null >"$probe"; then
      export GOMODCACHE="${TMPDIR:-/tmp}/fastfn-gomodcache"
      mkdir -p "$GOMODCACHE"
    else
      rm -f "$probe" 2>/dev/null || true
    fi
  fi
fi

mkdir -p "$OUT_DIR"

echo "== go coverage (cli) =="
go test -covermode=atomic -coverprofile "$OUT_FILE" ./...
go tool cover -func "$OUT_FILE" | tee "$OUT_TXT" >/dev/null

total_line="$(tail -n 1 "$OUT_TXT" || true)"
if [[ "$total_line" != total:* ]]; then
  echo "error: unexpected go coverage output (missing total line): $total_line" >&2
  exit 1
fi

pct="$(awk '/^total:/ {print $3}' "$OUT_TXT" | tail -n 1 || true)"
if [[ -z "$pct" ]]; then
  echo "error: unable to parse go coverage percent" >&2
  exit 1
fi

echo "go cli total coverage: $pct"

if [[ "$MIN_GO" != "0" && "$MIN_GO" != "0.0" ]]; then
  pct_num="${pct%%%}"
  if awk -v pct="$pct_num" -v min="$MIN_GO" 'BEGIN{exit (pct < min) ? 0 : 1}'; then
    echo "error: go coverage below threshold: ${pct_num}% < ${MIN_GO}%" >&2
    exit 1
  fi
fi
