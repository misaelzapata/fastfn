#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/coverage}"
PY_SOURCE_DIR="$ROOT_DIR/examples/functions/python"
PY_TEST_FILE="$ROOT_DIR/tests/unit/test-python-handlers.py"
NODE_TEST_FILE="$ROOT_DIR/tests/unit/test-node-handler.js"
MIN_PYTHON="${COVERAGE_MIN_PYTHON:-60}"
MIN_NODE="${COVERAGE_MIN_NODE:-65}"
MIN_COMBINED="${COVERAGE_MIN_COMBINED:-65}"
MIN_LUA="${COVERAGE_MIN_LUA:-0}"
ENFORCE_LUA="${COVERAGE_ENFORCE_LUA:-0}"

if [[ -n "${FORCE_COLOR:-}" && -n "${NO_COLOR:-}" ]]; then
  unset NO_COLOR
fi

# Run from cli/ to avoid shadowing installed python modules with repo root folders
# (for example, root-level ./coverage can shadow the coverage package).
cd "$ROOT_DIR/cli"
export PATH="$ROOT_DIR/node_modules/.bin:$PATH"

mkdir -p "$OUT_DIR/node"

if ! python3 -m coverage --version >/dev/null 2>&1; then
  echo "error: coverage.py is required (pip install coverage)" >&2
  exit 1
fi

C8_CMD=(c8)
if ! command -v c8 >/dev/null 2>&1; then
  C8_CMD=(npx --yes c8)
fi

echo "== python coverage =="
python3 -m coverage erase
python3 -m coverage run --branch --source="$PY_SOURCE_DIR" "$PY_TEST_FILE"
python3 -m coverage xml -o "$OUT_DIR/python-coverage.xml"
python3 -m coverage json -o "$OUT_DIR/python-coverage.json"
python3 -m coverage report > "$OUT_DIR/python-coverage.txt"

echo "== node coverage =="
rm -rf "$OUT_DIR/node"
mkdir -p "$OUT_DIR/node"
(
  cd "$ROOT_DIR"
  env -u NO_COLOR "${C8_CMD[@]}" --reporter=text --reporter=json-summary --reporter=lcov --report-dir "$OUT_DIR/node" \
    env -u NO_COLOR node "$NODE_TEST_FILE" > "$OUT_DIR/node-coverage.txt"
)

echo "== lua coverage =="
rm -rf "$OUT_DIR/lua"
mkdir -p "$OUT_DIR/lua"
if command -v docker >/dev/null 2>&1; then
  if ! LUA_COVERAGE=1 COVERAGE_DIR="$OUT_DIR/lua" "$ROOT_DIR/cli/test-lua.sh" > "$OUT_DIR/lua-coverage.txt" 2>&1; then
    echo "lua coverage failed; dumping logs:"
    cat "$OUT_DIR/lua-coverage.txt" || true
    exit 1
  fi
else
  echo "lua coverage skipped (docker not found)" | tee "$OUT_DIR/lua-coverage.txt"
fi

echo "== coverage summary =="
COVERAGE_ENFORCE_LUA="$ENFORCE_LUA" python3 - "$OUT_DIR" <<'PY'
import json
import os
import pathlib
import re
import sys

out_dir = pathlib.Path(sys.argv[1])

py = json.loads((out_dir / "python-coverage.json").read_text())
node = json.loads((out_dir / "node" / "coverage-summary.json").read_text())

py_totals = py.get("totals", {})
py_pct = float(py_totals.get("percent_covered", 0.0))
py_total = int(py_totals.get("num_statements", 0))
py_covered = int(py_totals.get("covered_lines", 0))

node_total_block = node.get("total", {}).get("lines", {})
node_pct_raw = node_total_block.get("pct", 0.0)
try:
    node_pct = float(node_pct_raw)
except (TypeError, ValueError):
    node_pct = 0.0
node_total = int(node_total_block.get("total", 0))
node_covered = int(node_total_block.get("covered", 0))

lua_report = out_dir / "lua" / "luacov.report.out"
lua_total = 0
lua_covered = 0
lua_pct = 0.0
lua_line = "- Lua lines: n/a (coverage report not available)"
if lua_report.exists():
    text = lua_report.read_text(encoding="utf-8", errors="ignore")
    match = None
    for line in reversed(text.splitlines()):
        m = re.search(r"^\s*Total\s+(\d+)\s+(\d+)\s+([0-9.]+)%\s*$", line)
        if m:
            match = m
            break
    if match:
        lua_covered = int(match.group(1))
        missed = int(match.group(2))
        lua_total = lua_covered + missed
        lua_pct = float(match.group(3))
        lua_line = f"- Lua lines: {lua_pct:.2f}% ({lua_covered}/{lua_total})"
    else:
        lua_line = "- Lua lines: n/a (unable to parse luacov summary)"

enforce_lua = str(os.environ.get("COVERAGE_ENFORCE_LUA", "0")).strip().lower() in {"1", "true", "yes", "on"}
include_lua_in_combined = enforce_lua and lua_total > 0
all_total = py_total + node_total + (lua_total if include_lua_in_combined else 0)
all_covered = py_covered + node_covered + (lua_covered if include_lua_in_combined else 0)
all_pct = (all_covered / all_total * 100.0) if all_total else 0.0
combined_scope = "python+node+lua" if include_lua_in_combined else "python+node"

summary = f"""# Coverage Summary

- Python lines: {py_pct:.2f}% ({py_covered}/{py_total})
- Node lines: {node_pct:.2f}% ({node_covered}/{node_total})
{lua_line}
- Combined lines ({combined_scope}): {all_pct:.2f}% ({all_covered}/{all_total})
- PHP lines: n/a (contract tests run in pipeline)
- Rust lines: n/a (contract tests run in pipeline)
"""
(out_dir / "summary.md").write_text(summary)
summary_json = {
    "python_pct": py_pct,
    "python_covered": py_covered,
    "python_total": py_total,
    "node_pct": node_pct,
    "node_covered": node_covered,
    "node_total": node_total,
    "lua_pct": lua_pct,
    "lua_covered": lua_covered,
    "lua_total": lua_total,
    "lua_available": lua_report.exists() and lua_total > 0,
    "combined_scope": combined_scope,
    "combined_pct": all_pct,
    "combined_covered": all_covered,
    "combined_total": all_total,
}
(out_dir / "summary.json").write_text(json.dumps(summary_json, indent=2))
print(summary)
PY

echo "== coverage gates =="
COVERAGE_MIN_PYTHON="$MIN_PYTHON" \
COVERAGE_MIN_NODE="$MIN_NODE" \
COVERAGE_MIN_COMBINED="$MIN_COMBINED" \
COVERAGE_MIN_LUA="$MIN_LUA" \
COVERAGE_ENFORCE_LUA="$ENFORCE_LUA" \
python3 - "$OUT_DIR" <<'PY'
import json
import os
import pathlib
import sys

out_dir = pathlib.Path(sys.argv[1])
summary = json.loads((out_dir / "summary.json").read_text())

min_python = float(os.environ["COVERAGE_MIN_PYTHON"])
min_node = float(os.environ["COVERAGE_MIN_NODE"])
min_combined = float(os.environ["COVERAGE_MIN_COMBINED"])
min_lua = float(os.environ["COVERAGE_MIN_LUA"])
enforce_lua = str(os.environ["COVERAGE_ENFORCE_LUA"]).strip().lower() in {"1", "true", "yes", "on"}

failures = []

if float(summary.get("python_pct", 0.0)) < min_python:
    failures.append(f"python coverage below threshold: {summary.get('python_pct', 0.0):.2f}% < {min_python:.2f}%")
if float(summary.get("node_pct", 0.0)) < min_node:
    failures.append(f"node coverage below threshold: {summary.get('node_pct', 0.0):.2f}% < {min_node:.2f}%")
if float(summary.get("combined_pct", 0.0)) < min_combined:
    failures.append(
        f"combined coverage below threshold: {summary.get('combined_pct', 0.0):.2f}% < {min_combined:.2f}%"
    )
if enforce_lua:
    if not bool(summary.get("lua_available", False)):
        failures.append("lua coverage required but unavailable")
    elif float(summary.get("lua_pct", 0.0)) < min_lua:
        failures.append(f"lua coverage below threshold: {summary.get('lua_pct', 0.0):.2f}% < {min_lua:.2f}%")

if failures:
    print("coverage gates failed:")
    for row in failures:
        print(f"- {row}")
    sys.exit(1)

print(
    "coverage gates passed: "
    f"python>={min_python:.2f} node>={min_node:.2f} combined>={min_combined:.2f}"
    + (f" lua>={min_lua:.2f}" if enforce_lua else " lua skipped")
)
PY
