#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Building fastfn CLI..."
cd "$ROOT_DIR/cli"
go build -o ../bin/fastfn
echo "Built: $ROOT_DIR/bin/fastfn"
