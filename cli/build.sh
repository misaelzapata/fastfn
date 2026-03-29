#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="${GO_BIN:-}"

go_env() {
  env -u GOROOT -u GOPATH "$GO_BIN" "$@"
}

go_toolchain_sane() {
  local bin="$1"
  local goroot
  goroot="$(env -u GOROOT -u GOPATH "$bin" env GOROOT 2>/dev/null || true)"
  [[ -n "$goroot" && -f "$goroot/src/unsafe/unsafe.go" ]]
}

resolve_go_bin() {
  local candidate=""
  if [[ -n "$GO_BIN" ]]; then
    if ! go_toolchain_sane "$GO_BIN"; then
      echo "error: GO_BIN points to an invalid Go toolchain: $GO_BIN" >&2
      exit 1
    fi
    return
  fi

  if candidate="$(command -v go 2>/dev/null || true)" && [[ -n "$candidate" ]] && go_toolchain_sane "$candidate"; then
    GO_BIN="$candidate"
    return
  fi

  if [[ -x /usr/local/go/bin/go ]] && go_toolchain_sane /usr/local/go/bin/go; then
    GO_BIN="/usr/local/go/bin/go"
    return
  fi

  echo "error: unable to find a sane Go toolchain; fix PATH/GO_BIN or install Go under /usr/local/go/bin/go" >&2
  exit 1
}

resolve_go_bin

echo "Building fastfn CLI..."
echo "using go binary: $GO_BIN"
cd "$ROOT_DIR/cli"
go_env build -o ../bin/fastfn
echo "Built: $ROOT_DIR/bin/fastfn"
