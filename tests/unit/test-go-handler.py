#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import shutil
import socket
import struct
import subprocess
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNTIME_DIR = ROOT / "srv/fn/runtimes"
GO_DAEMON_PATH = RUNTIME_DIR / "go-daemon.py"

_GO_SPEC = importlib.util.spec_from_file_location("fastfn_go_daemon", GO_DAEMON_PATH)
if _GO_SPEC is None or _GO_SPEC.loader is None:
    raise RuntimeError(f"failed to load runtime module: {GO_DAEMON_PATH}")
go_daemon = importlib.util.module_from_spec(_GO_SPEC)  # type: ignore
_GO_SPEC.loader.exec_module(go_daemon)  # type: ignore


def _recvall(conn: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def _read_frame(conn: socket.socket) -> dict:
    header = _recvall(conn, 4)
    assert len(header) == 4, "expected 4-byte frame header"
    (length,) = struct.unpack("!I", header)
    payload = _recvall(conn, length)
    assert len(payload) == length, "expected full frame payload"
    return json.loads(payload.decode("utf-8"))


def _write_raw_frame(conn: socket.socket, payload: bytes) -> None:
    conn.sendall(struct.pack("!I", len(payload)) + payload)


def test_write_frame_roundtrip() -> None:
    left, right = socket.socketpair()
    with left, right:
        expected = {"status": 200, "headers": {"Content-Type": "application/json"}, "body": '{"ok":true}'}
        go_daemon._write_frame(left, expected)
        actual = _read_frame(right)
        assert actual == expected, actual


def test_write_frame_fallback_for_unserializable_payload() -> None:
    left, right = socket.socketpair()
    with left, right:
        go_daemon._write_frame(left, {"bad": {"set"}})
        actual = _read_frame(right)
        assert actual.get("status") == 500, actual
        body = json.loads(actual.get("body") or "{}")
        assert "encode failure" in str(body.get("error", "")), body


def test_write_frame_fallback_for_oversized_payload() -> None:
    left, right = socket.socketpair()
    original_max = go_daemon.MAX_FRAME_BYTES
    try:
        go_daemon.MAX_FRAME_BYTES = 1024
        with left, right:
            go_daemon._write_frame(left, {"status": 200, "headers": {}, "body": "x" * 5000})
            actual = _read_frame(right)
            assert actual.get("status") == 500, actual
            body = json.loads(actual.get("body") or "{}")
            assert "response too large" in str(body.get("error", "")), body
    finally:
        go_daemon.MAX_FRAME_BYTES = original_max


def test_read_frame_invalid_utf8() -> None:
    left, right = socket.socketpair()
    with left, right:
        _write_raw_frame(right, b"\xff\xfe\xfa")
        try:
            go_daemon._read_frame(left)
        except ValueError as exc:
            assert "invalid utf-8 payload" in str(exc), str(exc)
            return
        raise AssertionError("expected invalid utf-8 payload error")


def test_read_frame_invalid_json() -> None:
    left, right = socket.socketpair()
    with left, right:
        _write_raw_frame(right, b"{bad json")
        try:
            go_daemon._read_frame(left)
        except ValueError as exc:
            assert "invalid json payload" in str(exc), str(exc)
            return
        raise AssertionError("expected invalid json payload error")


def test_read_frame_non_object_json() -> None:
    left, right = socket.socketpair()
    with left, right:
        _write_raw_frame(right, b"[]")
        try:
            go_daemon._read_frame(left)
        except ValueError as exc:
            assert "request must be an object" in str(exc), str(exc)
            return
        raise AssertionError("expected request must be an object error")


def test_read_frame_oversized_length() -> None:
    left, right = socket.socketpair()
    with left, right:
        too_large = go_daemon.MAX_FRAME_BYTES + 1
        right.sendall(struct.pack("!I", too_large))
        try:
            go_daemon._read_frame(left)
        except ValueError as exc:
            assert "invalid frame length" in str(exc), str(exc)
            return
        raise AssertionError("expected invalid frame length error")


def test_serve_conn_ignores_client_disconnect_on_write() -> None:
    original_read_frame = go_daemon._read_frame
    original_handle_request = go_daemon._handle_request
    left, right = socket.socketpair()
    try:
        go_daemon._read_frame = lambda _conn: {"fn": "any", "event": {}}  # type: ignore[assignment]
        go_daemon._handle_request = lambda _req: {"status": 200, "headers": {}, "body": "ok"}  # type: ignore[assignment]
        right.close()
        go_daemon._serve_conn(left)
    finally:
        go_daemon._read_frame = original_read_frame
        go_daemon._handle_request = original_handle_request
        try:
            left.close()
        except Exception:
            pass


def test_prepare_socket_path_tolerates_stat_race() -> None:
    old_stat = go_daemon.os.stat
    try:
        go_daemon.os.stat = lambda _p: (_ for _ in ()).throw(FileNotFoundError("gone"))  # type: ignore[assignment]
        go_daemon._prepare_socket_path("/tmp/fastfn/fn-go.sock")
    finally:
        go_daemon.os.stat = old_stat


def test_build_process_env_merges_without_mutating_global_env() -> None:
    old_value = os.environ.get("UNIT_BUILD_ENV")
    os.environ["UNIT_BUILD_ENV"] = "original"
    try:
        merged = go_daemon._build_process_env({"UNIT_BUILD_ENV": "override", "UNIT_REMOVE_ME": None})
        assert merged.get("UNIT_BUILD_ENV") == "override"
        assert "UNIT_REMOVE_ME" not in merged
        assert os.environ.get("UNIT_BUILD_ENV") == "original"
    finally:
        if old_value is None:
            os.environ.pop("UNIT_BUILD_ENV", None)
        else:
            os.environ["UNIT_BUILD_ENV"] = old_value


def test_resolve_go_command_uses_fn_go_bin_override() -> None:
    old_which = go_daemon.shutil.which
    previous = os.environ.get("FN_GO_BIN")
    try:
        os.environ["FN_GO_BIN"] = "custom-go"
        go_daemon.shutil.which = lambda cmd: "/tmp/custom-go-bin" if cmd == "custom-go" else "/usr/bin/go"
        assert go_daemon._resolve_go_command() == "/tmp/custom-go-bin"
    finally:
        go_daemon.shutil.which = old_which
        if previous is None:
            os.environ.pop("FN_GO_BIN", None)
        else:
            os.environ["FN_GO_BIN"] = previous


def test_emit_handler_logs_writes_prefixed_output() -> None:
    stdout_buffer = io.StringIO()
    stderr_buffer = io.StringIO()
    with redirect_stdout(stdout_buffer), redirect_stderr(stderr_buffer):
        go_daemon._emit_handler_logs(
            {"fn": "hello", "version": "v2"},
            {"stdout": "line one", "stderr": "warn one\nwarn two"},
        )
    assert "[fn:hello@v2 stdout] line one" in stdout_buffer.getvalue()
    assert "[fn:hello@v2 stderr] warn one" in stderr_buffer.getvalue()
    assert "[fn:hello@v2 stderr] warn two" in stderr_buffer.getvalue()


def test_ensure_go_binary_reuses_disk_metadata() -> None:
    class Proc:
        def __init__(self, returncode=0, stdout="", stderr=""):
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "app.go"
        handler.write_text(
            "package main\nfunc handler(event map[string]interface{}) map[string]interface{} { return map[string]interface{}{\"ok\": true} }\n",
            encoding="utf-8",
        )

        old_cache = go_daemon._BINARY_CACHE.copy()
        old_which = go_daemon.shutil.which
        old_run = go_daemon.subprocess.run
        try:
            go_daemon._BINARY_CACHE.clear()
            go_daemon.shutil.which = lambda name: "/usr/bin/go" if name == "go" else None
            calls = {"n": 0}

            def fake_run(cmd, cwd, capture_output, text, timeout, check):  # noqa: ARG001
                calls["n"] += 1
                out = Path(cwd)
                (out / "fn_handler").write_text("#!/bin/sh\necho ok\n", encoding="utf-8")
                return Proc(returncode=0)

            go_daemon.subprocess.run = fake_run
            b1 = go_daemon._ensure_go_binary(handler)
            assert b1.is_file(), b1
            assert calls["n"] == 1, calls

            go_daemon._BINARY_CACHE.clear()
            go_daemon.subprocess.run = lambda *_a, **_k: (_ for _ in ()).throw(AssertionError("unexpected rebuild"))
            b2 = go_daemon._ensure_go_binary(handler)
            assert b2 == b1
        finally:
            go_daemon._BINARY_CACHE.clear()
            go_daemon._BINARY_CACHE.update(old_cache)
            go_daemon.shutil.which = old_which
            go_daemon.subprocess.run = old_run


def test_handle_request_sets_process_env_from_function_env() -> None:
    old_resolve = go_daemon._resolve_handler_path
    old_binary = go_daemon._ensure_go_binary
    old_env = go_daemon._read_function_env
    old_run_prepared = go_daemon._run_prepared_request_persistent
    seen = {}
    try:
        go_daemon._resolve_handler_path = lambda *_a, **_k: Path("/tmp/handler.go")  # type: ignore[assignment]
        go_daemon._ensure_go_binary = lambda _p: Path("/tmp/fn_handler")  # type: ignore[assignment]
        go_daemon._read_function_env = lambda _p: {"FN_ENV": "1", "UNIT_PROCESS_ENV": "yes"}  # type: ignore[assignment]

        def fake_run(_pool_key, _handler_path, _binary, event, timeout_ms, settings):
            seen["event"] = event
            seen["timeout_ms"] = timeout_ms
            seen["settings"] = settings
            return {"status": 200, "headers": {}, "body": "ok"}

        go_daemon._run_prepared_request_persistent = fake_run  # type: ignore[assignment]
        resp = go_daemon._handle_request(
            {"fn": "demo", "event": {"env": {"A": "2"}, "context": {"timeout_ms": 100}}}
        )
        assert resp["status"] == 200
        assert seen["event"]["env"]["A"] == "2"
        assert seen["event"]["env"]["FN_ENV"] == "1"
        assert seen["timeout_ms"] == 100
        assert seen["settings"]["max_workers"] == 1
    finally:
        go_daemon._resolve_handler_path = old_resolve
        go_daemon._ensure_go_binary = old_binary
        go_daemon._read_function_env = old_env
        go_daemon._run_prepared_request_persistent = old_run_prepared


def test_go_wrapper_merges_params_into_event() -> None:
    """Go wrapper template merges event.params into top-level event map."""
    template = go_daemon._WRAPPER_TEMPLATE
    assert 'event["params"].(map[string]interface{})' in template, \
        "wrapper must extract params from event"
    assert "event[k] = v" in template, \
        "wrapper must merge params into event"
    assert "!exists" in template, \
        "wrapper must not overwrite existing event keys"


def test_go_wrapper_params_merge_runs_in_handler_request() -> None:
    """Params in event should be passed through to the Go handler."""
    old_resolve = go_daemon._resolve_handler_path
    old_binary = go_daemon._ensure_go_binary
    old_env = go_daemon._read_function_env
    old_run_prepared = go_daemon._run_prepared_request_persistent
    seen = {}
    try:
        go_daemon._resolve_handler_path = lambda *_a, **_k: Path("/tmp/handler.go")
        go_daemon._ensure_go_binary = lambda _p: Path("/tmp/fn_handler")
        go_daemon._read_function_env = lambda _p: {}

        def fake_run(_pool_key, _handler_path, _binary, event, timeout_ms, settings):
            seen["event"] = event
            seen["settings"] = settings
            return {"status": 200, "headers": {}, "body": "ok"}

        go_daemon._run_prepared_request_persistent = fake_run
        resp = go_daemon._handle_request(
            {"fn": "demo", "event": {"params": {"id": "42", "slug": "hello"}}}
        )
        assert resp["status"] == 200
        assert seen["event"]["params"]["id"] == "42"
        assert seen["event"]["params"]["slug"] == "hello"
        assert seen["settings"]["max_workers"] == 1
    finally:
        go_daemon._resolve_handler_path = old_resolve
        go_daemon._ensure_go_binary = old_binary
        go_daemon._read_function_env = old_env
        go_daemon._run_prepared_request_persistent = old_run_prepared


def test_go_wrapper_template_builds_with_stub_handler() -> None:
    go_cmd = shutil.which("go")
    if go_cmd is None:
        return

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        (tmpdir / "go.mod").write_text("module fastfnwrappertest\n\ngo 1.20\n", encoding="utf-8")
        (tmpdir / "handler.go").write_text(
            "package main\n\nfunc handler(event map[string]interface{}) interface{} {\n    return map[string]interface{}{\"status\": 200, \"headers\": map[string]interface{}{}, \"body\": \"ok\"}\n}\n",
            encoding="utf-8",
        )
        (tmpdir / "fastfn_entry.go").write_text(
            go_daemon._WRAPPER_TEMPLATE.replace("__FASTFN_HANDLER__", "handler"),
            encoding="utf-8",
        )

        proc = subprocess.run(
            [go_cmd, "build", "./..."],
            cwd=tmp,
            capture_output=True,
            text=True,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr


def main() -> None:
    test_write_frame_roundtrip()
    test_write_frame_fallback_for_unserializable_payload()
    test_write_frame_fallback_for_oversized_payload()
    test_read_frame_invalid_utf8()
    test_read_frame_invalid_json()
    test_read_frame_non_object_json()
    test_read_frame_oversized_length()
    test_serve_conn_ignores_client_disconnect_on_write()
    test_prepare_socket_path_tolerates_stat_race()
    test_build_process_env_merges_without_mutating_global_env()
    test_resolve_go_command_uses_fn_go_bin_override()
    test_emit_handler_logs_writes_prefixed_output()
    test_ensure_go_binary_reuses_disk_metadata()
    test_handle_request_sets_process_env_from_function_env()
    test_go_wrapper_merges_params_into_event()
    test_go_wrapper_params_merge_runs_in_handler_request()
    test_go_wrapper_template_builds_with_stub_handler()
    print("go runtime unit tests passed")


if __name__ == "__main__":
    main()
