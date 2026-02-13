#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/coverage}"

mkdir -p "$OUT_DIR/node"

if ! python3 -m coverage --version >/dev/null 2>&1; then
  echo "error: coverage.py is required (pip install coverage)" >&2
  exit 1
fi

C8_BIN="c8"
if ! command -v c8 >/dev/null 2>&1; then
  C8_BIN="npx --yes c8"
fi

echo "== python coverage =="
python3 -m coverage erase
python3 -m coverage run --branch --source=srv/fn/functions/python tests/unit/test_python_handlers.py
python3 -m coverage xml -o "$OUT_DIR/python-coverage.xml"
python3 -m coverage json -o "$OUT_DIR/python-coverage.json"
python3 -m coverage report > "$OUT_DIR/python-coverage.txt"

echo "== node coverage =="
rm -rf "$OUT_DIR/node"
mkdir -p "$OUT_DIR/node"
${C8_BIN} --reporter=text --reporter=json-summary --reporter=lcov --report-dir "$OUT_DIR/node" \
  node tests/unit/test_node_handler.js > "$OUT_DIR/node-coverage.txt"

echo "== coverage summary =="
python3 - "$OUT_DIR" <<'PY'
import json
import pathlib
import sys

out_dir = pathlib.Path(sys.argv[1])

py = json.loads((out_dir / "python-coverage.json").read_text())
node = json.loads((out_dir / "node" / "coverage-summary.json").read_text())

py_totals = py.get("totals", {})
py_pct = float(py_totals.get("percent_covered", 0.0))
py_total = int(py_totals.get("num_statements", 0))
py_covered = int(py_totals.get("covered_lines", 0))

node_total_block = node.get("total", {}).get("lines", {})
node_pct = float(node_total_block.get("pct", 0.0))
node_total = int(node_total_block.get("total", 0))
node_covered = int(node_total_block.get("covered", 0))

all_total = py_total + node_total
all_covered = py_covered + node_covered
all_pct = (all_covered / all_total * 100.0) if all_total else 0.0

summary = f"""# Coverage Summary

- Python lines: {py_pct:.2f}% ({py_covered}/{py_total})
- Node lines: {node_pct:.2f}% ({node_covered}/{node_total})
- Combined lines: {all_pct:.2f}% ({all_covered}/{all_total})
"""
(out_dir / "summary.md").write_text(summary)
print(summary)
PY
