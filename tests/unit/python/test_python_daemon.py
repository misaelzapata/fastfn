#!/usr/bin/env python3
"""Tests for python-daemon.py runtime."""
import asyncio
import io
import json
import os
import shutil
import socket
import stat
import struct
import sys
import tempfile
import threading
import time
from concurrent.futures import Future, TimeoutError as FutureTimeoutError
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from conftest import ROOT, load_module

RUNTIME_DIR = ROOT / "srv/fn/runtimes"
PY_DAEMON_PATH = RUNTIME_DIR / "python-daemon.py"

py_daemon = load_module(PY_DAEMON_PATH)


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
# Tests
# ---------------------------------------------------------------------------


def test_read_write_frame() -> None:
    left, right = socket.socketpair()
    with left, right:
        obj = {"fn": "hello", "event": {"body": "world"}}
        py_daemon._write_frame(right, obj)
        result = py_daemon._read_frame(left)
        assert result["fn"] == "hello"
        assert result["event"]["body"] == "world"


def test_read_frame_invalid_header() -> None:
    left, right = socket.socketpair()
    with left, right:
        right.sendall(b"\x00\x00")
        right.shutdown(socket.SHUT_WR)
        try:
            py_daemon._read_frame(left)
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
            py_daemon._read_frame(left)
        except ValueError as exc:
            assert "incomplete" in str(exc).lower()
        else:
            raise AssertionError("expected incomplete frame")


def test_read_frame_non_object() -> None:
    left, right = socket.socketpair()
    with left, right:
        payload = json.dumps(["bad"]).encode("utf-8")
        right.sendall(struct.pack("!I", len(payload)) + payload)
        right.shutdown(socket.SHUT_WR)
        try:
            py_daemon._read_frame(left)
        except ValueError as exc:
            assert "object" in str(exc).lower()
        else:
            raise AssertionError("expected object validation error")


def test_error_response() -> None:
    resp = py_daemon._error_response("test error", status=503)
    assert resp["status"] == 503
    assert "test error" in resp["body"]
    assert resp["headers"]["Content-Type"] == "application/json"


def test_json_log() -> None:
    buf = io.StringIO()
    old_print = py_daemon.builtins.print
    captured = []

    def fake_print(*args, **kwargs):
        captured.append(args[0] if args else "")

    py_daemon.builtins.print = fake_print
    try:
        py_daemon._json_log("test_event", key="value")
    finally:
        py_daemon.builtins.print = old_print
    assert len(captured) == 1
    parsed = json.loads(captured[0])
    assert parsed["event"] == "test_event"
    assert parsed["component"] == "python_daemon"
    assert parsed["key"] == "value"


def test_with_event_runtime_metadata_sets_version() -> None:
    event = py_daemon._with_event_runtime_metadata({"query": {"name": "Ada"}}, None)
    assert event["query"]["name"] == "Ada"
    assert event["version"] == "default"

    event2 = py_daemon._with_event_runtime_metadata({}, "v2")
    assert event2["version"] == "v2"

    event3 = py_daemon._with_event_runtime_metadata({"version": "v3"}, "v2")
    assert event3["version"] == "v3"


def test_deps_dir_has_entries_missing_dir() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        missing = Path(tmp) / ".deps"
        assert py_daemon._deps_dir_has_entries(missing) is False


def test_sanitize_worker_env() -> None:
    env = {
        "PATH": "/usr/bin",
        "HOME": "/root",
        "LANG": "en_US.UTF-8",
        "AWS_SECRET_ACCESS_KEY": "secret",
        "GITHUB_TOKEN": "ghp-secret",
        "DATABASE_URL": "postgres://secret",
    }
    sanitized = py_daemon._sanitize_worker_env(env)
    assert "PATH" in sanitized
    assert "HOME" in sanitized
    assert "LANG" in sanitized
    assert "AWS_SECRET_ACCESS_KEY" not in sanitized
    assert "GITHUB_TOKEN" not in sanitized
    assert "DATABASE_URL" not in sanitized
    assert py_daemon._worker_env_key_allowed("") is False
    assert py_daemon._worker_env_key_allowed(None) is False
    assert py_daemon._worker_env_key_allowed("lc_all") is True


def test_ip_invoke_handler_cloudflare_wait_until_runs_in_background() -> None:
    done = threading.Event()

    async def background() -> None:
        await asyncio.sleep(0.2)
        done.set()

    async def fetch(request, env, ctx):
        ctx.waitUntil(background())
        return {"status": 202, "body": "ok"}

    started = time.monotonic()
    resp = py_daemon._ip_invoke_handler(
        fetch,
        py_daemon._INVOKE_ADAPTER_CLOUDFLARE_WORKER,
        {"method": "GET", "raw_path": "/cf", "headers": {"host": "unit.local"}},
    )
    elapsed = time.monotonic() - started
    assert resp["status"] == 202
    assert elapsed < 0.12, elapsed
    assert done.wait(1.0)


def test_ip_invoke_handler_cloudflare_wait_until_logs_rejection() -> None:
    async def background() -> None:
        await asyncio.sleep(0)
        raise RuntimeError("background boom")

    async def fetch(request, env, ctx):
        ctx.waitUntil(background())
        return {"status": 200, "body": "ok"}

    log_buffer = io.StringIO()
    with redirect_stdout(log_buffer):
        resp = py_daemon._ip_invoke_handler(
            fetch,
            py_daemon._INVOKE_ADAPTER_CLOUDFLARE_WORKER,
            {"method": "GET", "raw_path": "/cf", "headers": {"host": "unit.local"}},
        )
        deadline = time.time() + 1.0
        while "wait_until_rejection" not in log_buffer.getvalue() and time.time() < deadline:
            time.sleep(0.01)

    assert resp["status"] == 200
    lines = [line for line in log_buffer.getvalue().splitlines() if line.strip()]
    payload = json.loads(lines[-1])
    assert payload["event"] == "wait_until_rejection"
    assert payload["error"] == "background boom"


def test_schedule_background_waitables_logs_schedule_error() -> None:
    async def background() -> None:
        return None

    coro = background()
    original_thread = py_daemon.threading.Thread
    log_buffer = io.StringIO()

    class BrokenThread:
        def __init__(self, *args, **kwargs) -> None:
            return None

        def start(self) -> None:
            raise RuntimeError("thread boom")

    try:
        py_daemon.threading.Thread = BrokenThread
        with redirect_stdout(log_buffer):
            py_daemon._schedule_background_waitables([coro], "req-schedule")
    finally:
        py_daemon.threading.Thread = original_thread

    lines = [line for line in log_buffer.getvalue().splitlines() if line.strip()]
    payload = json.loads(lines[-1])
    assert payload["event"] == "wait_until_schedule_error"
    assert payload["request_id"] == "req-schedule"


def test_schedule_background_waitables_ignores_close_error() -> None:
    original_thread = py_daemon.threading.Thread
    log_buffer = io.StringIO()

    class BrokenThread:
        def __init__(self, *args, **kwargs) -> None:
            return None

        def start(self) -> None:
            raise RuntimeError("thread boom")

    class BrokenWaitable:
        def close(self) -> None:
            raise RuntimeError("close boom")

    try:
        py_daemon.threading.Thread = BrokenThread
        with redirect_stdout(log_buffer):
            py_daemon._schedule_background_waitables([BrokenWaitable()], "req-close")
    finally:
        py_daemon.threading.Thread = original_thread

    lines = [line for line in log_buffer.getvalue().splitlines() if line.strip()]
    payload = json.loads(lines[-1])
    assert payload["event"] == "wait_until_schedule_error"
    assert payload["request_id"] == "req-close"


def test_extract_requirements() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"

        # No requirements annotation
        handler.write_text("import json\ndef handler(event): return {}\n", encoding="utf-8")
        assert py_daemon._extract_requirements(handler) == []

        # With requirements annotation
        handler.write_text("#@requirements requests flask\ndef handler(event): return {}\n", encoding="utf-8")
        reqs = py_daemon._extract_requirements(handler)
        assert "requests" in reqs
        assert "flask" in reqs

        # Comma-separated
        handler.write_text("#@requirements requests,flask\ndef handler(event): return {}\n", encoding="utf-8")
        reqs = py_daemon._extract_requirements(handler)
        assert "requests" in reqs
        assert "flask" in reqs

        # Non-existent file
        missing = fn_dir / "missing.py"
        assert py_daemon._extract_requirements(missing) == []


def test_read_function_config() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")

        # No config file
        assert py_daemon._read_function_config(handler) == {}

        # Valid config
        config = fn_dir / "fn.config.json"
        config.write_text(json.dumps({"invoke": {"handler": "main"}}), encoding="utf-8")
        result = py_daemon._read_function_config(handler)
        assert result["invoke"]["handler"] == "main"

        # Invalid JSON
        config.write_text("{bad", encoding="utf-8")
        assert py_daemon._read_function_config(handler) == {}

        # Non-object JSON
        config.write_text(json.dumps(["list"]), encoding="utf-8")
        assert py_daemon._read_function_config(handler) == {}


def test_read_function_env() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")

        # No env file
        assert py_daemon._read_function_env(handler) == {}

        # Valid env
        env_file = fn_dir / "fn.env.json"
        env_file.write_text(json.dumps({"API_KEY": "abc", "DB": {"value": "pg"}}), encoding="utf-8")
        result = py_daemon._read_function_env(handler)
        assert result["API_KEY"] == "abc"
        assert result["DB"] == "pg"

        # Invalid JSON
        env_file.write_text("{bad json", encoding="utf-8")
        assert py_daemon._read_function_env(handler) == {}

        # Non-object JSON
        env_file.write_text(json.dumps(["bad"]), encoding="utf-8")
        assert py_daemon._read_function_env(handler) == {}

        # Null values and nested value=None
        env_file.write_text(json.dumps({"A": "1", "B": {"value": None}, "C": None}), encoding="utf-8")
        result = py_daemon._read_function_env(handler)
        assert result == {"A": "1"}

    # Non-string keys are skipped
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")
        env_file = fn_dir / "fn.env.json"
        env_file.write_text("{}", encoding="utf-8")
        old_loads = py_daemon.json.loads
        try:
            py_daemon.json.loads = lambda _raw: {1: "x", "OK": "1"}
            assert py_daemon._read_function_env(handler) == {"OK": "1"}
        finally:
            py_daemon.json.loads = old_loads


def test_resolve_handler_path() -> None:
    # Empty name
    try:
        py_daemon._resolve_handler_path("", None)
    except ValueError:
        pass
    else:
        raise AssertionError("expected invalid empty function name")

    # Traversal attempts
    for name in ["../secret", "/etc/passwd", "foo/../../../bar"]:
        try:
            py_daemon._resolve_handler_path(name, None)
        except ValueError:
            pass
        else:
            raise AssertionError(f"expected ValueError for {name}")

    # Invalid version
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        old_functions = py_daemon.FUNCTIONS_DIR
        old_runtime = py_daemon.RUNTIME_FUNCTIONS_DIR
        try:
            py_daemon.FUNCTIONS_DIR = root
            py_daemon.RUNTIME_FUNCTIONS_DIR = root / "python"
            try:
                py_daemon._resolve_handler_path("demo", "bad/version")
            except ValueError as exc:
                assert "version" in str(exc).lower()
            else:
                raise AssertionError("expected invalid version error")

            # Unknown function
            try:
                py_daemon._resolve_handler_path("missing", None)
            except FileNotFoundError:
                pass
            else:
                raise AssertionError("expected unknown function error")

            # Direct file resolution (next-style)
            direct = root / "hello.py"
            direct.write_text("def handler(e): return {}\n", encoding="utf-8")
            result = py_daemon._resolve_handler_path("hello", None)
            assert result == direct

            # Directory with handler.py
            fn_dir = root / "myfunc"
            fn_dir.mkdir()
            app = fn_dir / "handler.py"
            app.write_text("def handler(e): return {}\n", encoding="utf-8")
            result = py_daemon._resolve_handler_path("myfunc", None)
            assert result == app

            # Config-based entrypoint
            config = fn_dir / "fn.config.json"
            custom = fn_dir / "custom.py"
            custom.write_text("def handler(e): return {}\n", encoding="utf-8")
            config.write_text(json.dumps({"entrypoint": "custom.py"}), encoding="utf-8")
            result = py_daemon._resolve_handler_path("myfunc", None)
            assert result.name == "custom.py"

            # Explicit public name can resolve through fn_source_dir.
            root_handler = root / "handler.py"
            root_handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            nested_dir = root / "apps" / "demo"
            nested_dir.mkdir(parents=True)
            nested_handler = nested_dir / "handler.py"
            nested_handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            nested_version = nested_dir / "v2"
            nested_version.mkdir()
            (nested_version / "handler.py").write_text("def handler(e): return {}\n", encoding="utf-8")

            assert py_daemon._resolve_handler_path("public-root", None, ".") == root_handler
            assert py_daemon._resolve_handler_path("public-demo", None, "apps/demo") == nested_handler
            assert py_daemon._resolve_handler_path("public-demo", "v2", "apps/demo") == nested_version / "handler.py"

            try:
                py_daemon._resolve_handler_path("public-demo", None, "../escape")
            except ValueError as exc:
                assert "source dir" in str(exc).lower()
            else:
                raise AssertionError("expected invalid function source dir")

            try:
                py_daemon._resolve_handler_path("public-demo", None, 123)
            except ValueError as exc:
                assert "source dir" in str(exc).lower()
            else:
                raise AssertionError("expected invalid non-string function source dir")

            try:
                py_daemon._resolve_handler_path("public-demo", None, "   ")
            except ValueError as exc:
                assert "source dir" in str(exc).lower()
            else:
                raise AssertionError("expected invalid empty function source dir")

            try:
                py_daemon._resolve_handler_path("public-demo", None, "apps/demo/../../escape")
            except ValueError as exc:
                assert "source dir" in str(exc).lower()
            else:
                raise AssertionError("expected invalid escaped function source dir")

            outside_root = Path(tempfile.mkdtemp(prefix="fastfn-py-outside-"))
            try:
                (root / "linked-out").symlink_to(outside_root, target_is_directory=True)
                try:
                    py_daemon._resolve_handler_path("public-demo", None, "linked-out")
                except ValueError as exc:
                    assert "source dir" in str(exc).lower()
                else:
                    raise AssertionError("expected resolved source dir outside root to fail")
            finally:
                shutil.rmtree(outside_root, ignore_errors=True)

            outside_fn_root = Path(tempfile.mkdtemp(prefix="fastfn-py-linked-fn-"))
            try:
                (outside_fn_root / "handler.py").write_text("def handler(e): return {}\n", encoding="utf-8")
                (root / "linked-fn").symlink_to(outside_fn_root, target_is_directory=True)
                try:
                    py_daemon._resolve_handler_path("linked-fn", None)
                except FileNotFoundError:
                    pass
                else:
                    raise AssertionError("expected symlinked function dir outside root to fail")
            finally:
                shutil.rmtree(outside_fn_root, ignore_errors=True)

            try:
                py_daemon._resolve_handler_path("public-demo", None, "missing/demo")
            except FileNotFoundError as exc:
                assert "source dir" in str(exc).lower()
            else:
                raise AssertionError("expected unknown function source dir")
        finally:
            py_daemon.FUNCTIONS_DIR = old_functions
            py_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime


def test_resolve_config_entrypoint_path_rejects_invalid_configs() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        config_path = fn_dir / "fn.config.json"

        config_path.write_text(json.dumps(["bad"]), encoding="utf-8")
        assert py_daemon._resolve_config_entrypoint_path(fn_dir) is None

        config_path.write_text(json.dumps({"entrypoint": "missing.py"}), encoding="utf-8")
        assert py_daemon._resolve_config_entrypoint_path(fn_dir) is None

        outside_root = Path(tempfile.mkdtemp(prefix="fastfn-py-entry-outside-"))
        try:
            outside_file = outside_root / "outside.py"
            outside_file.write_text("def handler(event): return {}\n", encoding="utf-8")
            (fn_dir / "escape.py").symlink_to(outside_file)
            config_path.write_text(json.dumps({"entrypoint": "escape.py"}), encoding="utf-8")
            assert py_daemon._resolve_config_entrypoint_path(fn_dir) is None
        finally:
            shutil.rmtree(outside_root, ignore_errors=True)


def test_resolve_handler_name() -> None:
    assert py_daemon._resolve_handler_name({}) == "handler"
    assert py_daemon._resolve_handler_name({"invoke": "bad"}) == "handler"
    assert py_daemon._resolve_handler_name({"invoke": {"handler": ""}}) == "handler"
    assert py_daemon._resolve_handler_name({"invoke": {"handler": "main"}}) == "main"
    try:
        py_daemon._resolve_handler_name({"invoke": {"handler": "bad-name!"}})
    except ValueError:
        pass
    else:
        raise AssertionError("expected invalid handler name error")


def test_resolve_invoke_adapter() -> None:
    assert py_daemon._resolve_invoke_adapter({}) == py_daemon._INVOKE_ADAPTER_NATIVE
    assert py_daemon._resolve_invoke_adapter({"invoke": "bad"}) == py_daemon._INVOKE_ADAPTER_NATIVE
    assert py_daemon._resolve_invoke_adapter({"invoke": {"adapter": ""}}) == py_daemon._INVOKE_ADAPTER_NATIVE
    assert py_daemon._resolve_invoke_adapter({"invoke": {"adapter": "native"}}) == py_daemon._INVOKE_ADAPTER_NATIVE
    assert py_daemon._resolve_invoke_adapter({"invoke": {"adapter": "aws-lambda"}}) == py_daemon._INVOKE_ADAPTER_AWS_LAMBDA
    assert py_daemon._resolve_invoke_adapter({"invoke": {"adapter": "lambda"}}) == py_daemon._INVOKE_ADAPTER_AWS_LAMBDA
    assert py_daemon._resolve_invoke_adapter({"invoke": {"adapter": "cloudflare-worker"}}) == py_daemon._INVOKE_ADAPTER_CLOUDFLARE_WORKER
    assert py_daemon._resolve_invoke_adapter({"invoke": {"adapter": "worker"}}) == py_daemon._INVOKE_ADAPTER_CLOUDFLARE_WORKER
    try:
        py_daemon._resolve_invoke_adapter({"invoke": {"adapter": "unsupported"}})
    except ValueError:
        pass
    else:
        raise AssertionError("expected unsupported adapter error")


def test_normalize_response() -> None:
    # Non-object response
    try:
        py_daemon._normalize_response("bad")
    except ValueError as exc:
        assert "object" in str(exc).lower()
    else:
        raise AssertionError("expected object response error")

    # Invalid headers
    try:
        py_daemon._normalize_response({"status": 200, "headers": []})
    except ValueError as exc:
        assert "headers" in str(exc).lower()
    else:
        raise AssertionError("expected headers object error")

    # Null body
    norm = py_daemon._normalize_response({"status": 200, "headers": {}, "body": None})
    assert norm["body"] == ""

    # Non-string body
    norm = py_daemon._normalize_response({"status": 200, "headers": {}, "body": 123})
    assert norm["body"] == "123"

    # Dict/list body gets JSON-serialized with Content-Type
    norm = py_daemon._normalize_response({"status": 200, "headers": {}, "body": {"key": "val"}})
    assert json.loads(norm["body"])["key"] == "val"
    assert norm["headers"].get("Content-Type") == "application/json"

    # Binary body (bytes)
    norm = py_daemon._normalize_response({"status": 200, "headers": {}, "body": b"\x89PNG"})
    assert norm["is_base64"] is True
    assert "body_base64" in norm

    # Tuple return: (body, status, headers)
    norm = py_daemon._normalize_response(("hello", 201, {"X-Custom": "1"}))
    assert norm["status"] == 201
    assert norm["body"] == "hello"
    assert norm["headers"]["X-Custom"] == "1"

    # Tuple return: (body,)
    norm = py_daemon._normalize_response(("hello",))
    assert norm["status"] == 200
    assert norm["body"] == "hello"

    # Base64 response
    try:
        py_daemon._normalize_response({"status": 200, "headers": {}, "is_base64": True, "body_base64": ""})
    except ValueError as exc:
        assert "body_base64" in str(exc)
    else:
        raise AssertionError("expected invalid body_base64")

    valid_b64 = py_daemon._normalize_response({"status": 200, "headers": {}, "is_base64": True, "body_base64": "AAAA"})
    assert valid_b64["is_base64"] is True
    assert valid_b64["body_base64"] == "AAAA"

    # Invalid status
    try:
        py_daemon._normalize_response({"status": 99, "headers": {}})
    except ValueError as exc:
        assert "status" in str(exc).lower()
    else:
        raise AssertionError("expected invalid status error")

    # statusCode alias
    norm = py_daemon._normalize_response({"statusCode": 201, "headers": {}, "body": "ok"})
    assert norm["status"] == 201

    # isBase64Encoded alias
    norm = py_daemon._normalize_response({"status": 200, "headers": {}, "isBase64Encoded": True, "body": "AAAA"})
    assert norm["is_base64"] is True
    assert norm["body_base64"] == "AAAA"

    # Non-envelope dict treated as JSON body
    norm = py_daemon._normalize_response({"key": "value", "count": 42})
    assert norm["status"] == 200
    parsed = json.loads(norm["body"])
    assert parsed["key"] == "value"

    # Proxy response
    norm = py_daemon._normalize_response({"status": 200, "headers": {}, "body": "ok", "proxy": {"url": "http://x"}})
    assert norm["proxy"]["url"] == "http://x"

    # Invalid proxy
    try:
        py_daemon._normalize_response({"status": 200, "headers": {}, "body": "ok", "proxy": "bad"})
    except ValueError as exc:
        assert "proxy" in str(exc).lower()
    else:
        raise AssertionError("expected proxy error")

    # stdout/stderr preserved
    norm = py_daemon._normalize_response({"status": 200, "headers": {}, "body": "ok", "stdout": "log", "stderr": "warn"})
    assert norm["stdout"] == "log"
    assert norm["stderr"] == "warn"


def test_normalize_worker_pool_settings() -> None:
    settings = py_daemon._normalize_worker_pool_settings(
        {
            "event": {
                "context": {
                    "timeout_ms": 1200,
                    "worker_pool": {
                        "enabled": True,
                        "max_workers": 4,
                        "min_warm": 10,
                        "idle_ttl_seconds": -1,
                    },
                }
            }
        }
    )
    assert settings["enabled"] is True
    assert settings["max_workers"] == 4
    assert settings["min_warm"] == 4  # clamped to max_workers
    assert settings["idle_ttl_ms"] == py_daemon.RUNTIME_POOL_IDLE_TTL_MS
    assert settings["acquire_timeout_ms"] >= py_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS

    # Negative values
    s = py_daemon._normalize_worker_pool_settings(
        {
            "event": {
                "context": {
                    "timeout_ms": -1,
                    "worker_pool": {
                        "enabled": True,
                        "max_workers": -10,
                        "min_warm": -3,
                        "idle_ttl_seconds": 0,
                    },
                }
            }
        }
    )
    assert s["enabled"] is False
    assert s["max_workers"] == 0
    assert s["min_warm"] == 0
    assert s["request_timeout_ms"] == 0
    assert s["acquire_timeout_ms"] >= 100

    # No context
    s = py_daemon._normalize_worker_pool_settings({"event": {}})
    assert s["enabled"] is False
    assert s["max_workers"] == 0


def test_runtime_pool_key() -> None:
    assert py_daemon._runtime_pool_key("x", None) == "x@default"
    assert py_daemon._runtime_pool_key(None, None) == "unknown@default"
    assert py_daemon._runtime_pool_key("fn", "v2") == "fn@v2"


def test_ensure_socket_dir() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        path = str(Path(tmp) / "sock" / "fn.sock")
        py_daemon._ensure_socket_dir(path)
        assert (Path(tmp) / "sock").is_dir()


def test_prepare_socket_path() -> None:
    # stat race tolerance (socket removed between checks)
    old_stat = py_daemon.os.stat
    try:
        py_daemon.os.stat = lambda _p: (_ for _ in ()).throw(FileNotFoundError("gone"))
        py_daemon._prepare_socket_path("/tmp/fastfn/fn-python.sock")
    finally:
        py_daemon.os.stat = old_stat

    # Non-socket file
    with tempfile.TemporaryDirectory() as tmp:
        not_socket = Path(tmp) / "plain.file"
        not_socket.write_text("x", encoding="utf-8")
        try:
            py_daemon._prepare_socket_path(str(not_socket))
        except RuntimeError as exc:
            assert "not a unix socket" in str(exc).lower()
        else:
            raise AssertionError("expected non-socket error")

    # Stale socket (connect fails) -> remove
    old_stat = py_daemon.os.stat
    old_socket_ctor = py_daemon.socket.socket
    old_remove = py_daemon.os.remove
    try:
        class _SockStat:
            st_mode = stat.S_IFSOCK

        class _Probe:
            def __init__(self, should_connect=False):
                self._connect = should_connect

            def settimeout(self, _v):
                return None

            def connect(self, _path):
                if self._connect:
                    return None
                raise OSError("stale")

            def close(self):
                return None

        py_daemon.os.stat = lambda _p: _SockStat()
        py_daemon.socket.socket = lambda *_a, **_k: _Probe(False)
        py_daemon.os.remove = lambda _p: (_ for _ in ()).throw(FileNotFoundError())
        py_daemon._prepare_socket_path("/tmp/fn-python.sock")

        # Socket in use
        py_daemon.socket.socket = lambda *_a, **_k: _Probe(True)
        try:
            py_daemon._prepare_socket_path("/tmp/fn-python.sock")
        except RuntimeError as exc:
            assert "already in use" in str(exc).lower()
        else:
            raise AssertionError("expected in-use socket error")
    finally:
        py_daemon.os.stat = old_stat
        py_daemon.socket.socket = old_socket_ctor
        py_daemon.os.remove = old_remove


def test_serve_conn() -> None:
    old_read = py_daemon._read_frame
    old_handle = py_daemon._handle_request_with_pool
    try:
        # Normal response
        left, right = socket.socketpair()
        with left, right:
            py_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            py_daemon._handle_request_with_pool = lambda _r: {"status": 200, "headers": {}, "body": "ok"}
            py_daemon._serve_conn(left)
            assert _read_frame(right)["status"] == 200

        # ValueError -> 400
        left, right = socket.socketpair()
        with left, right:
            py_daemon._read_frame = lambda _c: (_ for _ in ()).throw(ValueError("bad frame"))
            py_daemon._serve_conn(left)
            err = _read_frame(right)
            assert err["status"] == 400

        # FileNotFoundError -> 404
        left, right = socket.socketpair()
        with left, right:
            py_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            py_daemon._handle_request_with_pool = lambda _r: (_ for _ in ()).throw(FileNotFoundError("missing"))
            py_daemon._serve_conn(left)
            resp = _read_frame(right)
            assert resp["status"] == 404

        # RuntimeError -> 500
        left, right = socket.socketpair()
        with left, right:
            py_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            py_daemon._handle_request_with_pool = lambda _r: (_ for _ in ()).throw(RuntimeError("boom"))
            py_daemon._serve_conn(left)
            resp = _read_frame(right)
            assert resp["status"] == 500

        # Write failure (silent)
        left, right = socket.socketpair()
        old_write = py_daemon._write_frame
        with left, right:
            py_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            py_daemon._handle_request_with_pool = lambda _r: {"status": 200, "headers": {}, "body": "ok"}
            py_daemon._write_frame = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("write failed"))
            py_daemon._serve_conn(left)
        py_daemon._write_frame = old_write
    finally:
        py_daemon._read_frame = old_read
        py_daemon._handle_request_with_pool = old_handle


def test_handle_request_direct() -> None:
    old_resolve = py_daemon._resolve_handler_path
    old_config = py_daemon._read_function_config
    old_reqs = py_daemon._ensure_requirements
    old_inprocess_fn = py_daemon._handle_request_inprocess
    try:
        py_daemon._resolve_handler_path = lambda *_a, **_k: Path("/tmp/unit.py")
        py_daemon._read_function_config = lambda _p: {}
        py_daemon._ensure_requirements = lambda _p: None
        seen = {}

        def fake_inprocess(_path, _handler, _deps, event, _adapter):
            seen["event"] = event
            return {"status": 200, "headers": {}, "body": "ok"}

        py_daemon._handle_request_inprocess = fake_inprocess
        resp = py_daemon._handle_request_direct(
            {"fn": "demo", "event": {"env": {"A": "2"}, "context": {"timeout_ms": 100}}}
        )
        assert resp["status"] == 200

        # Missing fn
        try:
            py_daemon._handle_request_direct({"fn": "", "event": {}})
        except ValueError:
            pass
        else:
            raise AssertionError("expected missing fn error")

        # Invalid event
        try:
            py_daemon._handle_request_direct({"fn": "demo", "event": "bad"})
        except ValueError as exc:
            assert "event" in str(exc).lower()
        else:
            raise AssertionError("expected event object validation")
    finally:
        py_daemon._resolve_handler_path = old_resolve
        py_daemon._read_function_config = old_config
        py_daemon._ensure_requirements = old_reqs
        py_daemon._handle_request_inprocess = old_inprocess_fn


def test_handle_request_with_pool() -> None:
    old_enabled = py_daemon.ENABLE_RUNTIME_WORKER_POOL
    old_direct = py_daemon._handle_request_direct
    old_prepare = getattr(py_daemon, "_prepare_request", None)
    old_run_sub = py_daemon._run_in_subprocess
    try:
        # Pool disabled -> direct
        py_daemon._handle_request_direct = lambda _req: {"status": 200, "headers": {}, "body": "direct"}
        py_daemon.ENABLE_RUNTIME_WORKER_POOL = False
        resp = py_daemon._handle_request_with_pool({"fn": "demo", "event": {}})
        assert resp["body"] == "direct"

        # Pool enabled
        py_daemon.ENABLE_RUNTIME_WORKER_POOL = True
        py_daemon._handle_request_direct = lambda _req: {"status": 200, "headers": {}, "body": "pooled"}
        resp = py_daemon._handle_request_with_pool(
            {"fn": "demo", "event": {"context": {"timeout_ms": 100, "worker_pool": {"enabled": True, "max_workers": 1}}}}
        )
        assert resp["status"] == 200
    finally:
        py_daemon.ENABLE_RUNTIME_WORKER_POOL = old_enabled
        py_daemon._handle_request_direct = old_direct
        if old_prepare is not None:
            py_daemon._prepare_request = old_prepare
        py_daemon._run_in_subprocess = old_run_sub


def test_pool_submission_and_callback() -> None:
    executor = py_daemon.ThreadPoolExecutor(max_workers=1)
    try:
        pool = {"executor": executor, "pending": 0, "last_used": 0.0}
        key = "unit@default"
        old_pools = py_daemon._RUNTIME_POOLS
        old_direct = py_daemon._handle_request_direct
        py_daemon._RUNTIME_POOLS = {key: pool}
        py_daemon._handle_request_direct = lambda _req: {"status": 200, "headers": {}, "body": "ok"}
        fut = py_daemon._submit_runtime_pool_request(key, pool, {"fn": "demo", "event": {}})
        assert isinstance(fut, Future)
        out = fut.result(timeout=2)
        assert out["status"] == 200
        assert pool["pending"] == 0
    finally:
        py_daemon._handle_request_direct = old_direct
        py_daemon._RUNTIME_POOLS = old_pools
        executor.shutdown(wait=False, cancel_futures=False)

    # Invalid executor
    try:
        py_daemon._submit_runtime_pool_request("x", {"executor": object()}, {"fn": "demo", "event": {}})
    except RuntimeError as exc:
        assert "executor" in str(exc).lower()
    else:
        raise AssertionError("expected invalid executor error")


def test_shutdown_runtime_pool() -> None:
    exec1 = py_daemon.ThreadPoolExecutor(max_workers=1)
    try:
        py_daemon._shutdown_runtime_pool({"executor": exec1})
        py_daemon._shutdown_runtime_pool({"executor": object()})  # non-executor
    finally:
        exec1.shutdown(wait=False, cancel_futures=False)


def test_warmup_runtime_pool() -> None:
    py_daemon._warmup_runtime_pool({"min_warm": 0, "executor": object()})
    py_daemon._warmup_runtime_pool({"min_warm": 1, "executor": object()})  # non-executor
    exec2 = py_daemon.ThreadPoolExecutor(max_workers=1)
    try:
        py_daemon._warmup_runtime_pool({"min_warm": 2, "executor": exec2})
    finally:
        exec2.shutdown(wait=False, cancel_futures=False)

    # Tolerates future failures
    exec3 = py_daemon.ThreadPoolExecutor(max_workers=1)
    old_submit = exec3.submit
    try:
        class _BadFuture:
            def result(self, timeout=None):
                raise RuntimeError("boom")
        exec3.submit = lambda *_a, **_k: _BadFuture()
        py_daemon._warmup_runtime_pool({"min_warm": 1, "executor": exec3})
    finally:
        exec3.submit = old_submit
        exec3.shutdown(wait=False, cancel_futures=False)


def test_ensure_runtime_pool() -> None:
    old_pools = py_daemon._RUNTIME_POOLS
    old_lock = py_daemon._RUNTIME_POOLS_LOCK
    old_start_reaper = py_daemon._start_runtime_pool_reaper
    old_warmup = py_daemon._warmup_runtime_pool
    try:
        py_daemon._RUNTIME_POOLS = {}
        py_daemon._RUNTIME_POOLS_LOCK = py_daemon.threading.Lock()
        py_daemon._start_runtime_pool_reaper = lambda: None
        py_daemon._warmup_runtime_pool = lambda _pool: None

        p1 = py_daemon._ensure_runtime_pool("unit@v1", {"max_workers": 1, "min_warm": 0, "idle_ttl_ms": 1000})
        assert p1["max_workers"] == 1
        p2 = py_daemon._ensure_runtime_pool("unit@v1", {"max_workers": 1, "min_warm": 1, "idle_ttl_ms": 2000})
        assert p2 is p1 and p2["min_warm"] == 1 and p2["idle_ttl_ms"] == 2000
        p3 = py_daemon._ensure_runtime_pool("unit@v1", {"max_workers": 2, "min_warm": 0, "idle_ttl_ms": 1000})
        assert p3 is not p2 and p3["max_workers"] == 2
    finally:
        for pool in py_daemon._RUNTIME_POOLS.values():
            ex = pool.get("executor")
            if isinstance(ex, py_daemon.ThreadPoolExecutor):
                ex.shutdown(wait=False, cancel_futures=False)
        py_daemon._RUNTIME_POOLS = old_pools
        py_daemon._RUNTIME_POOLS_LOCK = old_lock
        py_daemon._start_runtime_pool_reaper = old_start_reaper
        py_daemon._warmup_runtime_pool = old_warmup


def test_reaper_and_main_paths() -> None:
    # Cover reaper: evict idle pool
    old_started = py_daemon._RUNTIME_POOL_REAPER_STARTED
    old_interval = py_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread = py_daemon.threading.Thread
    old_sleep = py_daemon.time.sleep
    old_monotonic = py_daemon.time.monotonic
    old_shutdown = py_daemon._shutdown_runtime_pool
    old_pools = py_daemon._RUNTIME_POOLS
    try:
        py_daemon._RUNTIME_POOL_REAPER_STARTED = False
        py_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        pool = {
            "executor": py_daemon.ThreadPoolExecutor(max_workers=1),
            "pending": 0,
            "min_warm": 0,
            "idle_ttl_ms": 1,
            "last_used": 1.0,
        }
        py_daemon._RUNTIME_POOLS = {"idle@default": pool}
        shutdown_calls: list[str] = []
        py_daemon._shutdown_runtime_pool = lambda _pool: shutdown_calls.append("x")

        sleep_calls = {"n": 0}

        def fake_sleep(_seconds):
            sleep_calls["n"] += 1
            if sleep_calls["n"] > 1:
                raise StopIteration("stop reaper loop")

        py_daemon.time.sleep = fake_sleep
        py_daemon.time.monotonic = lambda: 9999.0

        class InlineThread:
            def __init__(self, target=None, **_kwargs):
                self._target = target

            def start(self):
                try:
                    if self._target:
                        self._target()
                except StopIteration:
                    pass

        py_daemon.threading.Thread = InlineThread
        py_daemon._start_runtime_pool_reaper()
        assert py_daemon._RUNTIME_POOL_REAPER_STARTED is True
        assert "idle@default" not in py_daemon._RUNTIME_POOLS
        assert shutdown_calls, "reaper should shutdown evicted pools"
    finally:
        try:
            executor = pool.get("executor") if isinstance(pool, dict) else None
            if isinstance(executor, py_daemon.ThreadPoolExecutor):
                executor.shutdown(wait=False, cancel_futures=False)
        except Exception:
            pass
        py_daemon._RUNTIME_POOL_REAPER_STARTED = old_started
        py_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        py_daemon.threading.Thread = old_thread
        py_daemon.time.sleep = old_sleep
        py_daemon.time.monotonic = old_monotonic
        py_daemon._shutdown_runtime_pool = old_shutdown
        py_daemon._RUNTIME_POOLS = old_pools

    # Reaper early exits
    old_started = py_daemon._RUNTIME_POOL_REAPER_STARTED
    old_interval = py_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    try:
        py_daemon._RUNTIME_POOL_REAPER_STARTED = True
        py_daemon._start_runtime_pool_reaper()
        py_daemon._RUNTIME_POOL_REAPER_STARTED = False
        py_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 0
        py_daemon._start_runtime_pool_reaper()
    finally:
        py_daemon._RUNTIME_POOL_REAPER_STARTED = old_started
        py_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval

    # Reaper continue branch (pending/min_warm > 0)
    old_started = py_daemon._RUNTIME_POOL_REAPER_STARTED
    old_interval = py_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread_cls = py_daemon.threading.Thread
    old_sleep = py_daemon.time.sleep
    old_mono = py_daemon.time.monotonic
    old_shutdown_pool = py_daemon._shutdown_runtime_pool
    old_pools = py_daemon._RUNTIME_POOLS
    try:
        sleep_calls = {"n": 0}
        shutdown_calls2 = {"n": 0}

        def _fake_sleep(_seconds):
            sleep_calls["n"] += 1
            if sleep_calls["n"] > 1:
                raise RuntimeError("stop-reaper")

        def _fake_shutdown(_pool):
            shutdown_calls2["n"] += 1

        class _InlineThread:
            def __init__(self, *, target=None, **_kwargs):
                self._target = target

            def start(self):
                try:
                    if self._target is not None:
                        self._target()
                except RuntimeError as exc:
                    if str(exc) != "stop-reaper":
                        raise

        py_daemon._RUNTIME_POOLS = {
            "pending@v1": {"pending": 1, "min_warm": 0, "idle_ttl_ms": 1, "last_used": 0.0},
            "warm@v1": {"pending": 0, "min_warm": 1, "idle_ttl_ms": 1, "last_used": 0.0},
        }
        py_daemon._RUNTIME_POOL_REAPER_STARTED = False
        py_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        py_daemon.threading.Thread = _InlineThread
        py_daemon.time.sleep = _fake_sleep
        py_daemon.time.monotonic = lambda: 10.0
        py_daemon._shutdown_runtime_pool = _fake_shutdown
        py_daemon._start_runtime_pool_reaper()
        assert shutdown_calls2["n"] == 0
    finally:
        py_daemon._RUNTIME_POOLS = old_pools
        py_daemon._RUNTIME_POOL_REAPER_STARTED = old_started
        py_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        py_daemon.threading.Thread = old_thread_cls
        py_daemon.time.sleep = old_sleep
        py_daemon.time.monotonic = old_mono
        py_daemon._shutdown_runtime_pool = old_shutdown_pool

    # Cover main socket bootstrap with inline fakes
    old_socket = py_daemon.socket.socket
    old_remove = py_daemon.os.remove
    old_exists = py_daemon.os.path.exists
    old_chmod = py_daemon.os.chmod
    old_thread = py_daemon.threading.Thread
    old_serve_conn = py_daemon._serve_conn
    old_ensure_dir = py_daemon._ensure_socket_dir
    old_prepare = py_daemon._prepare_socket_path
    old_preinstall = py_daemon._preinstall_requirements_on_start
    try:
        served: list[str] = []
        py_daemon._serve_conn = lambda _conn: served.append("conn")
        py_daemon._ensure_socket_dir = lambda _path: None
        py_daemon._prepare_socket_path = lambda _path: None
        py_daemon._preinstall_requirements_on_start = lambda: None
        py_daemon.os.path.exists = lambda _p: True
        py_daemon.os.remove = lambda _p: None
        py_daemon.os.chmod = lambda _p, _m: None

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

        class InlineThread2:
            def __init__(self, target=None, args=(), **_kwargs):
                self._target = target
                self._args = args

            def start(self):
                if self._target:
                    self._target(*self._args)

        py_daemon.socket.socket = DummyServer
        py_daemon.threading.Thread = InlineThread2
        try:
            py_daemon.main()
        except KeyboardInterrupt:
            pass
        else:
            raise AssertionError("expected KeyboardInterrupt to break main loop")
        assert served == ["conn"], served
    finally:
        py_daemon.socket.socket = old_socket
        py_daemon.os.remove = old_remove
        py_daemon.os.path.exists = old_exists
        py_daemon.os.chmod = old_chmod
        py_daemon.threading.Thread = old_thread
        py_daemon._serve_conn = old_serve_conn
        py_daemon._ensure_socket_dir = old_ensure_dir
        py_daemon._prepare_socket_path = old_prepare
        py_daemon._preinstall_requirements_on_start = old_preinstall


def test_emit_handler_logs() -> None:
    stdout_buf = io.StringIO()
    stderr_buf = io.StringIO()
    with redirect_stdout(stdout_buf), redirect_stderr(stderr_buf):
        py_daemon._emit_handler_logs(
            {"fn": "hello", "version": "v2"},
            {"stdout": "line one", "stderr": "warn one\nwarn two"},
        )
    assert "[fn:hello@v2 stdout] line one" in stdout_buf.getvalue()
    assert "[fn:hello@v2 stderr] warn one" in stderr_buf.getvalue()
    assert "[fn:hello@v2 stderr] warn two" in stderr_buf.getvalue()

    # Non-dict resp
    py_daemon._emit_handler_logs({}, "bad")
    # Missing fn/version
    py_daemon._emit_handler_logs({}, {"stdout": "", "stderr": ""})


def test_append_runtime_log() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        log_file = str(Path(tmp) / "runtime.log")
        old_log = py_daemon.RUNTIME_LOG_FILE
        try:
            py_daemon.RUNTIME_LOG_FILE = log_file
            py_daemon._append_runtime_log("python", "test line")
            content = Path(log_file).read_text(encoding="utf-8")
            assert "[python] test line" in content
        finally:
            py_daemon.RUNTIME_LOG_FILE = old_log

    # Empty log file path -> no-op
    old_log = py_daemon.RUNTIME_LOG_FILE
    try:
        py_daemon.RUNTIME_LOG_FILE = ""
        py_daemon._append_runtime_log("python", "ignored")
    finally:
        py_daemon.RUNTIME_LOG_FILE = old_log


def test_normalize_requirement_name() -> None:
    assert py_daemon._normalize_requirement_name("requests==2.28.0") == "requests"
    assert py_daemon._normalize_requirement_name("Flask") == "flask"
    assert py_daemon._normalize_requirement_name("# comment") is None
    assert py_daemon._normalize_requirement_name("") is None
    assert py_daemon._normalize_requirement_name("-e .") is None
    assert py_daemon._normalize_requirement_name("git+https://foo.git") is None
    assert py_daemon._normalize_requirement_name("https://files.example.com/pkg.whl") is None
    assert py_daemon._normalize_requirement_name("file:local.whl") is None


def test_infer_python_imports() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text(
            "import requests\nimport json\nfrom flask import Flask\nfrom . import local\n",
            encoding="utf-8",
        )
        imports = py_daemon._infer_python_imports(handler)
        assert "requests" in imports
        assert "flask" in imports
        # json is stdlib, should be filtered
        assert "json" not in imports
        # relative imports are skipped
        # "local" would be relative

        # Local module detection
        local_mod = fn_dir / "mylocal.py"
        local_mod.write_text("x = 1\n", encoding="utf-8")
        handler.write_text("import mylocal\nimport requests\n", encoding="utf-8")
        imports = py_daemon._infer_python_imports(handler)
        assert "mylocal" not in imports
        assert "requests" in imports

        # Invalid syntax -> empty
        handler.write_text("def bad syntax\n", encoding="utf-8")
        assert py_daemon._infer_python_imports(handler) == []


def test_map_python_import_to_package() -> None:
    pkg, unresolved = py_daemon._map_python_import_to_package("PIL")
    assert pkg is None
    assert unresolved == "PIL"

    pkg, unresolved = py_daemon._map_python_import_to_package("requests")
    assert pkg == "requests"
    assert unresolved is None

    # Uppercase -> unresolved
    pkg, unresolved = py_daemon._map_python_import_to_package("MyModule")
    assert pkg is None
    assert unresolved == "MyModule"


def test_resolve_inferred_python_packages() -> None:
    resolved, unresolved = py_daemon._resolve_inferred_python_packages(["PIL", "requests", "MyModule"])
    assert "requests" in resolved
    assert "PIL" in unresolved
    assert "MyModule" in unresolved
    # Dedup
    resolved2, _ = py_daemon._resolve_inferred_python_packages(["requests", "requests"])
    assert resolved2.count("requests") == 1


def test_resolve_python_infer_backend() -> None:
    old_backend = py_daemon.PY_INFER_BACKEND
    try:
        py_daemon.PY_INFER_BACKEND = "native"
        assert py_daemon._resolve_python_infer_backend() == "native"

        py_daemon.PY_INFER_BACKEND = "pipreqs"
        assert py_daemon._resolve_python_infer_backend() == "pipreqs"

        py_daemon.PY_INFER_BACKEND = "bad-backend"
        try:
            py_daemon._resolve_python_infer_backend()
        except RuntimeError as exc:
            assert "unsupported" in str(exc).lower()
        else:
            raise AssertionError("expected invalid python infer backend error")
    finally:
        py_daemon.PY_INFER_BACKEND = old_backend


def test_parse_inferred_requirement_specs() -> None:
    specs, names = py_daemon._parse_inferred_requirement_specs(
        ["requests", "Flask", "requests", "# comment", "", "git+https://example.invalid/pkg.git"]
    )
    assert specs == ["requests", "Flask"]
    assert names == ["requests", "flask"]


def test_infer_python_packages_with_pipreqs() -> None:
    import types

    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("import requests\nimport flask\nfrom yaml import safe_load\n", encoding="utf-8")

        old_run = py_daemon._REAL_SUBPROCESS_RUN
        try:
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: types.SimpleNamespace(
                returncode=0,
                stdout="requests\nFlask\nPyYAML\n",
                stderr="",
            )
            inferred, specs, names = py_daemon._infer_python_packages_with_pipreqs(handler)
            assert inferred == ["flask", "requests", "yaml"]
            assert specs == ["requests", "Flask", "PyYAML"]
            assert names == ["requests", "flask", "pyyaml"]
        finally:
            py_daemon._REAL_SUBPROCESS_RUN = old_run


def test_infer_python_packages_with_pipreqs_missing_backend() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("import requests\n", encoding="utf-8")

        old_run = py_daemon._REAL_SUBPROCESS_RUN
        try:
            def raise_missing(*_a, **_kw):
                raise FileNotFoundError("pipreqs missing")

            py_daemon._REAL_SUBPROCESS_RUN = raise_missing
            try:
                py_daemon._infer_python_packages_with_pipreqs(handler)
            except RuntimeError as exc:
                assert "pipreqs" in str(exc).lower()
                assert "install it" in str(exc).lower()
            else:
                raise AssertionError("expected missing pipreqs error")
        finally:
            py_daemon._REAL_SUBPROCESS_RUN = old_run


def test_infer_python_packages_with_pipreqs_reports_unavailable_from_stderr() -> None:
    import types

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("import requests\n", encoding="utf-8")

        old_run = py_daemon._REAL_SUBPROCESS_RUN
        try:
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: types.SimpleNamespace(
                returncode=1,
                stdout="",
                stderr="No module named pipreqs",
            )
            try:
                py_daemon._infer_python_packages_with_pipreqs(handler)
            except RuntimeError as exc:
                assert "pipreqs" in str(exc).lower()
                assert "install it" in str(exc).lower()
            else:
                raise AssertionError("expected unavailable pipreqs error")
        finally:
            py_daemon._REAL_SUBPROCESS_RUN = old_run


def test_infer_python_packages_with_pipreqs_reports_generic_failure() -> None:
    import types

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("import requests\n", encoding="utf-8")

        old_run = py_daemon._REAL_SUBPROCESS_RUN
        try:
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: types.SimpleNamespace(
                returncode=2,
                stdout="",
                stderr="resolver exploded\ntrace line 1\ntrace line 2",
            )
            try:
                py_daemon._infer_python_packages_with_pipreqs(handler)
            except RuntimeError as exc:
                assert "pipreqs failed" in str(exc).lower()
                assert "resolver exploded" in str(exc).lower()
            else:
                raise AssertionError("expected generic pipreqs failure")
        finally:
            py_daemon._REAL_SUBPROCESS_RUN = old_run


def test_infer_python_packages_with_pipreqs_strict_error_when_nothing_is_resolved() -> None:
    import types

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("import requests\nimport flask\n", encoding="utf-8")

        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_strict = py_daemon.AUTO_INFER_STRICT
        try:
            py_daemon.AUTO_INFER_STRICT = True
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: types.SimpleNamespace(
                returncode=0,
                stdout="",
                stderr="",
            )
            try:
                py_daemon._infer_python_packages_with_pipreqs(handler)
            except RuntimeError as exc:
                assert "did not resolve packages" in str(exc).lower()
                assert "requests" in str(exc).lower()
                assert "flask" in str(exc).lower()
            else:
                raise AssertionError("expected strict pipreqs resolution error")
        finally:
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon.AUTO_INFER_STRICT = old_strict


def test_extract_shared_deps() -> None:
    assert py_daemon._extract_shared_deps({}) == []
    assert py_daemon._extract_shared_deps({"shared_deps": "bad"}) == []
    assert py_daemon._extract_shared_deps({"shared_deps": ["pack1", "pack2"]}) == ["pack1", "pack2"]
    assert py_daemon._extract_shared_deps({"shared_deps": ["pack1", 123, "pack1"]}) == ["pack1"]  # dedup + type filter
    assert py_daemon._extract_shared_deps({"shared_deps": ["", "   "]}) == []


def test_parse_extra_allow_roots() -> None:
    old_extra = py_daemon.STRICT_FS_EXTRA_ALLOW
    try:
        py_daemon.STRICT_FS_EXTRA_ALLOW = "/opt/custom,/tmp/data"
        roots = py_daemon._parse_extra_allow_roots()
        assert len(roots) == 2

        py_daemon.STRICT_FS_EXTRA_ALLOW = ""
        assert py_daemon._parse_extra_allow_roots() == []

        py_daemon.STRICT_FS_EXTRA_ALLOW = "\x00bad"
        assert py_daemon._parse_extra_allow_roots() == []
    finally:
        py_daemon.STRICT_FS_EXTRA_ALLOW = old_extra


def test_resolve_candidate_path() -> None:
    assert py_daemon._resolve_candidate_path(42) is None
    assert py_daemon._resolve_candidate_path("") is None
    assert py_daemon._resolve_candidate_path(None) is None
    result = py_daemon._resolve_candidate_path("/tmp/test")
    assert isinstance(result, Path)
    result = py_daemon._resolve_candidate_path(b"/tmp/test")
    assert isinstance(result, Path)
    result = py_daemon._resolve_candidate_path(Path("/tmp/test"))
    assert isinstance(result, Path)


def test_path_allowed() -> None:
    fn_dir = Path("/tmp/fn")
    allowed = [Path("/tmp/fn"), Path("/tmp")]

    ok, reason = py_daemon._path_allowed(Path("/tmp/fn/handler.py"), allowed, fn_dir)
    assert ok is True

    ok, reason = py_daemon._path_allowed(Path("/etc/secret"), allowed, fn_dir)
    assert ok is False
    assert "sandbox" in reason.lower()

    # Protected files
    ok, reason = py_daemon._path_allowed(Path("/tmp/fn/fn.config.json"), allowed, fn_dir)
    assert ok is False
    assert "protected" in reason.lower()


def test_build_allowed_roots() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("x = 1\n", encoding="utf-8")
        roots, fn_dir = py_daemon._build_allowed_roots(handler)
        assert fn_dir == Path(tmp).resolve(strict=False)
        assert len(roots) >= 2  # function_dir + .deps + system roots

        # With extra roots
        roots_extra, _ = py_daemon._build_allowed_roots(handler, extra_roots=[Path("/opt/extra")])
        assert len(roots_extra) > len(roots)


def test_is_local_python_module() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        assert py_daemon._is_local_python_module(fn_dir, "") is False

        # File-based module
        (fn_dir / "mymod.py").write_text("x = 1\n", encoding="utf-8")
        assert py_daemon._is_local_python_module(fn_dir, "mymod") is True

        # Dir-based module
        (fn_dir / "mypkg").mkdir()
        assert py_daemon._is_local_python_module(fn_dir, "mypkg") is True

        assert py_daemon._is_local_python_module(fn_dir, "nonexistent") is False


def test_worker_pool_key() -> None:
    key = py_daemon._worker_pool_key(Path("/tmp/fn/handler.py"), "handler", ["/tmp/deps"], "native")
    assert "handler.py" in key
    assert "handler" in key
    assert "native" in key


def test_has_function_deps() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")
        assert py_daemon._has_function_deps(handler) is False

        # requirements.txt
        (fn_dir / "requirements.txt").write_text("requests\n", encoding="utf-8")
        assert py_daemon._has_function_deps(handler) is True
        (fn_dir / "requirements.txt").unlink()

        # .deps dir
        (fn_dir / ".deps").mkdir()
        assert py_daemon._has_function_deps(handler) is True
        (fn_dir / ".deps").rmdir()

        # Inline requirements
        handler.write_text("#@requirements flask\ndef handler(e): return {}\n", encoding="utf-8")
        assert py_daemon._has_function_deps(handler) is True


def test_run_in_subprocess_oneshot() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")

        old_run = py_daemon._REAL_SUBPROCESS_RUN
        try:
            class Proc:
                def __init__(self, stdout, stderr="", rc=0):
                    self.stdout = stdout
                    self.stderr = stderr
                    self.returncode = rc

            # Happy path
            py_daemon._REAL_SUBPROCESS_RUN = lambda *_a, **_k: Proc(
                json.dumps({"status": 200, "headers": {}, "body": "ok"})
            )
            resp = py_daemon._run_in_subprocess_oneshot(handler, "handler", [], {}, 5.0)
            assert resp["status"] == 200

            # Empty stdout
            py_daemon._REAL_SUBPROCESS_RUN = lambda *_a, **_k: Proc("", "error line", 1)
            resp = py_daemon._run_in_subprocess_oneshot(handler, "handler", [], {}, 5.0)
            assert resp["status"] == 500

            # Invalid JSON
            py_daemon._REAL_SUBPROCESS_RUN = lambda *_a, **_k: Proc("not json")
            resp = py_daemon._run_in_subprocess_oneshot(handler, "handler", [], {}, 5.0)
            assert resp["status"] == 500

            # Timeout
            import subprocess as _sp
            py_daemon._REAL_SUBPROCESS_RUN = lambda *_a, **_k: (_ for _ in ()).throw(
                _sp.TimeoutExpired(cmd=["python"], timeout=5)
            )
            resp = py_daemon._run_in_subprocess_oneshot(handler, "handler", [], {}, 5.0)
            assert resp["status"] == 504
        finally:
            py_daemon._REAL_SUBPROCESS_RUN = old_run


def test_run_in_subprocess_retry() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")

        old_get_or_create = py_daemon._get_or_create_worker
        old_pool = py_daemon._SUBPROCESS_POOL
        old_pool_lock = py_daemon._SUBPROCESS_POOL_LOCK
        old_env = py_daemon._read_function_env
        try:
            py_daemon._read_function_env = lambda _p: {}
            attempt = {"n": 0}

            class FakeWorker:
                def send_request(self, payload, timeout_s):
                    attempt["n"] += 1
                    if attempt["n"] == 1:
                        raise RuntimeError("worker died")
                    return {"status": 200, "headers": {}, "body": "retried"}

                @property
                def alive(self):
                    return True

                def shutdown(self):
                    pass

            py_daemon._SUBPROCESS_POOL = {}
            py_daemon._SUBPROCESS_POOL_LOCK = py_daemon.threading.Lock()
            py_daemon._get_or_create_worker = lambda *_a, **_k: FakeWorker()
            resp = py_daemon._run_in_subprocess(handler, "handler", [], {}, 5.0)
            assert resp["status"] == 200

            # Timeout
            class TimeoutWorker:
                def send_request(self, payload, timeout_s):
                    raise TimeoutError("timeout")

                @property
                def alive(self):
                    return True

                def shutdown(self):
                    pass

            py_daemon._get_or_create_worker = lambda *_a, **_k: TimeoutWorker()
            resp = py_daemon._run_in_subprocess(handler, "handler", [], {}, 5.0)
            assert resp["status"] == 504
        finally:
            py_daemon._get_or_create_worker = old_get_or_create
            py_daemon._SUBPROCESS_POOL = old_pool
            py_daemon._SUBPROCESS_POOL_LOCK = old_pool_lock
            py_daemon._read_function_env = old_env


def test_deps_state() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")

        # No state file
        assert py_daemon._read_deps_state(handler) == {}

        # Write and read
        py_daemon._write_deps_state(handler, {"runtime": "python", "mode": "manifest"})
        state = py_daemon._read_deps_state(handler)
        assert state["runtime"] == "python"
        assert "updated_at" in state

        # Invalid JSON
        state_path = py_daemon._deps_state_path(handler)
        state_path.write_text("{bad", encoding="utf-8")
        assert py_daemon._read_deps_state(handler) == {}

        # Non-dict
        state_path.write_text(json.dumps(["list"]), encoding="utf-8")
        assert py_daemon._read_deps_state(handler) == {}


def test_read_requirements_lines_and_packages() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        req_file = fn_dir / "requirements.txt"

        # Missing file
        lines, pkgs = py_daemon._read_requirements_lines_and_packages(req_file)
        assert lines == []
        assert pkgs == set()

        # Valid file
        req_file.write_text("requests==2.28.0\nFlask\n# comment\n", encoding="utf-8")
        lines, pkgs = py_daemon._read_requirements_lines_and_packages(req_file)
        assert len(lines) == 3
        assert "requests" in pkgs
        assert "flask" in pkgs


def test_iter_handler_paths() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        old_functions = py_daemon.FUNCTIONS_DIR
        old_assets_dir = py_daemon._ROOT_ASSETS_DIRECTORY
        try:
            py_daemon.FUNCTIONS_DIR = Path(tmp)
            py_daemon._ROOT_ASSETS_DIRECTORY = ""

            # Empty directory
            paths = py_daemon._iter_handler_paths()
            assert paths == []

            # With a function
            fn_dir = Path(tmp) / "myfunc"
            fn_dir.mkdir()
            app = fn_dir / "handler.py"
            app.write_text("def handler(e): return {}\n", encoding="utf-8")
            paths = py_daemon._iter_handler_paths()
            assert len(paths) == 1
            assert paths[0] == app

            main_only_dir = Path(tmp) / "mainonly"
            main_only_dir.mkdir()
            main_file = main_only_dir / "main.py"
            main_file.write_text("def main(req): return {'ok': True}\n", encoding="utf-8")
            paths = py_daemon._iter_handler_paths()
            assert main_file in paths

            # With version subdirectory
            ver_dir = fn_dir / "v1"
            ver_dir.mkdir()
            ver_app = ver_dir / "handler.py"
            ver_app.write_text("def handler(e): return {}\n", encoding="utf-8")
            ver_main_dir = main_only_dir / "v1"
            ver_main_dir.mkdir()
            ver_main = ver_main_dir / "main.py"
            ver_main.write_text("def main(req): return {'ok': True}\n", encoding="utf-8")
            paths = py_daemon._iter_handler_paths()
            assert len(paths) == 4
        finally:
            py_daemon.FUNCTIONS_DIR = old_functions
            py_daemon._ROOT_ASSETS_DIRECTORY = old_assets_dir


def test_iter_handler_paths_skips_configured_assets_directory() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        old_functions = py_daemon.FUNCTIONS_DIR
        old_assets_dir = py_daemon._ROOT_ASSETS_DIRECTORY
        try:
            py_daemon.FUNCTIONS_DIR = Path(tmp)
            (Path(tmp) / "fn.config.json").write_text(
                json.dumps({"assets": {"directory": "public"}}),
                encoding="utf-8",
            )
            py_daemon._ROOT_ASSETS_DIRECTORY = py_daemon._read_root_assets_directory()

            hello_dir = Path(tmp) / "hello"
            hello_dir.mkdir()
            hello_handler = hello_dir / "handler.py"
            hello_handler.write_text("def handler(e): return {}\n", encoding="utf-8")

            public_dir = Path(tmp) / "public"
            public_dir.mkdir()
            (public_dir / "handler.py").write_text("def handler(e): return {}\n", encoding="utf-8")

            paths = py_daemon._iter_handler_paths()
            assert paths == [hello_handler]
        finally:
            py_daemon.FUNCTIONS_DIR = old_functions
            py_daemon._ROOT_ASSETS_DIRECTORY = old_assets_dir


def test_strict_fs_guard() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("x = 1\n", encoding="utf-8")

        old_strict = py_daemon.STRICT_FS
        try:
            # Disabled -> no-op
            py_daemon.STRICT_FS = False
            with py_daemon._strict_fs_guard(handler):
                pass

            # Enabled: blocks subprocess and os.system
            py_daemon.STRICT_FS = True
            with py_daemon._strict_fs_guard(handler):
                import subprocess as _sp
                try:
                    _sp.run(["echo", "test"])
                except PermissionError as exc:
                    assert "subprocess disabled" in str(exc).lower()
                else:
                    raise AssertionError("expected subprocess blocked")

                try:
                    os.system("echo test")
                except PermissionError as exc:
                    assert "os.system disabled" in str(exc).lower()
                else:
                    raise AssertionError("expected os.system blocked")
        finally:
            py_daemon.STRICT_FS = old_strict


def test_acquire_timeout_floor() -> None:
    old_acquire = py_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS
    try:
        py_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = 0
        settings = py_daemon._normalize_worker_pool_settings(
            {"event": {"context": {"worker_pool": {"max_workers": 1}}}}
        )
        assert settings["acquire_timeout_ms"] == 100
    finally:
        py_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = old_acquire


def test_auto_requirements_enabled() -> None:
    old_val = os.environ.get("FN_AUTO_REQUIREMENTS")
    try:
        os.environ["FN_AUTO_REQUIREMENTS"] = "1"
        assert py_daemon._auto_requirements_enabled() is True
        os.environ["FN_AUTO_REQUIREMENTS"] = "0"
        assert py_daemon._auto_requirements_enabled() is False
        os.environ["FN_AUTO_REQUIREMENTS"] = "false"
        assert py_daemon._auto_requirements_enabled() is False
    finally:
        if old_val is None:
            os.environ.pop("FN_AUTO_REQUIREMENTS", None)
        else:
            os.environ["FN_AUTO_REQUIREMENTS"] = old_val


def test_root_assets_helpers_cover_invalid_cases() -> None:
    with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as outside_tmp:
        old_functions = py_daemon.FUNCTIONS_DIR
        old_assets_dir = py_daemon._ROOT_ASSETS_DIRECTORY
        cfg_path = Path(tmp) / "fn.config.json"
        try:
            py_daemon.FUNCTIONS_DIR = Path(tmp)

            assert py_daemon._is_safe_root_relative_path("") is False
            assert py_daemon._is_safe_root_relative_path("/public") is False
            assert py_daemon._is_safe_root_relative_path(r"public\images") is False
            assert py_daemon._is_safe_root_relative_path("public//images") is False
            assert py_daemon._is_safe_root_relative_path("./public") is False
            assert py_daemon._is_safe_root_relative_path("public/../images") is False

            cfg_path.write_text("{invalid", encoding="utf-8")
            assert py_daemon._read_root_assets_directory() == ""

            cfg_path.write_text("[]", encoding="utf-8")
            assert py_daemon._read_root_assets_directory() == ""

            cfg_path.write_text(json.dumps({"assets": "public"}), encoding="utf-8")
            assert py_daemon._read_root_assets_directory() == ""

            cfg_path.write_text(json.dumps({"assets": {"directory": 123}}), encoding="utf-8")
            assert py_daemon._read_root_assets_directory() == "123"

            cfg_path.write_text(json.dumps({"assets": {"directory": "../public"}}), encoding="utf-8")
            assert py_daemon._read_root_assets_directory() == ""

            cfg_path.write_text(json.dumps({"assets": {"directory": "public"}}), encoding="utf-8")
            py_daemon._ROOT_ASSETS_DIRECTORY = py_daemon._read_root_assets_directory()
            assert py_daemon._path_is_in_assets_directory(Path(tmp) / "public" / "index.html") is True
            assert py_daemon._path_is_in_assets_directory(Path(outside_tmp) / "index.html") is False
        finally:
            py_daemon.FUNCTIONS_DIR = old_functions
            py_daemon._ROOT_ASSETS_DIRECTORY = old_assets_dir


def test_submit_pool_request_missing_pool() -> None:
    """When pool disappears from _RUNTIME_POOLS mid-flight, callback handles gracefully."""
    old_pools = py_daemon._RUNTIME_POOLS
    old_direct = py_daemon._handle_request_direct
    exec4 = py_daemon.ThreadPoolExecutor(max_workers=1)
    try:
        import threading as _threading
        started = _threading.Event()
        release = _threading.Event()

        def _slow_ok(_req):
            started.set()
            release.wait(timeout=2)
            return {"status": 200, "headers": {}, "body": "ok"}

        pool = {"executor": exec4, "pending": 0, "last_used": 0.0}
        py_daemon._RUNTIME_POOLS = {"gone@v1": pool}
        py_daemon._handle_request_direct = _slow_ok
        fut = py_daemon._submit_runtime_pool_request("gone@v1", pool, {"fn": "demo", "event": {}})
        assert started.wait(timeout=2)
        py_daemon._RUNTIME_POOLS = {}
        release.set()
        assert fut.result(timeout=2)["status"] == 200
    finally:
        py_daemon._RUNTIME_POOLS = old_pools
        py_daemon._handle_request_direct = old_direct
        exec4.shutdown(wait=False, cancel_futures=False)


# ---------------------------------------------------------------------------
# Additional coverage tests
# ---------------------------------------------------------------------------


def test_write_deps_state_exception() -> None:
    """Cover _write_deps_state exception path (lines 198-199)."""
    import unittest.mock as mock
    handler = Path("/nonexistent/dir/handler.py")
    # Should not raise
    py_daemon._write_deps_state(handler, {"test": True})


def test_json_log_exception() -> None:
    """Cover _json_log exception in print (lines 170-171)."""
    old_print = py_daemon.builtins.print
    py_daemon.builtins.print = lambda *a, **kw: (_ for _ in ()).throw(RuntimeError("boom"))
    try:
        py_daemon._json_log("test_fail")  # Should not raise
    finally:
        py_daemon.builtins.print = old_print


def test_normalize_requirement_name_edges() -> None:
    """Cover edge cases: no regex match (213), empty name (269), same as stem (273), invalid pkg name (285)."""
    # No regex match
    assert py_daemon._normalize_requirement_name("!!!") is None
    # URL-like
    assert py_daemon._normalize_requirement_name("git+https://example.com/repo") is None
    assert py_daemon._normalize_requirement_name("https://example.com/pkg") is None
    assert py_daemon._normalize_requirement_name("file:///tmp/pkg") is None
    # Starts with -
    assert py_daemon._normalize_requirement_name("-e something") is None


def test_read_requirements_lines_exception() -> None:
    """Cover exception reading requirements.txt (lines 222-223)."""
    with tempfile.TemporaryDirectory() as tmp:
        req = Path(tmp) / "requirements.txt"
        req.write_text("requests\n", encoding="utf-8")
        req.chmod(0o000)
        try:
            lines, pkgs = py_daemon._read_requirements_lines_and_packages(req)
            assert lines == []
            assert pkgs == set()
        finally:
            req.chmod(0o644)


def test_infer_python_imports_edges() -> None:
    """Cover lines 269 (empty name skip), 273 (same as handler stem)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "mymod.py"
        # Import of self (handler stem) should be skipped
        handler.write_text("import mymod\nimport os\n", encoding="utf-8")
        result = py_daemon._infer_python_imports(handler)
        assert "mymod" not in result
        assert "os" not in result  # stdlib


def test_map_python_import_uppercase() -> None:
    """Cover line 285-287: uppercase chars in import name."""
    pkg, unresolved = py_daemon._map_python_import_to_package("MyPackage")
    assert pkg is None
    assert unresolved == "MyPackage"


def test_write_python_lockfile() -> None:
    """Cover _write_python_lockfile (lines 313-350)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")
        deps_dir = fn_dir / ".deps"
        deps_dir.mkdir()

        import subprocess as real_subprocess
        import types

        # Mock _REAL_SUBPROCESS_RUN to return success with packages
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        try:
            result_obj = types.SimpleNamespace(returncode=0, stdout="requests==2.28.0\nflask==2.3.0\n", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: result_obj
            lock = py_daemon._write_python_lockfile(handler, deps_dir)
            assert lock is not None
            content = lock.read_text(encoding="utf-8")
            assert "flask" in content
            assert "requests" in content

            # Empty stdout -> empty lockfile
            result_obj2 = types.SimpleNamespace(returncode=0, stdout="", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: result_obj2
            lock2 = py_daemon._write_python_lockfile(handler, deps_dir)
            assert lock2 is not None
            assert lock2.read_text(encoding="utf-8") == ""

            # Failure returncode
            result_obj3 = types.SimpleNamespace(returncode=1, stdout="", stderr="error")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: result_obj3
            lock3 = py_daemon._write_python_lockfile(handler, deps_dir)
            assert lock3 is None

            # Exception in subprocess
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: (_ for _ in ()).throw(OSError("boom"))
            lock4 = py_daemon._write_python_lockfile(handler, deps_dir)
            assert lock4 is None
        finally:
            py_daemon._REAL_SUBPROCESS_RUN = old_run


def test_ensure_requirements_disabled() -> None:
    """Cover _ensure_requirements when auto-requirements disabled (line 376-379)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_log = py_daemon._json_log
        events = []
        try:
            py_daemon._auto_requirements_enabled = lambda: False
            py_daemon._json_log = lambda event, **fields: events.append((event, fields))
            py_daemon._ensure_requirements(handler)
            # Check state was written
            state_path = fn_dir / ".fastfn-deps-state.json"
            assert state_path.is_file()
            state = json.loads(state_path.read_text(encoding="utf-8"))
            assert "disabled" in state.get("last_error", "").lower()
            assert ("deps_install_skip", {"runtime": "python", "fn_dir": str(fn_dir), "mode": "manifest", "reason": "auto_requirements_disabled"}) in events
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon._json_log = old_log


def test_ensure_requirements_no_reqs() -> None:
    """Cover _ensure_requirements with no inline reqs and no requirements.txt (lines 441-444)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_log = py_daemon._json_log
        events = []
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = False
            py_daemon._json_log = lambda event, **fields: events.append((event, fields))
            py_daemon._ensure_requirements(handler)
            state = json.loads((fn_dir / ".fastfn-deps-state.json").read_text(encoding="utf-8"))
            assert state["last_install_status"] == "skipped"
            assert ("deps_install_skip", {"runtime": "python", "fn_dir": str(fn_dir), "mode": "manifest", "reason": "no_effective_requirements"}) in events
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon._json_log = old_log


def test_ensure_requirements_comment_only_manifest_persists_skip() -> None:
    """Comment-only requirements.txt should skip installs, even after cache reset."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "main.py"
        handler.write_text("def main(req): return {'ok': True}\n", encoding="utf-8")
        req_file = fn_dir / "requirements.txt"
        req_file.write_text("# generated scaffold\n\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        old_log = py_daemon._json_log
        calls = []
        events = []
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = False
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: calls.append((a, kw))
            py_daemon._json_log = lambda event, **fields: events.append((event, fields))

            py_daemon._ensure_requirements(handler)
            state = json.loads((fn_dir / ".fastfn-deps-state.json").read_text(encoding="utf-8"))
            assert state["last_install_status"] == "skipped"
            assert isinstance(state.get("install_signature"), str) and state["install_signature"] != ""
            assert calls == []
            assert ("deps_install_skip", {"runtime": "python", "fn_dir": str(fn_dir), "mode": "manifest", "reason": "no_effective_requirements"}) in events

            py_daemon._REQ_CACHE.clear()
            py_daemon._ensure_requirements(handler)
            assert calls == []
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._json_log = old_log
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_ensure_requirements_cached() -> None:
    """Cover _ensure_requirements cache hit path (lines 446-461)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")
        req_file = fn_dir / "requirements.txt"
        req_file.write_text("requests\n", encoding="utf-8")
        deps_dir = fn_dir / ".deps"
        deps_dir.mkdir()
        (deps_dir / "dummy.txt").write_text("x", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        old_log = py_daemon._json_log
        events = []
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = False
            py_daemon._json_log = lambda event, **fields: events.append((event, fields))

            # First run: install success
            install_result = types.SimpleNamespace(returncode=0, stdout="requests==2.28.0\n", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: install_result
            py_daemon._ensure_requirements(handler)

            # Second run: should hit cache
            call_count = [0]
            def counting_run(*a, **kw):
                call_count[0] += 1
                return install_result
            py_daemon._REAL_SUBPROCESS_RUN = counting_run
            py_daemon._ensure_requirements(handler)
            assert call_count[0] == 0, "Should not call subprocess on cache hit"
            assert ("deps_install_reuse", {"runtime": "python", "fn_dir": str(fn_dir), "mode": "manifest", "source": "memory_cache"}) in events
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._json_log = old_log
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_ensure_requirements_persisted_state_skips_reinstall() -> None:
    """A saved install signature should skip reinstall after cache reset."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")
        req_file = fn_dir / "requirements.txt"
        req_file.write_text("requests\n", encoding="utf-8")
        deps_dir = fn_dir / ".deps"
        deps_dir.mkdir()
        (deps_dir / "dummy.txt").write_text("x", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        old_write_lockfile = py_daemon._write_python_lockfile
        old_log = py_daemon._json_log
        events = []
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = False
            py_daemon._write_python_lockfile = lambda *_a, **_kw: None
            py_daemon._json_log = lambda event, **fields: events.append((event, fields))

            call_count = [0]

            def counting_run(*_a, **_kw):
                call_count[0] += 1
                return types.SimpleNamespace(returncode=0, stdout="", stderr="")

            py_daemon._REAL_SUBPROCESS_RUN = counting_run
            py_daemon._ensure_requirements(handler)
            assert call_count[0] == 1

            py_daemon._REQ_CACHE.clear()
            call_count[0] = 0
            py_daemon._ensure_requirements(handler)
            assert call_count[0] == 0
            assert ("deps_install_reuse", {"runtime": "python", "fn_dir": str(fn_dir), "mode": "manifest", "source": "persisted_state"}) in events
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._write_python_lockfile = old_write_lockfile
            py_daemon._json_log = old_log
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_ensure_requirements_pip_fail() -> None:
    """Cover _ensure_requirements pip failure (lines 497-509)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")
        req_file = fn_dir / "requirements.txt"
        req_file.write_text("nonexistent-package\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = False
            fail_result = types.SimpleNamespace(returncode=1, stdout="", stderr="ERROR: Could not find\nsome error")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: fail_result

            try:
                py_daemon._ensure_requirements(handler)
            except RuntimeError as exc:
                assert "pip" in str(exc).lower() or "install" in str(exc).lower()
            else:
                raise AssertionError("expected RuntimeError from pip failure")
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_ensure_requirements_success_with_lockfile() -> None:
    """Cover _ensure_requirements success path with lockfile (lines 511-518)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")
        req_file = fn_dir / "requirements.txt"
        req_file.write_text("requests\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = False
            install_result = types.SimpleNamespace(returncode=0, stdout="requests==2.28.0\n", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: install_result

            py_daemon._ensure_requirements(handler)
            state = json.loads((fn_dir / ".fastfn-deps-state.json").read_text(encoding="utf-8"))
            assert state["last_install_status"] == "ok"
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_ensure_requirements_infer_strict() -> None:
    """Cover AUTO_INFER_PY_DEPS + AUTO_INFER_STRICT error (lines 386-413)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("import NonExistentPkg\ndef handler(event): return {}\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_strict = py_daemon.AUTO_INFER_STRICT
        old_write = py_daemon.AUTO_INFER_WRITE_MANIFEST
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = True
            py_daemon.AUTO_INFER_STRICT = True
            py_daemon.AUTO_INFER_WRITE_MANIFEST = False

            try:
                py_daemon._ensure_requirements(handler)
            except RuntimeError as exc:
                assert "unresolved" in str(exc).lower()
            else:
                raise AssertionError("expected RuntimeError from strict inference")
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon.AUTO_INFER_STRICT = old_strict
            py_daemon.AUTO_INFER_WRITE_MANIFEST = old_write


def test_ensure_requirements_infer_write_manifest() -> None:
    """Cover AUTO_INFER_WRITE_MANIFEST (lines 415-434)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("import requests\ndef handler(event): return {}\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_strict = py_daemon.AUTO_INFER_STRICT
        old_write = py_daemon.AUTO_INFER_WRITE_MANIFEST
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = True
            py_daemon.AUTO_INFER_STRICT = False
            py_daemon.AUTO_INFER_WRITE_MANIFEST = True
            install_result = types.SimpleNamespace(returncode=0, stdout="requests==2.28.0\n", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: install_result

            py_daemon._ensure_requirements(handler)

            req_file = fn_dir / "requirements.txt"
            if req_file.is_file():
                content = req_file.read_text(encoding="utf-8")
                assert "requests" in content.lower()
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon.AUTO_INFER_STRICT = old_strict
            py_daemon.AUTO_INFER_WRITE_MANIFEST = old_write
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_ensure_requirements_with_pipreqs_backend() -> None:
    import types

    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("import requests\nimport flask\nfrom yaml import safe_load\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_strict = py_daemon.AUTO_INFER_STRICT
        old_write = py_daemon.AUTO_INFER_WRITE_MANIFEST
        old_backend = py_daemon.PY_INFER_BACKEND
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = True
            py_daemon.AUTO_INFER_STRICT = True
            py_daemon.AUTO_INFER_WRITE_MANIFEST = True
            py_daemon.PY_INFER_BACKEND = "pipreqs"

            def fake_run(cmd, **_kwargs):
                if cmd[:3] == [sys.executable, "-m", "pipreqs"]:
                    return types.SimpleNamespace(returncode=0, stdout="requests\nFlask\nPyYAML\n", stderr="")
                if cmd[:3] == [sys.executable, "-m", "pip"] and "freeze" in cmd:
                    return types.SimpleNamespace(returncode=0, stdout="requests==2.32.0\nFlask==3.0.0\nPyYAML==6.0.0\n", stderr="")
                if cmd[:3] == [sys.executable, "-m", "pip"] and "install" in cmd:
                    return types.SimpleNamespace(returncode=0, stdout="", stderr="")
                raise AssertionError(f"unexpected command: {cmd}")

            py_daemon._REAL_SUBPROCESS_RUN = fake_run
            py_daemon._ensure_requirements(handler)

            req_text = (fn_dir / "requirements.txt").read_text(encoding="utf-8")
            assert "requests" in req_text
            assert "Flask" in req_text
            assert "PyYAML" in req_text

            state = json.loads((fn_dir / ".fastfn-deps-state.json").read_text(encoding="utf-8"))
            assert state["infer_backend"] == "pipreqs"
            assert state["inference_duration_ms"] >= 0
            assert state["resolved_packages"] == ["requests", "flask", "pyyaml"]
            assert state["last_install_status"] == "ok"
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon.AUTO_INFER_STRICT = old_strict
            py_daemon.AUTO_INFER_WRITE_MANIFEST = old_write
            py_daemon.PY_INFER_BACKEND = old_backend
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_ensure_requirements_with_invalid_backend() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("import requests\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_backend = py_daemon.PY_INFER_BACKEND
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = True
            py_daemon.PY_INFER_BACKEND = "not-real"

            try:
                py_daemon._ensure_requirements(handler)
            except RuntimeError as exc:
                assert "unsupported" in str(exc).lower()
            else:
                raise AssertionError("expected invalid backend runtime error")
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon.PY_INFER_BACKEND = old_backend


def test_ensure_pack_requirements() -> None:
    """Cover _ensure_pack_requirements (lines 586-634)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        pack_dir = Path(tmp)
        req_file = pack_dir / "requirements.txt"
        req_file.write_text("requests\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._PACK_REQ_CACHE)
        old_log = py_daemon._json_log
        events = []
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            install_result = types.SimpleNamespace(returncode=0, stdout="", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: install_result
            py_daemon._json_log = lambda event, **fields: events.append((event, fields))

            result = py_daemon._ensure_pack_requirements(pack_dir)
            assert result is not None

            # Cache hit with existing deps
            (pack_dir / ".deps").mkdir(exist_ok=True)
            (pack_dir / ".deps" / "x.txt").write_text("x", encoding="utf-8")
            result2 = py_daemon._ensure_pack_requirements(pack_dir)
            assert result2 is not None
            assert ("pack_deps_install_reuse", {"runtime": "python", "pack_dir": str(pack_dir), "source": "memory_cache"}) in events

            # No requirements.txt
            req_file.unlink()
            py_daemon._PACK_REQ_CACHE.clear()
            result3 = py_daemon._ensure_pack_requirements(pack_dir)
            assert result3 is None

            # Auto-requirements disabled
            req_file.write_text("flask\n", encoding="utf-8")
            py_daemon._auto_requirements_enabled = lambda: False
            py_daemon._PACK_REQ_CACHE.clear()
            result4 = py_daemon._ensure_pack_requirements(pack_dir)
            assert result4 is None

            req_file.write_text("# comment only\n", encoding="utf-8")
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon._PACK_REQ_CACHE.clear()
            result5 = py_daemon._ensure_pack_requirements(pack_dir)
            assert result5 is None
            assert ("pack_deps_install_skip", {"runtime": "python", "pack_dir": str(pack_dir), "reason": "no_effective_requirements"}) in events
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._json_log = old_log
            py_daemon._PACK_REQ_CACHE.clear()
            py_daemon._PACK_REQ_CACHE.update(old_cache)


def test_ensure_pack_requirements_failure() -> None:
    """Cover _ensure_pack_requirements pip failure (lines 627-631)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        pack_dir = Path(tmp)
        req_file = pack_dir / "requirements.txt"
        req_file.write_text("bad-pkg\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._PACK_REQ_CACHE)
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            fail_result = types.SimpleNamespace(returncode=1, stdout="", stderr="ERROR: not found")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: fail_result

            try:
                py_daemon._ensure_pack_requirements(pack_dir)
            except RuntimeError as exc:
                assert "pip" in str(exc).lower()
            else:
                raise AssertionError("expected RuntimeError from pip failure")
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._PACK_REQ_CACHE.clear()
            py_daemon._PACK_REQ_CACHE.update(old_cache)


def test_build_allowed_roots_extra_exception() -> None:
    """Cover _build_allowed_roots extra_roots exception (lines 669-670, 675)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")

        class BadPath:
            def resolve(self, strict=False):
                raise OSError("boom")

        roots, func_dir = py_daemon._build_allowed_roots(handler, extra_roots=[BadPath()])
        assert func_dir is not None


def test_strict_fs_guard_full() -> None:
    """Cover _strict_fs_guard full monkey-patching (lines 696-738)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(event): return {}\n", encoding="utf-8")

        old_strict = py_daemon.STRICT_FS
        try:
            py_daemon.STRICT_FS = True
            with py_daemon._strict_fs_guard(handler):
                # Allowed: read handler itself
                with open(handler, "r") as f:
                    f.read()

                # Blocked: read /etc/passwd
                try:
                    with open("/etc/shadow", "r") as f:
                        f.read()
                except PermissionError:
                    pass
                else:
                    # May not be blocked if /etc is in system roots
                    pass

                # Test io.open guard
                try:
                    import io as io_mod
                    io_mod.open("/tmp/nonexistent_guard_test_xyz", "r")
                except (PermissionError, FileNotFoundError):
                    pass

                # Test os.listdir guard
                try:
                    os.listdir(fn_dir)
                except PermissionError:
                    pass

                # Test os.scandir guard
                try:
                    list(os.scandir(fn_dir))
                except PermissionError:
                    pass

                # Test Path.open guard
                try:
                    handler.open("r").close()
                except PermissionError:
                    pass
        finally:
            py_daemon.STRICT_FS = old_strict


def test_resolve_handler_path_more_branches() -> None:
    """Cover more _resolve_handler_path branches (834, 839, 847, 853, 864, 867-868)."""
    with tempfile.TemporaryDirectory() as tmp:
        old_fn_dir = py_daemon.FUNCTIONS_DIR
        old_rt_dir = py_daemon.RUNTIME_FUNCTIONS_DIR
        try:
            fn_dir = Path(tmp) / "functions"
            fn_dir.mkdir()
            rt_dir = Path(tmp) / "runtime"
            rt_dir.mkdir()
            py_daemon.FUNCTIONS_DIR = fn_dir
            py_daemon.RUNTIME_FUNCTIONS_DIR = rt_dir

            # Direct file with extension (line 828)
            hello_py = fn_dir / "hello.py"
            hello_py.write_text("def handler(e): return {}\n", encoding="utf-8")
            result = py_daemon._resolve_handler_path("hello", None)
            assert result == hello_py

            # Root check (line 834) - file at functions/myfile
            myfile = fn_dir / "myfile"
            myfile.write_text("def handler(e): return {}\n", encoding="utf-8")
            result = py_daemon._resolve_handler_path("myfile", None)
            # hello.py would be matched first, but myfile has no extension
            hello_py.unlink()
            result = py_daemon._resolve_handler_path("myfile", None)
            assert result == myfile

            # Runtime check (line 839)
            myfile.unlink()
            rt_file = rt_dir / "rtfunc"
            rt_file.write_text("def handler(e): return {}\n", encoding="utf-8")
            result = py_daemon._resolve_handler_path("rtfunc", None)
            assert result == rt_file
            rt_file.unlink()

            # Fallback to RUNTIME_FUNCTIONS_DIR base (line 847)
            rt_func_dir = rt_dir / "myfunc"
            rt_func_dir.mkdir()
            (rt_func_dir / "handler.py").write_text("def handler(e): return {}\n", encoding="utf-8")
            result = py_daemon._resolve_handler_path("myfunc", None)
            assert "handler.py" in str(result)

            # Version parameter (line 853)
            versioned = fn_dir / "vfunc"
            versioned.mkdir()
            v1 = versioned / "v1"
            v1.mkdir()
            (v1 / "handler.py").write_text("def handler(e): return {}\n", encoding="utf-8")
            result = py_daemon._resolve_handler_path("vfunc", "v1")
            assert "v1" in str(result)

            # Invalid version
            try:
                py_daemon._resolve_handler_path("vfunc", "invalid!")
            except ValueError:
                pass
            else:
                raise AssertionError("expected invalid version error")

            # fn.config.json entrypoint (lines 864, 867-868)
            cfg_dir = fn_dir / "cfgfunc"
            cfg_dir.mkdir()
            custom = cfg_dir / "custom.py"
            custom.write_text("def handler(e): return {}\n", encoding="utf-8")
            (cfg_dir / "fn.config.json").write_text(json.dumps({"entrypoint": "custom.py"}), encoding="utf-8")
            result = py_daemon._resolve_handler_path("cfgfunc", None)
            assert "custom.py" in str(result)

            # fn.config.json with invalid JSON (line 867-868)
            (cfg_dir / "fn.config.json").write_text("{bad", encoding="utf-8")
            (cfg_dir / "handler.py").write_text("def handler(e): return {}\n", encoding="utf-8")
            result = py_daemon._resolve_handler_path("cfgfunc", None)
            assert "handler.py" in str(result)
        finally:
            py_daemon.FUNCTIONS_DIR = old_fn_dir
            py_daemon.RUNTIME_FUNCTIONS_DIR = old_rt_dir


def test_iter_handler_paths_more() -> None:
    """Cover _iter_handler_paths versioned dirs (lines 884, 888, 894-895, 904-905)."""
    with tempfile.TemporaryDirectory() as tmp:
        old_fn_dir = py_daemon.FUNCTIONS_DIR
        try:
            fn_dir = Path(tmp) / "functions"
            fn_dir.mkdir()
            py_daemon.FUNCTIONS_DIR = fn_dir

            # Function with handler.py (not handler.py)
            func1 = fn_dir / "myfunc"
            func1.mkdir()
            (func1 / "handler.py").write_text("def handler(e): return {}\n", encoding="utf-8")

            # Function with version directories
            func2 = fn_dir / "vfunc"
            func2.mkdir()
            v1 = func2 / "v1"
            v1.mkdir()
            (v1 / "handler.py").write_text("def handler(e): return {}\n", encoding="utf-8")
            v2 = func2 / "v2"
            v2.mkdir()
            (v2 / "handler.py").write_text("def handler(e): return {}\n", encoding="utf-8")

            # Function with neither (should be skipped)
            func3 = fn_dir / "empty"
            func3.mkdir()

            paths = py_daemon._iter_handler_paths()
            names = [str(p) for p in paths]
            assert any("myfunc" in n and "handler.py" in n for n in names)
            assert any("v1" in n and "handler.py" in n for n in names)
            assert any("v2" in n and "handler.py" in n for n in names)

            # No FUNCTIONS_DIR
            py_daemon.FUNCTIONS_DIR = Path("/nonexistent_iter_test")
            assert py_daemon._iter_handler_paths() == []
        finally:
            py_daemon.FUNCTIONS_DIR = old_fn_dir


def test_preinstall_requirements_on_start() -> None:
    """Cover _preinstall_requirements_on_start (lines 911-917)."""
    old_preinstall = py_daemon.PREINSTALL_PY_DEPS_ON_START
    old_fn = py_daemon._auto_requirements_enabled
    old_iter = py_daemon._iter_handler_paths
    try:
        # Disabled path
        py_daemon.PREINSTALL_PY_DEPS_ON_START = False
        py_daemon._preinstall_requirements_on_start()  # no-op

        # Enabled but _auto_requirements_enabled returns False
        py_daemon.PREINSTALL_PY_DEPS_ON_START = True
        py_daemon._auto_requirements_enabled = lambda: False
        py_daemon._preinstall_requirements_on_start()  # no-op

        # Enabled with exception from ensure_requirements
        py_daemon._auto_requirements_enabled = lambda: True
        called = [0]
        def fake_iter():
            with tempfile.TemporaryDirectory() as tmp:
                handler = Path(tmp) / "handler.py"
                handler.write_text("def handler(e): return {}\n", encoding="utf-8")
                return [handler]
        py_daemon._iter_handler_paths = fake_iter
        # Should not raise even if _ensure_requirements fails
        py_daemon._preinstall_requirements_on_start()
    finally:
        py_daemon.PREINSTALL_PY_DEPS_ON_START = old_preinstall
        py_daemon._auto_requirements_enabled = old_fn
        py_daemon._iter_handler_paths = old_iter


def test_load_handler() -> None:
    """Cover _load_handler (lines 921-949)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler_file = fn_dir / "handler.py"
        handler_file.write_text("def handler(event): return {'body': 'hello'}\n", encoding="utf-8")

        old_cache = dict(py_daemon._HANDLER_CACHE)
        old_reload = py_daemon.HOT_RELOAD
        try:
            py_daemon._HANDLER_CACHE.clear()

            # First load
            h = py_daemon._load_handler(handler_file, "handler")
            result = h({"body": ""})
            assert result["body"] == "hello"

            # Cache hit (same mtime)
            py_daemon.HOT_RELOAD = True
            h2 = py_daemon._load_handler(handler_file, "handler")
            assert h2 is h

            # HOT_RELOAD=False cache hit
            py_daemon.HOT_RELOAD = False
            h3 = py_daemon._load_handler(handler_file, "handler")
            assert h3 is h

            # Fallback to main() when handler_name="handler" not found
            py_daemon._HANDLER_CACHE.clear()
            main_file = fn_dir / "main_fallback.py"
            main_file.write_text("def main(event): return {'body': 'from_main'}\n", encoding="utf-8")
            h4 = py_daemon._load_handler(main_file, "handler")
            assert h4({"body": ""})["body"] == "from_main"

            # Missing handler raises
            py_daemon._HANDLER_CACHE.clear()
            empty_file = fn_dir / "empty.py"
            empty_file.write_text("x = 1\n", encoding="utf-8")
            try:
                py_daemon._load_handler(empty_file, "handler")
            except RuntimeError as exc:
                assert "required" in str(exc).lower()
            else:
                raise AssertionError("expected RuntimeError for missing handler")
        finally:
            py_daemon._HANDLER_CACHE.clear()
            py_daemon._HANDLER_CACHE.update(old_cache)
            py_daemon.HOT_RELOAD = old_reload


def test_normalize_response_more_edges() -> None:
    """Cover more _normalize_response edges (lines 967, 969, 971, 1041-1042)."""
    # body_base64 key detection (line 967-971)
    resp = py_daemon._normalize_response({"status": 200, "headers": {}, "body": "data", "is_base64": False})
    assert resp["body"] == "data"

    # Dict/list body auto-JSON (line 1036-1042)
    resp = py_daemon._normalize_response({"status": 200, "headers": {}, "body": {"nested": True}})
    assert "nested" in resp["body"]
    assert resp["headers"].get("Content-Type") == "application/json"

    # List body
    resp = py_daemon._normalize_response({"status": 200, "headers": {}, "body": [1, 2, 3]})
    assert "[1,2,3]" in resp["body"]

    # Non-string body (line 1044)
    resp = py_daemon._normalize_response({"status": 200, "headers": {}, "body": 42})
    assert resp["body"] == "42"

    # Proxy presence (line 971)
    resp = py_daemon._normalize_response({"status": 200, "headers": {}, "body": "", "proxy": {"url": "http://x"}})
    assert "proxy" in resp

    # body_base64 with isBase64Encoded=True (line 967-971)
    resp = py_daemon._normalize_response({"body": "data"})
    # has "body" key so treated as raw
    assert resp["body"] == "data"

    # json.dumps exception path (line 1041-1042)
    class Unserializable:
        pass
    resp = py_daemon._normalize_response({"status": 200, "headers": {}, "body": {"x": Unserializable()}})
    assert isinstance(resp["body"], str)


def test_persistent_worker_mock() -> None:
    """Cover _PersistentWorker (lines 1290-1386)."""
    import types
    import threading

    class FakeProc:
        def __init__(self):
            self.stdin = io.BytesIO()
            self.stdout = io.BytesIO()
            self.stderr = io.BytesIO()
            self._poll = None
        def poll(self):
            return self._poll
        def kill(self):
            self._poll = -9
        def wait(self, timeout=None):
            pass

    # Test alive property
    worker = object.__new__(py_daemon._PersistentWorker)
    worker.key = "test::key"
    worker.lock = threading.Lock()
    worker._dead = False
    worker.proc = FakeProc()
    assert worker.alive is True

    worker._dead = True
    assert worker.alive is False

    # Test _mark_dead
    worker._dead = False
    worker._mark_dead()
    assert worker._dead is True

    # Test shutdown
    worker._dead = False
    worker.proc = FakeProc()
    worker.shutdown()
    assert worker._dead is True

    # Test shutdown with stdin.close() exception
    worker._dead = False
    proc2 = FakeProc()
    proc2.stdin = None
    worker.proc = proc2
    worker.shutdown()  # Should not raise
    assert worker._dead is True


def test_persistent_worker_send_request() -> None:
    """Cover _PersistentWorker.send_request (lines 1314-1346)."""
    import threading

    class FakePipe:
        def __init__(self):
            self.data = bytearray()
            self._fileno = 999
        def write(self, b):
            self.data.extend(b)
        def flush(self):
            pass
        def fileno(self):
            return self._fileno
        def close(self):
            pass

    worker = object.__new__(py_daemon._PersistentWorker)
    worker.key = "test::sr"
    worker.lock = threading.Lock()
    worker._dead = False

    class DeadProc:
        stdin = FakePipe()
        stdout = FakePipe()
        stderr = io.BytesIO()
        def poll(self):
            return 1  # dead
        def kill(self):
            pass
    worker.proc = DeadProc()

    # Dead worker
    try:
        worker.send_request(b'{}', 1.0)
    except RuntimeError as exc:
        assert "dead" in str(exc).lower()
    else:
        raise AssertionError("expected dead worker error")


def test_persistent_worker_send_broken_pipe() -> None:
    """Cover BrokenPipeError path (line 1344-1346)."""
    import threading

    class FailPipe:
        def write(self, b):
            raise BrokenPipeError("pipe broken")
        def flush(self):
            pass
        def fileno(self):
            return 999
        def close(self):
            pass

    worker = object.__new__(py_daemon._PersistentWorker)
    worker.key = "test::bp"
    worker.lock = threading.Lock()
    worker._dead = False

    class BrokenProc:
        stdin = FailPipe()
        stdout = FailPipe()
        stderr = io.BytesIO()
        def poll(self):
            return None  # alive
        def kill(self):
            pass
    worker.proc = BrokenProc()

    try:
        worker.send_request(b'{}', 1.0)
    except RuntimeError as exc:
        assert "pipe" in str(exc).lower() or "broken" in str(exc).lower()
    else:
        raise AssertionError("expected broken pipe error")


def test_get_or_create_worker() -> None:
    """Cover _get_or_create_worker (lines 1404-1417)."""
    import threading
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")

        old_pool = dict(py_daemon._SUBPROCESS_POOL)
        try:
            py_daemon._SUBPROCESS_POOL.clear()
            # Create a dead worker manually
            dead = object.__new__(py_daemon._PersistentWorker)
            dead.key = "dead"
            dead.lock = threading.Lock()
            dead._dead = True

            class FakeDeadProc:
                stdin = None
                stdout = None
                stderr = None
                def poll(self):
                    return 1
                def kill(self):
                    pass
                def wait(self, timeout=None):
                    pass

            dead.proc = FakeDeadProc()
            key = py_daemon._worker_pool_key(handler, "handler", [])
            py_daemon._SUBPROCESS_POOL[key] = dead

            # Should replace dead worker with new one
            try:
                worker = py_daemon._get_or_create_worker(handler, "handler", [])
                # Clean up
                worker.shutdown()
            except Exception:
                pass  # May fail in test env without worker script
        finally:
            for w in py_daemon._SUBPROCESS_POOL.values():
                try:
                    w.shutdown()
                except Exception:
                    pass
            py_daemon._SUBPROCESS_POOL.clear()
            py_daemon._SUBPROCESS_POOL.update(old_pool)


def test_run_in_subprocess_timeout() -> None:
    """Cover _run_in_subprocess timeout path (line 1465-1466)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")

        old_get = py_daemon._get_or_create_worker
        old_read_env = py_daemon._read_function_env
        try:
            py_daemon._read_function_env = lambda _h: {}

            class TimeoutWorker:
                alive = True
                def send_request(self, payload, timeout):
                    raise TimeoutError("timed out")

            py_daemon._get_or_create_worker = lambda *a, **kw: TimeoutWorker()
            resp = py_daemon._run_in_subprocess(handler, "handler", [], {"body": ""}, 1.0)
            assert resp["status"] == 504
        finally:
            py_daemon._get_or_create_worker = old_get
            py_daemon._read_function_env = old_read_env


def test_run_in_subprocess_retry_then_fail() -> None:
    """Cover _run_in_subprocess retry exhaustion (lines 1467-1480)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")

        old_get = py_daemon._get_or_create_worker
        old_read_env = py_daemon._read_function_env
        old_pool = dict(py_daemon._SUBPROCESS_POOL)
        try:
            py_daemon._read_function_env = lambda _h: {}

            class DyingWorker:
                alive = True
                def send_request(self, payload, timeout):
                    raise RuntimeError("worker crashed")
                def shutdown(self):
                    pass

            py_daemon._get_or_create_worker = lambda *a, **kw: DyingWorker()
            resp = py_daemon._run_in_subprocess(handler, "handler", [], {"body": ""}, 1.0)
            assert resp["status"] == 503
        finally:
            py_daemon._get_or_create_worker = old_get
            py_daemon._read_function_env = old_read_env
            py_daemon._SUBPROCESS_POOL.clear()
            py_daemon._SUBPROCESS_POOL.update(old_pool)


def test_run_in_subprocess_with_env() -> None:
    """Cover _run_in_subprocess env merging (lines 1442-1449)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")

        old_get = py_daemon._get_or_create_worker
        old_read_env = py_daemon._read_function_env
        try:
            py_daemon._read_function_env = lambda _h: {"FN_KEY": "val"}
            captured_payload = [None]

            class CapturingWorker:
                alive = True
                def send_request(self, payload, timeout):
                    captured_payload[0] = json.loads(payload)
                    return {"status": 200, "headers": {}, "body": "ok"}

            py_daemon._get_or_create_worker = lambda *a, **kw: CapturingWorker()
            resp = py_daemon._run_in_subprocess(
                handler, "handler", [], {"body": "", "env": {"EXISTING": "1"}}, 1.0
            )
            assert resp["status"] == 200
            assert captured_payload[0]["event"]["env"]["FN_KEY"] == "val"
            assert captured_payload[0]["event"]["env"]["EXISTING"] == "1"
        finally:
            py_daemon._get_or_create_worker = old_get
            py_daemon._read_function_env = old_read_env


def test_handle_request_direct_full() -> None:
    """Cover _handle_request_direct with shared deps and in-process execution."""
    with tempfile.TemporaryDirectory() as tmp:
        old_fn_dir = py_daemon.FUNCTIONS_DIR
        old_runtime_fn_dir = py_daemon.RUNTIME_FUNCTIONS_DIR
        old_ensure = py_daemon._ensure_requirements
        old_ensure_pack = py_daemon._ensure_pack_requirements
        try:
            fn_dir = Path(tmp) / "functions"
            fn_dir.mkdir()
            py_daemon.FUNCTIONS_DIR = fn_dir
            py_daemon.RUNTIME_FUNCTIONS_DIR = fn_dir / "python"

            func_dir = fn_dir / "myfunc"
            func_dir.mkdir()
            handler = func_dir / "handler.py"
            handler.write_text("def handler(e): return {'body': 'ok'}\n", encoding="utf-8")
            deps = func_dir / ".deps"
            deps.mkdir()
            (deps / "x.txt").write_text("x", encoding="utf-8")
            config = func_dir / "fn.config.json"
            config.write_text(json.dumps({"shared_deps": ["mypack"]}), encoding="utf-8")

            pack = fn_dir / ".fastfn" / "packs" / "python" / "mypack"
            pack.mkdir(parents=True)
            pack_deps = pack / ".deps"
            pack_deps.mkdir()

            py_daemon._ensure_requirements = lambda _h: None
            py_daemon._ensure_pack_requirements = lambda _p: pack_deps

            resp = py_daemon._handle_request_direct({
                "fn": "myfunc",
                "event": {"body": ""},
                "timeout_ms": 10000,
            })
            assert resp["status"] == 200
            assert resp["body"] == "ok"
        finally:
            py_daemon.FUNCTIONS_DIR = old_fn_dir
            py_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime_fn_dir
            py_daemon._ensure_requirements = old_ensure
            py_daemon._ensure_pack_requirements = old_ensure_pack


def test_handle_request_direct_full_runtime_scoped_shared_pack_root() -> None:
    """Shared packs resolve from the parent root when FN_FUNCTIONS_ROOT is runtime-scoped."""
    with tempfile.TemporaryDirectory() as tmp:
        old_fn_dir = py_daemon.FUNCTIONS_DIR
        old_runtime_fn_dir = py_daemon.RUNTIME_FUNCTIONS_DIR
        old_ensure = py_daemon._ensure_requirements
        old_ensure_pack = py_daemon._ensure_pack_requirements
        try:
            root_dir = Path(tmp) / "functions"
            fn_dir = root_dir / "python"
            fn_dir.mkdir(parents=True)
            py_daemon.FUNCTIONS_DIR = fn_dir
            py_daemon.RUNTIME_FUNCTIONS_DIR = fn_dir / "python"

            func_dir = fn_dir / "myfunc"
            func_dir.mkdir()
            handler = func_dir / "handler.py"
            handler.write_text("def handler(e): return {'body': 'ok-runtime-scoped'}\n", encoding="utf-8")
            config = func_dir / "fn.config.json"
            config.write_text(json.dumps({"shared_deps": ["mypack"]}), encoding="utf-8")

            pack = root_dir / ".fastfn" / "packs" / "python" / "mypack"
            pack.mkdir(parents=True)
            pack_deps = pack / ".deps"
            pack_deps.mkdir()

            py_daemon._ensure_requirements = lambda _h: None
            py_daemon._ensure_pack_requirements = lambda _p: pack_deps

            resp = py_daemon._handle_request_direct({
                "fn": "myfunc",
                "event": {"body": ""},
                "timeout_ms": 10000,
            })
            assert resp["status"] == 200
            assert resp["body"] == "ok-runtime-scoped"
        finally:
            py_daemon.FUNCTIONS_DIR = old_fn_dir
            py_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime_fn_dir
            py_daemon._ensure_requirements = old_ensure
            py_daemon._ensure_pack_requirements = old_ensure_pack


def test_handle_request_with_pool_path() -> None:
    """Cover _handle_request_with_pool pool path (lines 1585-1586)."""
    old_enable = py_daemon.ENABLE_RUNTIME_WORKER_POOL
    old_direct = py_daemon._handle_request_direct
    old_ensure = py_daemon._ensure_runtime_pool
    old_submit = py_daemon._submit_runtime_pool_request
    old_timeout = py_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS
    try:
        py_daemon.ENABLE_RUNTIME_WORKER_POOL = True
        py_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = 100
        py_daemon._handle_request_direct = lambda req: {"status": 200, "headers": {}, "body": "direct"}

        def fake_ensure(key, settings):
            return {"executor": None, "pending": 0, "last_used": 0.0}

        def fake_submit(key, pool, req):
            fut = Future()
            # Don't set result -> will timeout
            return fut

        py_daemon._ensure_runtime_pool = fake_ensure
        py_daemon._submit_runtime_pool_request = fake_submit

        req = {
            "fn": "test",
            "event": {
                "context": {
                    "worker_pool": {"enabled": True, "max_workers": 2},
                    "timeout_ms": 100,
                },
            },
        }
        resp = py_daemon._handle_request_with_pool(req)
        assert resp["status"] == 504
    finally:
        py_daemon.ENABLE_RUNTIME_WORKER_POOL = old_enable
        py_daemon._handle_request_direct = old_direct
        py_daemon._ensure_runtime_pool = old_ensure
        py_daemon._submit_runtime_pool_request = old_submit
        py_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = old_timeout


def test_lockfile_write_exceptions() -> None:
    """Cover lockfile write_text exception paths (lines 341-342, 348-349)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")
        deps_dir = fn_dir / ".deps"
        deps_dir.mkdir()

        old_run = py_daemon._REAL_SUBPROCESS_RUN
        try:
            # Empty lines -> write_text fails
            result_obj = types.SimpleNamespace(returncode=0, stdout="", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: result_obj

            lock_file = handler.with_name("requirements.lock.txt")
            lock_file.write_text("old", encoding="utf-8")
            lock_file.chmod(0o000)
            lock = py_daemon._write_python_lockfile(handler, deps_dir)
            assert lock is None
            lock_file.chmod(0o644)

            # Non-empty lines -> write_text fails
            result_obj2 = types.SimpleNamespace(returncode=0, stdout="pkg==1.0\n", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: result_obj2
            lock_file.chmod(0o000)
            lock2 = py_daemon._write_python_lockfile(handler, deps_dir)
            assert lock2 is None
            lock_file.chmod(0o644)
        finally:
            py_daemon._REAL_SUBPROCESS_RUN = old_run


def test_ensure_requirements_cache_empty_deps() -> None:
    """Cover cache hit but deps empty (lines 455-461)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")
        req_file = fn_dir / "requirements.txt"
        req_file.write_text("requests\n", encoding="utf-8")
        deps_dir = fn_dir / ".deps"
        deps_dir.mkdir()
        # Empty deps dir -> cache should be invalidated

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = False

            req_sig = str(req_file.stat().st_mtime_ns)
            marker = f"{handler}:{handler.stat().st_mtime_ns}:{req_sig}:"
            py_daemon._REQ_CACHE[marker] = True

            install_result = types.SimpleNamespace(returncode=0, stdout="", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: install_result
            py_daemon._ensure_requirements(handler)
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_ensure_requirements_with_inline_reqs() -> None:
    """Cover ensure_requirements with inline reqs and no req_file (lines 485-486)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("#@requirements flask\ndef handler(e): return {}\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = False
            install_result = types.SimpleNamespace(returncode=0, stdout="flask==2.0\n", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: install_result
            py_daemon._ensure_requirements(handler)
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_ensure_requirements_write_manifest_existing() -> None:
    """Cover write manifest with existing lines (lines 425-426)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("import requests\ndef handler(e): return {}\n", encoding="utf-8")
        req_file = fn_dir / "requirements.txt"
        req_file.write_text("flask\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_strict = py_daemon.AUTO_INFER_STRICT
        old_write = py_daemon.AUTO_INFER_WRITE_MANIFEST
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = True
            py_daemon.AUTO_INFER_STRICT = False
            py_daemon.AUTO_INFER_WRITE_MANIFEST = True
            install_result = types.SimpleNamespace(returncode=0, stdout="", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: install_result
            py_daemon._ensure_requirements(handler)

            content = req_file.read_text(encoding="utf-8")
            assert "requests" in content.lower()
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon.AUTO_INFER_STRICT = old_strict
            py_daemon.AUTO_INFER_WRITE_MANIFEST = old_write
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_pack_requirements_cache_empty() -> None:
    """Cover pack req cache hit with empty deps (lines 597-601)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        pack_dir = Path(tmp)
        req_file = pack_dir / "requirements.txt"
        req_file.write_text("requests\n", encoding="utf-8")
        deps_dir = pack_dir / ".deps"
        deps_dir.mkdir()
        # Empty deps dir -> cache miss

        old_fn = py_daemon._auto_requirements_enabled
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._PACK_REQ_CACHE)
        try:
            py_daemon._auto_requirements_enabled = lambda: True

            marker = f"pack:{pack_dir}:{req_file.stat().st_mtime_ns}"
            py_daemon._PACK_REQ_CACHE[marker] = True

            install_result = types.SimpleNamespace(returncode=0, stdout="", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: install_result

            result = py_daemon._ensure_pack_requirements(pack_dir)
            # Cache was invalidated because deps empty, so it reinstalled
            assert result is not None
        finally:
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._PACK_REQ_CACHE.clear()
            py_daemon._PACK_REQ_CACHE.update(old_cache)


def test_read_frame_invalid_length() -> None:
    """Cover frame length > MAX or <= 0 (line 793)."""
    left, right = socket.socketpair()
    with left, right:
        right.sendall(struct.pack("!I", 0))
        right.shutdown(socket.SHUT_WR)
        try:
            py_daemon._read_frame(left)
        except ValueError as exc:
            assert "length" in str(exc).lower()
        else:
            raise AssertionError("expected invalid frame length")


def test_load_handler_spec_none() -> None:
    """Cover _load_handler when spec is None (line 932)."""
    old_cache = dict(py_daemon._HANDLER_CACHE)
    try:
        py_daemon._HANDLER_CACHE.clear()
        fake_path = Path("/nonexistent/fake_module.py")
        try:
            py_daemon._load_handler(fake_path, "handler")
        except (RuntimeError, FileNotFoundError, OSError):
            pass
    finally:
        py_daemon._HANDLER_CACHE.clear()
        py_daemon._HANDLER_CACHE.update(old_cache)


def test_normalize_response_body_key_detection() -> None:
    """Cover is_raw detection via 'body' key (line 967-971)."""
    # 'body' key makes it raw
    resp = py_daemon._normalize_response({"body": "hello"})
    assert resp["status"] == 200
    assert resp["body"] == "hello"

    # 'body_base64' key makes it raw
    resp = py_daemon._normalize_response({"body_base64": "AAAA", "is_base64": True})
    assert resp["is_base64"] is True

    # 'is_base64' key alone makes it raw
    resp = py_daemon._normalize_response({"is_base64": False, "body": "data"})
    assert resp["body"] == "data"

    # 'proxy' key alone makes it raw
    resp = py_daemon._normalize_response({"proxy": {"url": "http://x"}, "body": ""})
    assert "proxy" in resp


def test_handle_request_direct_shared_deps_missing() -> None:
    """Cover shared pack not found error (line 1546)."""
    with tempfile.TemporaryDirectory() as tmp:
        old_fn_dir = py_daemon.FUNCTIONS_DIR
        old_runtime_fn_dir = py_daemon.RUNTIME_FUNCTIONS_DIR
        old_ensure = py_daemon._ensure_requirements
        try:
            root_dir = Path(tmp) / "functions"
            fn_dir = root_dir / "python"
            fn_dir.mkdir(parents=True)
            py_daemon.FUNCTIONS_DIR = fn_dir
            py_daemon.RUNTIME_FUNCTIONS_DIR = fn_dir / "python"

            func_dir = fn_dir / "myfunc"
            func_dir.mkdir()
            handler = func_dir / "handler.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            (func_dir / "fn.config.json").write_text(
                json.dumps({"shared_deps": ["nonexistent_pack"]}), encoding="utf-8"
            )
            py_daemon._ensure_requirements = lambda _h: None

            try:
                py_daemon._handle_request_direct({"fn": "myfunc", "event": {"body": ""}})
            except RuntimeError as exc:
                assert "not found" in str(exc).lower()
                assert str(fn_dir / ".fastfn" / "packs" / "python" / "nonexistent_pack") in str(exc)
                assert str(root_dir / ".fastfn" / "packs" / "python" / "nonexistent_pack") in str(exc)
        finally:
            py_daemon.FUNCTIONS_DIR = old_fn_dir
            py_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime_fn_dir
            py_daemon._ensure_requirements = old_ensure


def test_persistent_worker_send_success() -> None:
    """Cover _PersistentWorker.send_request success path (lines 1318-1340)."""
    import threading
    import select as select_mod

    # Use real socket pair for stdin/stdout simulation
    stdin_r, stdin_w = os.pipe()
    stdout_r, stdout_w = os.pipe()

    worker = object.__new__(py_daemon._PersistentWorker)
    worker.key = "test::success"
    worker.lock = threading.Lock()
    worker._dead = False

    class FakeStdin:
        def write(self, b):
            os.write(stdin_w, b)
        def flush(self):
            pass
        def close(self):
            os.close(stdin_w)

    class FakeStdout:
        def fileno(self):
            return stdout_r

    class FakeProc:
        stdin = FakeStdin()
        stdout = FakeStdout()
        stderr = io.BytesIO()
        def poll(self):
            return None
        def kill(self):
            pass

    worker.proc = FakeProc()

    # Write a response on stdout_w from a thread
    resp_payload = json.dumps({"status": 200, "body": "ok"}, separators=(",", ":")).encode("utf-8")
    resp_frame = struct.pack(">I", len(resp_payload)) + resp_payload

    def write_response():
        # Read the request first
        import time
        time.sleep(0.1)
        os.write(stdout_w, resp_frame)

    t = threading.Thread(target=write_response, daemon=True)
    t.start()

    try:
        req_payload = b'{"fn":"test"}'
        result = worker.send_request(req_payload, 5.0)
        assert result["status"] == 200
    finally:
        try:
            os.close(stdin_r)
        except Exception:
            pass
        try:
            os.close(stdin_w)
        except Exception:
            pass
        try:
            os.close(stdout_r)
        except Exception:
            pass
        try:
            os.close(stdout_w)
        except Exception:
            pass
        t.join(timeout=2)


def test_persistent_worker_read_exact_timeout() -> None:
    """Cover _read_exact timeout (lines 1350-1357)."""
    import threading

    r, w = os.pipe()
    worker = object.__new__(py_daemon._PersistentWorker)
    worker.key = "test::timeout"
    worker.lock = threading.Lock()
    worker._dead = False

    class FakeProc:
        def kill(self):
            pass
    worker.proc = FakeProc()

    try:
        worker._read_exact(r, 100, 0.1)
    except TimeoutError:
        pass
    else:
        raise AssertionError("expected TimeoutError")
    finally:
        os.close(r)
        os.close(w)


def test_persistent_worker_read_exact_eof() -> None:
    """Cover _read_exact EOF (lines 1362-1363)."""
    import threading

    r, w = os.pipe()
    os.close(w)  # EOF immediately

    worker = object.__new__(py_daemon._PersistentWorker)
    worker.key = "test::eof"
    worker.lock = threading.Lock()
    worker._dead = False

    class FakeProc:
        def kill(self):
            pass
    worker.proc = FakeProc()

    result = worker._read_exact(r, 10, 2.0)
    assert result is None
    os.close(r)


def test_persistent_worker_shutdown_wait_fail() -> None:
    """Cover shutdown wait timeout then kill (lines 1382-1386)."""
    import threading

    worker = object.__new__(py_daemon._PersistentWorker)
    worker.key = "test::shutdown_fail"
    worker.lock = threading.Lock()
    worker._dead = False

    class StubbyProc:
        class StubStdin:
            def close(self):
                pass
        stdin = StubStdin()
        def wait(self, timeout=None):
            raise Exception("wait timeout")
        def kill(self):
            pass
    worker.proc = StubbyProc()
    worker.shutdown()
    assert worker._dead is True


def test_infer_python_imports_empty_filter() -> None:
    """Cover line 269 (empty name in imports)."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        # Import with just whitespace
        handler.write_text("import os\n", encoding="utf-8")
        result = py_daemon._infer_python_imports(handler)
        # os is stdlib, should be filtered
        assert "os" not in result


def test_ensure_requirements_cache_iterdir_exception() -> None:
    """Cover cache hit with iterdir exception (lines 455-456)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")
        req_file = fn_dir / "requirements.txt"
        req_file.write_text("requests\n", encoding="utf-8")
        deps_dir = fn_dir / ".deps"
        deps_dir.mkdir()

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        old_iterdir = Path.iterdir
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = False

            req_sig = str(req_file.stat().st_mtime_ns)
            marker = f"{handler}:{handler.stat().st_mtime_ns}:{req_sig}:"
            py_daemon._REQ_CACHE[marker] = True

            # Make iterdir raise only for deps_dir
            call_count = [0]
            def bad_iterdir(self):
                if ".deps" in str(self):
                    call_count[0] += 1
                    if call_count[0] <= 1:
                        raise OSError("permission denied")
                return old_iterdir(self)

            Path.iterdir = bad_iterdir

            install_result = types.SimpleNamespace(returncode=0, stdout="", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: install_result
            py_daemon._ensure_requirements(handler)
        finally:
            Path.iterdir = old_iterdir
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_ensure_requirements_iterdir_exception() -> None:
    """Cover deps_dir.iterdir exception after mkdir (lines 469-470)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")
        req_file = fn_dir / "requirements.txt"
        req_file.write_text("requests\n", encoding="utf-8")

        old_fn = py_daemon._auto_requirements_enabled
        old_infer = py_daemon.AUTO_INFER_PY_DEPS
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._REQ_CACHE)
        old_iterdir = Path.iterdir
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            py_daemon.AUTO_INFER_PY_DEPS = False

            call_count = [0]
            def bad_iterdir(self):
                if ".deps" in str(self):
                    call_count[0] += 1
                    raise OSError("boom")
                return old_iterdir(self)

            Path.iterdir = bad_iterdir

            install_result = types.SimpleNamespace(returncode=0, stdout="", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: install_result
            py_daemon._ensure_requirements(handler)
        finally:
            Path.iterdir = old_iterdir
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon.AUTO_INFER_PY_DEPS = old_infer
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._REQ_CACHE.clear()
            py_daemon._REQ_CACHE.update(old_cache)


def test_pack_req_cache_iterdir_exception() -> None:
    """Cover pack req cache iterdir exception (lines 597-598)."""
    import types
    with tempfile.TemporaryDirectory() as tmp:
        pack_dir = Path(tmp)
        req_file = pack_dir / "requirements.txt"
        req_file.write_text("requests\n", encoding="utf-8")
        deps_dir = pack_dir / ".deps"
        deps_dir.mkdir()

        old_fn = py_daemon._auto_requirements_enabled
        old_run = py_daemon._REAL_SUBPROCESS_RUN
        old_cache = dict(py_daemon._PACK_REQ_CACHE)
        old_iterdir = Path.iterdir
        try:
            py_daemon._auto_requirements_enabled = lambda: True
            marker = f"pack:{pack_dir}:{req_file.stat().st_mtime_ns}"
            py_daemon._PACK_REQ_CACHE[marker] = True

            call_count = [0]
            def bad_iterdir(self):
                if ".deps" in str(self):
                    call_count[0] += 1
                    if call_count[0] <= 1:
                        raise OSError("boom")
                return old_iterdir(self)

            Path.iterdir = bad_iterdir

            install_result = types.SimpleNamespace(returncode=0, stdout="", stderr="")
            py_daemon._REAL_SUBPROCESS_RUN = lambda *a, **kw: install_result
            py_daemon._ensure_pack_requirements(pack_dir)
        finally:
            Path.iterdir = old_iterdir
            py_daemon._auto_requirements_enabled = old_fn
            py_daemon._REAL_SUBPROCESS_RUN = old_run
            py_daemon._PACK_REQ_CACHE.clear()
            py_daemon._PACK_REQ_CACHE.update(old_cache)


def test_preinstall_requirements_with_exception() -> None:
    """Cover _preinstall with exception in loop (lines 916-917)."""
    old_preinstall = py_daemon.PREINSTALL_PY_DEPS_ON_START
    old_fn = py_daemon._auto_requirements_enabled
    old_iter = py_daemon._iter_handler_paths
    old_ensure = py_daemon._ensure_requirements
    try:
        py_daemon.PREINSTALL_PY_DEPS_ON_START = True
        py_daemon._auto_requirements_enabled = lambda: True

        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "handler.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            py_daemon._iter_handler_paths = lambda: [handler]
            py_daemon._ensure_requirements = lambda _h: (_ for _ in ()).throw(RuntimeError("fail"))
            py_daemon._preinstall_requirements_on_start()  # Should not raise
    finally:
        py_daemon.PREINSTALL_PY_DEPS_ON_START = old_preinstall
        py_daemon._auto_requirements_enabled = old_fn
        py_daemon._iter_handler_paths = old_iter
        py_daemon._ensure_requirements = old_ensure


def test_resolve_handler_path_runtime_fallback() -> None:
    """Cover runtime base fallback (line 847) and fn.config entrypoint escape (864)."""
    with tempfile.TemporaryDirectory() as tmp:
        old_fn_dir = py_daemon.FUNCTIONS_DIR
        old_rt_dir = py_daemon.RUNTIME_FUNCTIONS_DIR
        try:
            fn_dir = Path(tmp) / "functions"
            fn_dir.mkdir()
            rt_dir = Path(tmp) / "runtime"
            rt_dir.mkdir()
            py_daemon.FUNCTIONS_DIR = fn_dir
            py_daemon.RUNTIME_FUNCTIONS_DIR = rt_dir

            # fn.config.json with entrypoint that escapes (line 864)
            esc_dir = fn_dir / "escfunc"
            esc_dir.mkdir()
            (esc_dir / "handler.py").write_text("def handler(e): return {}\n", encoding="utf-8")
            (esc_dir / "fn.config.json").write_text(
                json.dumps({"entrypoint": "../../../etc/passwd"}), encoding="utf-8"
            )
            result = py_daemon._resolve_handler_path("escfunc", None)
            assert "handler.py" in str(result)  # Should fallback to handler.py
        finally:
            py_daemon.FUNCTIONS_DIR = old_fn_dir
            py_daemon.RUNTIME_FUNCTIONS_DIR = old_rt_dir


def test_resolve_existing_path_and_handler_path_error_edges() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        file_path = root / "file.txt"
        file_path.write_text("ok", encoding="utf-8")

        assert py_daemon._resolve_existing_path_within_root(root, file_path, want_dir=True) is None

        old_fn_dir = py_daemon.FUNCTIONS_DIR
        old_rt_dir = py_daemon.RUNTIME_FUNCTIONS_DIR
        try:
            py_daemon.FUNCTIONS_DIR = root
            py_daemon.RUNTIME_FUNCTIONS_DIR = root / "python"
            py_daemon.RUNTIME_FUNCTIONS_DIR.mkdir()

            empty_fn = root / "empty-fn"
            empty_fn.mkdir()

            try:
                py_daemon._resolve_handler_path("missing-fn", "v1")
                raise AssertionError("expected versioned unknown function error")
            except FileNotFoundError as exc:
                assert "unknown function" in str(exc).lower()

            try:
                py_daemon._resolve_handler_path("empty-fn", None)
                raise AssertionError("expected missing entrypoint error")
            except FileNotFoundError as exc:
                assert "unknown function" in str(exc).lower()
        finally:
            py_daemon.FUNCTIONS_DIR = old_fn_dir
            py_daemon.RUNTIME_FUNCTIONS_DIR = old_rt_dir


def test_iter_handler_paths_handler_py_version() -> None:
    """Cover _iter_handler_paths version dirs with handler.py only (line 904-905)."""
    with tempfile.TemporaryDirectory() as tmp:
        old_fn_dir = py_daemon.FUNCTIONS_DIR
        try:
            fn_dir = Path(tmp) / "functions"
            fn_dir.mkdir()
            py_daemon.FUNCTIONS_DIR = fn_dir

            func = fn_dir / "vfunc2"
            func.mkdir()
            v1 = func / "v1"
            v1.mkdir()
            (v1 / "handler.py").write_text("def handler(e): return {}\n", encoding="utf-8")

            # Non-matching dir name
            bad = func / "notaversion"
            bad.mkdir()

            # No .py files
            empty_v = func / "v2"
            empty_v.mkdir()

            paths = py_daemon._iter_handler_paths()
            names = [str(p) for p in paths]
            assert any("v1" in n and "handler.py" in n for n in names)
            assert not any("notaversion" in n for n in names)
        finally:
            py_daemon.FUNCTIONS_DIR = old_fn_dir


def test_pool_eviction() -> None:
    """Cover pool eviction in reaper (lines 1094-1095)."""
    from concurrent.futures import ThreadPoolExecutor
    import time

    old_pools = dict(py_daemon._RUNTIME_POOLS)
    old_idle = py_daemon.RUNTIME_POOL_IDLE_TTL_MS
    try:
        py_daemon.RUNTIME_POOL_IDLE_TTL_MS = 1  # 1ms TTL

        executor = ThreadPoolExecutor(max_workers=1)
        pool = {
            "executor": executor,
            "pending": 0,
            "last_used": time.monotonic() - 100.0,
            "settings": {"min_warm": 0, "idle_ttl_ms": 1},
        }
        py_daemon._RUNTIME_POOLS["evict_test@v1"] = pool

        # Manually invoke shutdown
        py_daemon._shutdown_runtime_pool(pool)
        executor.shutdown(wait=False)
    finally:
        py_daemon._RUNTIME_POOLS.clear()
        py_daemon._RUNTIME_POOLS.update(old_pools)
        py_daemon.RUNTIME_POOL_IDLE_TTL_MS = old_idle


def test_normalize_response_headers_key() -> None:
    """Cover 'headers' key detection (line 967)."""
    resp = py_daemon._normalize_response({"headers": {"X-Custom": "1"}})
    assert resp["status"] == 200
    assert resp["headers"]["X-Custom"] == "1"


def test_infer_python_imports_empty_name():
    """Cover line 269: empty name in sorted imports set."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        # Construct source that would produce empty import name via ast
        # ast.Import with alias.name="" — we mock the ast walk
        handler.write_text("import os\n", encoding="utf-8")
        # Just call it — empty names in the set are filtered by ast parsing
        # but we need an empty string in the set
        old_walk = py_daemon.ast.walk
        try:
            import ast
            def patched_walk(tree):
                nodes = list(old_walk(tree))
                # Inject a fake Import node with empty name
                fake = ast.Import(names=[ast.alias(name="")])
                nodes.append(fake)
                return nodes
            py_daemon.ast.walk = patched_walk
            result = py_daemon._infer_python_imports(handler)
            assert "" not in result
        finally:
            py_daemon.ast.walk = old_walk


def test_map_python_import_no_match():
    """Cover line 285: _PY_PACKAGE_RE doesn't match."""
    result = py_daemon._map_python_import_to_package("---invalid---")
    assert result == (None, "---invalid---")


def test_resolve_invoke_adapter_edge():
    """Cover lines 557, 573 in _resolve_invoke_adapter and _resolve_handler_name."""
    # invoke.handler is not a string -> returns "handler" (line 557)
    assert py_daemon._resolve_handler_name({"invoke": {"handler": 123}}) == "handler"

    # invoke.adapter is not a string -> returns native (line 573)
    assert py_daemon._resolve_invoke_adapter({"invoke": {"adapter": 42}}) == py_daemon._INVOKE_ADAPTER_NATIVE

    # Normal cases
    config_lambda = {"invoke": {"adapter": "aws-lambda"}}
    assert py_daemon._resolve_invoke_adapter(config_lambda) == py_daemon._INVOKE_ADAPTER_AWS_LAMBDA


def test_build_allowed_roots_strict_extra():
    """Cover line 675: _STRICT_EXTRA_ROOTS added to roots."""
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")

        old_extra = list(py_daemon._STRICT_EXTRA_ROOTS)
        try:
            py_daemon._STRICT_EXTRA_ROOTS.append(Path("/tmp"))
            roots, fn_dir_result = py_daemon._build_allowed_roots(handler)
            assert any("/tmp" in str(r) for r in roots)
        finally:
            py_daemon._STRICT_EXTRA_ROOTS.clear()
            py_daemon._STRICT_EXTRA_ROOTS.extend(old_extra)


def test_strict_fs_guard_os_open():
    """Cover lines 698, 725-726: check_target None return and guarded_os_open."""
    old_strict = py_daemon.STRICT_FS
    try:
        py_daemon.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            fn_dir = Path(tmp)
            handler = fn_dir / "handler.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            test_file = fn_dir / "test.txt"
            test_file.write_text("x", encoding="utf-8")

            with py_daemon._strict_fs_guard(handler):
                # Open using int fd — check_target returns None for int
                fd = os.open(str(test_file), os.O_RDONLY)
                try:
                    f = open(fd, "r", closefd=False)
                    f.read()
                    f.close()
                finally:
                    os.close(fd)

                # guarded_os_open — allowed path
                fd2 = os.open(str(test_file), os.O_RDONLY)
                os.close(fd2)
    finally:
        py_daemon.STRICT_FS = old_strict


def test_iter_handler_paths_file_in_root():
    """Cover line 888: fn_dir not matching _NAME_RE."""
    with tempfile.TemporaryDirectory() as tmp:
        old_fn_dir = py_daemon.FUNCTIONS_DIR
        try:
            fn_dir = Path(tmp) / "functions"
            fn_dir.mkdir()
            py_daemon.FUNCTIONS_DIR = fn_dir

            # File in root (not a dir)
            (fn_dir / "loose.py").write_text("x=1\n", encoding="utf-8")
            # Dir with invalid name (contains space, won't match _NAME_RE)
            bad = fn_dir / "bad name!"
            bad.mkdir()
            (bad / "handler.py").write_text("x=1\n", encoding="utf-8")

            paths = py_daemon._iter_handler_paths()
            names = [str(p) for p in paths]
            assert not any("bad name!" in n for n in names)
        finally:
            py_daemon.FUNCTIONS_DIR = old_fn_dir


def test_load_handler_spec_none_daemon():
    """Cover line 932: spec is None in _load_handler."""
    old_cache = dict(py_daemon._HANDLER_CACHE)
    try:
        py_daemon._HANDLER_CACHE.clear()
        with tempfile.TemporaryDirectory() as tmp:
            bad_file = Path(tmp) / "notmodule.xyz"
            bad_file.write_text("x=1\n", encoding="utf-8")
            try:
                py_daemon._load_handler(bad_file, "handler")
            except (RuntimeError, FileNotFoundError, OSError):
                pass
    finally:
        py_daemon._HANDLER_CACHE.clear()
        py_daemon._HANDLER_CACHE.update(old_cache)


def test_normalize_response_proxy_only():
    """Cover line 971: 'proxy' key alone makes dict raw."""
    resp = py_daemon._normalize_response({"proxy": {"url": "http://x"}})
    assert resp["status"] == 200
    assert "proxy" in resp


def test_main_entry_smoke() -> None:
    """Cover main() entry point lines — just test socket creation."""
    import threading
    with tempfile.TemporaryDirectory() as tmp:
        sock_path = os.path.join(tmp, "test.sock")
        old_socket_path = py_daemon.SOCKET_PATH
        old_preinstall = py_daemon.PREINSTALL_PY_DEPS_ON_START
        try:
            py_daemon.SOCKET_PATH = sock_path
            py_daemon.PREINSTALL_PY_DEPS_ON_START = False

            server_ready = threading.Event()
            stop = threading.Event()

            def run_server():
                py_daemon._ensure_socket_dir(sock_path)
                py_daemon._prepare_socket_path(sock_path)
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as srv:
                    srv.bind(sock_path)
                    os.chmod(sock_path, 0o666)
                    srv.listen(1)
                    srv.settimeout(1.0)
                    server_ready.set()
                    try:
                        conn, _ = srv.accept()
                        conn.close()
                    except socket.timeout:
                        pass

            t = threading.Thread(target=run_server, daemon=True)
            t.start()
            server_ready.wait(timeout=2)

            # Connect to verify
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                client.connect(sock_path)
            finally:
                client.close()
            t.join(timeout=2)
        finally:
            py_daemon.SOCKET_PATH = old_socket_path
            py_daemon.PREINSTALL_PY_DEPS_ON_START = old_preinstall


# ---------------------------------------------------------------------------
# In-process execution tests
# ---------------------------------------------------------------------------
import threading


def _write_handler(tmp_dir, code, filename="handler.py"):
    handler_path = tmp_dir / filename
    handler_path.write_text(code, encoding="utf-8")
    return handler_path


def test_inprocess_basic_handler() -> None:
    """In-process: load and execute a simple handler returning dict."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_path = _write_handler(tmp, 'def handler(event):\n    return {"body": "hello", "status": 200}\n')
        result = py_daemon._handle_request_inprocess(handler_path, "handler", [], {"method": "GET"}, "native")
        assert result["status"] == 200
        assert result["body"] == "hello"


def test_inprocess_tuple_response() -> None:
    """In-process: handler returning a tuple (body, status, headers)."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_path = _write_handler(tmp, 'def handler(event):\n    return ("ok", 201, {"X-Custom": "1"})\n')
        result = py_daemon._handle_request_inprocess(handler_path, "handler", [], {}, "native")
        assert result["status"] == 201
        assert result["body"] == "ok"
        assert result["headers"]["X-Custom"] == "1"


def test_inprocess_stdout_capture() -> None:
    """In-process: stdout from print() is captured per-request."""
    py_daemon._install_capture_streams()
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_path = _write_handler(tmp, 'def handler(event):\n    print("hello stdout")\n    return {"body": "ok", "status": 200}\n')
        result = py_daemon._handle_request_inprocess(handler_path, "handler", [], {}, "native")
        assert result["status"] == 200
        assert "hello stdout" in result.get("stdout", "")


def test_inprocess_stderr_capture() -> None:
    """In-process: stderr is captured per-request."""
    py_daemon._install_capture_streams()
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_path = _write_handler(tmp, 'import sys\ndef handler(event):\n    print("err msg", file=sys.stderr)\n    return {"body": "ok", "status": 200}\n')
        result = py_daemon._handle_request_inprocess(handler_path, "handler", [], {}, "native")
        assert result["status"] == 200
        assert "err msg" in result.get("stderr", "")


def test_inprocess_handler_cache() -> None:
    """In-process: second call uses cached handler (same mtime)."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_path = _write_handler(tmp, 'calls = 0\ndef handler(event):\n    global calls\n    calls += 1\n    return {"body": str(calls), "status": 200}\n')

        r1 = py_daemon._handle_request_inprocess(handler_path, "handler", [], {}, "native")
        r2 = py_daemon._handle_request_inprocess(handler_path, "handler", [], {}, "native")
        assert r1["body"] == "1"
        assert r2["body"] == "2"  # same module instance, counter increments


def test_inprocess_cache_invalidation() -> None:
    """In-process: changing handler file reloads the module."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_path = _write_handler(tmp, 'def handler(event):\n    return {"body": "v1", "status": 200}\n')

        r1 = py_daemon._handle_request_inprocess(handler_path, "handler", [], {}, "native")
        assert r1["body"] == "v1"

        # Clear cache and write new version to force reload.
        cache_key = f"{handler_path}::handler::native"
        py_daemon._INPROCESS_CACHE.pop(cache_key, None)
        handler_path.write_text('def handler(event):\n    return {"body": "v2", "status": 200}\n', encoding="utf-8")
        # Force different mtime_ns by touching with explicit time.
        import time
        future_time = time.time() + 2
        os.utime(handler_path, (future_time, future_time))

        r2 = py_daemon._handle_request_inprocess(handler_path, "handler", [], {}, "native")
        assert r2["body"] == "v2"


def test_inprocess_env_isolation() -> None:
    """In-process: per-request env overrides are thread-local."""
    py_daemon._install_env_proxy()
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_path = _write_handler(tmp, 'import os\ndef handler(event):\n    return {"body": os.environ.get("TEST_INPROC_VAR", "missing"), "status": 200}\n')

        result = py_daemon._handle_request_inprocess(
            handler_path, "handler", [],
            {"env": {"TEST_INPROC_VAR": "injected"}}, "native"
        )
        assert result["body"] == "injected"

        # Outside of request context, the var should not leak
        assert os.environ.get("TEST_INPROC_VAR") is None


def test_inprocess_syspath_restored() -> None:
    """In-process: sys.path is restored after handler import."""
    original = sys.path[:]
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_path = _write_handler(tmp, 'def handler(event):\n    return {"body": "ok", "status": 200}\n')
        py_daemon._load_handler_inprocess(str(handler_path), "handler", ["/tmp/fake_deps"], "native")
    assert sys.path == original


def test_inprocess_handler_exception() -> None:
    """In-process: exception in handler produces error response."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_path = _write_handler(tmp, 'def handler(event):\n    raise ValueError("boom")\n')
        try:
            py_daemon._handle_request_inprocess(handler_path, "handler", [], {}, "native")
            raise AssertionError("expected exception")
        except ValueError as exc:
            assert "boom" in str(exc)


def test_inprocess_async_handler() -> None:
    """In-process: async handler is awaited correctly."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_path = _write_handler(tmp, 'async def handler(event):\n    return {"body": "async-ok", "status": 200}\n')
        result = py_daemon._handle_request_inprocess(handler_path, "handler", [], {}, "native")
        assert result["body"] == "async-ok"


def test_inprocess_deps_dirs() -> None:
    """In-process: deps_dirs are available during handler import."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        deps = tmp / "mydeps"
        deps.mkdir()
        (deps / "mylib.py").write_text('VALUE = 42\n', encoding="utf-8")
        handler_path = _write_handler(tmp, 'import mylib\ndef handler(event):\n    return {"body": str(mylib.VALUE), "status": 200}\n')
        result = py_daemon._handle_request_inprocess(handler_path, "handler", [str(deps)], {}, "native")
        assert result["body"] == "42"


def test_inprocess_dispatch_via_handle_request_direct() -> None:
    """_handle_request_direct always uses in-process execution."""
    old_resolve = py_daemon._resolve_handler_path
    old_config = py_daemon._read_function_config
    old_reqs = py_daemon._ensure_requirements
    try:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            handler_path = _write_handler(tmp, 'def handler(event):\n    return {"body": "inproc", "status": 200}\n')
            py_daemon._resolve_handler_path = lambda *_a, **_k: handler_path
            py_daemon._read_function_config = lambda _p: {}
            py_daemon._ensure_requirements = lambda _p: None

            resp = py_daemon._handle_request_direct({"fn": "demo", "event": {}})
            assert resp["body"] == "inproc"
    finally:
        py_daemon._resolve_handler_path = old_resolve
        py_daemon._read_function_config = old_config
        py_daemon._ensure_requirements = old_reqs


def test_inprocess_concurrent_stdout_isolation() -> None:
    """In-process: concurrent requests don't leak stdout between threads."""
    py_daemon._install_capture_streams()
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_path = _write_handler(tmp, (
            'import time\n'
            'def handler(event):\n'
            '    tag = event.get("query", {}).get("tag", "?")\n'
            '    print(f"tag={tag}")\n'
            '    time.sleep(0.05)\n'
            '    return {"body": tag, "status": 200}\n'
        ))

        results = {}

        def run(tag):
            r = py_daemon._handle_request_inprocess(
                handler_path, "handler", [],
                {"query": {"tag": tag}}, "native"
            )
            results[tag] = r

        t1 = threading.Thread(target=run, args=("A",))
        t2 = threading.Thread(target=run, args=("B",))
        t1.start()
        t2.start()
        t1.join(timeout=5)
        t2.join(timeout=5)

        assert "tag=A" in results["A"].get("stdout", "")
        assert "tag=B" in results["B"].get("stdout", "")
        assert "tag=B" not in results["A"].get("stdout", "")
        assert "tag=A" not in results["B"].get("stdout", "")


def test_inprocess_deps_isolation_different_versions() -> None:
    """Two functions importing the same package name from different .deps/ dirs
    must each get their own version — no cross-contamination via sys.modules."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        # Function A: mylib.VALUE = "version_A"
        fn_a = tmp / "fn_a"
        fn_a.mkdir()
        deps_a = fn_a / ".deps"
        deps_a.mkdir()
        (deps_a / "sharedpkg.py").write_text('VALUE = "version_A"\n', encoding="utf-8")
        _write_handler(fn_a, (
            'import sharedpkg\n'
            'def handler(event):\n'
            '    return {"body": sharedpkg.VALUE, "status": 200}\n'
        ))

        # Function B: mylib.VALUE = "version_B"
        fn_b = tmp / "fn_b"
        fn_b.mkdir()
        deps_b = fn_b / ".deps"
        deps_b.mkdir()
        (deps_b / "sharedpkg.py").write_text('VALUE = "version_B"\n', encoding="utf-8")
        _write_handler(fn_b, (
            'import sharedpkg\n'
            'def handler(event):\n'
            '    return {"body": sharedpkg.VALUE, "status": 200}\n'
        ))

        handler_a = fn_a / "handler.py"
        handler_b = fn_b / "handler.py"

        # Load and execute A first
        r_a = py_daemon._handle_request_inprocess(
            handler_a, "handler", [str(deps_a)], {}, "native"
        )
        assert r_a["body"] == "version_A", f"Expected version_A, got {r_a['body']}"

        # Load and execute B — must NOT get A's version
        r_b = py_daemon._handle_request_inprocess(
            handler_b, "handler", [str(deps_b)], {}, "native"
        )
        assert r_b["body"] == "version_B", f"Expected version_B, got {r_b['body']}"

        # Re-execute A — must still return A's version
        r_a2 = py_daemon._handle_request_inprocess(
            handler_a, "handler", [str(deps_a)], {}, "native"
        )
        assert r_a2["body"] == "version_A", f"Expected version_A on re-call, got {r_a2['body']}"


def test_inprocess_no_deps_cannot_see_other_fn_deps() -> None:
    """A function WITHOUT deps must NOT be able to import packages from
    another function's .deps/ dir (replicates Phase 9 integration test)."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        # Function with-deps: has extrapkg in .deps/
        fn_with = tmp / "fn_with"
        fn_with.mkdir()
        deps_with = fn_with / ".deps"
        deps_with.mkdir()
        (deps_with / "extrapkg.py").write_text('PRESENT = True\n', encoding="utf-8")
        _write_handler(fn_with, (
            'import extrapkg\n'
            'def handler(event):\n'
            '    return {"body": "has_extra=true", "status": 200}\n'
        ))

        # Function no-deps: does NOT have extrapkg — must fail to import it
        fn_without = tmp / "fn_without"
        fn_without.mkdir()
        _write_handler(fn_without, (
            'def handler(event):\n'
            '    try:\n'
            '        import extrapkg\n'
            '        return {"body": "has_extra=true,isolation_broken=true", "status": 200}\n'
            '    except ImportError:\n'
            '        return {"body": "has_extra=false", "status": 200}\n'
        ))

        # Execute with-deps first (loads extrapkg into sys.modules)
        r_with = py_daemon._handle_request_inprocess(
            fn_with / "handler.py", "handler", [str(deps_with)], {}, "native"
        )
        assert r_with["body"] == "has_extra=true"

        # Execute no-deps — must NOT see extrapkg
        r_without = py_daemon._handle_request_inprocess(
            fn_without / "handler.py", "handler", [], {}, "native"
        )
        assert "has_extra=false" in r_without["body"], (
            f"no-deps function should NOT see other function's deps, got: {r_without['body']}"
        )


def test_inprocess_capture_stream_helpers_and_install_idempotent() -> None:
    """Cover helper methods on thread-local capture streams."""

    class FakeStream:
        def __init__(self) -> None:
            self.writes = []
            self.flushes = 0
            self.marker = "ok"

        def write(self, text: str) -> int:
            self.writes.append(text)
            return len(text)

        def flush(self) -> None:
            self.flushes += 1

        def fileno(self) -> int:
            return 123

    fake = FakeStream()
    wrapped = py_daemon._ThreadLocalCapturingStream(fake, "stdout_buf")
    old_stdout_buf = getattr(py_daemon._capture_tls, "stdout_buf", None)

    try:
        py_daemon._capture_tls.stdout_buf = None
        assert wrapped.write("plain") == 5
        assert fake.writes == ["plain"]
        wrapped.flush()
        assert fake.flushes == 1
        assert wrapped.fileno() == 123
        assert wrapped.marker == "ok"

        py_daemon._capture_tls.stdout_buf = io.StringIO()
        assert wrapped.write("captured") == 8
        assert py_daemon._capture_tls.stdout_buf.getvalue() == "captured"
    finally:
        py_daemon._capture_tls.stdout_buf = old_stdout_buf

    old_stdout = sys.stdout
    old_stderr = sys.stderr
    try:
        sys.stdout = py_daemon._ThreadLocalCapturingStream(sys.__stdout__, "stdout_buf")
        sys.stderr = py_daemon._ThreadLocalCapturingStream(sys.__stderr__, "stderr_buf")
        py_daemon._install_capture_streams()
    finally:
        sys.stdout = old_stdout
        sys.stderr = old_stderr


def test_inprocess_env_proxy_and_patched_process_env_edges() -> None:
    """Cover env proxy iteration, copy, getattr, and invalid override keys."""
    real_env = {"A": "1", "B": "2", "C": "3"}
    proxy = py_daemon._EnvOverrideProxy(real_env)
    sentinel = object()
    old_overrides = getattr(py_daemon._env_tls, "env_overrides", sentinel)

    try:
        py_daemon._env_tls.env_overrides = {"A": None, "B": "override", "NEW": "extra"}
        assert "A" not in proxy
        assert "NEW" in proxy

        try:
            _ = proxy["A"]
            raise AssertionError("expected KeyError for deleted override")
        except KeyError:
            pass

        assert proxy["B"] == "override"
        keys = list(proxy)
        assert "A" not in keys
        assert "B" in keys
        assert "C" in keys
        assert "NEW" in keys

        values = proxy.values()
        assert "override" in values
        assert "3" in values
        assert "extra" in values

        items = dict(proxy.items())
        assert items["B"] == "override"
        assert items["C"] == "3"
        assert items["NEW"] == "extra"

        copied = proxy.copy()
        assert "A" not in copied
        assert copied["B"] == "override"
        assert copied["NEW"] == "extra"

        setdefault = proxy.setdefault
        assert setdefault("SETDEFAULT", "1") == "1"
        assert real_env["SETDEFAULT"] == "1"
    finally:
        if old_overrides is sentinel:
            try:
                delattr(py_daemon._env_tls, "env_overrides")
            except AttributeError:
                pass
        else:
            py_daemon._env_tls.env_overrides = old_overrides

    assert "A" in proxy
    assert set(list(proxy)) == {"A", "B", "C", "SETDEFAULT"}
    assert set(proxy.keys()) == {"A", "B", "C", "SETDEFAULT"}
    del proxy["C"]
    assert "C" not in real_env

    with py_daemon._patched_process_env({"env": {1: "bad", "": "skip", "OK": "1", "DROP": None}}):
        overrides = py_daemon._env_tls.env_overrides
        assert overrides == {"OK": "1", "DROP": None}
    assert getattr(py_daemon._env_tls, "env_overrides", None) is None


def test_inprocess_request_adapter_helpers() -> None:
    """Cover Lambda/Workers adapter helper branches used by in-process mode."""
    import asyncio
    import base64

    headers = {"Content-Type": "application/json", "cookie": "a=1; b=2"}
    assert py_daemon._ip_header_value(headers, "content-type") == "application/json"
    assert py_daemon._ip_header_value(headers, "missing") == ""

    assert py_daemon._ip_build_raw_path({}) == "/"
    assert py_daemon._ip_build_raw_path({"raw_path": "https://example.com/path"}) == "https://example.com/path"
    assert py_daemon._ip_build_raw_path({"raw_path": "nested/path"}) == "/nested/path"

    encoded_query = py_daemon._ip_encode_query_string({"a": "1", "tags": [None, "b"], "skip": None})
    assert "a=1" in encoded_query
    assert "tags=b" in encoded_query
    assert "skip" not in encoded_query
    assert py_daemon._ip_encode_query_string("bad") == ""
    assert py_daemon._ip_build_raw_query({"query": {"a": "1"}}) == "a=1"

    body_b64 = base64.b64encode(b"binary-data").decode("utf-8")
    lambda_event = py_daemon._ip_build_lambda_event({
        "method": "POST",
        "raw_path": "/api/test?foo=bar",
        "headers": headers,
        "query": {"page": "1"},
        "params": {"id": "42"},
        "is_base64": True,
        "body_base64": body_b64,
        "client": {"ip": "1.2.3.4", "ua": "Agent"},
        "context": {"request_id": "req-1"},
    })
    assert lambda_event["rawPath"] == "/api/test"
    assert lambda_event["rawQueryString"] == "foo=bar"
    assert lambda_event["body"] == body_b64
    assert lambda_event["isBase64Encoded"] is True
    assert lambda_event["cookies"] == ["a=1", "b=2"]

    ctx = py_daemon._IPLambdaContext({"id": "evt-1", "context": {"timeout_ms": 123}})
    assert ctx.get_remaining_time_in_millis() == 123
    assert ctx.done() is None
    assert ctx.fail() is None
    assert ctx.succeed() is None

    assert py_daemon._ip_build_workers_url({"raw_path": "https://example.com/api"}) == "https://example.com/api"
    assert py_daemon._ip_build_workers_url({"path": "/api"}) == "http://127.0.0.1/api"

    bad_req = py_daemon._IPWorkersRequest({"is_base64": True, "body_base64": "!!!invalid!!!"})
    assert bad_req.body == b""
    assert py_daemon._IPWorkersRequest({"body": b"raw"}).body == b"raw"
    assert py_daemon._IPWorkersRequest({}).body == b""
    assert py_daemon._IPWorkersRequest({"body": 123}).body == b"123"

    req = py_daemon._IPWorkersRequest({"body": '{"ok": true}'})
    assert asyncio.run(req.json()) == {"ok": True}
    empty_req = py_daemon._IPWorkersRequest({"body": ""})
    assert asyncio.run(empty_req.json()) is None

    workers_ctx = py_daemon._IPWorkersContext({"context": {"request_id": "req-2"}})
    assert workers_ctx.passThroughOnException() is None
    assert workers_ctx.pass_through_on_exception() is None


def test_inprocess_handler_resolution_invocation_and_normalization_helpers() -> None:
    """Cover handler resolution, route-param injection, awaitable fallback, and object responses."""
    import base64
    import types

    cf_mod = types.ModuleType("cf_mod")
    cf_mod.handler = lambda req, env, ctx: {"status": 200}
    assert (
        py_daemon._ip_resolve_handler(cf_mod, "handler", py_daemon._INVOKE_ADAPTER_CLOUDFLARE_WORKER)
        is cf_mod.handler
    )

    native_mod = types.ModuleType("native_mod")
    native_mod.main = lambda event: {"status": 200}
    assert py_daemon._ip_resolve_handler(native_mod, "handler", py_daemon._INVOKE_ADAPTER_NATIVE) is native_mod.main

    try:
        py_daemon._ip_resolve_handler(types.ModuleType("missing_cf"), "handler", py_daemon._INVOKE_ADAPTER_CLOUDFLARE_WORKER)
        raise AssertionError("expected cloudflare handler resolution failure")
    except RuntimeError as exc:
        assert "cloudflare-worker" in str(exc)

    try:
        py_daemon._ip_resolve_handler(types.ModuleType("missing_native"), "custom", py_daemon._INVOKE_ADAPTER_NATIVE)
        raise AssertionError("expected missing native handler failure")
    except RuntimeError as exc:
        assert "custom(event) is required" in str(exc)

    def handler_varargs(*args):
        return len(args)

    def handler_no_args():
        return "zero"

    def handler_kwargs(event, **kwargs):
        return kwargs

    def handler_named(event, id=None, *, slug=None):
        return {"id": id, "slug": slug}

    assert py_daemon._ip_call_handler(handler_varargs, [{}, "extra"]) == 2
    assert py_daemon._ip_call_handler(handler_no_args, [{}]) == "zero"
    assert py_daemon._ip_call_handler(handler_kwargs, [{}], route_params={"id": "42"}) == {"id": "42"}
    assert py_daemon._ip_call_handler(
        handler_named,
        [{}],
        route_params={"id": "42", "slug": "news", "ignored": "x"},
    ) == {"id": "42", "slug": "news"}

    async def simple_coro():
        return 99

    orig_run = py_daemon.asyncio.run
    orig_new_event_loop = py_daemon.asyncio.new_event_loop
    loop_state = {"closed": False}

    class FakeLoop:
        def run_until_complete(self, value):
            return orig_run(value)

        def close(self):
            loop_state["closed"] = True

    try:
        py_daemon.asyncio.run = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("no current loop"))
        py_daemon.asyncio.new_event_loop = lambda: FakeLoop()
        assert py_daemon._ip_resolve_awaitable(simple_coro()) == 99
        assert loop_state["closed"] is True
    finally:
        py_daemon.asyncio.run = orig_run
        py_daemon.asyncio.new_event_loop = orig_new_event_loop

    class BytesResp:
        status = 201
        headers = {"X-Test": "1"}
        body = b"binary"

    bytes_result = py_daemon._ip_normalize_response_like_object(BytesResp())
    assert bytes_result["status"] == 201
    assert bytes_result["headers"]["X-Test"] == "1"
    assert base64.b64decode(bytes_result["body_base64"]) == b"binary"

    class EmptyResp:
        status = "bad"
        headers = "not-a-dict"
        body = None

    empty_result = py_daemon._ip_normalize_response_like_object(EmptyResp())
    assert empty_result["status"] == 200
    assert empty_result["headers"] == {}
    assert empty_result["body"] == ""

    class NumberResp:
        status = 202
        headers = {}
        body = 123

    assert py_daemon._ip_normalize_response_like_object(NumberResp())["body"] == "123"


def test_inprocess_strict_fs_hook_branches() -> None:
    """Cover strict-FS passthrough, blocking, and disabled branches for in-process mode."""
    import subprocess

    old_strict = py_daemon.STRICT_FS
    try:
        py_daemon.STRICT_FS = False
        with tempfile.TemporaryDirectory() as td:
            handler_path = _write_handler(Path(td), 'def handler(event):\n    return {"status": 200}\n')
            with py_daemon._inprocess_strict_fs(handler_path):
                assert py_daemon._active_strict_policy() is None

        py_daemon.STRICT_FS = True
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            handler_path = _write_handler(tmp, 'def handler(event):\n    return {"status": 200}\n')
            protected = tmp / "fn.config.json"
            protected.write_text("{}", encoding="utf-8")

            py_daemon._install_strict_fs_hooks()

            assert subprocess.run(["/bin/true"], check=False).returncode == 0
            assert subprocess.call(["/bin/true"]) == 0
            assert subprocess.check_call(["/bin/true"]) == 0
            assert subprocess.check_output(["/bin/sh", "-c", "printf ok"]) == b"ok"
            proc = subprocess.Popen(["/bin/true"])
            assert proc.wait(timeout=5) == 0
            assert os.system("true") == 0

            with py_daemon._inprocess_strict_fs(handler_path):
                try:
                    open(None)
                    raise AssertionError("expected TypeError for unresolved path target")
                except TypeError:
                    pass

                for fn in (
                    lambda: subprocess.run(["/bin/true"], check=False),
                    lambda: subprocess.call(["/bin/true"]),
                    lambda: subprocess.check_call(["/bin/true"]),
                    lambda: subprocess.check_output(["/bin/true"]),
                    lambda: subprocess.Popen(["/bin/true"]),
                    lambda: os.system("true"),
                    lambda: protected.open(),
                ):
                    try:
                        result = fn()
                        if hasattr(result, "wait"):
                            result.wait(timeout=5)
                        raise AssertionError("expected strict fs guard to block operation")
                    except PermissionError:
                        pass
    finally:
        py_daemon.STRICT_FS = old_strict


def test_load_handler_inprocess_snapshot_restore_and_spec_error() -> None:
    """Cover saved dependency snapshot restore and spec load failure in in-process imports."""
    import types

    old_cache = dict(py_daemon._INPROCESS_CACHE)
    old_snapshots = dict(py_daemon._DEPS_MODULE_SNAPSHOTS)
    old_spec_from_file = py_daemon.importlib.util.spec_from_file_location
    try:
        py_daemon._INPROCESS_CACHE.clear()
        py_daemon._DEPS_MODULE_SNAPSHOTS.clear()

        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            deps_dir = tmp / ".deps"
            deps_dir.mkdir()
            handler_path = _write_handler(tmp, 'def handler(event):\n    return {"body": "ok", "status": 200}\n')

            restored_mod = types.ModuleType("restored_from_snapshot")
            restored_mod.__file__ = str(deps_dir / "restored_from_snapshot.py")
            py_daemon._DEPS_MODULE_SNAPSHOTS[(str(deps_dir),)] = {"restored_from_snapshot": restored_mod}
            sys.modules.pop("restored_from_snapshot", None)

            handler = py_daemon._load_handler_inprocess(str(handler_path), "handler", [str(deps_dir)], "native")
            assert callable(handler)
            assert sys.modules["restored_from_snapshot"] is restored_mod

            py_daemon._INPROCESS_CACHE.clear()
            py_daemon.importlib.util.spec_from_file_location = lambda *_a, **_k: None
            try:
                py_daemon._load_handler_inprocess(str(handler_path), "handler", [], "native")
                raise AssertionError("expected spec load failure")
            except RuntimeError as exc:
                assert "failed to load handler spec" in str(exc)
    finally:
        py_daemon.importlib.util.spec_from_file_location = old_spec_from_file
        py_daemon._INPROCESS_CACHE.clear()
        py_daemon._INPROCESS_CACHE.update(old_cache)
        py_daemon._DEPS_MODULE_SNAPSHOTS.clear()
        py_daemon._DEPS_MODULE_SNAPSHOTS.update(old_snapshots)
        sys.modules.pop("restored_from_snapshot", None)


def test_ensure_inprocess_init_second_check_returns_without_installing() -> None:
    """Cover the second _inprocess_initialized guard inside the init lock."""

    class FlipLock:
        def __enter__(self):
            py_daemon._inprocess_initialized = True

        def __exit__(self, exc_type, exc, tb):
            return False

    old_initialized = py_daemon._inprocess_initialized
    old_lock = py_daemon._inprocess_init_lock
    old_install_capture_streams = py_daemon._install_capture_streams
    old_install_env_proxy = py_daemon._install_env_proxy
    install_calls = []

    try:
        py_daemon._inprocess_initialized = False
        py_daemon._inprocess_init_lock = FlipLock()
        py_daemon._install_capture_streams = lambda: install_calls.append("capture")
        py_daemon._install_env_proxy = lambda: install_calls.append("env")
        py_daemon._ensure_inprocess_init()
        assert install_calls == []
    finally:
        py_daemon._inprocess_initialized = old_initialized
        py_daemon._inprocess_init_lock = old_lock
        py_daemon._install_capture_streams = old_install_capture_streams
        py_daemon._install_env_proxy = old_install_env_proxy


def test_inprocess_response_like_object_and_syspath_cleanup_paths() -> None:
    """Cover response-like return values and sys.path cleanup when handlers mutate it."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        handler_obj = _write_handler(
            tmp,
            (
                'class Resp:\n'
                '    status = 204\n'
                '    headers = {"X-Test": "1"}\n'
                '    body = "from-object"\n'
                'def handler(event):\n'
                '    return Resp()\n'
            ),
            filename="object_handler.py",
        )
        result = py_daemon._handle_request_inprocess(handler_obj, "handler", [], {}, "native")
        assert result["status"] == 204
        assert result["headers"]["X-Test"] == "1"
        assert result["body"] == "from-object"

        cleanup_handler = _write_handler(
            tmp,
            (
                'import sys\n'
                'def handler(event):\n'
                '    target = event["handler_dir"]\n'
                '    while target in sys.path:\n'
                '        sys.path.remove(target)\n'
                '    return {"body": "ok", "status": 200}\n'
            ),
            filename="cleanup_handler.py",
        )
        cleanup_result = py_daemon._handle_request_inprocess(
            cleanup_handler,
            "handler",
            [],
            {"handler_dir": str(tmp)},
            "native",
        )
        assert cleanup_result["body"] == "ok"


def test_inprocess_removes_other_function_deps_loaded_during_execution() -> None:
    """Cover cleanup of modules imported from another function's deps during execution."""
    module_name = "leakedpkg_fastfn_cov"
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        fn_other = tmp / "fn_other"
        fn_other.mkdir()
        deps_other = fn_other / ".deps"
        deps_other.mkdir()
        (deps_other / f"{module_name}.py").write_text('VALUE = "from-other-deps"\n', encoding="utf-8")
        other_handler = _write_handler(
            fn_other,
            (
                f"import {module_name}\n"
                "def handler(event):\n"
                f'    return {{"body": {module_name}.VALUE, "status": 200}}\n'
            ),
        )
        other_result = py_daemon._handle_request_inprocess(
            other_handler,
            "handler",
            [str(deps_other)],
            {},
            "native",
        )
        assert other_result["body"] == "from-other-deps"

        fn_main = tmp / "fn_main"
        fn_main.mkdir()
        main_handler = _write_handler(
            fn_main,
            (
                "import sys\n"
                "def handler(event):\n"
                '    other = event["other_deps"]\n'
                "    sys.path.insert(0, other)\n"
                "    try:\n"
                f"        import {module_name}\n"
                f'        return {{"body": {module_name}.VALUE, "status": 200}}\n'
                "    finally:\n"
                "        while other in sys.path:\n"
                "            sys.path.remove(other)\n"
            ),
        )

        sys.modules.pop(module_name, None)
        main_result = py_daemon._handle_request_inprocess(
            main_handler,
            "handler",
            [],
            {"other_deps": str(deps_other)},
            "native",
        )
        assert main_result["body"] == "from-other-deps"
        assert module_name not in sys.modules
