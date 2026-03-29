#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Set

ROOT = Path(__file__).resolve().parents[2]
DOCS_DIR = ROOT / "docs"
MANIFEST_PATH = DOCS_DIR / "assets" / "screenshots" / "manifest.json"
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"}

MD_IMAGE_RE = re.compile(r"!\[[^\]]*\]\(([^)]+)\)")
HTML_IMAGE_RE = re.compile(r"<img[^>]+src=[\"']([^\"']+)[\"']", re.IGNORECASE)


@dataclass
class Ref:
    path: str
    used_by: str


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _is_local_asset(raw: str) -> bool:
    s = raw.strip().split("#", 1)[0].split("?", 1)[0]
    if not s:
        return False
    low = s.lower()
    if low.startswith(("http://", "https://", "data:", "mailto:")):
        return False
    return Path(s).suffix.lower() in IMAGE_EXTS


def _resolve_ref(md_file: Path, raw: str) -> Path | None:
    clean = raw.strip().split("#", 1)[0].split("?", 1)[0]
    if not clean:
        return None
    if clean.startswith("/"):
        return (DOCS_DIR / clean.lstrip("/")).resolve()
    return (md_file.parent / clean).resolve()


def collect_doc_refs() -> Dict[str, Set[str]]:
    refs: Dict[str, Set[str]] = {}
    for md in DOCS_DIR.rglob("*.md"):
        rel_md = md.relative_to(DOCS_DIR).as_posix()
        if rel_md.startswith("internal/"):
            continue
        text = md.read_text(encoding="utf-8")
        candidates = []
        candidates.extend(MD_IMAGE_RE.findall(text))
        candidates.extend(HTML_IMAGE_RE.findall(text))
        for raw in candidates:
            if not _is_local_asset(raw):
                continue
            resolved = _resolve_ref(md, raw)
            if resolved is None:
                continue
            try:
                rel = resolved.relative_to(DOCS_DIR).as_posix()
            except ValueError:
                continue
            refs.setdefault(rel, set()).add(rel_md)
    return refs


def load_manifest() -> dict:
    if not MANIFEST_PATH.exists():
        return {"version": 1, "assets": []}
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def update_manifest() -> int:
    refs = collect_doc_refs()
    manifest = load_manifest()
    existing = {item.get("path"): item for item in manifest.get("assets", []) if isinstance(item, dict)}

    assets: List[dict] = []
    for rel_path in sorted(refs.keys()):
        abs_path = DOCS_DIR / rel_path
        old = existing.get(rel_path, {})
        sha = _sha256(abs_path) if abs_path.exists() else ""
        asset_id = old.get("id") or rel_path.replace("/", "-").replace(".", "-")
        source = old.get("source") or {
            "kind": "manual",
            "script": "",
            "command": "",
        }
        assets.append(
            {
                "id": asset_id,
                "path": rel_path,
                "sha256": sha,
                "source": source,
                "used_by": sorted(refs.get(rel_path, set())),
            }
        )

    out = {
        "version": 1,
        "generated_at": old.get("generated_at") if (old := manifest) else None,
        "assets": assets,
    }
    # keep deterministic and simple timestamp placeholder; CI can regenerate
    out["generated_at"] = "2026-03-12T00:00:00Z"

    MANIFEST_PATH.write_text(json.dumps(out, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(f"updated manifest: {MANIFEST_PATH} ({len(assets)} assets)")
    return 0


def verify_manifest() -> int:
    refs = collect_doc_refs()
    if not MANIFEST_PATH.exists():
        print(f"error: missing manifest {MANIFEST_PATH}", file=sys.stderr)
        return 1

    manifest = load_manifest()
    assets = manifest.get("assets", [])
    if not isinstance(assets, list):
        print("error: manifest 'assets' must be a list", file=sys.stderr)
        return 1

    errors: List[str] = []
    by_path: Dict[str, dict] = {}
    for item in assets:
        if not isinstance(item, dict):
            errors.append("manifest asset entry is not an object")
            continue
        p = item.get("path")
        if not isinstance(p, str) or not p:
            errors.append("manifest asset entry missing path")
            continue
        if p in by_path:
            errors.append(f"duplicate manifest path: {p}")
            continue
        by_path[p] = item

    for rel, used_by in sorted(refs.items()):
        if rel not in by_path:
            errors.append(f"referenced asset missing in manifest: {rel}")
            continue
        item = by_path[rel]
        abs_path = DOCS_DIR / rel
        if not abs_path.exists():
            errors.append(f"manifest asset file does not exist: {rel}")
            continue
        expected = item.get("sha256", "")
        actual = _sha256(abs_path)
        if expected != actual:
            errors.append(f"sha256 mismatch for {rel}: manifest={expected} actual={actual}")

        source = item.get("source")
        if not isinstance(source, dict):
            errors.append(f"missing source object for {rel}")
        else:
            if not isinstance(source.get("kind"), str) or not source.get("kind"):
                errors.append(f"missing source.kind for {rel}")
            if not isinstance(source.get("script"), str):
                errors.append(f"invalid source.script for {rel}")

        listed_used_by = item.get("used_by", [])
        if not isinstance(listed_used_by, list):
            errors.append(f"used_by must be list for {rel}")
        else:
            listed = sorted(str(x) for x in listed_used_by)
            expected_used = sorted(used_by)
            if listed != expected_used:
                errors.append(
                    f"used_by mismatch for {rel}: manifest={listed} expected={expected_used}"
                )

    for rel in sorted(by_path.keys()):
        if rel not in refs:
            errors.append(f"manifest includes unreferenced asset: {rel}")

    if errors:
        print("visual manifest verification failed:", file=sys.stderr)
        for e in errors:
            print(f"- {e}", file=sys.stderr)
        return 1

    print(f"visual manifest verification passed ({len(refs)} assets)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage docs visual evidence manifest")
    parser.add_argument("mode", choices=["update", "verify"])
    args = parser.parse_args()

    if args.mode == "update":
        return update_manifest()
    return verify_manifest()


if __name__ == "__main__":
    raise SystemExit(main())
