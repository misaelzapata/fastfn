#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _as_float(value: object, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _as_int(value: object, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _match_path(path: str, include_prefixes: list[str], include_suffixes: list[str]) -> bool:
    if include_prefixes and not any(path.startswith(prefix) for prefix in include_prefixes):
        return False
    if include_suffixes and not any(path.endswith(suffix) for suffix in include_suffixes):
        return False
    return True


def _parse_coveragepy(input_path: Path, include_prefixes: list[str], include_suffixes: list[str]) -> list[dict[str, object]]:
    payload = json.loads(input_path.read_text(encoding="utf-8"))
    files = payload.get("files")
    if not isinstance(files, dict):
        raise ValueError(f"invalid coverage.py json: {input_path}")

    rows: list[dict[str, object]] = []
    for file_path, file_payload in sorted(files.items()):
        path_str = str(file_path).replace("\\", "/")
        if not _match_path(path_str, include_prefixes, include_suffixes):
            continue
        summary = file_payload.get("summary") if isinstance(file_payload, dict) else {}
        total = _as_int(summary.get("num_statements")) if isinstance(summary, dict) else 0
        covered = _as_int(summary.get("covered_lines")) if isinstance(summary, dict) else 0
        pct = (covered / total * 100.0) if total else 100.0
        rows.append({"file": path_str, "covered": covered, "total": total, "pct": pct})
    return rows


def _parse_c8(input_path: Path, include_prefixes: list[str], include_suffixes: list[str]) -> list[dict[str, object]]:
    payload = json.loads(input_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"invalid c8 coverage summary: {input_path}")

    rows: list[dict[str, object]] = []
    for file_path, file_payload in sorted(payload.items()):
        if file_path == "total":
            continue
        path_str = str(file_path).replace("\\", "/")
        if not _match_path(path_str, include_prefixes, include_suffixes):
            continue
        if not isinstance(file_payload, dict):
            continue
        lines = file_payload.get("lines")
        if not isinstance(lines, dict):
            continue
        total = _as_int(lines.get("total"))
        covered = _as_int(lines.get("covered"))
        pct = _as_float(lines.get("pct"), (covered / total * 100.0) if total else 100.0)
        rows.append({"file": path_str, "covered": covered, "total": total, "pct": pct})
    return rows


def _pct(covered: int, total: int) -> float:
    return (covered / total * 100.0) if total else 100.0


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate line coverage by total + file for coverage.py or c8.")
    parser.add_argument("--format", choices=["coveragepy", "c8"], required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--min-total", type=float, default=100.0)
    parser.add_argument("--min-file", type=float, default=100.0)
    parser.add_argument("--include-prefix", action="append", default=[])
    parser.add_argument("--include-suffix", action="append", default=[])
    parser.add_argument("--output-json", default="")
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        print(f"coverage check failed: missing input file {input_path}", file=sys.stderr)
        return 1

    include_prefixes = [p.replace("\\", "/") for p in args.include_prefix if p]
    include_suffixes = [s.replace("\\", "/") for s in args.include_suffix if s]

    if args.format == "coveragepy":
        rows = _parse_coveragepy(input_path, include_prefixes, include_suffixes)
    else:
        rows = _parse_c8(input_path, include_prefixes, include_suffixes)

    if not rows:
        print("coverage check failed: no files matched selection filters", file=sys.stderr)
        return 1

    total_statements = sum(int(r["total"]) for r in rows)
    total_covered = sum(int(r["covered"]) for r in rows)
    total_pct = _pct(total_covered, total_statements)

    failures: list[str] = []
    if total_pct < args.min_total:
        failures.append(f"total line coverage below threshold: {total_pct:.2f}% < {args.min_total:.2f}%")

    for row in rows:
        if float(row["pct"]) < args.min_file:
            failures.append(f"file below threshold: {row['file']} {float(row['pct']):.2f}% < {args.min_file:.2f}%")

    report = {
        "format": args.format,
        "input": str(input_path),
        "total": {
            "covered": total_covered,
            "total": total_statements,
            "pct": total_pct,
        },
        "files": rows,
    }
    if args.output_json:
        out = Path(args.output_json)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    if failures:
        print("line coverage check failed:", file=sys.stderr)
        for row in failures:
            print(f"- {row}", file=sys.stderr)
        return 1

    print(
        "line coverage check passed: "
        f"format={args.format} total={total_pct:.2f}% "
        f"min-total={args.min_total:.2f}% min-file={args.min_file:.2f}% files={len(rows)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
