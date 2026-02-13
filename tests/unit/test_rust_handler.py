#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "examples/functions/rust/rust_profile/app.rs"
CFG = ROOT / "examples/functions/rust/rust_profile/fn.config.json"


def main() -> None:
    assert SRC.is_file(), f"missing rust source: {SRC}"
    raw = SRC.read_text(encoding="utf-8")
    assert "pub fn handler" in raw, "handler signature missing"
    assert "serde_json" in raw, "serde_json usage missing"

    assert CFG.is_file(), f"missing rust config: {CFG}"
    cfg_raw = CFG.read_text(encoding="utf-8")
    assert '"methods": ["GET"]' in cfg_raw, "GET policy missing in config"

    print("rust unit tests passed")


if __name__ == "__main__":
    main()
