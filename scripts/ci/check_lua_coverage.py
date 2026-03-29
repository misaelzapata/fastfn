#!/usr/bin/env python3
"""Validate Lua line coverage from a luacov report file.

Parses the luacov text report (lines like ``file.lua  <hit> <missed> <pct>%``)
and enforces per-file and total coverage thresholds.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def _parse_luacov_report(report_path: Path) -> list[dict[str, object]]:
    text = report_path.read_text(encoding="utf-8", errors="ignore")
    rows: list[dict[str, object]] = []

    for line in text.splitlines():
        # Match lines like: path/to/file.lua   123   45   73.17%
        m = re.match(r"^\s*(\S+\.lua)\s+(\d+)\s+(\d+)\s+([0-9.]+)%\s*$", line)
        if not m:
            continue
        file_path = m.group(1)
        covered = int(m.group(2))
        missed = int(m.group(3))
        total = covered + missed
        pct = float(m.group(4))
        rows.append({"file": file_path, "covered": covered, "total": total, "pct": pct})

    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Lua line coverage from luacov report.")
    parser.add_argument("--report", required=True, help="Path to luacov.report.out")
    parser.add_argument("--min-total", type=float, default=100.0)
    parser.add_argument("--min-file", type=float, default=100.0)
    parser.add_argument("--output-json", default="")
    args = parser.parse_args()

    report_path = Path(args.report)
    if not report_path.exists():
        print(f"lua coverage check failed: missing report {report_path}", file=sys.stderr)
        return 1

    rows = _parse_luacov_report(report_path)
    if not rows:
        print("lua coverage check failed: no files found in report", file=sys.stderr)
        return 1

    total_statements = sum(int(r["total"]) for r in rows)
    total_covered = sum(int(r["covered"]) for r in rows)
    total_pct = (total_covered / total_statements * 100.0) if total_statements else 100.0

    failures: list[str] = []
    if total_pct < args.min_total:
        failures.append(f"total lua line coverage below threshold: {total_pct:.2f}% < {args.min_total:.2f}%")

    for row in rows:
        if float(row["pct"]) < args.min_file:
            failures.append(f"file below threshold: {row['file']} {float(row['pct']):.2f}% < {args.min_file:.2f}%")

    report = {
        "format": "luacov",
        "total": {"covered": total_covered, "total": total_statements, "pct": total_pct},
        "files": rows,
    }
    if args.output_json:
        out = Path(args.output_json)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    if failures:
        print("lua coverage check failed:", file=sys.stderr)
        for f in failures:
            print(f"- {f}", file=sys.stderr)
        return 1

    print(
        f"lua coverage check passed: total={total_pct:.2f}% "
        f"min-total={args.min_total:.2f}% min-file={args.min_file:.2f}% files={len(rows)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
