#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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

echo "== go tests (cli) =="
go test -v ./...
