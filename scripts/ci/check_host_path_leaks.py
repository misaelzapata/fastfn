#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

POSIX_USER_HOME_RE = re.compile(
    r"(?P<path>/(?P<base>home|Users)/(?P<user>[A-Za-z0-9._-]+)/[^\s`'\"]*)"
)
WINDOWS_USER_HOME_RE = re.compile(
    r"(?P<path>[A-Za-z]:\\Users\\(?P<user>[^\\\s]+)\\[^\s`'\"]*)",
    re.IGNORECASE,
)
NEUTRAL_USERS = {"user"}
SKIP_PREFIXES = (
    ".git/",
    ".venv/",
    "node_modules/",
    "coverage/",
    "site/",
    "sdk/rust/target/",
)


def tracked_files() -> list[Path]:
    proc = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    files: list[Path] = []
    for raw in proc.stdout.split(b"\0"):
        if not raw:
            continue
        rel = raw.decode("utf-8")
        if rel.startswith(SKIP_PREFIXES):
            continue
        files.append(ROOT / rel)
    return files


def iter_text_lines(path: Path) -> list[str] | None:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if b"\0" in raw:
        return None
    try:
        return raw.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        return None


def repo_specific_prefixes() -> set[str]:
    prefixes = {str(ROOT.resolve())}
    try:
        prefixes.add(str(Path.home().resolve()))
    except OSError:
        pass
    return {prefix for prefix in prefixes if prefix not in {"", "/", "."}}


def is_neutral_user_path(match: re.Match[str]) -> bool:
    return match.group("user").lower() in NEUTRAL_USERS


def scan_line(line: str, prefixes: set[str]) -> list[str]:
    issues: list[str] = []
    for prefix in prefixes:
        if prefix in line:
            issues.append(prefix)
    for match in POSIX_USER_HOME_RE.finditer(line):
        if not is_neutral_user_path(match):
            issues.append(match.group("path"))
    for match in WINDOWS_USER_HOME_RE.finditer(line):
        if not is_neutral_user_path(match):
            issues.append(match.group("path"))
    return issues


def main() -> int:
    prefixes = repo_specific_prefixes()
    failures: list[str] = []
    for path in tracked_files():
        lines = iter_text_lines(path)
        if lines is None:
            continue
        rel = path.relative_to(ROOT).as_posix()
        for lineno, line in enumerate(lines, start=1):
            issues = scan_line(line, prefixes)
            for issue in issues:
                failures.append(f"{rel}:{lineno}: leaked host path: {issue}")

    if failures:
        print("host path leak check failed:", file=sys.stderr)
        print(
            "Use neutral placeholders like /home/user/... or env vars such as $HOME instead of"
            " absolute paths from a workstation or CI runner.",
            file=sys.stderr,
        )
        for entry in failures:
            print(f"- {entry}", file=sys.stderr)
        return 1

    print("host path leak check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
