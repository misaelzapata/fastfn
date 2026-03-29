#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
from typing import Any


def lua_report_to_lcov(report_path: str, lcov_path: str, root_dir: str) -> None:
    report = pathlib.Path(report_path)
    lcov = pathlib.Path(lcov_path)
    root = pathlib.Path(root_dir).resolve()
    if not report.exists():
        lcov.write_text("", encoding="utf-8")
        print("lua lcov export skipped (luacov report not found)")
        return
    separator_re = re.compile(r"^=+$")
    count_re = re.compile(r"^\s*(\*{7}0|\d+)\s")
    state = "idle"
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
            return str(resolved.relative_to(root)).replace("\\", "/")
        except Exception:
            return raw.lstrip("/")

    for raw_line in report.read_text(encoding="utf-8", errors="ignore").splitlines():
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
        match = count_re.match(line)
        if not match:
            continue
        token = match.group(1)
        hits = 0 if token.startswith("*") else int(token)
        entries[current_path].append((line_no, hits))

    records: list[str] = []
    file_count = 0
    for file_path in sorted(entries.keys()):
        line_hits = entries[file_path]
        if not line_hits:
            continue
        file_count += 1
        covered = sum(1 for _, hits in line_hits if hits > 0)
        records.append("TN:")
        records.append(f"SF:{file_path}")
        for line_number, hits in line_hits:
            records.append(f"DA:{line_number},{hits}")
        records.append(f"LF:{len(line_hits)}")
        records.append(f"LH:{covered}")
        records.append("end_of_record")
    lcov.write_text(("\n".join(records) + "\n") if records else "", encoding="utf-8")
    print(f"lua lcov export: files={file_count} path={lcov}")


def parse_runtime_file_coverage(json_path: pathlib.Path, file_suffix: str) -> tuple[float, int, int, bool]:
    if not json_path.exists():
        return 0.0, 0, 0, False
    data = json.loads(json_path.read_text(encoding="utf-8"))
    files = data.get("files", {})
    for file_path, payload in files.items():
        if str(file_path).replace("\\", "/").endswith(file_suffix):
            summary = payload.get("summary", {})
            total = int(summary.get("num_statements", 0))
            covered = int(summary.get("covered_lines", 0))
            pct = (covered / total * 100.0) if total else 0.0
            return pct, covered, total, total > 0
    return 0.0, 0, 0, False


def write_summary(out_dir_str: str) -> None:
    out_dir = pathlib.Path(out_dir_str)
    py = json.loads((out_dir / "python-coverage.json").read_text(encoding="utf-8"))
    node = json.loads((out_dir / "node" / "coverage-summary.json").read_text(encoding="utf-8"))

    py_totals = py.get("totals", {})
    py_total = int(py_totals.get("num_statements", 0))
    py_covered = int(py_totals.get("covered_lines", 0))
    py_pct = (py_covered / py_total * 100.0) if py_total else 0.0

    node_total_block = node.get("total", {}).get("lines", {})
    try:
        node_pct = float(node_total_block.get("pct", 0.0))
    except (TypeError, ValueError):
        node_pct = 0.0
    node_total = int(node_total_block.get("total", 0))
    node_covered = int(node_total_block.get("covered", 0))

    php_pct, php_covered, php_total, php_available = parse_runtime_file_coverage(
        out_dir / "php-runtime-coverage.json", "/srv/fn/runtimes/php-daemon.php"
    )
    rust_pct, rust_covered, rust_total, rust_available = parse_runtime_file_coverage(
        out_dir / "rust-runtime-coverage.json", "/srv/fn/runtimes/rust-daemon.py"
    )
    go_pct, go_covered, go_total, go_available = parse_runtime_file_coverage(
        out_dir / "go-runtime-coverage.json", "/srv/fn/runtimes/go-daemon.py"
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
            current = re.search(r"^\s*Total\s+(\d+)\s+(\d+)\s+([0-9.]+)%\s*$", line)
            if current:
                match = current
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
    all_total = py_total + node_total + php_total + rust_total + go_total + (lua_total if include_lua_in_combined else 0)
    all_covered = py_covered + node_covered + php_covered + rust_covered + go_covered + (lua_covered if include_lua_in_combined else 0)
    all_pct = (all_covered / all_total * 100.0) if all_total else 0.0
    combined_scope = "python+node+lua+php+rust+go" if include_lua_in_combined else "python+node+php+rust+go"

    php_line = f"- PHP lines: {php_pct:.2f}% ({php_covered}/{php_total})" if php_available else "- PHP lines: n/a (runtime coverage report not available)"
    rust_line = f"- Rust lines: {rust_pct:.2f}% ({rust_covered}/{rust_total})" if rust_available else "- Rust lines: n/a (runtime coverage report not available)"
    go_line = f"- Go runtime lines: {go_pct:.2f}% ({go_covered}/{go_total})" if go_available else "- Go runtime lines: n/a (runtime coverage report not available)"

    summary = (
        "# Coverage Summary\n\n"
        f"- Python lines: {py_pct:.2f}% ({py_covered}/{py_total})\n"
        f"- Node lines: {node_pct:.2f}% ({node_covered}/{node_total})\n"
        f"{lua_line}\n"
        f"{php_line}\n"
        f"{rust_line}\n"
        f"{go_line}\n"
        f"- Combined lines ({combined_scope}): {all_pct:.2f}% ({all_covered}/{all_total})\n"
    )
    (out_dir / "summary.md").write_text(summary, encoding="utf-8")
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
        "go_rt_pct": go_pct,
        "go_rt_covered": go_covered,
        "go_rt_total": go_total,
        "go_rt_available": go_available,
        "combined_scope": combined_scope,
        "combined_pct": all_pct,
        "combined_covered": all_covered,
        "combined_total": all_total,
    }
    (out_dir / "summary.json").write_text(json.dumps(summary_json, indent=2), encoding="utf-8")
    print(summary)


def verify_summary(out_dir_str: str) -> None:
    out_dir = pathlib.Path(out_dir_str)
    summary = json.loads((out_dir / "summary.json").read_text(encoding="utf-8"))
    min_python = float(os.environ["COVERAGE_MIN_PYTHON"])
    min_node = float(os.environ["COVERAGE_MIN_NODE"])
    min_combined = float(os.environ["COVERAGE_MIN_COMBINED"])
    min_lua = float(os.environ["COVERAGE_MIN_LUA"])
    min_php = float(os.environ["COVERAGE_MIN_PHP"])
    min_rust = float(os.environ["COVERAGE_MIN_RUST"])
    enforce_lua = str(os.environ["COVERAGE_ENFORCE_LUA"]).strip().lower() in {"1", "true", "yes", "on"}
    failures: list[str] = []
    if float(summary.get("python_pct", 0.0)) < min_python:
        failures.append(f"python coverage below threshold: {summary.get('python_pct', 0.0):.2f}% < {min_python:.2f}%")
    if float(summary.get("node_pct", 0.0)) < min_node:
        failures.append(f"node coverage below threshold: {summary.get('node_pct', 0.0):.2f}% < {min_node:.2f}%")
    if float(summary.get("combined_pct", 0.0)) < min_combined:
        failures.append(f"combined coverage below threshold: {summary.get('combined_pct', 0.0):.2f}% < {min_combined:.2f}%")
    if enforce_lua and float(summary.get("lua_pct", 0.0)) < min_lua:
        failures.append(f"lua coverage below threshold: {summary.get('lua_pct', 0.0):.2f}% < {min_lua:.2f}%")
    if float(summary.get("php_pct", 0.0)) < min_php:
        failures.append(f"php runtime coverage below threshold: {summary.get('php_pct', 0.0):.2f}% < {min_php:.2f}%")
    if float(summary.get("rust_pct", 0.0)) < min_rust:
        failures.append(f"rust runtime coverage below threshold: {summary.get('rust_pct', 0.0):.2f}% < {min_rust:.2f}%")
    if failures:
        for item in failures:
            print(item, file=os.sys.stderr)
        raise SystemExit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    lcov = sub.add_parser("lua-report-to-lcov")
    lcov.add_argument("--report", required=True)
    lcov.add_argument("--output", required=True)
    lcov.add_argument("--root-dir", required=True)
    lcov.set_defaults(func=lambda args: lua_report_to_lcov(args.report, args.output, args.root_dir))

    summary = sub.add_parser("write-summary")
    summary.add_argument("--out-dir", required=True)
    summary.set_defaults(func=lambda args: write_summary(args.out_dir))

    verify = sub.add_parser("verify-summary")
    verify.add_argument("--out-dir", required=True)
    verify.set_defaults(func=lambda args: verify_summary(args.out_dir))
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
