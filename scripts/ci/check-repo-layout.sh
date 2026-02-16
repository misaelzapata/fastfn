#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0

require_dir() {
  path="$1"
  if [ ! -d "$ROOT_DIR/$path" ]; then
    echo "[layout] missing required directory: $path" >&2
    fail=1
  fi
}

forbid_path() {
  path="$1"
  if [ -e "$ROOT_DIR/$path" ]; then
    echo "[layout] forbidden top-level path present: $path" >&2
    fail=1
  fi
}

require_dir "docs"
require_dir "examples"
require_dir "tests"
require_dir "docs/overrides"
require_dir "tests/results"

forbid_path "test"
forbid_path "test-integration"
forbid_path "test-results"
forbid_path "docs_overrides"
forbid_path "verify.sh"
forbid_path "debug_logs.txt"
forbid_path "my-test-function"

tmp_compose_files="$(find "$ROOT_DIR" -maxdepth 1 -type f -name 'fastfn-compose-*.yml' 2>/dev/null || true)"
if [ -n "$tmp_compose_files" ]; then
  echo "[layout] forbidden temporary compose files in repo root:" >&2
  echo "$tmp_compose_files" >&2
  fail=1
fi

runtime_underscores="$(find "$ROOT_DIR/srv/fn/runtimes" "$ROOT_DIR/cli/embed/runtime/srv/fn/runtimes" -maxdepth 1 -type f -name '*_*' 2>/dev/null || true)"
if [ -n "$runtime_underscores" ]; then
  echo "[layout] runtime filenames must use kebab-case (no underscores):" >&2
  echo "$runtime_underscores" >&2
  fail=1
fi

if git -C "$ROOT_DIR" ls-files --error-unmatch bin/fastfn >/dev/null 2>&1; then
  echo "[layout] bin/fastfn must not be tracked (build artifact)" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "[layout] repository layout check passed"
