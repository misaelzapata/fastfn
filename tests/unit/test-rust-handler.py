#!/usr/bin/env python3
import importlib.util
import json
import shutil
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "examples/functions/rust/rust-profile/handler.rs"
CFG = ROOT / "examples/functions/rust/rust-profile/fn.config.json"
RUNTIME_DIR = ROOT / "srv/fn/runtimes"
RUST_DAEMON_PATH = RUNTIME_DIR / "rust-daemon.py"

_RUST_SPEC = importlib.util.spec_from_file_location("fastfn_rust_daemon", RUST_DAEMON_PATH)
if _RUST_SPEC is None or _RUST_SPEC.loader is None:
    raise RuntimeError(f"failed to load runtime module: {RUST_DAEMON_PATH}")
rust_daemon = importlib.util.module_from_spec(_RUST_SPEC)  # type: ignore
_RUST_SPEC.loader.exec_module(rust_daemon)  # type: ignore


def ensure_toolchain() -> None:
    rustc = shutil.which("rustc")
    cargo = shutil.which("cargo")
    if not rustc or not cargo:
        raise RuntimeError("rustc/cargo not found in PATH")


def configure_runtime_paths() -> None:
    rust_daemon.FUNCTIONS_DIR = ROOT / "examples/functions"
    rust_daemon.RUNTIME_FUNCTIONS_DIR = rust_daemon.FUNCTIONS_DIR / "rust"
    rust_daemon._BINARY_CACHE.clear()


def test_source_contract() -> None:
    assert SRC.is_file(), f"missing rust source: {SRC}"
    raw = SRC.read_text(encoding="utf-8")
    assert "pub fn handler" in raw, "handler signature missing"
    assert "serde_json" in raw, "serde_json usage missing"

    assert CFG.is_file(), f"missing rust config: {CFG}"
    cfg_raw = CFG.read_text(encoding="utf-8")
    assert '"methods": ["GET"]' in cfg_raw, "GET policy missing in config"


def test_runtime_handler_execution() -> None:
    resp = rust_daemon._handle_request_direct(
        {
            "fn": "rust-profile",
            "event": {
                "query": {"name": "UnitRust"},
            },
        }
    )
    assert resp.get("status") == 200, resp
    headers = resp.get("headers") or {}
    assert headers.get("Content-Type") == "application/json", headers

    body = json.loads(resp.get("body") or "{}")
    assert body.get("runtime") == "rust", body
    assert body.get("function") == "rust-profile", body
    assert body.get("hello") == "rust-UnitRust", body


def test_runtime_not_found() -> None:
    try:
        rust_daemon._handle_request_direct({"fn": "missing_rust-profile", "event": {}})
    except FileNotFoundError:
        return
    raise AssertionError("missing rust function should raise FileNotFoundError")


def test_invalid_cached_binary_triggers_rebuild() -> None:
    ensure_toolchain()
    cargo_bin = shutil.which("cargo")
    assert cargo_bin, "cargo should be available for rust runtime tests"

    with tempfile.TemporaryDirectory() as tmp:
        handler_path = Path(tmp) / "handler.rs"
        handler_path.write_text(SRC.read_text(encoding="utf-8"), encoding="utf-8")

        build_dir = handler_path.parent / ".rust-build"
        binary = build_dir / "target" / "release" / "fn_handler"
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(b"not-native")
        binary.chmod(0o755)

        signature = {
            "source_mtime_ns": handler_path.stat().st_mtime_ns,
            "main_rs_hash": rust_daemon._MAIN_RS_DIGEST,
            "cargo_toml_hash": rust_daemon._CARGO_TOML_DIGEST,
            "runtime_platform": rust_daemon.sys.platform,
            "runtime_machine": rust_daemon.platform.machine(),
        }
        meta_path = build_dir / ".fastfn-build-meta.json"
        meta_path.write_text(
            json.dumps({"signature": signature, "binary": str(binary)}, separators=(",", ":"), sort_keys=True),
            encoding="utf-8",
        )

        old_resolve = rust_daemon._resolve_command
        old_run = rust_daemon.subprocess.run
        rust_daemon._BINARY_CACHE.clear()
        calls = {"count": 0}

        def fake_run(cmd, capture_output, text, cwd, timeout, check):
            calls["count"] += 1
            shutil.copy2(cargo_bin, binary)
            binary.chmod(binary.stat().st_mode | 0o111)

            class Result:
                returncode = 0
                stderr = ""
                stdout = ""

            return Result()

        try:
            rust_daemon._resolve_command = lambda *_a, **_k: cargo_bin
            rust_daemon.subprocess.run = fake_run
            resolved = rust_daemon._ensure_rust_binary(handler_path)
            assert resolved == binary
            assert calls["count"] == 1, "expected cargo rebuild for invalid cached binary"
        finally:
            rust_daemon._resolve_command = old_resolve
            rust_daemon.subprocess.run = old_run
            rust_daemon._BINARY_CACHE.clear()


def main() -> None:
    ensure_toolchain()
    configure_runtime_paths()
    test_source_contract()
    test_runtime_handler_execution()
    test_runtime_not_found()
    test_invalid_cached_binary_triggers_rebuild()
    print("rust unit tests passed")


if __name__ == "__main__":
    main()
