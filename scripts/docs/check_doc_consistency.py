#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCS_EN = ROOT / "docs" / "en"
DOCS_ES = ROOT / "docs" / "es"

CANONICAL_BENCHMARK_PAGES = {
    ROOT / "docs" / "en" / "explanation" / "performance-benchmarks.md",
    ROOT / "docs" / "es" / "explicacion" / "benchmarks-rendimiento.md",
}

FORBIDDEN_GLOBAL = [
    "200%",
    "300%",
]

FORBIDDEN_OUTSIDE_BENCHMARKS = [
    "276.7ms",
    "243.1ms",
    "1283.3ms",
    "451.6ms",
    "529.2ms",
    "423.3ms",
    "872.9ms",
    "953.0ms",
    "12.1%",
    "64.8%",
    "20.0%",
    "9.2%",
    "8.9%",
    "76.7%",
    "27.0%",
    "4.5%",
]

CLI_DOCS = {
    ROOT / "docs" / "en" / "reference" / "cli.md": ["fastfn version", "fastfn --version"],
    ROOT / "docs" / "es" / "referencia" / "cli-reference.md": ["fastfn version", "fastfn --version"],
}


def iter_markdown_files() -> list[Path]:
    files: list[Path] = []
    files.extend(sorted(DOCS_EN.rglob("*.md")))
    files.extend(sorted(DOCS_ES.rglob("*.md")))
    return files


def main() -> int:
    failures: list[str] = []

    for md in iter_markdown_files():
        text = md.read_text(encoding="utf-8")
        rel = md.relative_to(ROOT).as_posix()

        for token in FORBIDDEN_GLOBAL:
            if token in text:
                failures.append(f"{rel}: forbidden claim token {token!r}")

        if md not in CANONICAL_BENCHMARK_PAGES:
            for token in FORBIDDEN_OUTSIDE_BENCHMARKS:
                if token in text:
                    failures.append(f"{rel}: benchmark snapshot token {token!r} must live only in benchmark pages")

    for path, required_tokens in CLI_DOCS.items():
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(ROOT).as_posix()
        for token in required_tokens:
            if token not in text:
                failures.append(f"{rel}: missing CLI version token {token!r}")

    if failures:
        print("docs consistency check failed:", file=sys.stderr)
        for entry in failures:
            print(f"- {entry}", file=sys.stderr)
        return 1

    print("docs consistency check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
