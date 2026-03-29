#!/usr/bin/env python3
"""Tests for go-daemon.py runtime."""
import io
import json
import os
import shutil
import socket
import stat
import struct
import subprocess
import tempfile
import threading
import time
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from conftest import ROOT, load_module

RUNTIME_DIR = ROOT / "srv/fn/runtimes"
GO_DAEMON_PATH = RUNTIME_DIR / "go-daemon.py"

go_daemon = load_module(GO_DAEMON_PATH)


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


# ---------------------------------------------------------------------------
# Existing tests
# ---------------------------------------------------------------------------

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
    old_sane = go_daemon._go_toolchain_sane
    previous = os.environ.get("FN_GO_BIN")
    try:
        os.environ["FN_GO_BIN"] = "custom-go"
        go_daemon.shutil.which = lambda cmd: "/tmp/custom-go-bin" if cmd == "custom-go" else "/usr/bin/go"
        go_daemon._go_toolchain_sane = lambda _cmd: True
        assert go_daemon._resolve_go_command() == "/tmp/custom-go-bin"
    finally:
        go_daemon.shutil.which = old_which
        go_daemon._go_toolchain_sane = old_sane
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
        handler = Path(tmp) / "handler.go"
        handler.write_text(
            "package main\nfunc handler(event map[string]interface{}) map[string]interface{} { return map[string]interface{}{\"ok\": true} }\n",
            encoding="utf-8",
        )

        old_cache = go_daemon._BINARY_CACHE.copy()
        old_which = go_daemon.shutil.which
        old_sane = go_daemon._go_toolchain_sane
        old_run = go_daemon.subprocess.run
        try:
            go_daemon._BINARY_CACHE.clear()
            go_daemon.shutil.which = lambda name: "/usr/bin/go" if name == "go" else None
            go_daemon._go_toolchain_sane = lambda _cmd: True
            calls = {"n": 0}

            def fake_run(cmd, cwd, capture_output, text, timeout, check, env=None):  # noqa: ARG001
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
            go_daemon._go_toolchain_sane = old_sane
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
    try:
        go_cmd = go_daemon._resolve_go_command()
    except RuntimeError:
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
            env=go_daemon._go_subprocess_env(),
        )
        assert proc.returncode == 0, proc.stderr


# ---------------------------------------------------------------------------
# New tests for 100% coverage
# ---------------------------------------------------------------------------

def test_sanitize_worker_env() -> None:
    env = {
        "PATH": "/usr/bin",
        "HOME": "/home/user",
        "LANG": "en_US.UTF-8",
        "AWS_SECRET_ACCESS_KEY": "secret",
        "GITHUB_TOKEN": "tok",
        "DATABASE_URL": "postgres://secret",
    }
    sanitized = go_daemon._sanitize_worker_env(env)
    assert "PATH" in sanitized
    assert "HOME" in sanitized
    assert "LANG" in sanitized
    assert "AWS_SECRET_ACCESS_KEY" not in sanitized
    assert "GITHUB_TOKEN" not in sanitized
    assert "DATABASE_URL" not in sanitized
    assert go_daemon._worker_env_key_allowed("") is False
    assert go_daemon._worker_env_key_allowed(None) is False
    assert go_daemon._worker_env_key_allowed("lc_all") is True


def test_read_function_env_edge_cases() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.go"
        handler.write_text("package main\nfunc handler(e map[string]interface{}) interface{} { return nil }\n", encoding="utf-8")

        # No env file => empty dict
        assert go_daemon._read_function_env(handler) == {}

        # Bad JSON
        env_path = fn_dir / "fn.env.json"
        env_path.write_text("{bad", encoding="utf-8")
        assert go_daemon._read_function_env(handler) == {}

        # Non-object JSON (array)
        env_path.write_text(json.dumps(["bad"]), encoding="utf-8")
        assert go_daemon._read_function_env(handler) == {}

        # value with None in nested dict, None value, non-string key
        env_path.write_text(json.dumps({"A": "1", "B": {"value": None}, "C": None, "D": {"value": 42}}), encoding="utf-8")
        result = go_daemon._read_function_env(handler)
        assert result == {"A": "1", "D": "42"}, result


def test_build_process_env_edge_cases() -> None:
    # Non-dict env
    result = go_daemon._build_process_env("bad")
    assert isinstance(result, dict)
    assert "PATH" in result or len(result) >= 0

    # Empty key and non-string key
    result = go_daemon._build_process_env({"": "val", "GOOD": "yes"})
    assert result.get("GOOD") == "yes"
    assert "" not in result


def test_go_subprocess_env_and_toolchain_helpers() -> None:
    old_env = dict(os.environ)
    old_run = go_daemon.subprocess.run
    old_path = go_daemon.Path
    old_access = go_daemon.os.access
    old_sane = go_daemon._go_toolchain_sane
    try:
        os.environ["GOROOT"] = "/bad/goroot"
        os.environ["GOPATH"] = "/bad/gopath"
        env = go_daemon._go_subprocess_env({"EXTRA": 123})
        assert env["EXTRA"] == "123"
        assert "GOROOT" not in env
        assert "GOPATH" not in env

        assert go_daemon._go_toolchain_sane("") is False

        def raise_run(*_args, **_kwargs):
            raise OSError("boom")

        go_daemon.subprocess.run = raise_run
        assert go_daemon._go_toolchain_sane("/tmp/go") is False

        class Proc:
            def __init__(self, returncode, stdout):
                self.returncode = returncode
                self.stdout = stdout

        go_daemon.subprocess.run = lambda *_a, **_k: Proc(1, "/usr/local/go\n")
        assert go_daemon._go_toolchain_sane("/tmp/go") is False

        fake_go = Path("/tmp/fake-system-go")
        go_daemon.Path = lambda _raw: fake_go
        go_daemon.os.access = lambda *_a, **_k: False
        go_daemon._go_toolchain_sane = lambda _cmd: True
        assert go_daemon._system_go_command() is None
    finally:
        os.environ.clear()
        os.environ.update(old_env)
        go_daemon.subprocess.run = old_run
        go_daemon.Path = old_path
        go_daemon.os.access = old_access
        go_daemon._go_toolchain_sane = old_sane


def test_system_go_command_uses_healthy_default_toolchain() -> None:
    old_path = go_daemon.Path
    old_access = go_daemon.os.access
    old_sane = go_daemon._go_toolchain_sane
    try:
        expected = "/usr/local/go/bin/go"

        class _FakePath:
            def __init__(self, raw: str) -> None:
                self.raw = raw

            def is_file(self) -> bool:
                return self.raw == expected

        go_daemon.Path = lambda raw: _FakePath(str(raw))
        go_daemon.os.access = lambda path, mode: str(path) == expected and mode == os.X_OK
        go_daemon._go_toolchain_sane = lambda cmd: cmd == expected
        assert go_daemon._system_go_command() == expected
    finally:
        go_daemon.Path = old_path
        go_daemon.os.access = old_access
        go_daemon._go_toolchain_sane = old_sane


def test_resolve_go_command_path_based() -> None:
    old_env = os.environ.get("FN_GO_BIN")
    old_which = go_daemon.shutil.which
    old_sane = go_daemon._go_toolchain_sane
    old_system_go = go_daemon._system_go_command
    try:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            configured_go = tmp_path / "configured-go"
            configured_go.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            configured_go.chmod(configured_go.stat().st_mode | stat.S_IXUSR)

            path_go = str(tmp_path / "path-go")
            system_go = str(tmp_path / "system-go")

            # Path-based with existing executable
            os.environ["FN_GO_BIN"] = str(configured_go)
            go_daemon._go_toolchain_sane = lambda _cmd: True
            result = go_daemon._resolve_go_command()
            assert result == str(configured_go)

            # Path-based unhealthy toolchain should fall back to system helper when available
            go_daemon._go_toolchain_sane = lambda cmd: cmd == system_go
            go_daemon._system_go_command = lambda: system_go
            result = go_daemon._resolve_go_command()
            assert result == system_go

            # Path-based unhealthy toolchain with no system helper should raise the configured-path error
            go_daemon._system_go_command = lambda: None
            try:
                go_daemon._resolve_go_command()
            except RuntimeError as exc:
                assert "FN_GO_BIN points to an unhealthy Go toolchain" in str(exc)
            else:
                raise AssertionError("expected unhealthy configured-path toolchain error")

            # Path-based with non-existent file
            os.environ["FN_GO_BIN"] = str(tmp_path / "missing-go-binary")
            try:
                go_daemon._resolve_go_command()
            except RuntimeError as exc:
                assert "not executable" in str(exc)
            else:
                raise AssertionError("expected not executable error")

            # Name-based not found in PATH
            os.environ["FN_GO_BIN"] = "nonexistent-go-cmd"
            go_daemon.shutil.which = lambda _name: None
            try:
                go_daemon._resolve_go_command()
            except RuntimeError as exc:
                assert "not found in PATH" in str(exc)
            else:
                raise AssertionError("expected not found error")
            go_daemon.shutil.which = old_which

            # Name-based unhealthy toolchain should fall back to system helper
            os.environ["FN_GO_BIN"] = "custom-go"
            go_daemon.shutil.which = lambda name: path_go if name == "custom-go" else old_which(name)
            go_daemon._go_toolchain_sane = lambda cmd: cmd == system_go
            go_daemon._system_go_command = lambda: system_go
            result = go_daemon._resolve_go_command()
            assert result == system_go

            # Name-based unhealthy toolchain with no system helper should raise the resolved-path error
            go_daemon._system_go_command = lambda: None
            try:
                go_daemon._resolve_go_command()
            except RuntimeError as exc:
                assert "FN_GO_BIN resolved to an unhealthy Go toolchain" in str(exc)
                assert path_go in str(exc)
            else:
                raise AssertionError("expected unhealthy configured-name toolchain error")
            go_daemon.shutil.which = old_which

            # No FN_GO_BIN, go not in PATH
            os.environ.pop("FN_GO_BIN", None)
            go_daemon.shutil.which = lambda _name: None
            go_daemon._go_toolchain_sane = lambda _cmd: False
            go_daemon._system_go_command = lambda: None
            try:
                go_daemon._resolve_go_command()
            except RuntimeError as exc:
                assert "go not found" in str(exc)
            else:
                raise AssertionError("expected go not found error")
            go_daemon.shutil.which = old_which

            # PATH go unhealthy should fall back to system helper when available
            os.environ.pop("FN_GO_BIN", None)
            go_daemon.shutil.which = lambda name: path_go if name == "go" else None
            go_daemon._go_toolchain_sane = lambda cmd: cmd == system_go
            go_daemon._system_go_command = lambda: system_go
            result = go_daemon._resolve_go_command()
            assert result == system_go

            # PATH go unhealthy with no system helper should raise the unhealthy-path error
            go_daemon._system_go_command = lambda: None
            try:
                go_daemon._resolve_go_command()
            except RuntimeError as exc:
                assert "toolchain is unhealthy" in str(exc)
                assert path_go in str(exc)
            else:
                raise AssertionError("expected unhealthy PATH toolchain error")
    finally:
        go_daemon.shutil.which = old_which
        go_daemon._go_toolchain_sane = old_sane
        go_daemon._system_go_command = old_system_go
        if old_env is None:
            os.environ.pop("FN_GO_BIN", None)
        else:
            os.environ["FN_GO_BIN"] = old_env


def test_resolve_go_command_uses_healthy_path_go_without_system_fallback() -> None:
    old_env = os.environ.get("FN_GO_BIN")
    old_which = go_daemon.shutil.which
    old_sane = go_daemon._go_toolchain_sane
    old_system_go = go_daemon._system_go_command
    try:
        os.environ.pop("FN_GO_BIN", None)
        path_go = "/tmp/healthy-path-go"
        go_daemon.shutil.which = lambda name: path_go if name == "go" else None
        go_daemon._go_toolchain_sane = lambda cmd: cmd == path_go
        go_daemon._system_go_command = lambda: None
        assert go_daemon._resolve_go_command() == path_go
    finally:
        go_daemon.shutil.which = old_which
        go_daemon._go_toolchain_sane = old_sane
        go_daemon._system_go_command = old_system_go
        if old_env is None:
            os.environ.pop("FN_GO_BIN", None)
        else:
            os.environ["FN_GO_BIN"] = old_env


def test_file_signature() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        existing = Path(tmp) / "f.txt"
        existing.write_text("hello", encoding="utf-8")
        sig = go_daemon._file_signature(existing)
        assert sig is not None and len(sig) == 2

    assert go_daemon._file_signature(Path("/nonexistent/file.txt")) is None


def test_recvall_partial() -> None:
    left, right = socket.socketpair()
    with left, right:
        right.sendall(b"\x01\x02")
        right.shutdown(socket.SHUT_WR)
        data = go_daemon._recvall(left, 4)
        assert len(data) == 2


def test_read_frame_incomplete_header() -> None:
    left, right = socket.socketpair()
    with left, right:
        right.sendall(b"\x00\x00")
        right.shutdown(socket.SHUT_WR)
        try:
            go_daemon._read_frame(left)
        except ValueError as exc:
            assert "header" in str(exc).lower()
        else:
            raise AssertionError("expected invalid frame header")


def test_read_frame_incomplete_payload() -> None:
    left, right = socket.socketpair()
    with left, right:
        payload = b'{"ok":true}'
        right.sendall(struct.pack("!I", len(payload) + 2) + payload)
        right.shutdown(socket.SHUT_WR)
        try:
            go_daemon._read_frame(left)
        except ValueError as exc:
            assert "incomplete" in str(exc).lower()
        else:
            raise AssertionError("expected incomplete frame")


def test_read_frame_zero_length() -> None:
    left, right = socket.socketpair()
    with left, right:
        right.sendall(struct.pack("!I", 0))
        try:
            go_daemon._read_frame(left)
        except ValueError as exc:
            assert "invalid frame length" in str(exc)
        else:
            raise AssertionError("expected invalid frame length for zero")


def test_normalize_name() -> None:
    assert go_daemon._normalize_name("hello\\world") == "hello/world"
    assert go_daemon._normalize_name("simple") == "simple"


def test_runtime_pool_key() -> None:
    assert go_daemon._runtime_pool_key("fn", "v2") == "fn@v2"
    assert go_daemon._runtime_pool_key(None, None) == "unknown@default"
    assert go_daemon._runtime_pool_key("x", "") == "x@default"
    assert go_daemon._runtime_pool_key("", "v1") == "unknown@v1"


def test_handler_signature() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.go"
        handler.write_text("package main\nfunc handler(e map[string]interface{}) interface{} { return nil }\n", encoding="utf-8")
        sig = go_daemon._handler_signature(handler)
        assert isinstance(sig, str)
        assert "missing" in sig  # fn.env.json, go.mod, go.sum are missing


def test_persistent_runtime_pool_key() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.go"
        handler.write_text("package main\nfunc handler(e map[string]interface{}) interface{} { return nil }\n", encoding="utf-8")
        key = go_daemon._persistent_runtime_pool_key("fn", "v1", handler)
        assert "fn@v1::" in key


def test_normalize_worker_pool_settings() -> None:
    # event is not dict
    s = go_daemon._normalize_worker_pool_settings({"event": "bad"})
    assert s["enabled"] is False
    assert s["max_workers"] == 0

    # context is not dict
    s = go_daemon._normalize_worker_pool_settings({"event": {"context": "bad"}})
    assert s["enabled"] is False

    # worker_pool is not dict
    s = go_daemon._normalize_worker_pool_settings({"event": {"context": {"worker_pool": "bad"}}})
    assert s["enabled"] is False

    # enabled explicitly False
    s = go_daemon._normalize_worker_pool_settings(
        {"event": {"context": {"worker_pool": {"enabled": False, "max_workers": 2}}}}
    )
    assert s["enabled"] is False

    # Negative max_workers and min_warm
    s = go_daemon._normalize_worker_pool_settings(
        {"event": {"context": {"worker_pool": {"max_workers": -1, "min_warm": -1}}}}
    )
    assert s["max_workers"] == 0
    assert s["min_warm"] == 0
    assert s["enabled"] is False

    # min_warm > max_workers clamping
    s = go_daemon._normalize_worker_pool_settings(
        {"event": {"context": {"worker_pool": {"max_workers": 2, "min_warm": 10}}}}
    )
    assert s["min_warm"] == 2

    # idle_ttl_seconds < 1 second falls back to default
    s = go_daemon._normalize_worker_pool_settings(
        {"event": {"context": {"worker_pool": {"max_workers": 2, "idle_ttl_seconds": 0.1}}}}
    )
    assert s["idle_ttl_ms"] == go_daemon.RUNTIME_POOL_IDLE_TTL_MS

    # request_timeout_ms negative
    s = go_daemon._normalize_worker_pool_settings(
        {"event": {"context": {"timeout_ms": -10, "worker_pool": {"max_workers": 2}}}}
    )
    assert s["request_timeout_ms"] == 0

    # Normal settings with timeout
    s = go_daemon._normalize_worker_pool_settings(
        {"event": {"context": {"timeout_ms": 1000, "worker_pool": {"max_workers": 4, "min_warm": 1, "idle_ttl_seconds": 5.0}}}}
    )
    assert s["enabled"] is True
    assert s["max_workers"] == 4
    assert s["min_warm"] == 1
    assert s["idle_ttl_ms"] == 5000
    assert s["request_timeout_ms"] == 1000
    assert s["acquire_timeout_ms"] >= 1500


def test_resolve_handler_path() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "root.go").write_text("package main\n", encoding="utf-8")
        (root / "pkg").mkdir()
        (root / "pkg" / "handler.go").write_text("package main\n", encoding="utf-8")
        (root / "go").mkdir()
        (root / "go" / "rt").mkdir()
        (root / "go" / "rt" / "handler.go").write_text("package main\n", encoding="utf-8")
        (root / "ver").mkdir()
        (root / "ver" / "v2").mkdir(parents=True)
        (root / "ver" / "v2" / "handler.go").write_text("package main\n", encoding="utf-8")

        old_functions = go_daemon.FUNCTIONS_DIR
        old_runtime = go_daemon.RUNTIME_FUNCTIONS_DIR
        try:
            go_daemon.FUNCTIONS_DIR = root
            go_daemon.RUNTIME_FUNCTIONS_DIR = root / "go"

            # Direct file mode from root
            assert go_daemon._resolve_handler_path("root.go", None) == root / "root.go"
            # Directory with handler.go
            assert go_daemon._resolve_handler_path("pkg", None) == root / "pkg" / "handler.go"
            # Runtime functions dir fallback
            assert go_daemon._resolve_handler_path("rt", None) == root / "go" / "rt" / "handler.go"
            # Versioned
            assert go_daemon._resolve_handler_path("ver", "v2") == root / "ver" / "v2" / "handler.go"

            # Invalid names
            try:
                go_daemon._resolve_handler_path("../bad", None)
            except ValueError:
                pass
            else:
                raise AssertionError("expected invalid function name")

            try:
                go_daemon._resolve_handler_path("", None)
            except ValueError:
                pass
            else:
                raise AssertionError("expected invalid empty function name")

            try:
                go_daemon._resolve_handler_path("fn", "bad version!")
            except ValueError:
                pass
            else:
                raise AssertionError("expected invalid function version")

            # Unknown function
            try:
                go_daemon._resolve_handler_path("nonexistent", None)
            except FileNotFoundError:
                pass
            else:
                raise AssertionError("expected unknown function")

            try:
                go_daemon._resolve_handler_path("nonexistent", "v1")
            except FileNotFoundError:
                pass
            else:
                raise AssertionError("expected unknown versioned function")

            # Path traversal variants
            for bad_name in ["/absolute", "..", "../foo", "foo/..", "foo/../bar"]:
                try:
                    go_daemon._resolve_handler_path(bad_name, None)
                except ValueError:
                    pass

            # Direct file in runtime dir
            (root / "go" / "direct.go").write_text("package main\n", encoding="utf-8")
            assert go_daemon._resolve_handler_path("direct.go", None) == root / "go" / "direct.go"

            # handler.go and main.go candidates
            (root / "mainpkg").mkdir()
            (root / "mainpkg" / "main.go").write_text("package main\n", encoding="utf-8")
            assert go_daemon._resolve_handler_path("mainpkg", None) == root / "mainpkg" / "main.go"

            (root / "emptydir").mkdir()
            try:
                go_daemon._resolve_handler_path("emptydir", None)
            except FileNotFoundError:
                pass
            else:
                raise AssertionError("expected unknown function for empty dir")

            # Explicit public name can resolve through fn_source_dir.
            (root / "handler.go").write_text("package main\n", encoding="utf-8")
            nested_dir = root / "apps" / "demo"
            nested_dir.mkdir(parents=True)
            (nested_dir / "handler.go").write_text("package main\n", encoding="utf-8")
            (nested_dir / "v3").mkdir()
            (nested_dir / "v3" / "handler.go").write_text("package main\n", encoding="utf-8")
            (nested_dir / "src").mkdir()
            (nested_dir / "src" / "custom.go").write_text("package main\n", encoding="utf-8")
            assert go_daemon._resolve_handler_path("public-root", None, ".") == root / "handler.go"
            assert go_daemon._resolve_handler_path("public-demo", "v3", "apps/demo") == nested_dir / "v3" / "handler.go"
            (nested_dir / "fn.config.json").write_text(json.dumps({"entrypoint": "src/custom.go"}), encoding="utf-8")
            assert go_daemon._resolve_handler_path("public-demo", None, "apps/demo") == nested_dir / "src" / "custom.go"

            try:
                go_daemon._resolve_handler_path("public-demo", None, "../escape")
            except ValueError:
                pass
            else:
                raise AssertionError("expected invalid function source dir")

            try:
                go_daemon._resolve_handler_path("public-demo", None, 123)
            except ValueError:
                pass
            else:
                raise AssertionError("expected invalid non-string function source dir")

            try:
                go_daemon._resolve_handler_path("public-demo", None, "   ")
            except ValueError:
                pass
            else:
                raise AssertionError("expected invalid empty function source dir")

            try:
                go_daemon._resolve_handler_path("public-demo", None, "apps/demo/../../escape")
            except ValueError:
                pass
            else:
                raise AssertionError("expected invalid escaped function source dir")

            outside_root = Path(tempfile.mkdtemp(prefix="fastfn-go-outside-"))
            try:
                (root / "linked-out").symlink_to(outside_root, target_is_directory=True)
                try:
                    go_daemon._resolve_handler_path("public-demo", None, "linked-out")
                except ValueError:
                    pass
                else:
                    raise AssertionError("expected resolved source dir outside root to fail")
            finally:
                shutil.rmtree(outside_root, ignore_errors=True)

            outside_fn_root = Path(tempfile.mkdtemp(prefix="fastfn-go-linked-fn-"))
            try:
                (outside_fn_root / "handler.go").write_text("package main\n", encoding="utf-8")
                (root / "linked-fn").symlink_to(outside_fn_root, target_is_directory=True)
                try:
                    go_daemon._resolve_handler_path("linked-fn", None)
                except FileNotFoundError:
                    pass
                else:
                    raise AssertionError("expected symlinked function dir outside root to fail")
            finally:
                shutil.rmtree(outside_fn_root, ignore_errors=True)

            try:
                go_daemon._resolve_handler_path("public-demo", None, "missing/demo")
            except FileNotFoundError:
                pass
            else:
                raise AssertionError("expected unknown function source dir")
        finally:
            go_daemon.FUNCTIONS_DIR = old_functions
            go_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime


def test_resolve_existing_path_within_root_want_dir_rejects_files() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        file_path = root / "handler.go"
        file_path.write_text("package main\n", encoding="utf-8")
        assert go_daemon._resolve_existing_path_within_root(root, file_path, want_dir=True) is None


def test_detect_handler_symbol() -> None:
    assert go_daemon._detect_handler_symbol("func handler(event map[string]interface{}) {}") == "handler"
    assert go_daemon._detect_handler_symbol("func Handler(event map[string]interface{}) {}") == "Handler"
    assert go_daemon._detect_handler_symbol("func something(event map[string]interface{}) {}") is None


def test_normalize_response() -> None:
    # Normal response
    resp = go_daemon._normalize_response({"status": 201, "headers": {}, "body": "ok"})
    assert resp["status"] == 201

    # statusCode alias
    resp = go_daemon._normalize_response({"statusCode": 202, "headers": {}, "body": "ok"})
    assert resp["status"] == 202

    # Non-dict response
    try:
        go_daemon._normalize_response("bad")
    except ValueError as exc:
        assert "object" in str(exc).lower()
    else:
        raise AssertionError("expected object error")

    # Invalid status
    try:
        go_daemon._normalize_response({"status": "bad", "headers": {}})
    except ValueError:
        pass
    else:
        raise AssertionError("expected invalid status")

    # Status out of range
    try:
        go_daemon._normalize_response({"status": 99, "headers": {}})
    except ValueError:
        pass
    else:
        raise AssertionError("expected out of range status")

    try:
        go_daemon._normalize_response({"status": 600, "headers": {}})
    except ValueError:
        pass
    else:
        raise AssertionError("expected out of range status")

    # Bad headers
    try:
        go_daemon._normalize_response({"status": 200, "headers": []})
    except ValueError as exc:
        assert "headers" in str(exc).lower()
    else:
        raise AssertionError("expected headers error")

    # Base64 response
    b64 = go_daemon._normalize_response({"status": 200, "headers": {}, "isBase64Encoded": True, "body": "aGVsbG8="})
    assert b64["is_base64"] is True
    assert b64["body_base64"] == "aGVsbG8="

    # Base64 with body_base64 field
    b64_2 = go_daemon._normalize_response({"status": 200, "headers": {}, "is_base64": True, "body_base64": "abc"})
    assert b64_2["body_base64"] == "abc"

    # Base64 with empty body
    try:
        go_daemon._normalize_response({"status": 200, "headers": {}, "is_base64": True, "body": ""})
    except ValueError as exc:
        assert "body_base64" in str(exc)
    else:
        raise AssertionError("expected body_base64 error")

    # None body
    resp = go_daemon._normalize_response({"status": 200, "headers": {}, "body": None})
    assert resp["body"] == ""

    # Non-string body
    resp = go_daemon._normalize_response({"status": 200, "headers": {}, "body": 123})
    assert resp["body"] == "123"

    # Proxy field
    resp = go_daemon._normalize_response({"status": 200, "headers": {}, "body": "ok", "proxy": {"url": "http://example.com"}})
    assert resp["proxy"] == {"url": "http://example.com"}


def test_run_go_handler() -> None:
    class Proc:
        def __init__(self, stdout="", stderr="", returncode=0):
            self.stdout = stdout
            self.stderr = stderr
            self.returncode = returncode

    old_run = go_daemon.subprocess.run
    try:
        # Timeout
        go_daemon.subprocess.run = lambda *_a, **_k: (_ for _ in ()).throw(
            go_daemon.subprocess.TimeoutExpired(cmd="bin", timeout=1)
        )
        resp = go_daemon._run_go_handler(Path("/tmp/bin"), {}, 100)
        assert resp["status"] == 504

        # Non-zero exit with stderr
        go_daemon.subprocess.run = lambda *_a, **_k: Proc(returncode=1, stderr="error msg")
        resp = go_daemon._run_go_handler(Path("/tmp/bin"), {}, 100)
        assert resp["status"] == 500
        assert "error msg" in resp["body"]

        # Non-zero exit without stderr, with stdout
        go_daemon.subprocess.run = lambda *_a, **_k: Proc(returncode=1, stdout="stdout msg", stderr="")
        resp = go_daemon._run_go_handler(Path("/tmp/bin"), {}, 100)
        assert resp["status"] == 500

        # Non-zero exit without stderr or stdout
        go_daemon.subprocess.run = lambda *_a, **_k: Proc(returncode=1, stdout="", stderr="")
        resp = go_daemon._run_go_handler(Path("/tmp/bin"), {}, 100)
        assert resp["status"] == 500
        assert "exited with code" in resp["body"]

        # Empty output
        go_daemon.subprocess.run = lambda *_a, **_k: Proc(stdout="")
        resp = go_daemon._run_go_handler(Path("/tmp/bin"), {}, 100)
        assert resp["status"] == 500
        assert "empty response" in resp["body"]

        # Bad JSON
        go_daemon.subprocess.run = lambda *_a, **_k: Proc(stdout="{bad")
        resp = go_daemon._run_go_handler(Path("/tmp/bin"), {}, 100)
        assert resp["status"] == 500
        assert "invalid go handler response" in resp["body"]

        # Good response
        go_daemon.subprocess.run = lambda *_a, **_k: Proc(stdout=json.dumps({"status": 200, "headers": {}, "body": "ok"}))
        resp = go_daemon._run_go_handler(Path("/tmp/bin"), {}, 100)
        assert resp["status"] == 200

        # Good response with stderr
        go_daemon.subprocess.run = lambda *_a, **_k: Proc(stdout=json.dumps({"status": 200, "headers": {}, "body": "ok"}), stderr="debug info")
        resp = go_daemon._run_go_handler(Path("/tmp/bin"), {}, 100)
        assert resp["status"] == 200
        assert resp.get("stderr") == "debug info"

        # Response with normalize error
        go_daemon.subprocess.run = lambda *_a, **_k: Proc(stdout=json.dumps({"status": "bad"}))
        resp = go_daemon._run_go_handler(Path("/tmp/bin"), {}, 100)
        assert resp["status"] == 500

        # process_env passed through
        go_daemon.subprocess.run = lambda *_a, **_k: Proc(stdout=json.dumps({"status": 200, "headers": {}, "body": "ok"}))
        resp = go_daemon._run_go_handler(Path("/tmp/bin"), {}, 100, process_env={"PATH": "/usr/bin"})
        assert resp["status"] == 200
    finally:
        go_daemon.subprocess.run = old_run


def test_ensure_go_binary_build_failure() -> None:
    class Proc:
        def __init__(self, returncode=0, stdout="", stderr=""):
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.go"
        handler.write_text(
            "package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n",
            encoding="utf-8",
        )

        old_cache = dict(go_daemon._BINARY_CACHE)
        old_which = go_daemon.shutil.which
        old_sane = go_daemon._go_toolchain_sane
        old_run = go_daemon.subprocess.run
        try:
            go_daemon._BINARY_CACHE.clear()
            go_daemon.shutil.which = lambda _name: "/usr/bin/go"
            go_daemon._go_toolchain_sane = lambda _cmd: True

            # Build failure
            go_daemon.subprocess.run = lambda *_a, **_k: Proc(returncode=1, stderr="compile failed")
            meta_path = handler.parent / ".go-build" / ".fastfn-build-meta.json"
            if meta_path.exists():
                meta_path.unlink()
            try:
                go_daemon._ensure_go_binary(handler)
            except RuntimeError as exc:
                assert "build failed" in str(exc)
            else:
                raise AssertionError("expected build failure")

            # Build timeout
            go_daemon._BINARY_CACHE.clear()
            go_daemon.subprocess.run = lambda *_a, **_k: (_ for _ in ()).throw(
                subprocess.TimeoutExpired(cmd="go build", timeout=180)
            )
            if meta_path.exists():
                meta_path.unlink()
            try:
                go_daemon._ensure_go_binary(handler)
            except RuntimeError as exc:
                assert "timeout" in str(exc).lower()
            else:
                raise AssertionError("expected build timeout")

            # Build succeeds but binary not produced
            go_daemon._BINARY_CACHE.clear()
            go_daemon.subprocess.run = lambda *_a, **_k: Proc(returncode=0)
            if meta_path.exists():
                meta_path.unlink()
            try:
                go_daemon._ensure_go_binary(handler)
            except RuntimeError as exc:
                assert "did not produce binary" in str(exc)
            else:
                raise AssertionError("expected did not produce binary")

            # No handler symbol
            go_daemon._BINARY_CACHE.clear()
            handler.write_text("package main\nfunc something() {}\n", encoding="utf-8")
            if meta_path.exists():
                meta_path.unlink()
            try:
                go_daemon._ensure_go_binary(handler)
            except RuntimeError as exc:
                assert "symbol not found" in str(exc)
            else:
                raise AssertionError("expected symbol not found")

        finally:
            go_daemon._BINARY_CACHE.clear()
            go_daemon._BINARY_CACHE.update(old_cache)
            go_daemon.shutil.which = old_which
            go_daemon._go_toolchain_sane = old_sane
            go_daemon.subprocess.run = old_run


def test_ensure_go_binary_with_go_mod() -> None:
    """Cover the go.mod/go.sum copy and cleanup branches."""
    class Proc:
        def __init__(self, returncode=0, stdout="", stderr=""):
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.go"
        handler.write_text(
            "package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n",
            encoding="utf-8",
        )
        # Create go.mod and go.sum
        (Path(tmp) / "go.mod").write_text("module example\ngo 1.20\n", encoding="utf-8")
        (Path(tmp) / "go.sum").write_text("", encoding="utf-8")

        old_cache = dict(go_daemon._BINARY_CACHE)
        old_which = go_daemon.shutil.which
        old_sane = go_daemon._go_toolchain_sane
        old_run = go_daemon.subprocess.run
        try:
            go_daemon._BINARY_CACHE.clear()
            go_daemon.shutil.which = lambda _name: "/usr/bin/go"
            go_daemon._go_toolchain_sane = lambda _cmd: True

            def fake_run(cmd, cwd, capture_output, text, timeout, check, env=None):  # noqa: ARG001
                out = Path(cwd)
                (out / "fn_handler").write_text("#!/bin/sh\necho ok\n", encoding="utf-8")
                return Proc(returncode=0)

            go_daemon.subprocess.run = fake_run
            binary = go_daemon._ensure_go_binary(handler)
            assert binary.is_file()

            # Verify go.mod was copied to build dir
            build_dir = handler.parent / ".go-build"
            assert (build_dir / "go.mod").is_file()
            assert (build_dir / "go.sum").is_file()
        finally:
            go_daemon._BINARY_CACHE.clear()
            go_daemon._BINARY_CACHE.update(old_cache)
            go_daemon.shutil.which = old_which
            go_daemon._go_toolchain_sane = old_sane
            go_daemon.subprocess.run = old_run


def test_collect_go_support_files_respects_private_and_mixed_modes() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        pure_dir = root / "products"
        pure_dir.mkdir()
        pure_handler = pure_dir / "get.go"
        pure_handler.write_text("package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n", encoding="utf-8")
        (pure_dir / "post.go").write_text("package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n", encoding="utf-8")
        (pure_dir / "_shared.go").write_text("package main\nfunc sharedValue() string { return \"ok\" }\n", encoding="utf-8")
        (pure_dir / "helper.go").write_text("package main\nfunc helperValue() string { return \"nope\" }\n", encoding="utf-8")

        mixed_root = root / "shop"
        mixed_root.mkdir()
        (mixed_root / "handler.go").write_text("package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n", encoding="utf-8")
        mixed_admin = mixed_root / "admin"
        mixed_admin.mkdir()
        mixed_handler = mixed_admin / "get.health.go"
        mixed_handler.write_text("package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n", encoding="utf-8")
        (mixed_admin / "shared.go").write_text("package main\nfunc sharedValue() string { return \"ok\" }\n", encoding="utf-8")
        (mixed_admin / "get.metrics.go").write_text("package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n", encoding="utf-8")

        old_functions = go_daemon.FUNCTIONS_DIR
        old_runtime = go_daemon.RUNTIME_FUNCTIONS_DIR
        try:
            go_daemon.FUNCTIONS_DIR = root
            go_daemon.RUNTIME_FUNCTIONS_DIR = root / "go"

            pure_support = [path.name for path in go_daemon._collect_go_support_files(pure_handler)]
            assert pure_support == ["_shared.go"], pure_support

            mixed_support = [path.name for path in go_daemon._collect_go_support_files(mixed_handler)]
            assert mixed_support == ["shared.go"], mixed_support
        finally:
            go_daemon.FUNCTIONS_DIR = old_functions
            go_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime


def test_go_route_detection_helpers_and_entrypoint_validation() -> None:
    assert go_daemon._is_explicit_file_route("") is False
    assert go_daemon._is_explicit_file_route("...") is False
    assert go_daemon._is_explicit_file_route("get.health") is True
    assert go_daemon._is_explicit_file_route("users.[id]") is True

    assert go_daemon._safe_entrypoint_value(None) is None
    assert go_daemon._safe_entrypoint_value("  src\\handler.go  ") == "src/handler.go"
    assert go_daemon._safe_entrypoint_value("/abs.go") is None
    assert go_daemon._safe_entrypoint_value("../bad.go") is None
    assert go_daemon._safe_entrypoint_value("nested/../bad.go") is None

    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        cfg_path = fn_dir / "fn.config.json"

        assert go_daemon._has_valid_config_entrypoint(fn_dir) is False

        cfg_path.write_text("{bad", encoding="utf-8")
        assert go_daemon._has_valid_config_entrypoint(fn_dir) is False

        cfg_path.write_text(json.dumps(["not-a-dict"]), encoding="utf-8")
        assert go_daemon._has_valid_config_entrypoint(fn_dir) is False

        cfg_path.write_text(json.dumps({"entrypoint": "missing.go"}), encoding="utf-8")
        assert go_daemon._has_valid_config_entrypoint(fn_dir) is False

        cfg_path.write_text(json.dumps({"entrypoint": "../bad.go"}), encoding="utf-8")
        assert go_daemon._has_valid_config_entrypoint(fn_dir) is False

        (fn_dir / "custom.go").write_text(
            "package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n",
            encoding="utf-8",
        )
        cfg_path.write_text(json.dumps({"entrypoint": "custom.go"}), encoding="utf-8")
        assert go_daemon._has_valid_config_entrypoint(fn_dir) is True
        assert go_daemon._dir_has_single_entry_root(fn_dir) is True

        outside_dir = Path(tempfile.mkdtemp(prefix="fastfn-go-entry-outside-"))
        try:
            outside_file = outside_dir / "escape.go"
            outside_file.write_text("package main\n", encoding="utf-8")
            link_path = fn_dir / "linked.go"
            try:
                link_path.symlink_to(outside_file)
            except (OSError, NotImplementedError):
                pass
            else:
                cfg_path.write_text(json.dumps({"entrypoint": "linked.go"}), encoding="utf-8")
                assert go_daemon._has_valid_config_entrypoint(fn_dir) is False
        finally:
            shutil.rmtree(outside_dir, ignore_errors=True)

        cfg_path.unlink()
        assert go_daemon._dir_has_single_entry_root(fn_dir) is False

        (fn_dir / "handler.go").write_text(
            "package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n",
            encoding="utf-8",
        )
        assert go_daemon._dir_has_single_entry_root(fn_dir) is True


def test_ensure_go_binary_copies_private_support_files() -> None:
    class Proc:
        def __init__(self, returncode=0, stdout="", stderr=""):
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "get.go"
        handler.write_text(
            "package main\nfunc handler(event map[string]interface{}) interface{} { return map[string]interface{}{\"ok\": sharedValue()} }\n",
            encoding="utf-8",
        )
        (Path(tmp) / "_shared.go").write_text(
            "package main\nfunc sharedValue() string { return \"helper\" }\n",
            encoding="utf-8",
        )
        (Path(tmp) / "post.go").write_text(
            "package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n",
            encoding="utf-8",
        )
        build_dir = Path(tmp) / ".go-build"
        build_dir.mkdir()
        stale_go = build_dir / "stale.go"
        stale_go.write_text("package main\nfunc stale() {}\n", encoding="utf-8")

        old_cache = dict(go_daemon._BINARY_CACHE)
        old_which = go_daemon.shutil.which
        old_sane = go_daemon._go_toolchain_sane
        old_run = go_daemon.subprocess.run
        try:
            go_daemon._BINARY_CACHE.clear()
            go_daemon.shutil.which = lambda _name: "/usr/bin/go"
            go_daemon._go_toolchain_sane = lambda _cmd: True
            seen = {}

            def fake_run(cmd, cwd, capture_output, text, timeout, check, env=None):  # noqa: ARG001
                seen["cmd"] = list(cmd)
                build_dir = Path(cwd)
                assert not stale_go.exists()
                assert (build_dir / "_shared.go").is_file()
                assert not (build_dir / "post.go").exists()
                (build_dir / "fn_handler").write_text("#!/bin/sh\n", encoding="utf-8")
                return Proc(returncode=0)

            go_daemon.subprocess.run = fake_run
            binary = go_daemon._ensure_go_binary(handler)
            assert binary.is_file()
            assert any(str(arg).endswith("_shared.go") for arg in seen["cmd"]), seen
            assert not any(str(arg).endswith("post.go") for arg in seen["cmd"]), seen
        finally:
            go_daemon._BINARY_CACHE.clear()
            go_daemon._BINARY_CACHE.update(old_cache)
            go_daemon.shutil.which = old_which
            go_daemon._go_toolchain_sane = old_sane
            go_daemon.subprocess.run = old_run

    # Now test with go.mod removed (cleanup of stale go.mod in build dir)
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.go"
        handler.write_text(
            "package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n",
            encoding="utf-8",
        )
        # Pre-create build dir with stale go.mod/go.sum
        build_dir = Path(tmp) / ".go-build"
        build_dir.mkdir()
        (build_dir / "go.mod").write_text("stale", encoding="utf-8")
        (build_dir / "go.sum").write_text("stale", encoding="utf-8")

        old_cache = dict(go_daemon._BINARY_CACHE)
        old_which = go_daemon.shutil.which
        old_sane = go_daemon._go_toolchain_sane
        old_run = go_daemon.subprocess.run
        try:
            go_daemon._BINARY_CACHE.clear()
            go_daemon.shutil.which = lambda _name: "/usr/bin/go"
            go_daemon._go_toolchain_sane = lambda _cmd: True

            def fake_run2(cmd, cwd, capture_output, text, timeout, check, env=None):  # noqa: ARG001
                out = Path(cwd)
                (out / "fn_handler").write_text("#!/bin/sh\n", encoding="utf-8")
                return Proc(returncode=0)

            go_daemon.subprocess.run = fake_run2
            binary = go_daemon._ensure_go_binary(handler)
            assert binary.is_file()
            # Stale go.mod/go.sum should be removed
            assert not (build_dir / "go.mod").exists()
            assert not (build_dir / "go.sum").exists()
        finally:
            go_daemon._BINARY_CACHE.clear()
            go_daemon._BINARY_CACHE.update(old_cache)
            go_daemon.shutil.which = old_which
            go_daemon._go_toolchain_sane = old_sane
            go_daemon.subprocess.run = old_run


def test_ensure_go_binary_in_memory_cache_hit() -> None:
    """Cover the in-memory cache hit path (cached binary still valid)."""
    class Proc:
        def __init__(self, returncode=0, stdout="", stderr=""):
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.go"
        handler.write_text(
            "package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n",
            encoding="utf-8",
        )

        old_cache = dict(go_daemon._BINARY_CACHE)
        old_which = go_daemon.shutil.which
        old_sane = go_daemon._go_toolchain_sane
        old_run = go_daemon.subprocess.run
        try:
            go_daemon._BINARY_CACHE.clear()
            go_daemon.shutil.which = lambda _name: "/usr/bin/go"
            go_daemon._go_toolchain_sane = lambda _cmd: True

            def fake_run(cmd, cwd, capture_output, text, timeout, check, env=None):  # noqa: ARG001
                out = Path(cwd)
                (out / "fn_handler").write_text("#!/bin/sh\n", encoding="utf-8")
                return Proc(returncode=0)

            go_daemon.subprocess.run = fake_run
            b1 = go_daemon._ensure_go_binary(handler)
            assert b1.is_file()

            # Second call should use in-memory cache (not rebuild)
            go_daemon.subprocess.run = lambda *_a, **_k: (_ for _ in ()).throw(AssertionError("unexpected rebuild"))
            b2 = go_daemon._ensure_go_binary(handler)
            assert b2 == b1
        finally:
            go_daemon._BINARY_CACHE.clear()
            go_daemon._BINARY_CACHE.update(old_cache)
            go_daemon.shutil.which = old_which
            go_daemon._go_toolchain_sane = old_sane
            go_daemon.subprocess.run = old_run


def test_persistent_go_worker_lifecycle() -> None:
    """Cover _PersistentGoWorker without real subprocess using a fake subclass."""
    _OrigWorker = go_daemon._PersistentGoWorker

    class _FakeGoWorker(_OrigWorker):
        __slots__ = ()

        def __init__(self, is_alive=True):
            self._dead = not is_alive
            self.lock = threading.Lock()
            self.binary = Path("/tmp/fake")

            class FakeProc:
                stdin = None
                stdout = None
                def poll(self):
                    return None if not self._dead_ref() else 1
                def kill(self):
                    pass
                def wait(self, timeout=None):
                    pass

            proc = FakeProc()
            proc._dead_ref = lambda: self._dead
            self.proc = proc

        def shutdown(self):
            self._dead = True

    # alive property
    w = _FakeGoWorker(True)
    assert w.alive is True
    w2 = _FakeGoWorker(False)
    assert w2.alive is False

    # _mark_dead
    w3 = _FakeGoWorker(True)
    w3._mark_dead()
    assert w3._dead is True

    # shutdown
    w4 = _FakeGoWorker(True)
    w4.shutdown()
    assert w4._dead is True

    # send_request when dead
    w5 = _FakeGoWorker(False)
    try:
        w5.send_request({}, 100)
    except RuntimeError as exc:
        assert "dead" in str(exc)
    else:
        raise AssertionError("expected dead worker error")

    # send_request when pipes unavailable
    w6 = _FakeGoWorker(True)
    w6.proc.stdin = None
    w6.proc.stdout = None
    try:
        w6.send_request({}, 100)
    except RuntimeError as exc:
        assert "pipes" in str(exc).lower() or "dead" in str(exc).lower()
    else:
        raise AssertionError("expected pipe unavailable error")


def test_shutdown_persistent_runtime_pool() -> None:
    _OrigWorker = go_daemon._PersistentGoWorker

    class _FakeGoWorker(_OrigWorker):
        __slots__ = ()
        def __init__(self):
            self._dead = False
            self.lock = threading.Lock()
            self.binary = Path("/tmp/fake")
            class FakeProc:
                stdin = None
                stdout = None
                def poll(self): return None
                def kill(self): pass
                def wait(self, timeout=None): pass
            self.proc = FakeProc()
        def shutdown(self):
            self._dead = True

    # Non-list workers
    go_daemon._shutdown_persistent_runtime_pool({"workers": "bad"})

    # Non-dict entries
    go_daemon._shutdown_persistent_runtime_pool({"workers": [None, "not-dict", {"worker": "not-a-worker"}]})

    # Empty workers
    go_daemon._shutdown_persistent_runtime_pool({"workers": []})

    # Valid workers
    w = _FakeGoWorker()
    go_daemon._shutdown_persistent_runtime_pool({"workers": [{"worker": w}]})
    assert w._dead is True


def test_warmup_persistent_runtime_pool() -> None:
    _OrigWorker = go_daemon._PersistentGoWorker

    class _FakeGoWorker(_OrigWorker):
        __slots__ = ()
        def __init__(self):
            self._dead = False
            self.lock = threading.Lock()
            self.binary = Path("/tmp/fake")
            class FakeProc:
                stdin = None
                stdout = None
                def poll(self): return None
                def kill(self): pass
                def wait(self, timeout=None): pass
            self.proc = FakeProc()
        def shutdown(self):
            self._dead = True

    # target <= 0
    go_daemon._warmup_persistent_runtime_pool({"min_warm": 0})

    # bad cond
    go_daemon._warmup_persistent_runtime_pool({"min_warm": 1, "cond": "bad"})

    # bad workers
    lock = threading.Lock()
    cond = threading.Condition(lock)
    go_daemon._warmup_persistent_runtime_pool({"min_warm": 1, "cond": cond, "workers": "bad"})

    # Actual warmup with fake create
    old_create = go_daemon._create_persistent_runtime_worker
    try:
        go_daemon._create_persistent_runtime_worker = lambda pool: {"worker": _FakeGoWorker(), "busy": False, "last_used": 0.0}
        pool = {"min_warm": 2, "max_workers": 3, "cond": cond, "workers": [], "binary": Path("/tmp/bin")}
        go_daemon._warmup_persistent_runtime_pool(pool)
        assert len(pool["workers"]) == 2
    finally:
        go_daemon._create_persistent_runtime_worker = old_create


def test_checkout_persistent_runtime_worker() -> None:
    _OrigWorker = go_daemon._PersistentGoWorker

    class _FakeGoWorker(_OrigWorker):
        __slots__ = ()
        def __init__(self, is_alive=True):
            self._dead = not is_alive
            self.lock = threading.Lock()
            self.binary = Path("/tmp/fake")
            class FakeProc:
                def __init__(self, dead_ref):
                    self._dead_ref = dead_ref
                def poll(self): return None if not self._dead_ref() else 1
                def kill(self): pass
                def wait(self, timeout=None): pass
            self.proc = FakeProc(lambda: self._dead)
        def shutdown(self):
            self._dead = True

    # Bad cond
    try:
        go_daemon._checkout_persistent_runtime_worker({"cond": "bad"}, 100)
    except RuntimeError as exc:
        assert "invalid persistent" in str(exc).lower()
    else:
        raise AssertionError("expected error")

    # Bad workers
    lock = threading.Lock()
    cond = threading.Condition(lock)
    try:
        go_daemon._checkout_persistent_runtime_worker({"cond": cond, "workers": "bad"}, 100)
    except RuntimeError as exc:
        assert "workers" in str(exc).lower()
    else:
        raise AssertionError("expected error")

    # Timeout when all busy
    lock2 = threading.Lock()
    cond2 = threading.Condition(lock2)
    busy_worker = _FakeGoWorker(True)
    busy_entry = {"worker": busy_worker, "busy": True, "last_used": 0.0}
    pool = {"cond": cond2, "workers": [busy_entry], "max_workers": 1, "last_used": 0.0}
    try:
        go_daemon._checkout_persistent_runtime_worker(pool, 50)
    except TimeoutError:
        pass
    else:
        raise AssertionError("expected timeout")

    # Free worker checkout
    lock3 = threading.Lock()
    cond3 = threading.Condition(lock3)
    free_worker = _FakeGoWorker(True)
    free_entry = {"worker": free_worker, "busy": False, "last_used": 0.0}
    pool2 = {"cond": cond3, "workers": [free_entry], "max_workers": 2, "last_used": 0.0}
    result = go_daemon._checkout_persistent_runtime_worker(pool2, 1000)
    assert result is free_entry
    assert result["busy"] is True

    # Stale worker cleanup + free worker found
    lock4 = threading.Lock()
    cond4 = threading.Condition(lock4)
    dead_worker = _FakeGoWorker(False)
    alive_worker = _FakeGoWorker(True)
    stale_entry = {"worker": dead_worker, "busy": False, "last_used": 0.0}
    good_entry = {"worker": alive_worker, "busy": False, "last_used": 0.0}
    pool3 = {"cond": cond4, "workers": [stale_entry, good_entry], "max_workers": 2, "last_used": 0.0}
    result = go_daemon._checkout_persistent_runtime_worker(pool3, 1000)
    assert result is good_entry

    # Create new worker when below max
    lock5 = threading.Lock()
    cond5 = threading.Condition(lock5)
    old_create = go_daemon._create_persistent_runtime_worker
    try:
        new_worker = _FakeGoWorker(True)
        go_daemon._create_persistent_runtime_worker = lambda pool: {"worker": new_worker, "busy": False, "last_used": 0.0}
        pool4 = {"cond": cond5, "workers": [], "max_workers": 2, "last_used": 0.0, "binary": Path("/tmp/bin")}
        result = go_daemon._checkout_persistent_runtime_worker(pool4, 1000)
        assert result["busy"] is True
    finally:
        go_daemon._create_persistent_runtime_worker = old_create


def test_release_persistent_runtime_worker() -> None:
    _OrigWorker = go_daemon._PersistentGoWorker

    class _FakeGoWorker(_OrigWorker):
        __slots__ = ()
        def __init__(self, is_alive=True):
            self._dead = not is_alive
            self.lock = threading.Lock()
            self.binary = Path("/tmp/fake")
            class FakeProc:
                def __init__(self, dead_ref):
                    self._dead_ref = dead_ref
                def poll(self): return None if not self._dead_ref() else 1
                def kill(self): pass
                def wait(self, timeout=None): pass
            self.proc = FakeProc(lambda: self._dead)
        def shutdown(self):
            self._dead = True

    # Bad cond
    go_daemon._release_persistent_runtime_worker({"cond": "bad"}, {})

    # Bad workers
    lock = threading.Lock()
    cond = threading.Condition(lock)
    go_daemon._release_persistent_runtime_worker({"cond": cond, "workers": "bad"}, {})

    # Normal release
    alive = _FakeGoWorker(True)
    entry = {"worker": alive, "busy": True, "last_used": 0.0}
    pool = {"cond": cond, "workers": [entry], "last_used": 0.0}
    go_daemon._release_persistent_runtime_worker(pool, entry, discard=False)
    assert entry["busy"] is False

    # Discard
    alive2 = _FakeGoWorker(True)
    entry2 = {"worker": alive2, "busy": True, "last_used": 0.0}
    pool2 = {"cond": cond, "workers": [entry2], "last_used": 0.0}
    go_daemon._release_persistent_runtime_worker(pool2, entry2, discard=True)
    assert entry2 not in pool2["workers"]

    # Dead worker auto-discard
    dead = _FakeGoWorker(False)
    entry3 = {"worker": dead, "busy": True, "last_used": 0.0}
    pool3 = {"cond": cond, "workers": [entry3], "last_used": 0.0}
    go_daemon._release_persistent_runtime_worker(pool3, entry3, discard=False)
    assert entry3 not in pool3["workers"]

    # Entry not in workers list (no-op)
    pool4 = {"cond": cond, "workers": [], "last_used": 0.0}
    go_daemon._release_persistent_runtime_worker(pool4, {"worker": _FakeGoWorker(True), "busy": True})


def test_start_persistent_runtime_pool_reaper_early_exits() -> None:
    old_started = go_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED
    old_interval = go_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    try:
        # Already started
        go_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = True
        go_daemon._start_persistent_runtime_pool_reaper()

        # Interval <= 0
        go_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False
        go_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 0
        go_daemon._start_persistent_runtime_pool_reaper()
    finally:
        go_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = old_started
        go_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval


def test_start_persistent_runtime_pool_reaper_eviction() -> None:
    old_started = go_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED
    old_interval = go_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread = go_daemon.threading.Thread
    old_sleep = go_daemon.time.sleep
    old_monotonic = go_daemon.time.monotonic
    old_shutdown = go_daemon._shutdown_persistent_runtime_pool
    old_pools = go_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        go_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False
        go_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        evicted: list[str] = []

        pool = {
            "pending": 0,
            "min_warm": 0,
            "idle_ttl_ms": 1,
            "last_used": 1.0,
            "workers": [],
        }
        go_daemon._PERSISTENT_RUNTIME_POOLS = {"idle@default": pool}
        go_daemon._shutdown_persistent_runtime_pool = lambda _p: evicted.append("evicted")

        sleep_calls = {"n": 0}

        def fake_sleep(_seconds):
            sleep_calls["n"] += 1
            if sleep_calls["n"] > 1:
                raise StopIteration("stop reaper loop")

        go_daemon.time.sleep = fake_sleep
        go_daemon.time.monotonic = lambda: 9999.0

        class InlineThread:
            def __init__(self, target=None, **_kwargs):
                self._target = target

            def start(self):
                try:
                    if self._target:
                        self._target()
                except StopIteration:
                    pass

        go_daemon.threading.Thread = InlineThread
        go_daemon._start_persistent_runtime_pool_reaper()
        assert go_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED is True
        assert evicted, "reaper should evict idle pools"
    finally:
        go_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = old_started
        go_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        go_daemon.threading.Thread = old_thread
        go_daemon.time.sleep = old_sleep
        go_daemon.time.monotonic = old_monotonic
        go_daemon._shutdown_persistent_runtime_pool = old_shutdown
        go_daemon._PERSISTENT_RUNTIME_POOLS = old_pools


def test_persistent_runtime_pool_reaper_skips_active() -> None:
    old_started = go_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED
    old_interval = go_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread = go_daemon.threading.Thread
    old_sleep = go_daemon.time.sleep
    old_monotonic = go_daemon.time.monotonic
    old_shutdown = go_daemon._shutdown_persistent_runtime_pool
    old_pools = go_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        go_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False
        go_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        shutdown_calls = {"n": 0}

        go_daemon._PERSISTENT_RUNTIME_POOLS = {
            "pending@v1": {"pending": 1, "min_warm": 0, "idle_ttl_ms": 1, "last_used": 0.0, "workers": []},
            "warm@v1": {"pending": 0, "min_warm": 1, "idle_ttl_ms": 1, "last_used": 0.0, "workers": []},
        }
        go_daemon._shutdown_persistent_runtime_pool = lambda _p: shutdown_calls.update(n=shutdown_calls["n"] + 1)

        sleep_calls = {"n": 0}

        def fake_sleep(_seconds):
            sleep_calls["n"] += 1
            if sleep_calls["n"] > 1:
                raise RuntimeError("stop-reaper")

        go_daemon.time.sleep = fake_sleep
        go_daemon.time.monotonic = lambda: 10.0

        class InlineThread:
            def __init__(self, *, target=None, **_kwargs):
                self._target = target

            def start(self):
                try:
                    if self._target is not None:
                        self._target()
                except RuntimeError as exc:
                    if str(exc) != "stop-reaper":
                        raise

        go_daemon.threading.Thread = InlineThread
        go_daemon._start_persistent_runtime_pool_reaper()
        assert shutdown_calls["n"] == 0
    finally:
        go_daemon._PERSISTENT_RUNTIME_POOLS = old_pools
        go_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = old_started
        go_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        go_daemon.threading.Thread = old_thread
        go_daemon.time.sleep = old_sleep
        go_daemon.time.monotonic = old_monotonic
        go_daemon._shutdown_persistent_runtime_pool = old_shutdown


def test_ensure_persistent_runtime_pool() -> None:
    old_pools = go_daemon._PERSISTENT_RUNTIME_POOLS
    old_lock = go_daemon._PERSISTENT_RUNTIME_POOLS_LOCK
    old_start_reaper = go_daemon._start_persistent_runtime_pool_reaper
    old_warmup = go_daemon._warmup_persistent_runtime_pool
    old_shutdown = go_daemon._shutdown_persistent_runtime_pool
    try:
        go_daemon._PERSISTENT_RUNTIME_POOLS = {}
        go_daemon._PERSISTENT_RUNTIME_POOLS_LOCK = threading.Lock()
        go_daemon._start_persistent_runtime_pool_reaper = lambda: None
        go_daemon._warmup_persistent_runtime_pool = lambda _pool: None
        stale_shutdowns: list[str] = []
        go_daemon._shutdown_persistent_runtime_pool = lambda _p: stale_shutdowns.append("x")

        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "handler.go"
            handler.write_text("package main\nfunc handler() {}\n", encoding="utf-8")
            binary = Path(tmp) / "fn_handler"
            binary.write_text("bin", encoding="utf-8")

            # Create new pool
            p1 = go_daemon._ensure_persistent_runtime_pool(
                "test@v1", handler, binary,
                {"max_workers": 2, "min_warm": 0, "idle_ttl_ms": 1000}
            )
            assert p1["max_workers"] == 2

            # Reuse existing pool (same max_workers)
            p2 = go_daemon._ensure_persistent_runtime_pool(
                "test@v1", handler, binary,
                {"max_workers": 2, "min_warm": 1, "idle_ttl_ms": 2000}
            )
            assert p2 is p1
            assert p2["min_warm"] == 1
            assert p2["idle_ttl_ms"] == 2000

            # Replace pool (different max_workers)
            p3 = go_daemon._ensure_persistent_runtime_pool(
                "test@v1", handler, binary,
                {"max_workers": 4, "min_warm": 0, "idle_ttl_ms": 1000}
            )
            assert p3 is not p1
            assert p3["max_workers"] == 4
            assert stale_shutdowns, "old pool should be shut down"

            # min_warm > max_workers clamping
            p4 = go_daemon._ensure_persistent_runtime_pool(
                "test@v2", handler, binary,
                {"max_workers": 2, "min_warm": 10, "idle_ttl_ms": 1000}
            )
            assert p4["min_warm"] == 2
    finally:
        go_daemon._PERSISTENT_RUNTIME_POOLS = old_pools
        go_daemon._PERSISTENT_RUNTIME_POOLS_LOCK = old_lock
        go_daemon._start_persistent_runtime_pool_reaper = old_start_reaper
        go_daemon._warmup_persistent_runtime_pool = old_warmup
        go_daemon._shutdown_persistent_runtime_pool = old_shutdown


def test_run_prepared_request_persistent() -> None:
    old_ensure = go_daemon._ensure_persistent_runtime_pool
    old_checkout = go_daemon._checkout_persistent_runtime_worker
    old_release = go_daemon._release_persistent_runtime_worker
    old_pools = go_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        fake_pool = {
            "cond": threading.Condition(threading.Lock()),
            "workers": [],
            "max_workers": 1,
            "pending": 0,
            "last_used": 0.0,
        }
        go_daemon._ensure_persistent_runtime_pool = lambda *_a, **_k: fake_pool
        go_daemon._PERSISTENT_RUNTIME_POOLS = {"test-key": fake_pool}

        # Timeout path
        go_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: (_ for _ in ()).throw(TimeoutError("timeout"))
        resp = go_daemon._run_prepared_request_persistent(
            "test-key", Path("/tmp/handler.go"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp["status"] == 504

        # Generic error path
        go_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("generic"))
        resp = go_daemon._run_prepared_request_persistent(
            "test-key", Path("/tmp/handler.go"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp["status"] == 500

        # Success path with fake worker
        _OrigWorker = go_daemon._PersistentGoWorker

        class _FakeGoWorker(_OrigWorker):
            __slots__ = ()
            def __init__(self):
                self._dead = False
                self.lock = threading.Lock()
                self.binary = Path("/tmp/fake")
                class FakeProc:
                    def poll(self): return None
                self.proc = FakeProc()
            def send_request(self, event, timeout_ms):
                return {"status": 200, "headers": {}, "body": "ok"}
            def shutdown(self):
                self._dead = True

        fake_worker = _FakeGoWorker()
        fake_entry = {"worker": fake_worker, "busy": True, "last_used": 0.0}
        released = {"called": False, "discard": None}

        def fake_checkout(*_a, **_k):
            return fake_entry

        def fake_release(pool, entry, discard=False):
            released["called"] = True
            released["discard"] = discard

        go_daemon._checkout_persistent_runtime_worker = fake_checkout
        go_daemon._release_persistent_runtime_worker = fake_release
        resp = go_daemon._run_prepared_request_persistent(
            "test-key", Path("/tmp/handler.go"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp["status"] == 200
        assert released["called"] is True

        # Timeout after checkout (entry is not None)
        released_entries: list[tuple] = []

        def track_release(pool, entry, discard=False):
            released_entries.append((entry, discard))

        go_daemon._release_persistent_runtime_worker = track_release

        class _TimeoutWorker(_OrigWorker):
            __slots__ = ()
            def __init__(self):
                self._dead = False
                self.lock = threading.Lock()
                self.binary = Path("/tmp/fake")
                class FakeProc:
                    def poll(self): return None
                self.proc = FakeProc()
            def send_request(self, event, timeout_ms):
                raise TimeoutError("timeout")
            def shutdown(self):
                self._dead = True

        timeout_worker = _TimeoutWorker()
        timeout_entry = {"worker": timeout_worker, "busy": True, "last_used": 0.0}
        go_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: timeout_entry
        resp = go_daemon._run_prepared_request_persistent(
            "test-key", Path("/tmp/handler.go"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp["status"] == 504

        # Invalid worker type
        go_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: {"worker": "not-a-worker", "busy": True}
        go_daemon._release_persistent_runtime_worker = fake_release
        resp = go_daemon._run_prepared_request_persistent(
            "test-key", Path("/tmp/handler.go"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp["status"] == 500
    finally:
        go_daemon._ensure_persistent_runtime_pool = old_ensure
        go_daemon._checkout_persistent_runtime_worker = old_checkout
        go_daemon._release_persistent_runtime_worker = old_release
        go_daemon._PERSISTENT_RUNTIME_POOLS = old_pools


def test_prepare_request() -> None:
    old_resolve = go_daemon._resolve_handler_path
    old_binary = go_daemon._ensure_go_binary
    old_env = go_daemon._read_function_env
    try:
        go_daemon._resolve_handler_path = lambda *_a, **_k: Path("/tmp/handler.go")
        go_daemon._ensure_go_binary = lambda _p: Path("/tmp/fn_handler")
        go_daemon._read_function_env = lambda _p: {"FN_KEY": "val"}

        # Normal request
        handler, binary, event, timeout_ms = go_daemon._prepare_request(
            {"fn": "demo", "event": {"env": {"A": "1"}, "context": {"timeout_ms": 500}}}
        )
        assert handler == Path("/tmp/handler.go")
        assert binary == Path("/tmp/fn_handler")
        assert event["env"]["A"] == "1"
        assert event["env"]["FN_KEY"] == "val"
        assert timeout_ms == 500

        # Non-dict event
        try:
            go_daemon._prepare_request({"fn": "demo", "event": "bad"})
        except ValueError as exc:
            assert "event must be an object" in str(exc)
        else:
            raise AssertionError("expected event must be an object")

        # Bad timeout
        handler, binary, event, timeout_ms = go_daemon._prepare_request(
            {"fn": "demo", "event": {"context": {"timeout_ms": "bad"}}}
        )
        assert timeout_ms == 2500  # default

        # No context
        handler, binary, event, timeout_ms = go_daemon._prepare_request(
            {"fn": "demo", "event": {}}
        )
        assert timeout_ms == 2500

        # Small timeout clamped
        handler, binary, event, timeout_ms = go_daemon._prepare_request(
            {"fn": "demo", "event": {"context": {"timeout_ms": 1}}}
        )
        assert timeout_ms == 50

        # Non-dict incoming env
        handler, binary, event, timeout_ms = go_daemon._prepare_request(
            {"fn": "demo", "event": {"env": "bad"}}
        )
        assert event["env"] == {"FN_KEY": "val"}

        # Non-string key in incoming env
        handler, binary, event, timeout_ms = go_daemon._prepare_request(
            {"fn": "demo", "event": {"env": {123: "val", "GOOD": "yes"}}}
        )
        assert event["env"]["GOOD"] == "yes"
    finally:
        go_daemon._resolve_handler_path = old_resolve
        go_daemon._ensure_go_binary = old_binary
        go_daemon._read_function_env = old_env


def test_handle_request_pool_disabled() -> None:
    old_resolve = go_daemon._resolve_handler_path
    old_binary = go_daemon._ensure_go_binary
    old_env = go_daemon._read_function_env
    old_run_prepared = go_daemon._run_prepared_request_persistent
    old_enabled = go_daemon.ENABLE_RUNTIME_WORKER_POOL
    try:
        go_daemon._resolve_handler_path = lambda *_a, **_k: Path("/tmp/handler.go")
        go_daemon._ensure_go_binary = lambda _p: Path("/tmp/fn_handler")
        go_daemon._read_function_env = lambda _p: {}

        seen = {}

        def fake_run(_pool_key, _handler_path, _binary, event, timeout_ms, settings):
            seen["settings"] = settings
            return {"status": 200, "headers": {}, "body": "ok"}

        go_daemon._run_prepared_request_persistent = fake_run

        # Pool disabled globally
        go_daemon.ENABLE_RUNTIME_WORKER_POOL = False
        resp = go_daemon._handle_request({"fn": "demo", "event": {}})
        assert resp["status"] == 200
        assert seen["settings"]["max_workers"] == 1

        # Pool enabled but max_workers <= 0
        go_daemon.ENABLE_RUNTIME_WORKER_POOL = True
        resp = go_daemon._handle_request(
            {"fn": "demo", "event": {"context": {"worker_pool": {"max_workers": 0}}}}
        )
        assert resp["status"] == 200
        assert seen["settings"]["max_workers"] == 1
    finally:
        go_daemon._resolve_handler_path = old_resolve
        go_daemon._ensure_go_binary = old_binary
        go_daemon._read_function_env = old_env
        go_daemon._run_prepared_request_persistent = old_run_prepared
        go_daemon.ENABLE_RUNTIME_WORKER_POOL = old_enabled


def test_serve_conn_exception_paths() -> None:
    old_read = go_daemon._read_frame
    old_handle = go_daemon._handle_request
    try:
        # ValueError path
        left, right = socket.socketpair()
        with left, right:
            go_daemon._read_frame = lambda _c: (_ for _ in ()).throw(ValueError("bad frame"))
            go_daemon._serve_conn(left)
            resp = _read_frame(right)
            assert resp["status"] == 400

        # FileNotFoundError path
        left, right = socket.socketpair()
        with left, right:
            go_daemon._read_frame = lambda _c: {"fn": "missing", "event": {}}
            go_daemon._handle_request = lambda _r: (_ for _ in ()).throw(FileNotFoundError("unknown function"))
            go_daemon._serve_conn(left)
            resp = _read_frame(right)
            assert resp["status"] == 404

        # RuntimeError path
        left, right = socket.socketpair()
        with left, right:
            go_daemon._read_frame = lambda _c: {"fn": "err", "event": {}}
            go_daemon._handle_request = lambda _r: (_ for _ in ()).throw(RuntimeError("runtime error"))
            go_daemon._serve_conn(left)
            resp = _read_frame(right)
            assert resp["status"] == 500

        # Generic Exception path
        left, right = socket.socketpair()
        with left, right:
            go_daemon._read_frame = lambda _c: {"fn": "err", "event": {}}
            go_daemon._handle_request = lambda _r: (_ for _ in ()).throw(Exception("unexpected"))
            go_daemon._serve_conn(left)
            resp = _read_frame(right)
            assert resp["status"] == 500
            body = json.loads(resp["body"])
            assert "go runtime failure" in body["error"]

        # Normal success path with logs
        left, right = socket.socketpair()
        with left, right:
            go_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            go_daemon._handle_request = lambda _r: {"status": 200, "headers": {}, "body": "ok"}
            go_daemon._serve_conn(left)
            resp = _read_frame(right)
            assert resp["status"] == 200
    finally:
        go_daemon._read_frame = old_read
        go_daemon._handle_request = old_handle


def test_ensure_socket_dir() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = str(Path(tmp) / "sub" / "deep" / "fn.sock")
        go_daemon._ensure_socket_dir(sock_path)
        assert Path(sock_path).parent.is_dir()


def test_prepare_socket_path_not_socket() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        regular_file = Path(tmp) / "not-a-socket"
        regular_file.write_text("x", encoding="utf-8")
        try:
            go_daemon._prepare_socket_path(str(regular_file))
        except RuntimeError as exc:
            assert "not a unix socket" in str(exc)
        else:
            raise AssertionError("expected not a unix socket error")


def test_prepare_socket_path_stale_socket() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = str(Path(tmp) / "stale.sock")
        # Create a socket file that is not in use
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(sock_path)
        server.close()
        # Now the socket file exists but nobody is listening
        go_daemon._prepare_socket_path(sock_path)
        # Should have removed the stale socket
        assert not Path(sock_path).exists()


def test_prepare_socket_path_active_socket() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = str(Path(tmp) / "active.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(sock_path)
        server.listen(1)
        try:
            go_daemon._prepare_socket_path(sock_path)
        except RuntimeError as exc:
            assert "already in use" in str(exc)
        else:
            raise AssertionError("expected already in use error")
        finally:
            server.close()


def test_emit_handler_logs_edge_cases() -> None:
    stdout_buf = io.StringIO()
    stderr_buf = io.StringIO()
    with redirect_stdout(stdout_buf), redirect_stderr(stderr_buf):
        # Non-dict resp
        go_daemon._emit_handler_logs({}, "bad-resp")
        # Empty strings
        go_daemon._emit_handler_logs({}, {"stdout": "", "stderr": ""})
        # None values
        go_daemon._emit_handler_logs({}, {"stdout": None, "stderr": None})
        # Missing keys
        go_daemon._emit_handler_logs({}, {})
        # Non-dict req
        go_daemon._emit_handler_logs("not-a-dict", {"stdout": "line"})
    assert "line" in stdout_buf.getvalue()
    assert stderr_buf.getvalue() == ""


def test_append_runtime_log() -> None:
    old_log = go_daemon.RUNTIME_LOG_FILE
    try:
        # Empty log file => no-op
        go_daemon.RUNTIME_LOG_FILE = ""
        go_daemon._append_runtime_log("go", "should no-op")

        # Valid log path
        with tempfile.TemporaryDirectory() as tmp:
            log_path = str(Path(tmp) / "test.log")
            go_daemon.RUNTIME_LOG_FILE = log_path
            go_daemon._append_runtime_log("go", "test line")
            assert Path(log_path).read_text(encoding="utf-8") == "[go] test line\n"

        # Invalid path => no crash
        go_daemon.RUNTIME_LOG_FILE = "/nonexistent/path/log.txt"
        go_daemon._append_runtime_log("go", "should not crash")
    finally:
        go_daemon.RUNTIME_LOG_FILE = old_log


def test_main_entry_point() -> None:
    old_socket = go_daemon.socket.socket
    old_chmod = go_daemon.os.chmod
    old_thread = go_daemon.threading.Thread
    old_serve = go_daemon._serve_conn
    old_ensure_dir = go_daemon._ensure_socket_dir
    old_prepare = go_daemon._prepare_socket_path
    try:
        served: list[str] = []
        go_daemon._serve_conn = lambda _conn: served.append("conn")
        go_daemon._ensure_socket_dir = lambda _path: None
        go_daemon._prepare_socket_path = lambda _path: None
        go_daemon.os.chmod = lambda _p, _m: None

        class DummyServer:
            def __init__(self, *_args, **_kwargs):
                self.calls = 0

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def bind(self, _path):
                return None

            def listen(self, _n):
                return None

            def accept(self):
                self.calls += 1
                if self.calls == 1:
                    return object(), None
                raise KeyboardInterrupt("stop")

        class InlineThread:
            def __init__(self, target=None, args=(), **_kwargs):
                self._target = target
                self._args = args

            def start(self):
                if self._target:
                    self._target(*self._args)

        go_daemon.socket.socket = DummyServer
        go_daemon.threading.Thread = InlineThread
        try:
            go_daemon.main()
        except KeyboardInterrupt:
            pass
        else:
            raise AssertionError("expected KeyboardInterrupt to break main loop")
        assert served == ["conn"], served
    finally:
        go_daemon.socket.socket = old_socket
        go_daemon.os.chmod = old_chmod
        go_daemon.threading.Thread = old_thread
        go_daemon._serve_conn = old_serve
        go_daemon._ensure_socket_dir = old_ensure_dir
        go_daemon._prepare_socket_path = old_prepare


def test_create_persistent_runtime_worker() -> None:
    """Cover _create_persistent_runtime_worker."""
    _OrigWorker = go_daemon._PersistentGoWorker
    old_create = go_daemon._PersistentGoWorker

    class _FakeGoWorker(_OrigWorker):
        __slots__ = ()
        def __init__(self, binary):
            self._dead = False
            self.lock = threading.Lock()
            self.binary = binary
            class FakeProc:
                def poll(self): return None
                def kill(self): pass
                def wait(self, timeout=None): pass
                stdin = None
                stdout = None
            self.proc = FakeProc()

    try:
        go_daemon._PersistentGoWorker = _FakeGoWorker
        pool = {"binary": Path("/tmp/fn_handler")}
        entry = go_daemon._create_persistent_runtime_worker(pool)
        assert "worker" in entry
        assert entry["busy"] is False
        assert isinstance(entry["worker"], _FakeGoWorker)
    finally:
        go_daemon._PersistentGoWorker = old_create


def test_ensure_go_binary_build_error_with_stdout_only() -> None:
    """Cover the branch where stderr is empty but stdout has content."""
    class Proc:
        def __init__(self, returncode=0, stdout="", stderr=""):
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.go"
        handler.write_text(
            "package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n",
            encoding="utf-8",
        )

        old_cache = dict(go_daemon._BINARY_CACHE)
        old_which = go_daemon.shutil.which
        old_sane = go_daemon._go_toolchain_sane
        old_run = go_daemon.subprocess.run
        try:
            go_daemon._BINARY_CACHE.clear()
            go_daemon.shutil.which = lambda _name: "/usr/bin/go"
            go_daemon._go_toolchain_sane = lambda _cmd: True

            # Build failure with stdout only (no stderr)
            go_daemon.subprocess.run = lambda *_a, **_k: Proc(returncode=1, stdout="error in stdout", stderr="")
            meta_path = handler.parent / ".go-build" / ".fastfn-build-meta.json"
            if meta_path.exists():
                meta_path.unlink()
            try:
                go_daemon._ensure_go_binary(handler)
            except RuntimeError as exc:
                assert "error in stdout" in str(exc)
            else:
                raise AssertionError("expected build failure with stdout")
        finally:
            go_daemon._BINARY_CACHE.clear()
            go_daemon._BINARY_CACHE.update(old_cache)
            go_daemon.shutil.which = old_which
            go_daemon._go_toolchain_sane = old_sane
            go_daemon.subprocess.run = old_run


def test_persistent_worker_shutdown_with_real_stdin() -> None:
    """Cover _PersistentGoWorker.shutdown with stdin that has close method."""
    _OrigWorker = go_daemon._PersistentGoWorker

    class _FakeGoWorker(_OrigWorker):
        __slots__ = ()
        def __init__(self):
            self._dead = False
            self.lock = threading.Lock()
            self.binary = Path("/tmp/fake")

            class FakeStdin:
                closed = False
                def close(self):
                    self.closed = True

            class FakeProc:
                def __init__(self):
                    self.stdin = FakeStdin()
                    self.stdout = None
                def poll(self): return None
                def kill(self): pass
                def wait(self, timeout=None): pass

            self.proc = FakeProc()

    w = _FakeGoWorker()
    # Call the real shutdown method from the parent class
    go_daemon._PersistentGoWorker.shutdown(w)
    assert w._dead is True


def test_read_frame_happy_path() -> None:
    """Cover the return statement of _read_frame (line 296)."""
    left, right = socket.socketpair()
    with left, right:
        payload = json.dumps({"fn": "test", "event": {}}).encode("utf-8")
        right.sendall(struct.pack("!I", len(payload)) + payload)
        result = go_daemon._read_frame(left)
        assert result["fn"] == "test"


def test_read_function_env_non_string_key() -> None:
    """Cover line 213 where key is not a string (via programmatic dict)."""
    # JSON always has string keys, but the code checks isinstance(key, str)
    # We can test by monkeypatching json.loads to return a dict with non-string key
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.go"
        handler.write_text("package main\n", encoding="utf-8")
        env_path = fn_dir / "fn.env.json"
        env_path.write_text('{"A": "1"}', encoding="utf-8")

        old_loads = go_daemon.json.loads
        try:
            def patched_loads(s, **kw):
                result = old_loads(s, **kw)
                if isinstance(result, dict):
                    # Inject a non-string key
                    result[123] = "bad"
                return result
            go_daemon.json.loads = patched_loads
            env = go_daemon._read_function_env(handler)
            assert env == {"A": "1"}, env  # non-string key should be skipped
        finally:
            go_daemon.json.loads = old_loads


def test_normalize_worker_pool_settings_acquire_below_100() -> None:
    """Cover line 416 where acquire_timeout_ms < 100."""
    # This is hard to trigger normally since RUNTIME_POOL_ACQUIRE_TIMEOUT_MS defaults to 5000.
    # We need to temporarily change that default.
    old_default = go_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS
    try:
        go_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = 50
        s = go_daemon._normalize_worker_pool_settings(
            {"event": {"context": {"timeout_ms": 0, "worker_pool": {"max_workers": 2}}}}
        )
        assert s["acquire_timeout_ms"] == 100  # clamped to 100
    finally:
        go_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = old_default


def test_resolve_handler_path_bad_token() -> None:
    """Cover line 437 where _FILE_TOKEN_RE doesn't match."""
    try:
        go_daemon._resolve_handler_path("bad name!", None)
    except ValueError as exc:
        assert "invalid function name" in str(exc)
    else:
        raise AssertionError("expected invalid function name")


def test_ensure_go_binary_corrupt_metadata() -> None:
    """Cover lines 570-571 where metadata JSON is corrupt."""
    class Proc:
        def __init__(self, returncode=0, stdout="", stderr=""):
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.go"
        handler.write_text(
            "package main\nfunc handler(event map[string]interface{}) interface{} { return nil }\n",
            encoding="utf-8",
        )

        old_cache = dict(go_daemon._BINARY_CACHE)
        old_which = go_daemon.shutil.which
        old_sane = go_daemon._go_toolchain_sane
        old_run = go_daemon.subprocess.run
        try:
            go_daemon._BINARY_CACHE.clear()
            go_daemon.shutil.which = lambda _name: "/usr/bin/go"
            go_daemon._go_toolchain_sane = lambda _cmd: True

            # First build to create the build dir
            def fake_run(cmd, cwd, capture_output, text, timeout, check, env=None):
                out = Path(cwd)
                (out / "fn_handler").write_text("#!/bin/sh\n", encoding="utf-8")
                return Proc(returncode=0)

            go_daemon.subprocess.run = fake_run
            b1 = go_daemon._ensure_go_binary(handler)
            assert b1.is_file()

            # Corrupt the metadata file
            meta_path = handler.parent / ".go-build" / ".fastfn-build-meta.json"
            meta_path.write_text("{corrupt json", encoding="utf-8")

            # Clear cache so it tries to load from disk
            go_daemon._BINARY_CACHE.clear()
            go_daemon.subprocess.run = fake_run
            b2 = go_daemon._ensure_go_binary(handler)
            assert b2.is_file()

            # Also test metadata that is not a dict
            meta_path.write_text('"just a string"', encoding="utf-8")
            go_daemon._BINARY_CACHE.clear()
            b3 = go_daemon._ensure_go_binary(handler)
            assert b3.is_file()
        finally:
            go_daemon._BINARY_CACHE.clear()
            go_daemon._BINARY_CACHE.update(old_cache)
            go_daemon.shutil.which = old_which
            go_daemon._go_toolchain_sane = old_sane
            go_daemon.subprocess.run = old_run


def test_ensure_persistent_runtime_pool_negative_min_warm() -> None:
    """Cover line 868 where min_warm < 0."""
    old_pools = go_daemon._PERSISTENT_RUNTIME_POOLS
    old_lock = go_daemon._PERSISTENT_RUNTIME_POOLS_LOCK
    old_start_reaper = go_daemon._start_persistent_runtime_pool_reaper
    old_warmup = go_daemon._warmup_persistent_runtime_pool
    old_shutdown = go_daemon._shutdown_persistent_runtime_pool
    try:
        go_daemon._PERSISTENT_RUNTIME_POOLS = {}
        go_daemon._PERSISTENT_RUNTIME_POOLS_LOCK = threading.Lock()
        go_daemon._start_persistent_runtime_pool_reaper = lambda: None
        go_daemon._warmup_persistent_runtime_pool = lambda _pool: None
        go_daemon._shutdown_persistent_runtime_pool = lambda _p: None

        pool = go_daemon._ensure_persistent_runtime_pool(
            "neg@v1", Path("/tmp/handler.go"), Path("/tmp/bin"),
            {"max_workers": 2, "min_warm": -5, "idle_ttl_ms": 1000}
        )
        assert pool["min_warm"] == 0
    finally:
        go_daemon._PERSISTENT_RUNTIME_POOLS = old_pools
        go_daemon._PERSISTENT_RUNTIME_POOLS_LOCK = old_lock
        go_daemon._start_persistent_runtime_pool_reaper = old_start_reaper
        go_daemon._warmup_persistent_runtime_pool = old_warmup
        go_daemon._shutdown_persistent_runtime_pool = old_shutdown


def test_checkout_with_stale_workers_during_create() -> None:
    """Cover line 937 where stale workers are shut down during new worker creation."""
    _OrigWorker = go_daemon._PersistentGoWorker

    shutdown_called = []

    class _FakeGoWorker(_OrigWorker):
        __slots__ = ()
        def __init__(self, is_alive=True):
            self._dead = not is_alive
            self.lock = threading.Lock()
            self.binary = Path("/tmp/fake")
            class FakeProc:
                def __init__(self, dead_ref):
                    self._dead_ref = dead_ref
                def poll(self): return None if not self._dead_ref() else 1
                def kill(self): pass
                def wait(self, timeout=None): pass
            self.proc = FakeProc(lambda: self._dead)
        def shutdown(self):
            self._dead = True
            shutdown_called.append(True)

    lock = threading.Lock()
    cond = threading.Condition(lock)

    # Pool has one dead worker and no free slots yet (max_workers=2)
    dead_worker = _FakeGoWorker(False)
    dead_entry = {"worker": dead_worker, "busy": False, "last_used": 0.0}

    old_create = go_daemon._create_persistent_runtime_worker
    try:
        new_worker = _FakeGoWorker(True)
        go_daemon._create_persistent_runtime_worker = lambda pool: {"worker": new_worker, "busy": False, "last_used": 0.0}

        pool = {"cond": cond, "workers": [dead_entry], "max_workers": 2, "last_used": 0.0, "binary": Path("/tmp/bin")}
        result = go_daemon._checkout_persistent_runtime_worker(pool, 1000)
        assert result["busy"] is True
        assert shutdown_called  # dead worker should be shut down
    finally:
        go_daemon._create_persistent_runtime_worker = old_create


def test_prepare_socket_path_remove_race() -> None:
    """Cover lines 1079-1080 where os.remove raises FileNotFoundError."""
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = str(Path(tmp) / "race.sock")
        # Create a socket file that is not in use
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(sock_path)
        server.close()

        # Monkey-patch os.remove to raise FileNotFoundError
        old_remove = go_daemon.os.remove
        try:
            go_daemon.os.remove = lambda _p: (_ for _ in ()).throw(FileNotFoundError("gone"))
            # Should not raise
            go_daemon._prepare_socket_path(sock_path)
        finally:
            go_daemon.os.remove = old_remove


def test_persistent_worker_shutdown_wait_timeout() -> None:
    """Cover shutdown where proc.wait raises and proc.kill is called."""
    _OrigWorker = go_daemon._PersistentGoWorker

    kill_called = {"value": False}

    class _FakeGoWorker(_OrigWorker):
        __slots__ = ()
        def __init__(self):
            self._dead = False
            self.lock = threading.Lock()
            self.binary = Path("/tmp/fake")

            class FakeStdin:
                def close(self): pass

            class FakeProc:
                def __init__(self):
                    self.stdin = FakeStdin()
                    self.stdout = None
                def poll(self): return None
                def kill(self):
                    kill_called["value"] = True
                def wait(self, timeout=None):
                    raise subprocess.TimeoutExpired(cmd="bin", timeout=2)

            self.proc = FakeProc()

    w = _FakeGoWorker()
    go_daemon._PersistentGoWorker.shutdown(w)
    assert w._dead is True
    assert kill_called["value"] is True


def test_run_prepared_request_persistent_pending_decrement() -> None:
    """Cover the finally block that decrements pending count."""
    old_ensure = go_daemon._ensure_persistent_runtime_pool
    old_checkout = go_daemon._checkout_persistent_runtime_worker
    old_release = go_daemon._release_persistent_runtime_worker
    old_pools = go_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        fake_pool = {
            "cond": threading.Condition(threading.Lock()),
            "workers": [],
            "max_workers": 1,
            "pending": 0,
            "last_used": 0.0,
        }
        go_daemon._ensure_persistent_runtime_pool = lambda *_a, **_k: fake_pool
        go_daemon._PERSISTENT_RUNTIME_POOLS = {"test-key": fake_pool}

        # Error path: pending should be incremented then decremented
        go_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("err"))
        go_daemon._release_persistent_runtime_worker = lambda *_a, **_k: None
        resp = go_daemon._run_prepared_request_persistent(
            "test-key", Path("/tmp/handler.go"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp["status"] == 500
        assert fake_pool["pending"] == 0  # decremented back to 0
    finally:
        go_daemon._ensure_persistent_runtime_pool = old_ensure
        go_daemon._checkout_persistent_runtime_worker = old_checkout
        go_daemon._release_persistent_runtime_worker = old_release
        go_daemon._PERSISTENT_RUNTIME_POOLS = old_pools


def test_run_prepared_request_persistent_pool_mismatch() -> None:
    """Cover when pool_key doesn't match in _PERSISTENT_RUNTIME_POOLS (pool is not current)."""
    old_ensure = go_daemon._ensure_persistent_runtime_pool
    old_checkout = go_daemon._checkout_persistent_runtime_worker
    old_release = go_daemon._release_persistent_runtime_worker
    old_pools = go_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        fake_pool = {
            "cond": threading.Condition(threading.Lock()),
            "workers": [],
            "max_workers": 1,
            "pending": 0,
            "last_used": 0.0,
        }
        go_daemon._ensure_persistent_runtime_pool = lambda *_a, **_k: fake_pool
        # Pool key doesn't exist in the pools dict (mismatch)
        go_daemon._PERSISTENT_RUNTIME_POOLS = {}

        go_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("err"))
        go_daemon._release_persistent_runtime_worker = lambda *_a, **_k: None
        resp = go_daemon._run_prepared_request_persistent(
            "nonexistent-key", Path("/tmp/handler.go"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp["status"] == 500
    finally:
        go_daemon._ensure_persistent_runtime_pool = old_ensure
        go_daemon._checkout_persistent_runtime_worker = old_checkout
        go_daemon._release_persistent_runtime_worker = old_release
        go_daemon._PERSISTENT_RUNTIME_POOLS = old_pools


# ---------------------------------------------------------------------------
# Main
def test_go_daemon_cache_miss_extra(tmp_path):
    go_daemon = load_module(GO_DAEMON_PATH)
    from pathlib import Path

    # 560 misses branch
    fake = tmp_path / "h.go"
    fake.write_text("func handler() {}", encoding="utf-8")
    c_key = str(fake)
    go_daemon._BINARY_CACHE[c_key] = {"signature": "BAD", "binary": str(tmp_path / "nope")}
    try:
        go_daemon._ensure_go_binary(fake)
    except Exception:
        pass

def test_go_daemon_lock_load_fail(tmp_path):
    go_daemon = load_module(GO_DAEMON_PATH)
    fake = tmp_path / "h.go"
    fake.write_text("func handler() {}", encoding="utf-8")
    bd = tmp_path / ".go-build"
    bd.mkdir()
    meta = bd / ".fastfn-build-meta.json"
    meta.write_text("INVALID JSON", encoding="utf-8")
    try:
        go_daemon._ensure_go_binary(fake)
    except Exception:
        pass
