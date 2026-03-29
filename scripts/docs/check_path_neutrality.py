#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCS_DIRS = [ROOT / "docs" / "en", ROOT / "docs" / "es"]
RUNTIME_PATH_RE = re.compile(r"(?:<FN_FUNCTIONS_ROOT>|functions)/(?:node|python|php|rust|lua|go)/")
RUNTIME_TREE_RE = re.compile(r"^\s*(?:node|python|php|rust|lua|go)/(?:$|.+)")


def iter_markdown_files() -> list[Path]:
    files: list[Path] = []
    for base in DOCS_DIRS:
        files.extend(sorted(base.rglob("*.md")))
    return files


def scan_file(path: Path) -> list[tuple[int, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    issues: list[tuple[int, str]] = []
    allow_runtime_paths = False
    in_fence = False
    for lineno, line in enumerate(lines, start=1):
        if "<!-- runtime-paths-ok:start -->" in line:
            allow_runtime_paths = True
            continue
        if "<!-- runtime-paths-ok:end -->" in line:
            allow_runtime_paths = False
            continue
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
        if allow_runtime_paths:
            continue
        if "examples/functions/" in line:
            continue
        if RUNTIME_PATH_RE.search(line):
            issues.append((lineno, line.strip()))
            continue
        if in_fence and RUNTIME_TREE_RE.search(line):
            issues.append((lineno, line.strip()))
    return issues


def main() -> int:
    failures: list[str] = []
    for md in iter_markdown_files():
        issues = scan_file(md)
        rel = md.relative_to(ROOT).as_posix()
        for lineno, line in issues:
            failures.append(f"{rel}:{lineno}: {line}")

    if failures:
        print("path neutrality check failed:", file=sys.stderr)
        print("Use neutral function paths (`functions/<name>/...`) by default.", file=sys.stderr)
        print("If runtime-prefixed paths are intentionally shown, wrap that block with:", file=sys.stderr)
        print("<!-- runtime-paths-ok:start --> and <!-- runtime-paths-ok:end -->", file=sys.stderr)
        for entry in failures:
            print(f"- {entry}", file=sys.stderr)
        return 1

    print("path neutrality check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
