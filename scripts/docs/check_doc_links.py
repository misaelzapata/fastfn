#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.parse import unquote, urlsplit

import yaml

ROOT = Path(__file__).resolve().parents[2]
DOCS_DIR = ROOT / "docs"
SITE_DIR = ROOT / "site"
MKDOCS_CONFIG = ROOT / "mkdocs.yml"
SITE_PREFIX = "/fastfn/"


class MkDocsLoader(yaml.SafeLoader):
    pass


def _construct_python_name(loader: yaml.Loader, suffix: str, node: yaml.Node) -> str:
    return suffix


MkDocsLoader.add_multi_constructor("tag:yaml.org,2002:python/name:", _construct_python_name)

INLINE_LINK_RE = re.compile(r"(!?)\[(?P<label>[^\]]*)\]\((?P<target>[^)\s]+(?:\s+\"[^\"]*\")?)\)")
REFERENCE_LINK_RE = re.compile(r"(!?)\[(?P<label>[^\]]+)\]\[(?P<ref>[^\]]*)\]")
REFERENCE_DEF_RE = re.compile(r"^[ \t]{0,3}\[(?P<ref>[^\]]+)\]:[ \t]*(?P<target>\S+)", re.MULTILINE)
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$", re.MULTILINE)
HTML_ID_RE = re.compile(r'\bid=(["\'])(?P<id>[^"\']+)\1')


@dataclass
class LinkRef:
    source: Path
    line: int
    target: str
    is_image: bool


def iter_markdown_files() -> list[Path]:
    return sorted(DOCS_DIR.rglob("*.md"))


def strip_fenced_code(text: str) -> str:
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    fence: str | None = None
    for line in lines:
        match = re.match(r"^([ \t]*)(`{3,}|~{3,})", line)
        if match:
            marker = match.group(2)[0]
            if fence is None:
                fence = marker
            elif fence == marker:
                fence = None
            out.append("\n")
            continue
        if fence is None:
            out.append(line)
        else:
            out.append("\n" if line.endswith("\n") else "")
    return re.sub(r"<!--.*?-->", "", "".join(out), flags=re.DOTALL)


def line_for_offset(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def normalize_ref_name(name: str) -> str:
    return re.sub(r"\s+", " ", name.strip()).lower()


def extract_reference_defs(text: str) -> dict[str, str]:
    refs: dict[str, str] = {}
    for match in REFERENCE_DEF_RE.finditer(text):
        refs[normalize_ref_name(match.group("ref"))] = match.group("target").strip()
    return refs


def extract_links(path: Path) -> list[LinkRef]:
    raw = path.read_text(encoding="utf-8")
    text = strip_fenced_code(raw)
    refs = extract_reference_defs(text)
    found: list[LinkRef] = []

    for match in INLINE_LINK_RE.finditer(text):
        target = match.group("target").strip()
        if " " in target and not target.startswith("<"):
            target = target.split(" ", 1)[0]
        found.append(
            LinkRef(
                source=path,
                line=line_for_offset(text, match.start()),
                target=target.strip("<>"),
                is_image=match.group(1) == "!",
            )
        )

    for match in REFERENCE_LINK_RE.finditer(text):
        ref = normalize_ref_name(match.group("ref") or match.group("label"))
        target = refs.get(ref)
        if not target:
            continue
        found.append(
            LinkRef(
                source=path,
                line=line_for_offset(text, match.start()),
                target=target.strip("<>"),
                is_image=match.group(1) == "!",
            )
        )

    return found


def slugify_heading(raw: str) -> str:
    text = re.sub(r"`([^`]*)`", r"\1", raw)
    text = re.sub(r"<[^>]+>", "", text)
    text = unicodedata.normalize("NFKD", text)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.lower()
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    text = re.sub(r"[\s_-]+", "-", text).strip("-")
    return text


def markdown_anchors(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    anchors: set[str] = set()
    seen: dict[str, int] = {}
    for match in HEADING_RE.finditer(text):
        slug = slugify_heading(match.group(2))
        if not slug:
            continue
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        anchors.add(slug if count == 0 else f"{slug}_{count}")
    return anchors


def html_ids(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    return {match.group("id") for match in HTML_ID_RE.finditer(text)}


def load_nav_targets(value: object) -> list[str]:
    targets: list[str] = []
    if isinstance(value, str):
        targets.append(value)
        return targets
    if isinstance(value, list):
        for item in value:
            targets.extend(load_nav_targets(item))
        return targets
    if isinstance(value, dict):
        for nested in value.values():
            targets.extend(load_nav_targets(nested))
    return targets


def validate_nav_targets() -> list[str]:
    config = yaml.load(MKDOCS_CONFIG.read_text(encoding="utf-8"), Loader=MkDocsLoader) or {}
    failures: list[str] = []
    for target in load_nav_targets(config.get("nav", [])):
        if "://" in target or target.startswith("#"):
            continue
        full = DOCS_DIR / target
        if not full.exists():
            failures.append(f"mkdocs.yml: nav target missing: {target}")
    return failures


def resolve_doc_target(source: Path, raw_target: str) -> tuple[Path | None, str | None]:
    target = raw_target.strip()
    if not target or target.startswith(("http://", "https://", "mailto:", "tel:", "javascript:")):
        return None, None
    if target.startswith("#"):
        return source, target[1:]

    parts = urlsplit(target)
    path = unquote(parts.path)
    fragment = unquote(parts.fragment) if parts.fragment else None

    if path.startswith(SITE_PREFIX):
        return resolve_site_target(path, fragment)
    if path.startswith("/"):
        if path.startswith("/en/") or path.startswith("/es/"):
            return resolve_site_target(SITE_PREFIX + path.lstrip("/"), fragment)
        return None, None

    resolved = (source.parent / path).resolve()
    try:
        resolved.relative_to(ROOT)
    except ValueError:
        return Path("__outside__"), fragment
    return resolved, fragment


def resolve_site_target(path: str, fragment: str | None) -> tuple[Path | None, str | None]:
    relative = path[len(SITE_PREFIX) :].strip("/")
    if relative == "":
        candidate_paths = [SITE_DIR / "index.html"]
    else:
        candidate_paths = [
            SITE_DIR / relative,
            SITE_DIR / f"{relative}.html",
            SITE_DIR / relative / "index.html",
        ]
    for candidate in candidate_paths:
        if candidate.exists():
            return candidate, fragment
    return Path("__missing_site__") / relative, fragment


def validate_link(link: LinkRef) -> Iterable[str]:
    target_path, fragment = resolve_doc_target(link.source, link.target)
    if target_path is None:
        return []
    if str(target_path).startswith("__outside__"):
        return [f"{link.source.relative_to(ROOT)}:{link.line}: link escapes repo root: {link.target}"]
    if str(target_path).startswith("__missing_site__"):
        return [f"{link.source.relative_to(ROOT)}:{link.line}: site link target missing after mkdocs build: {link.target}"]
    if not target_path.exists():
        return [f"{link.source.relative_to(ROOT)}:{link.line}: link target missing: {link.target}"]

    if fragment:
        if target_path.suffix == ".md":
            anchors = markdown_anchors(target_path)
        elif target_path.suffix == ".html":
            anchors = html_ids(target_path)
        else:
            anchors = set()
        if fragment not in anchors:
            return [f"{link.source.relative_to(ROOT)}:{link.line}: missing anchor #{fragment} in {target_path.relative_to(ROOT)}"]
    return []


def main() -> int:
    failures: list[str] = []
    failures.extend(validate_nav_targets())

    for md in iter_markdown_files():
        for link in extract_links(md):
            failures.extend(validate_link(link))

    if failures:
        print("docs link check failed:", file=sys.stderr)
        for entry in failures:
            print(f"- {entry}", file=sys.stderr)
        return 1

    print("docs link check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
