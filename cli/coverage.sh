#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/coverage}"
PY_SOURCE_DIR="$ROOT_DIR/examples/functions/python"
PY_TEST_FILE="$ROOT_DIR/tests/unit/test-python-handlers.py"
NODE_TEST_FILE="$ROOT_DIR/tests/unit/test-node-handler.js"
PHP_RUNTIME_TEST_FILE="$ROOT_DIR/tests/unit/test-php-daemon.py"
RUST_RUNTIME_TEST_FILE="$ROOT_DIR/tests/unit/test-rust-daemon.py"
RUST_HANDLER_TEST_FILE="$ROOT_DIR/tests/unit/test-rust-handler.py"
# Large end-to-end demos are validated via integration scripts, not unit coverage gates.
PY_COVERAGE_OMIT="${PY_COVERAGE_OMIT:-$ROOT_DIR/examples/functions/python/telegram-ai-reply-py/app.py}"
MIN_PYTHON="${COVERAGE_MIN_PYTHON:-100}"
MIN_PYTHON_FILE="${COVERAGE_MIN_PYTHON_FILE:-$MIN_PYTHON}"
MIN_NODE="${COVERAGE_MIN_NODE:-100}"
MIN_NODE_FILE="${COVERAGE_MIN_NODE_FILE:-$MIN_NODE}"
MIN_COMBINED="${COVERAGE_MIN_COMBINED:-100}"
MIN_LUA="${COVERAGE_MIN_LUA:-100}"
MIN_LUA_FILE="${COVERAGE_MIN_LUA_FILE:-$MIN_LUA}"
MIN_PHP="${COVERAGE_MIN_PHP:-100}"
MIN_PHP_FILE="${COVERAGE_MIN_PHP_FILE:-$MIN_PHP}"
MIN_RUST="${COVERAGE_MIN_RUST:-100}"
MIN_RUST_FILE="${COVERAGE_MIN_RUST_FILE:-$MIN_RUST}"
ENFORCE_LUA="${COVERAGE_ENFORCE_LUA:-1}"
ENFORCE_LUA_PER_FILE="${COVERAGE_ENFORCE_LUA_PER_FILE:-1}"

if [[ -n "${FORCE_COLOR:-}" && -n "${NO_COLOR:-}" ]]; then
  unset NO_COLOR
fi

# Run from cli/ to avoid shadowing installed python modules with repo root folders
# (for example, root-level ./coverage can shadow the coverage package).
cd "$ROOT_DIR/cli"
export PATH="$ROOT_DIR/node_modules/.bin:$PATH"

mkdir -p "$OUT_DIR/node"

echo "== hygiene checks =="
if rg -n "(__private|FASTFN_EXPOSE_INTERNALS)" "$ROOT_DIR/examples/functions/node" >/dev/null 2>&1; then
  echo "error: internal exports are forbidden in examples/functions/node" >&2
  rg -n "(__private|FASTFN_EXPOSE_INTERNALS)" "$ROOT_DIR/examples/functions/node" >&2 || true
  exit 1
fi

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
python3 -m coverage run --branch --source="$PY_SOURCE_DIR" --omit="$PY_COVERAGE_OMIT" "$PY_TEST_FILE"
python3 -m coverage xml --omit="$PY_COVERAGE_OMIT" -o "$OUT_DIR/python-coverage.xml"
python3 -m coverage json --omit="$PY_COVERAGE_OMIT" -o "$OUT_DIR/python-coverage.json"
python3 -m coverage report --omit="$PY_COVERAGE_OMIT" > "$OUT_DIR/python-coverage.txt"

echo "== node coverage =="
rm -rf "$OUT_DIR/node"
mkdir -p "$OUT_DIR/node"
(
  cd "$ROOT_DIR"
  echo "[node] running unit tests with c8..."
  export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096}"
  env -u NO_COLOR "${C8_CMD[@]}" --reporter=text --reporter=json-summary --reporter=lcov --report-dir "$OUT_DIR/node" \
    env -u NO_COLOR node "$NODE_TEST_FILE" 2>&1 | tee "$OUT_DIR/node-coverage.txt"
)

echo "== lua coverage =="
rm -rf "$OUT_DIR/lua"
mkdir -p "$OUT_DIR/lua"
if command -v docker >/dev/null 2>&1; then
  echo "[lua] running Lua coverage suite via Docker..."
  if ! LUA_COVERAGE=1 COVERAGE_DIR="$OUT_DIR/lua" "$ROOT_DIR/cli/test-lua.sh" 2>&1 | tee "$OUT_DIR/lua-coverage.txt"; then
    echo "lua coverage failed; see $OUT_DIR/lua-coverage.txt" >&2
    exit 1
  fi
else
  echo "lua coverage skipped (docker not found)" | tee "$OUT_DIR/lua-coverage.txt"
fi

# Convert luacov text report to lcov so Codecov can ingest Lua line coverage.
python3 - "$OUT_DIR/lua/luacov.report.out" "$OUT_DIR/lua/lcov.info" "$ROOT_DIR" <<'PY'
from __future__ import annotations

import pathlib
import re
import sys

report_path = pathlib.Path(sys.argv[1])
lcov_path = pathlib.Path(sys.argv[2])
root_dir = pathlib.Path(sys.argv[3]).resolve()

if not report_path.exists():
    lcov_path.write_text("")
    print("lua lcov export skipped (luacov report not found)")
    raise SystemExit(0)

separator_re = re.compile(r"^=+$")
count_re = re.compile(r"^\s*(\*{7}0|\d+)\s")

state = "idle"  # idle -> await_path -> await_code -> in_file
pending_path: str | None = None
current_path: str | None = None
line_no = 0
entries: dict[str, list[tuple[int, int]]] = {}


def normalize_path(raw_path: str) -> str:
    raw = raw_path.strip()
    if raw.startswith("/app/"):
        return raw[len("/app/") :]
    try:
        resolved = pathlib.Path(raw).resolve()
        return str(resolved.relative_to(root_dir)).replace("\\", "/")
    except Exception:
        return raw.lstrip("/")


for raw_line in report_path.read_text(encoding="utf-8", errors="ignore").splitlines():
    line = raw_line.rstrip("\n")

    if separator_re.match(line):
        if state == "idle":
            state = "await_path"
        elif state == "await_code":
            if pending_path:
                current_path = pending_path
                entries.setdefault(current_path, [])
                line_no = 0
                pending_path = None
                state = "in_file"
            else:
                state = "await_path"
        elif state == "in_file":
            current_path = None
            line_no = 0
            state = "await_path"
        else:
            state = "await_path"
        continue

    if state == "await_path":
        stripped = line.strip()
        if not stripped:
            continue
        if stripped == "Summary":
            break
        if stripped.startswith("/") and stripped.endswith(".lua"):
            pending_path = normalize_path(stripped)
            state = "await_code"
        continue

    if state != "in_file" or not current_path:
        continue

    line_no += 1
    m = count_re.match(line)
    if not m:
        continue
    token = m.group(1)
    hits = 0 if token.startswith("*") else int(token)
    entries[current_path].append((line_no, hits))

records: list[str] = []
file_count = 0
for file_path in sorted(entries.keys()):
    line_hits = entries[file_path]
    if not line_hits:
        continue
    file_count += 1
    covered = sum(1 for _, h in line_hits if h > 0)
    records.append("TN:")
    records.append(f"SF:{file_path}")
    for ln, hits in line_hits:
        records.append(f"DA:{ln},{hits}")
    records.append(f"LF:{len(line_hits)}")
    records.append(f"LH:{covered}")
    records.append("end_of_record")

lcov_text = ("\n".join(records) + "\n") if records else ""
lcov_path.write_text(lcov_text)
print(f"lua lcov export: files={file_count} path={lcov_path}")
PY

echo "== php runtime coverage =="
python3 -m coverage erase
python3 -m coverage run --branch --source="$ROOT_DIR/srv/fn/runtimes" "$PHP_RUNTIME_TEST_FILE"
python3 -m coverage xml --include="$ROOT_DIR/srv/fn/runtimes/php-daemon.py" -o "$OUT_DIR/php-runtime-coverage.xml"
python3 -m coverage json --include="$ROOT_DIR/srv/fn/runtimes/php-daemon.py" -o "$OUT_DIR/php-runtime-coverage.json"
python3 -m coverage report --include="$ROOT_DIR/srv/fn/runtimes/php-daemon.py" > "$OUT_DIR/php-runtime-coverage.txt"

echo "== rust runtime coverage =="
python3 -m coverage erase
python3 -m coverage run --branch --source="$ROOT_DIR/srv/fn/runtimes" "$RUST_RUNTIME_TEST_FILE"
if [[ -f "$RUST_HANDLER_TEST_FILE" ]] && command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
  python3 -m coverage run -a --branch --source="$ROOT_DIR/srv/fn/runtimes" "$RUST_HANDLER_TEST_FILE"
fi
python3 -m coverage xml --include="$ROOT_DIR/srv/fn/runtimes/rust-daemon.py" -o "$OUT_DIR/rust-runtime-coverage.xml"
python3 -m coverage json --include="$ROOT_DIR/srv/fn/runtimes/rust-daemon.py" -o "$OUT_DIR/rust-runtime-coverage.json"
python3 -m coverage report --include="$ROOT_DIR/srv/fn/runtimes/rust-daemon.py" > "$OUT_DIR/rust-runtime-coverage.txt"

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

def parse_runtime_file_coverage(json_path: pathlib.Path, file_suffix: str):
    if not json_path.exists():
        return 0.0, 0, 0, False
    data = json.loads(json_path.read_text())
    files = data.get("files", {})
    for fp, payload in files.items():
        if str(fp).replace("\\", "/").endswith(file_suffix):
            summary = payload.get("summary", {})
            total = int(summary.get("num_statements", 0))
            covered = int(summary.get("covered_lines", 0))
            pct = (covered / total * 100.0) if total else 0.0
            return pct, covered, total, total > 0
    return 0.0, 0, 0, False

php_pct, php_covered, php_total, php_available = parse_runtime_file_coverage(
    out_dir / "php-runtime-coverage.json",
    "/srv/fn/runtimes/php-daemon.py",
)
rust_pct, rust_covered, rust_total, rust_available = parse_runtime_file_coverage(
    out_dir / "rust-runtime-coverage.json",
    "/srv/fn/runtimes/rust-daemon.py",
)

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
all_total = py_total + node_total + (lua_total if include_lua_in_combined else 0) + php_total + rust_total
all_covered = py_covered + node_covered + (lua_covered if include_lua_in_combined else 0) + php_covered + rust_covered
all_pct = (all_covered / all_total * 100.0) if all_total else 0.0
combined_scope = "python+node+lua+php+rust" if include_lua_in_combined else "python+node+php+rust"

php_line = (
    f"- PHP lines: {php_pct:.2f}% ({php_covered}/{php_total})"
    if php_available
    else "- PHP lines: n/a (runtime coverage report not available)"
)
rust_line = (
    f"- Rust lines: {rust_pct:.2f}% ({rust_covered}/{rust_total})"
    if rust_available
    else "- Rust lines: n/a (runtime coverage report not available)"
)

summary = f"""# Coverage Summary

- Python lines: {py_pct:.2f}% ({py_covered}/{py_total})
- Node lines: {node_pct:.2f}% ({node_covered}/{node_total})
{lua_line}
{php_line}
{rust_line}
- Combined lines ({combined_scope}): {all_pct:.2f}% ({all_covered}/{all_total})
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
    "php_pct": php_pct,
    "php_covered": php_covered,
    "php_total": php_total,
    "php_available": php_available,
    "rust_pct": rust_pct,
    "rust_covered": rust_covered,
    "rust_total": rust_total,
    "rust_available": rust_available,
    "combined_scope": combined_scope,
    "combined_pct": all_pct,
    "combined_covered": all_covered,
    "combined_total": all_total,
}
(out_dir / "summary.json").write_text(json.dumps(summary_json, indent=2))
print(summary)
PY

echo "== coverage gates =="
python3 "$ROOT_DIR/scripts/ci/check_line_coverage.py" \
  --format coveragepy \
  --input "$OUT_DIR/python-coverage.json" \
  --min-total "$MIN_PYTHON" \
  --min-file "$MIN_PYTHON_FILE" \
  --include-prefix "$PY_SOURCE_DIR/" \
  --output-json "$OUT_DIR/python-coverage-by-file.json"

python3 "$ROOT_DIR/scripts/ci/check_line_coverage.py" \
  --format c8 \
  --input "$OUT_DIR/node/coverage-summary.json" \
  --min-total "$MIN_NODE" \
  --min-file "$MIN_NODE_FILE" \
  --include-prefix "$ROOT_DIR/examples/functions/" \
  --output-json "$OUT_DIR/node/coverage-by-file.json"

python3 "$ROOT_DIR/scripts/ci/check_line_coverage.py" \
  --format coveragepy \
  --input "$OUT_DIR/php-runtime-coverage.json" \
  --min-total "$MIN_PHP" \
  --min-file "$MIN_PHP_FILE" \
  --include-suffix "/srv/fn/runtimes/php-daemon.py" \
  --output-json "$OUT_DIR/php-runtime-coverage-by-file.json"

python3 "$ROOT_DIR/scripts/ci/check_line_coverage.py" \
  --format coveragepy \
  --input "$OUT_DIR/rust-runtime-coverage.json" \
  --min-total "$MIN_RUST" \
  --min-file "$MIN_RUST_FILE" \
  --include-suffix "/srv/fn/runtimes/rust-daemon.py" \
  --output-json "$OUT_DIR/rust-runtime-coverage-by-file.json"

if [[ "$ENFORCE_LUA_PER_FILE" == "1" || "$MIN_LUA_FILE" != "0" || "$MIN_LUA" != "0" ]]; then
  if [[ -f "$OUT_DIR/lua/luacov.report.out" ]]; then
    python3 "$ROOT_DIR/scripts/ci/check_lua_coverage.py" \
      --report "$OUT_DIR/lua/luacov.report.out" \
      --min-total "$MIN_LUA" \
      --min-file "$MIN_LUA_FILE" \
      --output-json "$OUT_DIR/lua/coverage-by-file.json"
  elif [[ "$ENFORCE_LUA" == "1" || "$ENFORCE_LUA_PER_FILE" == "1" ]]; then
    echo "error: lua coverage report required but not found" >&2
    exit 1
  fi
fi

COVERAGE_MIN_PYTHON="$MIN_PYTHON" \
COVERAGE_MIN_NODE="$MIN_NODE" \
COVERAGE_MIN_COMBINED="$MIN_COMBINED" \
COVERAGE_MIN_LUA="$MIN_LUA" \
COVERAGE_MIN_PHP="$MIN_PHP" \
COVERAGE_MIN_RUST="$MIN_RUST" \
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
min_php = float(os.environ["COVERAGE_MIN_PHP"])
min_rust = float(os.environ["COVERAGE_MIN_RUST"])
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

if min_php > 0:
    if not bool(summary.get("php_available", False)):
        failures.append("php coverage required but unavailable")
    elif float(summary.get("php_pct", 0.0)) < min_php:
        failures.append(f"php coverage below threshold: {summary.get('php_pct', 0.0):.2f}% < {min_php:.2f}%")

if min_rust > 0:
    if not bool(summary.get("rust_available", False)):
        failures.append("rust coverage required but unavailable")
    elif float(summary.get("rust_pct", 0.0)) < min_rust:
        failures.append(f"rust coverage below threshold: {summary.get('rust_pct', 0.0):.2f}% < {min_rust:.2f}%")

if failures:
    print("coverage gates failed:")
    for row in failures:
        print(f"- {row}")
    sys.exit(1)

print(
    "coverage gates passed: "
    f"python>={min_python:.2f} node>={min_node:.2f} combined>={min_combined:.2f}"
    + (f" lua>={min_lua:.2f}" if enforce_lua else " lua skipped")
    + (f" php>={min_php:.2f}" if min_php > 0 else " php skipped")
    + (f" rust>={min_rust:.2f}" if min_rust > 0 else " rust skipped")
)
PY
