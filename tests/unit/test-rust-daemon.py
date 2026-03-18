#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import socket
import struct
import tempfile
from concurrent.futures import Future, TimeoutError as FutureTimeoutError
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNTIME_DIR = ROOT / "srv/fn/runtimes"
RUST_DAEMON_PATH = RUNTIME_DIR / "rust-daemon.py"

_RUST_SPEC = importlib.util.spec_from_file_location("fastfn_rust_daemon_cov", RUST_DAEMON_PATH)
if _RUST_SPEC is None or _RUST_SPEC.loader is None:
    raise RuntimeError(f"failed to load runtime module: {RUST_DAEMON_PATH}")
rust_daemon = importlib.util.module_from_spec(_RUST_SPEC)  # type: ignore
_RUST_SPEC.loader.exec_module(rust_daemon)  # type: ignore


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


def test_read_function_env_and_resolve_path() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "root.rs").write_text("pub fn handler(_e: serde_json::Value) -> serde_json::Value { serde_json::json!({}) }", encoding="utf-8")
        (root / "pkg").mkdir()
        (root / "pkg" / "app.rs").write_text("pub fn handler(_e: serde_json::Value) -> serde_json::Value { serde_json::json!({}) }", encoding="utf-8")
        (root / "rust").mkdir()
        (root / "rust" / "rt").mkdir()
        (root / "rust" / "rt" / "handler.rs").write_text(
            "pub fn handler(_e: serde_json::Value) -> serde_json::Value { serde_json::json!({}) }",
            encoding="utf-8",
        )
        (root / "ver").mkdir()
        (root / "ver" / "v2").mkdir(parents=True)
        (root / "ver" / "v2" / "src").mkdir(parents=True)
        (root / "ver" / "v2" / "src" / "lib.rs").write_text(
            "pub fn handler(_e: serde_json::Value) -> serde_json::Value { serde_json::json!({}) }",
            encoding="utf-8",
        )

        old_functions = rust_daemon.FUNCTIONS_DIR
        old_runtime = rust_daemon.RUNTIME_FUNCTIONS_DIR
        try:
            rust_daemon.FUNCTIONS_DIR = root
            rust_daemon.RUNTIME_FUNCTIONS_DIR = root / "rust"

            assert rust_daemon._resolve_handler_path("root.rs", None) == root / "root.rs"
            assert rust_daemon._resolve_handler_path("pkg", None) == root / "pkg" / "app.rs"
            assert rust_daemon._resolve_handler_path("rt", None) == root / "rust" / "rt" / "handler.rs"
            assert rust_daemon._resolve_handler_path("ver", "v2") == root / "ver" / "v2" / "src" / "lib.rs"

            try:
                rust_daemon._resolve_handler_path("../bad", None)
            except ValueError:
                pass
            else:
                raise AssertionError("expected invalid function name")
        finally:
            rust_daemon.FUNCTIONS_DIR = old_functions
            rust_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime

        handler = root / "pkg" / "app.rs"
        (root / "pkg" / "fn.env.json").write_text(
            json.dumps({"A": "1", "B": {"value": 2}, "C": None}),
            encoding="utf-8",
        )
        env = rust_daemon._read_function_env(handler)
        assert env == {"A": "1", "B": "2"}, env


def test_read_write_frame_and_normalize_response() -> None:
    left, right = socket.socketpair()
    with left, right:
        expected = {"ok": True, "x": 1}
        rust_daemon._write_frame(left, expected)
        assert rust_daemon._read_frame(right) == expected

    left, right = socket.socketpair()
    with left, right:
        _write_raw_frame(right, b"\xff\xfe")
        try:
            rust_daemon._read_frame(left)
        except Exception as exc:  # noqa: BLE001
            assert "utf-8" in str(exc).lower() or "decode" in str(exc).lower(), str(exc)
        else:
            raise AssertionError("expected invalid utf-8")

    left, right = socket.socketpair()
    with left, right:
        too_large = rust_daemon.MAX_FRAME_BYTES + 1
        right.sendall(struct.pack("!I", too_large))
        try:
            rust_daemon._read_frame(left)
        except ValueError as exc:
            assert "invalid frame length" in str(exc), str(exc)
        else:
            raise AssertionError("expected invalid frame length")

    ok_resp = rust_daemon._normalize_response({"status": 201, "headers": {}, "body": "ok"})
    assert ok_resp["status"] == 201
    b64_resp = rust_daemon._normalize_response({"statusCode": 200, "headers": {}, "isBase64Encoded": True, "body": "aaa"})
    assert b64_resp["is_base64"] is True and b64_resp["body_base64"] == "aaa"
    try:
        rust_daemon._normalize_response({"status": "200"})
    except ValueError:
        pass
    else:
        raise AssertionError("expected invalid status")


def test_ensure_rust_binary_paths() -> None:
    class Proc:
        def __init__(self, returncode=0, stdout="", stderr=""):
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "app.rs"
        handler.write_text("pub fn handler(_event: serde_json::Value) -> serde_json::Value { serde_json::json!({\"ok\":true}) }\n", encoding="utf-8")

        old_cache = rust_daemon._BINARY_CACHE.copy()
        old_hot_reload = rust_daemon.HOT_RELOAD
        old_which = rust_daemon.shutil.which
        old_run = rust_daemon.subprocess.run
        try:
            rust_daemon._BINARY_CACHE.clear()
            rust_daemon.HOT_RELOAD = False
            rust_daemon.shutil.which = lambda name: "/usr/bin/cargo" if name == "cargo" else None
            calls = {"n": 0}

            def fake_run(cmd, capture_output, text, cwd, timeout, check):  # noqa: ARG001
                calls["n"] += 1
                out = Path(cwd) / "target" / "release"
                out.mkdir(parents=True, exist_ok=True)
                bin_path = out / "fn_handler"
                # Write a fake ELF binary header so _binary_looks_native passes on Linux.
                bin_path.write_bytes(b"\x7fELF" + b"\x00" * 100)
                bin_path.chmod(0o755)
                return Proc(returncode=0)

            rust_daemon.subprocess.run = fake_run
            b1 = rust_daemon._ensure_rust_binary(handler)
            assert b1.is_file(), b1
            b2 = rust_daemon._ensure_rust_binary(handler)
            assert b2 == b1
            assert calls["n"] == 1, calls

            rust_daemon._BINARY_CACHE.clear()
            rust_daemon.subprocess.run = lambda *_a, **_k: (_ for _ in ()).throw(AssertionError("unexpected rebuild"))
            b3 = rust_daemon._ensure_rust_binary(handler)
            assert b3 == b1

            rust_daemon._BINARY_CACHE.clear()
            rust_daemon.subprocess.run = lambda *_a, **_k: Proc(returncode=1, stderr="compile failed")
            meta_path = handler.parent / ".rust-build" / ".fastfn-build-meta.json"
            if meta_path.exists():
                meta_path.unlink()
            try:
                rust_daemon._ensure_rust_binary(handler)
            except RuntimeError as exc:
                assert "build failed" in str(exc), str(exc)
            else:
                raise AssertionError("expected rust build failure")
        finally:
            rust_daemon._BINARY_CACHE.clear()
            rust_daemon._BINARY_CACHE.update(old_cache)
            rust_daemon.HOT_RELOAD = old_hot_reload
            rust_daemon.shutil.which = old_which
            rust_daemon.subprocess.run = old_run


def test_run_handler_direct_pool_and_serve_conn() -> None:
    class Proc:
        def __init__(self, stdout: str, stderr: str = ""):
            self.stdout = stdout
            self.stderr = stderr
            self.returncode = 0

    old_run = rust_daemon.subprocess.run
    try:
        rust_daemon.subprocess.run = lambda *_a, **_k: (_ for _ in ()).throw(
            rust_daemon.subprocess.TimeoutExpired(cmd="bin", timeout=1)
        )
        timeout_resp = rust_daemon._run_rust_handler(Path("/tmp/bin"), {}, 100)
        assert timeout_resp["status"] == 504

        rust_daemon.subprocess.run = lambda *_a, **_k: Proc("", "boom")
        empty_resp = rust_daemon._run_rust_handler(Path("/tmp/bin"), {}, 100)
        assert empty_resp["status"] == 500

        rust_daemon.subprocess.run = lambda *_a, **_k: Proc("{bad")
        bad_resp = rust_daemon._run_rust_handler(Path("/tmp/bin"), {}, 100)
        assert bad_resp["status"] == 500

        rust_daemon.subprocess.run = lambda *_a, **_k: Proc(json.dumps({"status": 200, "headers": {}, "body": "ok"}))
        ok_resp = rust_daemon._run_rust_handler(Path("/tmp/bin"), {}, 100)
        assert ok_resp["status"] == 200
    finally:
        rust_daemon.subprocess.run = old_run

    stdout_buffer = io.StringIO()
    stderr_buffer = io.StringIO()
    with redirect_stdout(stdout_buffer), redirect_stderr(stderr_buffer):
        rust_daemon._emit_handler_logs(
            {"fn": "hello", "version": "v2"},
            {"stdout": "line one", "stderr": "warn one\nwarn two"},
        )
    assert "[fn:hello@v2 stdout] line one" in stdout_buffer.getvalue()
    assert "[fn:hello@v2 stderr] warn one" in stderr_buffer.getvalue()
    assert "[fn:hello@v2 stderr] warn two" in stderr_buffer.getvalue()

    old_resolve = rust_daemon._resolve_handler_path
    old_binary = rust_daemon._ensure_rust_binary
    old_env = rust_daemon._read_function_env
    old_run_prepared = rust_daemon._run_prepared_request_persistent
    old_enabled = rust_daemon.ENABLE_RUNTIME_WORKER_POOL
    old_direct = rust_daemon._handle_request_direct
    old_prepare = rust_daemon._prepare_request
    old_read = rust_daemon._read_frame
    old_handle_pool = rust_daemon._handle_request_with_pool

    try:
        rust_daemon._resolve_handler_path = lambda *_a, **_k: Path("/tmp/handler.rs")
        rust_daemon._ensure_rust_binary = lambda _p: Path("/tmp/fn_handler")
        rust_daemon._read_function_env = lambda _p: {"FN_ENV": "1", "UNIT_PROCESS_ENV": "yes"}
        seen = {}

        def fake_run_handler(_pool_key, _path, _binary, event, timeout_ms, settings):
            seen["event"] = event
            seen["timeout_ms"] = timeout_ms
            seen["settings"] = settings
            return {"status": 200, "headers": {}, "body": "ok"}

        rust_daemon._run_prepared_request_persistent = fake_run_handler
        direct_resp = rust_daemon._handle_request_direct(
            {"fn": "demo", "event": {"env": {"A": "2"}, "context": {"timeout_ms": 10}}}
        )
        assert direct_resp["status"] == 200
        assert seen["event"]["env"]["A"] == "2"
        assert seen["event"]["env"]["FN_ENV"] == "1"
        assert seen["timeout_ms"] == 510
        assert seen["settings"]["max_workers"] == 1

        rust_daemon.ENABLE_RUNTIME_WORKER_POOL = False
        rust_daemon._handle_request_direct = lambda _req: {"status": 200, "headers": {}, "body": "direct"}
        fallback_resp = rust_daemon._handle_request_with_pool({"fn": "demo", "event": {}})
        assert fallback_resp["body"] == "direct"

        rust_daemon.ENABLE_RUNTIME_WORKER_POOL = True
        rust_daemon._prepare_request = lambda _req: (Path("/tmp/handler.rs"), Path("/tmp/fn_handler"), {}, 510)
        rust_daemon._run_prepared_request_persistent = lambda *_a, **_k: {"status": 504, "headers": {}, "body": "timeout"}
        timeout_resp = rust_daemon._handle_request_with_pool(
            {"fn": "demo", "event": {"context": {"timeout_ms": 10, "worker_pool": {"enabled": True, "max_workers": 1}}}}
        )
        assert timeout_resp["status"] == 504

        left, right = socket.socketpair()
        with left, right:
            rust_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            rust_daemon._handle_request_with_pool = lambda _r: {"status": 200, "headers": {}, "body": "ok"}
            rust_daemon._serve_conn(left)
            assert _read_frame(right)["status"] == 200

        left, right = socket.socketpair()
        with left, right:
            rust_daemon._read_frame = lambda _c: (_ for _ in ()).throw(ValueError("bad frame"))
            rust_daemon._serve_conn(left)
            err = _read_frame(right)
            assert err["status"] == 400
    finally:
        rust_daemon._resolve_handler_path = old_resolve
        rust_daemon._ensure_rust_binary = old_binary
        rust_daemon._read_function_env = old_env
        rust_daemon._run_prepared_request_persistent = old_run_prepared
        rust_daemon.ENABLE_RUNTIME_WORKER_POOL = old_enabled
        rust_daemon._handle_request_direct = old_direct
        rust_daemon._prepare_request = old_prepare
        rust_daemon._read_frame = old_read
        rust_daemon._handle_request_with_pool = old_handle_pool

    # cover done callback path in _submit_runtime_pool_request with real executor
    executor = rust_daemon.ThreadPoolExecutor(max_workers=1)
    old_pools = rust_daemon._RUNTIME_POOLS
    old_direct = rust_daemon._handle_request_direct
    try:
        pool = {"executor": executor, "pending": 0, "last_used": 0.0}
        key = "unit@default"
        rust_daemon._RUNTIME_POOLS = {key: pool}
        rust_daemon._handle_request_direct = lambda _req: {"status": 200, "headers": {}, "body": "ok"}
        fut = rust_daemon._submit_runtime_pool_request(key, pool, {"fn": "demo", "event": {}})
        assert isinstance(fut, Future)
        out = fut.result(timeout=2)
        assert out["status"] == 200
        assert pool["pending"] == 0
    finally:
        rust_daemon._RUNTIME_POOLS = old_pools
        rust_daemon._handle_request_direct = old_direct
        executor.shutdown(wait=False, cancel_futures=False)


def test_reaper_and_main_paths() -> None:
    # reaper path: evict idle pool and shutdown executor
    old_started = rust_daemon._RUNTIME_POOL_REAPER_STARTED
    old_interval = rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread = rust_daemon.threading.Thread
    old_sleep = rust_daemon.time.sleep
    old_monotonic = rust_daemon.time.monotonic
    old_shutdown = rust_daemon._shutdown_runtime_pool
    old_pools = rust_daemon._RUNTIME_POOLS
    try:
        rust_daemon._RUNTIME_POOL_REAPER_STARTED = False
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        pool = {
            "executor": rust_daemon.ThreadPoolExecutor(max_workers=1),
            "pending": 0,
            "min_warm": 0,
            "idle_ttl_ms": 1,
            "last_used": 1.0,
        }
        rust_daemon._RUNTIME_POOLS = {"idle@default": pool}
        shutdown_calls: list[str] = []
        rust_daemon._shutdown_runtime_pool = lambda _pool: shutdown_calls.append("x")

        sleep_calls = {"n": 0}

        def fake_sleep(_seconds):
            sleep_calls["n"] += 1
            if sleep_calls["n"] > 1:
                raise StopIteration("stop reaper loop")

        rust_daemon.time.sleep = fake_sleep
        rust_daemon.time.monotonic = lambda: 9999.0

        class InlineThread:
            def __init__(self, target=None, **_kwargs):
                self._target = target

            def start(self):
                try:
                    if self._target:
                        self._target()
                except StopIteration:
                    pass

        rust_daemon.threading.Thread = InlineThread
        rust_daemon._start_runtime_pool_reaper()
        assert rust_daemon._RUNTIME_POOL_REAPER_STARTED is True
        assert rust_daemon._RUNTIME_POOLS == {} or "idle@default" not in rust_daemon._RUNTIME_POOLS
        assert shutdown_calls, "reaper should shutdown evicted pools"
    finally:
        try:
            executor = pool.get("executor") if isinstance(pool, dict) else None
            if isinstance(executor, rust_daemon.ThreadPoolExecutor):
                executor.shutdown(wait=False, cancel_futures=False)
        except Exception:
            pass
        rust_daemon._RUNTIME_POOL_REAPER_STARTED = old_started
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        rust_daemon.threading.Thread = old_thread
        rust_daemon.time.sleep = old_sleep
        rust_daemon.time.monotonic = old_monotonic
        rust_daemon._shutdown_runtime_pool = old_shutdown
        rust_daemon._RUNTIME_POOLS = old_pools

    # cover main socket bootstrap/loop with inline fakes
    old_socket = rust_daemon.socket.socket
    old_remove = rust_daemon.os.remove
    old_exists = rust_daemon.os.path.exists
    old_chmod = rust_daemon.os.chmod
    old_thread = rust_daemon.threading.Thread
    old_serve_conn = rust_daemon._serve_conn
    old_ensure_dir = rust_daemon._ensure_socket_dir
    try:
        served: list[str] = []
        rust_daemon._serve_conn = lambda _conn: served.append("conn")
        rust_daemon._ensure_socket_dir = lambda _path: None
        rust_daemon.os.path.exists = lambda _p: True
        rust_daemon.os.remove = lambda _p: None
        rust_daemon.os.chmod = lambda _p, _m: None

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

        rust_daemon.socket.socket = DummyServer
        rust_daemon.threading.Thread = InlineThread
        try:
            rust_daemon.main()
        except KeyboardInterrupt:
            pass
        else:
            raise AssertionError("expected KeyboardInterrupt to break main loop")
        assert served == ["conn"], served
    finally:
        rust_daemon.socket.socket = old_socket
        rust_daemon.os.remove = old_remove
        rust_daemon.os.path.exists = old_exists
        rust_daemon.os.chmod = old_chmod
        rust_daemon.threading.Thread = old_thread
        rust_daemon._serve_conn = old_serve_conn
        rust_daemon._ensure_socket_dir = old_ensure_dir


def test_additional_edge_branches() -> None:
    # _read_function_env missing/invalid/non-object
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "app.rs"
        handler.write_text("pub fn handler(_e: serde_json::Value) -> serde_json::Value { serde_json::json!({}) }\n", encoding="utf-8")
        assert rust_daemon._read_function_env(handler) == {}

        env_path = fn_dir / "fn.env.json"
        env_path.write_text("{bad", encoding="utf-8")
        assert rust_daemon._read_function_env(handler) == {}

        env_path.write_text(json.dumps(["bad"]), encoding="utf-8")
        assert rust_daemon._read_function_env(handler) == {}

        env_path.write_text(json.dumps({"A": "1", "B": {"value": None}, "C": None}), encoding="utf-8")
        assert rust_daemon._read_function_env(handler) == {"A": "1"}

    # _read_frame: incomplete header/payload and non-object request
    left, right = socket.socketpair()
    with left, right:
        right.sendall(b"\x00\x00")
        right.shutdown(socket.SHUT_WR)
        try:
            rust_daemon._read_frame(left)
        except ValueError as exc:
            assert "header" in str(exc).lower()
        else:
            raise AssertionError("expected invalid frame header")

    left, right = socket.socketpair()
    with left, right:
        payload = b'{"ok":true}'
        right.sendall(struct.pack("!I", len(payload) + 2) + payload)
        right.shutdown(socket.SHUT_WR)
        try:
            rust_daemon._read_frame(left)
        except ValueError as exc:
            assert "incomplete" in str(exc).lower()
        else:
            raise AssertionError("expected incomplete frame")

    left, right = socket.socketpair()
    with left, right:
        payload = json.dumps(["bad"]).encode("utf-8")
        right.sendall(struct.pack("!I", len(payload)) + payload)
        right.shutdown(socket.SHUT_WR)
        try:
            rust_daemon._read_frame(left)
        except ValueError as exc:
            assert "object" in str(exc).lower()
        else:
            raise AssertionError("expected object validation error")

    # _resolve_handler_path empty name and _normalize_response edge branches
    try:
        rust_daemon._resolve_handler_path("", None)
    except ValueError:
        pass
    else:
        raise AssertionError("expected invalid empty function name")

    try:
        rust_daemon._normalize_response("bad")
    except ValueError as exc:
        assert "object" in str(exc).lower()
    else:
        raise AssertionError("expected object response error")

    try:
        rust_daemon._normalize_response({"status": 200, "headers": []})
    except ValueError as exc:
        assert "headers" in str(exc).lower()
    else:
        raise AssertionError("expected headers object error")

    norm_body = rust_daemon._normalize_response({"status": 200, "headers": {}, "body": None})
    assert norm_body["body"] == ""
    norm_body2 = rust_daemon._normalize_response({"status": 200, "headers": {}, "body": 123})
    assert norm_body2["body"] == "123"

    # _ensure_rust_binary cargo missing / timeout / missing binary
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "app.rs"
        handler.write_text("pub fn handler(_e: serde_json::Value) -> serde_json::Value { serde_json::json!({}) }\n", encoding="utf-8")
        old_which = rust_daemon.shutil.which
        old_run = rust_daemon.subprocess.run
        old_cache = dict(rust_daemon._BINARY_CACHE)
        try:
            rust_daemon._BINARY_CACHE.clear()
            rust_daemon.shutil.which = lambda _name: None
            try:
                rust_daemon._ensure_rust_binary(handler)
            except RuntimeError as exc:
                assert "cargo not found" in str(exc).lower()
            else:
                raise AssertionError("expected cargo missing error")

            rust_daemon.shutil.which = lambda _name: "/usr/bin/cargo"
            rust_daemon.subprocess.run = lambda *_a, **_k: (_ for _ in ()).throw(
                rust_daemon.subprocess.TimeoutExpired(cmd="cargo", timeout=1)
            )
            try:
                rust_daemon._ensure_rust_binary(handler)
            except RuntimeError as exc:
                assert "timeout" in str(exc).lower()
            else:
                raise AssertionError("expected rust timeout error")

            class Proc:
                returncode = 0
                stdout = ""
                stderr = ""

            rust_daemon.subprocess.run = lambda *_a, **_k: Proc()
            try:
                rust_daemon._ensure_rust_binary(handler)
            except RuntimeError as exc:
                assert "no binary" in str(exc).lower()
            else:
                raise AssertionError("expected missing binary error")
        finally:
            rust_daemon.shutil.which = old_which
            rust_daemon.subprocess.run = old_run
            rust_daemon._BINARY_CACHE.clear()
            rust_daemon._BINARY_CACHE.update(old_cache)

    # worker-pool helper branches
    s = rust_daemon._normalize_worker_pool_settings(
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

    exec1 = rust_daemon.ThreadPoolExecutor(max_workers=1)
    try:
        rust_daemon._shutdown_runtime_pool({"executor": exec1})
        rust_daemon._shutdown_runtime_pool({"executor": object()})
    finally:
        exec1.shutdown(wait=False, cancel_futures=False)

    rust_daemon._warmup_runtime_pool({"min_warm": 0, "executor": object()})
    rust_daemon._warmup_runtime_pool({"min_warm": 1, "executor": object()})
    exec2 = rust_daemon.ThreadPoolExecutor(max_workers=1)
    try:
        rust_daemon._warmup_runtime_pool({"min_warm": 2, "executor": exec2})
    finally:
        exec2.shutdown(wait=False, cancel_futures=False)

    old_pools = rust_daemon._RUNTIME_POOLS
    old_lock = rust_daemon._RUNTIME_POOLS_LOCK
    old_start_reaper = rust_daemon._start_runtime_pool_reaper
    old_warmup = rust_daemon._warmup_runtime_pool
    try:
        rust_daemon._RUNTIME_POOLS = {}
        rust_daemon._RUNTIME_POOLS_LOCK = rust_daemon.threading.Lock()
        rust_daemon._start_runtime_pool_reaper = lambda: None
        rust_daemon._warmup_runtime_pool = lambda _pool: None

        p1 = rust_daemon._ensure_runtime_pool("unit@v1", {"max_workers": 1, "min_warm": 0, "idle_ttl_ms": 1000})
        assert p1["max_workers"] == 1
        p2 = rust_daemon._ensure_runtime_pool("unit@v1", {"max_workers": 1, "min_warm": 1, "idle_ttl_ms": 2000})
        assert p2 is p1 and p2["min_warm"] == 1 and p2["idle_ttl_ms"] == 2000
        p3 = rust_daemon._ensure_runtime_pool("unit@v1", {"max_workers": 2, "min_warm": 0, "idle_ttl_ms": 1000})
        assert p3 is not p2 and p3["max_workers"] == 2
    finally:
        for pool in rust_daemon._RUNTIME_POOLS.values():
            ex = pool.get("executor")
            if isinstance(ex, rust_daemon.ThreadPoolExecutor):
                ex.shutdown(wait=False, cancel_futures=False)
        rust_daemon._RUNTIME_POOLS = old_pools
        rust_daemon._RUNTIME_POOLS_LOCK = old_lock
        rust_daemon._start_runtime_pool_reaper = old_start_reaper
        rust_daemon._warmup_runtime_pool = old_warmup

    try:
        rust_daemon._handle_request_direct({"fn": "demo", "event": "bad"})
    except ValueError as exc:
        assert "event" in str(exc).lower()
    else:
        raise AssertionError("expected event object validation")

    with tempfile.TemporaryDirectory() as tmp:
        path = str(Path(tmp) / "sock" / "fn.sock")
        rust_daemon._ensure_socket_dir(path)
        assert (Path(tmp) / "sock").is_dir()

    # _prepare_socket_path tolerates stat race (socket removed between checks)
    old_stat = rust_daemon.os.stat
    try:
        rust_daemon.os.stat = lambda _p: (_ for _ in ()).throw(FileNotFoundError("gone"))
        rust_daemon._prepare_socket_path("/tmp/fastfn/fn-rust.sock")
    finally:
        rust_daemon.os.stat = old_stat

    old_read = rust_daemon._read_frame
    old_handle = rust_daemon._handle_request_with_pool
    old_write = rust_daemon._write_frame
    try:
        left, right = socket.socketpair()
        with left, right:
            rust_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            rust_daemon._handle_request_with_pool = lambda _r: (_ for _ in ()).throw(FileNotFoundError("missing"))
            rust_daemon._serve_conn(left)
            resp = _read_frame(right)
            assert resp["status"] == 404

        left, right = socket.socketpair()
        with left, right:
            rust_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            rust_daemon._handle_request_with_pool = lambda _r: (_ for _ in ()).throw(RuntimeError("boom"))
            rust_daemon._serve_conn(left)
            resp = _read_frame(right)
            assert resp["status"] == 500

        left, right = socket.socketpair()
        with left, right:
            rust_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            rust_daemon._handle_request_with_pool = lambda _r: {"status": 200, "headers": {}, "body": "ok"}
            rust_daemon._write_frame = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("write failed"))
            rust_daemon._serve_conn(left)
    finally:
        rust_daemon._read_frame = old_read
        rust_daemon._handle_request_with_pool = old_handle
        rust_daemon._write_frame = old_write

    # _read_function_env: non-string keys are skipped.
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "app.rs"
        handler.write_text("pub fn handler(_e: serde_json::Value) -> serde_json::Value { serde_json::json!({}) }\n", encoding="utf-8")
        env_path = fn_dir / "fn.env.json"
        env_path.write_text("{}", encoding="utf-8")
        old_loads = rust_daemon.json.loads
        try:
            rust_daemon.json.loads = lambda _raw: {1: "x", "OK": "1"}
            assert rust_daemon._read_function_env(handler) == {"OK": "1"}
        finally:
            rust_daemon.json.loads = old_loads

    # _patched_process_env stores per-request env in thread-local storage
    # instead of mutating global os.environ (security fix for concurrency).
    old_prev = os.environ.get("UNIT_PREV")
    os.environ["UNIT_PREV"] = "old"
    try:
        with rust_daemon._patched_process_env({1: "x", "": "y", "UNIT_PREV": "new", "UNIT_NONE": None}):
            # Overrides are in thread-local, visible via _build_subprocess_env
            sub_env = rust_daemon._build_subprocess_env()
            assert sub_env.get("UNIT_PREV") == "new"
            assert "UNIT_NONE" not in sub_env
            # Global os.environ is NOT mutated (security invariant)
            assert os.environ.get("UNIT_PREV") == "old"
        # After context exit, overrides are cleared
        sub_env_after = rust_daemon._build_subprocess_env()
        assert sub_env_after.get("UNIT_PREV") == "old"
    finally:
        if old_prev is None:
            os.environ.pop("UNIT_PREV", None)
        else:
            os.environ["UNIT_PREV"] = old_prev

    # _resolve_handler_path fallback + invalid version + unknown function.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        old_functions = rust_daemon.FUNCTIONS_DIR
        old_runtime = rust_daemon.RUNTIME_FUNCTIONS_DIR
        try:
            rust_daemon.FUNCTIONS_DIR = root
            rust_daemon.RUNTIME_FUNCTIONS_DIR = root / "rust"
            try:
                rust_daemon._resolve_handler_path("missing", "bad/version")
            except ValueError as exc:
                assert "version" in str(exc).lower()
            else:
                raise AssertionError("expected invalid version error")
            try:
                rust_daemon._resolve_handler_path("missing", None)
            except FileNotFoundError:
                pass
            else:
                raise AssertionError("expected unknown function error")
            (root / "rust").mkdir(parents=True, exist_ok=True)
            (root / "rust" / "runtime-only.rs").write_text("// rt", encoding="utf-8")
            assert rust_daemon._resolve_handler_path("runtime-only.rs", None) == root / "rust" / "runtime-only.rs"
        finally:
            rust_daemon.FUNCTIONS_DIR = old_functions
            rust_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime

    try:
        rust_daemon._normalize_response({"status": 200, "headers": {}, "is_base64": True, "body_base64": ""})
    except ValueError as exc:
        assert "body_base64" in str(exc)
    else:
        raise AssertionError("expected invalid body_base64")

    # _ensure_rust_binary cached/hot-reload branch.
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.rs"
        handler.write_text("pub fn handler(_e: serde_json::Value) -> serde_json::Value { serde_json::json!({}) }\n", encoding="utf-8")
        binary = Path(tmp) / "fn_handler"
        binary.write_bytes(b"\x7fELF" + b"\x00" * 100)
        binary.chmod(0o755)
        old_hot = rust_daemon.HOT_RELOAD
        old_cache = dict(rust_daemon._BINARY_CACHE)
        old_which_hr = rust_daemon.shutil.which
        try:
            rust_daemon.shutil.which = lambda _name: "/usr/bin/cargo"
            rust_daemon.HOT_RELOAD = True
            rust_daemon._BINARY_CACHE.clear()
            rust_daemon._BINARY_CACHE[str(handler)] = {
                "signature": {
                    "source_mtime_ns": handler.stat().st_mtime_ns,
                    "main_rs_hash": rust_daemon._MAIN_RS_DIGEST,
                    "cargo_toml_hash": rust_daemon._CARGO_TOML_DIGEST,
                    "runtime_platform": rust_daemon.sys.platform,
                    "runtime_machine": rust_daemon.platform.machine(),
                },
                "binary": str(binary),
            }
            assert rust_daemon._ensure_rust_binary(handler) == binary
        finally:
            rust_daemon.HOT_RELOAD = old_hot
            rust_daemon._BINARY_CACHE.clear()
            rust_daemon._BINARY_CACHE.update(old_cache)
            rust_daemon.shutil.which = old_which_hr

    # _run_rust_handler includes stderr when present.
    class _Proc:
        def __init__(self, stdout: str, stderr: str):
            self.stdout = stdout
            self.stderr = stderr
            self.returncode = 0

    old_run = rust_daemon.subprocess.run
    try:
        rust_daemon.subprocess.run = lambda *_a, **_k: _Proc(json.dumps({"status": 200, "headers": {}, "body": "ok"}), "warn")
        out = rust_daemon._run_rust_handler(Path("/tmp/bin"), {}, 200)
        assert out.get("stderr") == "warn"
    finally:
        rust_daemon.subprocess.run = old_run

    # _normalize_worker_pool_settings acquire_timeout floor branch + min_warm cap.
    old_acquire = rust_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS
    try:
        rust_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = 0
        settings = rust_daemon._normalize_worker_pool_settings({"event": {"context": {"worker_pool": {"max_workers": 1}}}})
        assert settings["acquire_timeout_ms"] == 100
        capped = rust_daemon._normalize_worker_pool_settings(
            {"event": {"context": {"worker_pool": {"max_workers": 2, "min_warm": 5}}}}
        )
        assert capped["min_warm"] == 2
    finally:
        rust_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = old_acquire

    # _start_runtime_pool_reaper early exits.
    old_started = rust_daemon._RUNTIME_POOL_REAPER_STARTED
    old_interval = rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    try:
        rust_daemon._RUNTIME_POOL_REAPER_STARTED = True
        rust_daemon._start_runtime_pool_reaper()
        rust_daemon._RUNTIME_POOL_REAPER_STARTED = False
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 0
        rust_daemon._start_runtime_pool_reaper()
    finally:
        rust_daemon._RUNTIME_POOL_REAPER_STARTED = old_started
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval

    # _warmup_runtime_pool tolerates future failures.
    exec3 = rust_daemon.ThreadPoolExecutor(max_workers=1)
    old_submit = exec3.submit
    try:
        class _BadFuture:
            def result(self, timeout=None):  # noqa: ARG002
                raise RuntimeError("boom")

        exec3.submit = lambda *_a, **_k: _BadFuture()
        rust_daemon._warmup_runtime_pool({"min_warm": 1, "executor": exec3})
    finally:
        exec3.submit = old_submit
        exec3.shutdown(wait=False, cancel_futures=False)

    # _submit_runtime_pool_request invalid executor + missing current pool callback.
    try:
        rust_daemon._submit_runtime_pool_request("x", {"executor": object()}, {"fn": "demo", "event": {}})
    except RuntimeError as exc:
        assert "executor" in str(exc).lower()
    else:
        raise AssertionError("expected invalid executor error")

    old_pools = rust_daemon._RUNTIME_POOLS
    old_direct = rust_daemon._handle_request_direct
    exec4 = rust_daemon.ThreadPoolExecutor(max_workers=1)
    try:
        started = rust_daemon.threading.Event()
        release = rust_daemon.threading.Event()

        def _slow_ok(_req):
            started.set()
            release.wait(timeout=2)
            return {"status": 200, "headers": {}, "body": "ok"}

        pool = {"executor": exec4, "pending": 0, "last_used": 0.0}
        rust_daemon._RUNTIME_POOLS = {"gone@v1": pool}
        rust_daemon._handle_request_direct = _slow_ok
        fut = rust_daemon._submit_runtime_pool_request("gone@v1", pool, {"fn": "demo", "event": {}})
        assert started.wait(timeout=2)
        rust_daemon._RUNTIME_POOLS = {}
        release.set()
        assert fut.result(timeout=2)["status"] == 200
    finally:
        rust_daemon._RUNTIME_POOLS = old_pools
        rust_daemon._handle_request_direct = old_direct
        exec4.shutdown(wait=False, cancel_futures=False)

    # _start_runtime_pool_reaper inner-loop continue branch (pending/min_warm > 0).
    old_started = rust_daemon._RUNTIME_POOL_REAPER_STARTED
    old_interval = rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread_cls = rust_daemon.threading.Thread
    old_sleep = rust_daemon.time.sleep
    old_mono = rust_daemon.time.monotonic
    old_shutdown_pool = rust_daemon._shutdown_runtime_pool
    old_pools = rust_daemon._RUNTIME_POOLS
    try:
        sleep_calls = {"n": 0}
        shutdown_calls = {"n": 0}

        def _fake_sleep(_seconds):
            sleep_calls["n"] += 1
            if sleep_calls["n"] > 1:
                raise RuntimeError("stop-reaper")

        def _fake_shutdown(_pool):
            shutdown_calls["n"] += 1

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

        rust_daemon._RUNTIME_POOLS = {
            "pending@v1": {"pending": 1, "min_warm": 0, "idle_ttl_ms": 1, "last_used": 0.0},
            "warm@v1": {"pending": 0, "min_warm": 1, "idle_ttl_ms": 1, "last_used": 0.0},
        }
        rust_daemon._RUNTIME_POOL_REAPER_STARTED = False
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        rust_daemon.threading.Thread = _InlineThread
        rust_daemon.time.sleep = _fake_sleep
        rust_daemon.time.monotonic = lambda: 10.0
        rust_daemon._shutdown_runtime_pool = _fake_shutdown
        rust_daemon._start_runtime_pool_reaper()
        assert shutdown_calls["n"] == 0
    finally:
        rust_daemon._RUNTIME_POOLS = old_pools
        rust_daemon._RUNTIME_POOL_REAPER_STARTED = old_started
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        rust_daemon.threading.Thread = old_thread_cls
        rust_daemon.time.sleep = old_sleep
        rust_daemon.time.monotonic = old_mono
        rust_daemon._shutdown_runtime_pool = old_shutdown_pool

    # _handle_request_direct fn required branch.
    try:
        rust_daemon._handle_request_direct({"event": {}})
    except ValueError as exc:
        assert "fn is required" in str(exc).lower()
    else:
        raise AssertionError("expected fn is required error")

    # _prepare_socket_path non-socket / stale socket / in-use socket branches.
    with tempfile.TemporaryDirectory() as tmp:
        not_socket = Path(tmp) / "plain.file"
        not_socket.write_text("x", encoding="utf-8")
        try:
            rust_daemon._prepare_socket_path(str(not_socket))
        except RuntimeError as exc:
            assert "not a unix socket" in str(exc).lower()
        else:
            raise AssertionError("expected non-socket error")

    old_stat = rust_daemon.os.stat
    old_socket_ctor = rust_daemon.socket.socket
    old_remove = rust_daemon.os.remove
    try:
        class _SockStat:
            st_mode = rust_daemon.stat.S_IFSOCK

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

        rust_daemon.os.stat = lambda _p: _SockStat()
        rust_daemon.socket.socket = lambda *_a, **_k: _Probe(False)
        rust_daemon.os.remove = lambda _p: (_ for _ in ()).throw(FileNotFoundError())
        rust_daemon._prepare_socket_path("/tmp/fn-rust.sock")

        rust_daemon.socket.socket = lambda *_a, **_k: _Probe(True)
        try:
            rust_daemon._prepare_socket_path("/tmp/fn-rust.sock")
        except RuntimeError as exc:
            assert "already in use" in str(exc).lower()
        else:
            raise AssertionError("expected in-use socket error")
    finally:
        rust_daemon.os.stat = old_stat
        rust_daemon.socket.socket = old_socket_ctor
        rust_daemon.os.remove = old_remove


def test_rust_main_rs_merges_params_into_event() -> None:
    """Rust main.rs template merges event.params into top-level event."""
    main_rs = rust_daemon._MAIN_RS
    assert 'event.get("params").cloned()' in main_rs or "event.get(\\\"params\\\").cloned()" in main_rs, \
        "main.rs must extract params from event"
    assert "as_object_mut" in main_rs, \
        "main.rs must use as_object_mut to merge params"
    assert "contains_key" in main_rs or "or_insert" in main_rs, \
        "main.rs must avoid overwriting existing event keys when merging params"


def test_rust_handle_request_passes_params_through() -> None:
    """Params in event should be passed through to the Rust handler."""
    old_resolve = rust_daemon._resolve_handler_path
    old_binary = rust_daemon._ensure_rust_binary
    old_env = rust_daemon._read_function_env
    old_run_prepared = rust_daemon._run_prepared_request_persistent
    seen = {}
    try:
        rust_daemon._resolve_handler_path = lambda *_a, **_k: Path("/tmp/handler.rs")
        rust_daemon._ensure_rust_binary = lambda _p: Path("/tmp/fn_handler")
        rust_daemon._read_function_env = lambda _p: {}

        def fake_run(_pool_key, _handler_path, _binary, event, timeout_ms, settings):
            seen["event"] = event
            seen["settings"] = settings
            return {"status": 200, "headers": {}, "body": "ok"}

        rust_daemon._run_prepared_request_persistent = fake_run
        resp = rust_daemon._handle_request_direct(
            {"fn": "demo", "event": {"params": {"id": "42", "slug": "test"}}}
        )
        assert resp["status"] == 200
        assert seen["event"]["params"]["id"] == "42"
        assert seen["event"]["params"]["slug"] == "test"
        assert seen["settings"]["max_workers"] == 1
    finally:
        rust_daemon._resolve_handler_path = old_resolve
        rust_daemon._ensure_rust_binary = old_binary
        rust_daemon._read_function_env = old_env
        rust_daemon._run_prepared_request_persistent = old_run_prepared


def test_persistent_pool_lifecycle() -> None:
    """Cover persistent pool: create, checkout, release, discard, shutdown, reaper, binary checks."""
    import threading as _threading

    # _handler_signature covers existing and missing file branches.
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "app.rs"
        handler.write_text("pub fn handler(_e: serde_json::Value) -> serde_json::Value { serde_json::json!({}) }\n", encoding="utf-8")
        sig = rust_daemon._handler_signature(handler)
        assert isinstance(sig, str)
        assert "missing" in sig  # fn.env.json is missing

    # _file_signature: existing and missing.
    with tempfile.TemporaryDirectory() as tmp:
        existing = Path(tmp) / "f.txt"
        existing.write_text("x", encoding="utf-8")
        sig = rust_daemon._file_signature(existing)
        assert sig is not None and len(sig) == 2
        assert rust_daemon._file_signature(Path("/nonexistent/file.txt")) is None

    # _binary_looks_native: non-file, non-executable, bad header.
    with tempfile.TemporaryDirectory() as tmp:
        non_exec = Path(tmp) / "not-exec"
        non_exec.write_text("x", encoding="utf-8")
        assert rust_daemon._binary_looks_native(non_exec) is False

        assert rust_daemon._binary_looks_native(Path("/nonexistent/bin")) is False

    # _shutdown_persistent_runtime_pool with non-list workers, non-dict entries, and non-worker objects.
    rust_daemon._shutdown_persistent_runtime_pool({"workers": "bad"})
    rust_daemon._shutdown_persistent_runtime_pool({"workers": [None, "not-dict", {"worker": "not-a-worker"}]})
    rust_daemon._shutdown_persistent_runtime_pool({"workers": []})

    # _warmup_persistent_runtime_pool branches: target <= 0, bad cond, bad workers.
    rust_daemon._warmup_persistent_runtime_pool({"min_warm": 0})
    rust_daemon._warmup_persistent_runtime_pool({"min_warm": 1, "cond": "bad"})
    lock = _threading.Lock()
    cond = _threading.Condition(lock)
    rust_daemon._warmup_persistent_runtime_pool({"min_warm": 1, "cond": cond, "workers": "bad"})

    # _checkout_persistent_runtime_worker: bad cond and bad workers.
    try:
        rust_daemon._checkout_persistent_runtime_worker({"cond": "bad"}, 100)
    except RuntimeError as exc:
        assert "invalid persistent" in str(exc).lower()
    else:
        raise AssertionError("expected invalid persistent runtime pool error")

    lock2 = _threading.Lock()
    cond2 = _threading.Condition(lock2)
    try:
        rust_daemon._checkout_persistent_runtime_worker({"cond": cond2, "workers": "bad"}, 100)
    except RuntimeError as exc:
        assert "workers" in str(exc).lower()
    else:
        raise AssertionError("expected invalid workers error")

    # _checkout_persistent_runtime_worker: timeout when all workers are busy and max reached.
    lock3 = _threading.Lock()
    cond3 = _threading.Condition(lock3)

    # Create a fake worker that passes isinstance check by subclassing.
    _OrigRustWorker = rust_daemon._PersistentRustWorker

    class _FakeRustWorker(_OrigRustWorker):
        __slots__ = ()

        def __init__(self, is_alive=True):
            # Skip real __init__ to avoid subprocess spawn.
            self._dead = not is_alive
            self.lock = _threading.Lock()

        @property
        def alive(self):
            return not self._dead

        def shutdown(self):
            self._dead = True

    alive_worker = _FakeRustWorker(True)
    busy_entry = {"worker": alive_worker, "busy": True, "last_used": 0.0}
    pool = {"cond": cond3, "workers": [busy_entry], "max_workers": 1, "last_used": 0.0, "binary": Path("/tmp/fn_handler")}
    try:
        rust_daemon._checkout_persistent_runtime_worker(pool, 50)
    except TimeoutError:
        pass
    else:
        raise AssertionError("expected timeout on busy pool")

    # _checkout_persistent_runtime_worker: stale worker cleanup.
    lock4 = _threading.Lock()
    cond4 = _threading.Condition(lock4)
    dead_worker = _FakeRustWorker(False)
    alive_worker2 = _FakeRustWorker(True)
    stale_entry = {"worker": dead_worker, "busy": False, "last_used": 0.0}
    free_entry = {"worker": alive_worker2, "busy": False, "last_used": 0.0}
    pool2 = {"cond": cond4, "workers": [stale_entry, free_entry], "max_workers": 2, "last_used": 0.0}
    result = rust_daemon._checkout_persistent_runtime_worker(pool2, 1000)
    assert result is free_entry
    assert result["busy"] is True

    # _release_persistent_runtime_worker: normal release, discard, bad cond, bad workers, entry not in workers.
    rust_daemon._release_persistent_runtime_worker({"cond": "bad"}, {})
    lock5 = _threading.Lock()
    cond5 = _threading.Condition(lock5)
    rust_daemon._release_persistent_runtime_worker({"cond": cond5, "workers": "bad"}, {})

    alive_worker3 = _FakeRustWorker(True)
    entry3 = {"worker": alive_worker3, "busy": True, "last_used": 0.0}
    pool3 = {"cond": cond5, "workers": [entry3], "last_used": 0.0}
    rust_daemon._release_persistent_runtime_worker(pool3, entry3, discard=False)
    assert entry3["busy"] is False

    alive_worker4 = _FakeRustWorker(True)
    entry4 = {"worker": alive_worker4, "busy": True, "last_used": 0.0}
    pool4 = {"cond": cond5, "workers": [entry4], "last_used": 0.0}
    rust_daemon._release_persistent_runtime_worker(pool4, entry4, discard=True)
    assert entry4 not in pool4["workers"]

    # _release_persistent_runtime_worker: dead worker gets discarded even without discard=True.
    dead_worker2 = _FakeRustWorker(False)
    entry5 = {"worker": dead_worker2, "busy": True, "last_used": 0.0}
    pool5 = {"cond": cond5, "workers": [entry5], "last_used": 0.0}
    rust_daemon._release_persistent_runtime_worker(pool5, entry5, discard=False)
    assert entry5 not in pool5["workers"]

    # _release_persistent_runtime_worker: entry not in workers list (no-op).
    pool6 = {"cond": cond5, "workers": [], "last_used": 0.0}
    rust_daemon._release_persistent_runtime_worker(pool6, {"worker": _FakeRustWorker(True), "busy": True})

    # _start_persistent_runtime_pool_reaper: early exits.
    old_started = rust_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED
    old_interval = rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    try:
        rust_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = True
        rust_daemon._start_persistent_runtime_pool_reaper()
        rust_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 0
        rust_daemon._start_persistent_runtime_pool_reaper()
    finally:
        rust_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = old_started
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval

    # _start_persistent_runtime_pool_reaper: actual eviction.
    old_started = rust_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED
    old_interval = rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread = rust_daemon.threading.Thread
    old_sleep = rust_daemon.time.sleep
    old_monotonic = rust_daemon.time.monotonic
    old_shutdown = rust_daemon._shutdown_persistent_runtime_pool
    old_pools = rust_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        rust_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        evicted_pools: list[str] = []

        persistent_pool = {
            "pending": 0,
            "min_warm": 0,
            "idle_ttl_ms": 1,
            "last_used": 1.0,
            "workers": [],
        }
        rust_daemon._PERSISTENT_RUNTIME_POOLS = {"idle-persistent@v1": persistent_pool}
        rust_daemon._shutdown_persistent_runtime_pool = lambda _p: evicted_pools.append("evicted")

        sleep_calls = {"n": 0}

        def fake_sleep(_seconds):
            sleep_calls["n"] += 1
            if sleep_calls["n"] > 1:
                raise StopIteration("stop")

        rust_daemon.time.sleep = fake_sleep
        rust_daemon.time.monotonic = lambda: 9999.0

        class InlineThread:
            def __init__(self, target=None, **_kwargs):
                self._target = target

            def start(self):
                try:
                    if self._target:
                        self._target()
                except StopIteration:
                    pass

        rust_daemon.threading.Thread = InlineThread
        rust_daemon._start_persistent_runtime_pool_reaper()
        assert rust_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED is True
        assert evicted_pools, "persistent reaper should evict idle pools"
    finally:
        rust_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = old_started
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        rust_daemon.threading.Thread = old_thread
        rust_daemon.time.sleep = old_sleep
        rust_daemon.time.monotonic = old_monotonic
        rust_daemon._shutdown_persistent_runtime_pool = old_shutdown
        rust_daemon._PERSISTENT_RUNTIME_POOLS = old_pools

    # persistent reaper skips pools with pending > 0 or min_warm > 0.
    old_started = rust_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED
    old_interval = rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread = rust_daemon.threading.Thread
    old_sleep = rust_daemon.time.sleep
    old_monotonic = rust_daemon.time.monotonic
    old_shutdown = rust_daemon._shutdown_persistent_runtime_pool
    old_pools = rust_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        rust_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        shutdown_calls_inner = {"n": 0}

        rust_daemon._PERSISTENT_RUNTIME_POOLS = {
            "pending@v1": {"pending": 1, "min_warm": 0, "idle_ttl_ms": 1, "last_used": 0.0, "workers": []},
            "warm@v1": {"pending": 0, "min_warm": 1, "idle_ttl_ms": 1, "last_used": 0.0, "workers": []},
        }
        rust_daemon._shutdown_persistent_runtime_pool = lambda _p: shutdown_calls_inner.update(n=shutdown_calls_inner["n"] + 1)

        sleep_calls2 = {"n": 0}

        def fake_sleep2(_seconds):
            sleep_calls2["n"] += 1
            if sleep_calls2["n"] > 1:
                raise RuntimeError("stop-reaper")

        rust_daemon.time.sleep = fake_sleep2
        rust_daemon.time.monotonic = lambda: 10.0

        class InlineThread2:
            def __init__(self, *, target=None, **_kwargs):
                self._target = target

            def start(self):
                try:
                    if self._target is not None:
                        self._target()
                except RuntimeError as exc:
                    if str(exc) != "stop-reaper":
                        raise

        rust_daemon.threading.Thread = InlineThread2
        rust_daemon._start_persistent_runtime_pool_reaper()
        assert shutdown_calls_inner["n"] == 0
    finally:
        rust_daemon._PERSISTENT_RUNTIME_POOLS = old_pools
        rust_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = old_started
        rust_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        rust_daemon.threading.Thread = old_thread
        rust_daemon.time.sleep = old_sleep
        rust_daemon.time.monotonic = old_monotonic
        rust_daemon._shutdown_persistent_runtime_pool = old_shutdown

    # _ensure_persistent_runtime_pool: create new, reuse existing, replace with different max_workers.
    old_pools = rust_daemon._PERSISTENT_RUNTIME_POOLS
    old_lock = rust_daemon._PERSISTENT_RUNTIME_POOLS_LOCK
    old_start_reaper = rust_daemon._start_persistent_runtime_pool_reaper
    old_warmup = rust_daemon._warmup_persistent_runtime_pool
    old_shutdown = rust_daemon._shutdown_persistent_runtime_pool
    try:
        rust_daemon._PERSISTENT_RUNTIME_POOLS = {}
        rust_daemon._PERSISTENT_RUNTIME_POOLS_LOCK = _threading.Lock()
        rust_daemon._start_persistent_runtime_pool_reaper = lambda: None
        rust_daemon._warmup_persistent_runtime_pool = lambda _pool: None
        stale_shutdowns: list[str] = []
        rust_daemon._shutdown_persistent_runtime_pool = lambda _p: stale_shutdowns.append("x")

        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "app.rs"
            handler.write_text("pub fn handler() {}", encoding="utf-8")
            binary = Path(tmp) / "fn_handler"
            binary.write_text("bin", encoding="utf-8")

            p1 = rust_daemon._ensure_persistent_runtime_pool(
                "test@v1", handler, binary,
                {"max_workers": 2, "min_warm": 0, "idle_ttl_ms": 1000, "acquire_timeout_ms": 5000}
            )
            assert p1["max_workers"] == 2

            p2 = rust_daemon._ensure_persistent_runtime_pool(
                "test@v1", handler, binary,
                {"max_workers": 2, "min_warm": 1, "idle_ttl_ms": 2000, "acquire_timeout_ms": 5000}
            )
            assert p2 is p1
            assert p2["min_warm"] == 1
            assert p2["idle_ttl_ms"] == 2000

            p3 = rust_daemon._ensure_persistent_runtime_pool(
                "test@v1", handler, binary,
                {"max_workers": 4, "min_warm": 0, "idle_ttl_ms": 1000, "acquire_timeout_ms": 5000}
            )
            assert p3 is not p1
            assert p3["max_workers"] == 4
            assert stale_shutdowns, "old pool should be shut down"
    finally:
        rust_daemon._PERSISTENT_RUNTIME_POOLS = old_pools
        rust_daemon._PERSISTENT_RUNTIME_POOLS_LOCK = old_lock
        rust_daemon._start_persistent_runtime_pool_reaper = old_start_reaper
        rust_daemon._warmup_persistent_runtime_pool = old_warmup
        rust_daemon._shutdown_persistent_runtime_pool = old_shutdown

    # _run_prepared_request_persistent: timeout and generic exception paths.
    old_ensure = rust_daemon._ensure_persistent_runtime_pool
    old_checkout = rust_daemon._checkout_persistent_runtime_worker
    old_release = rust_daemon._release_persistent_runtime_worker
    old_pools = rust_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        fake_pool = {
            "cond": _threading.Condition(_threading.Lock()),
            "workers": [],
            "max_workers": 1,
            "pending": 0,
            "last_used": 0.0,
        }
        rust_daemon._ensure_persistent_runtime_pool = lambda *_a, **_k: fake_pool
        rust_daemon._PERSISTENT_RUNTIME_POOLS = {"test-key": fake_pool}

        rust_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: (_ for _ in ()).throw(TimeoutError("timeout"))
        resp = rust_daemon._run_prepared_request_persistent(
            "test-key", Path("/tmp/handler.rs"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp["status"] == 504

        rust_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("generic error"))
        resp2 = rust_daemon._run_prepared_request_persistent(
            "test-key", Path("/tmp/handler.rs"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp2["status"] == 500
    finally:
        rust_daemon._ensure_persistent_runtime_pool = old_ensure
        rust_daemon._checkout_persistent_runtime_worker = old_checkout
        rust_daemon._release_persistent_runtime_worker = old_release
        rust_daemon._PERSISTENT_RUNTIME_POOLS = old_pools

    # _append_runtime_log: cover writing to file and exception path.
    old_log = rust_daemon.RUNTIME_LOG_FILE
    try:
        rust_daemon.RUNTIME_LOG_FILE = ""
        rust_daemon._append_runtime_log("rust", "should no-op")

        with tempfile.TemporaryDirectory() as tmp:
            log_path = str(Path(tmp) / "test.log")
            rust_daemon.RUNTIME_LOG_FILE = log_path
            rust_daemon._append_runtime_log("rust", "test line")
            assert Path(log_path).read_text(encoding="utf-8") == "[rust] test line\n"

        rust_daemon.RUNTIME_LOG_FILE = "/nonexistent/path/log.txt"
        rust_daemon._append_runtime_log("rust", "should not crash")
    finally:
        rust_daemon.RUNTIME_LOG_FILE = old_log

    # _emit_handler_logs: non-dict resp and empty/missing stdout/stderr.
    stdout_buf = io.StringIO()
    stderr_buf = io.StringIO()
    with redirect_stdout(stdout_buf), redirect_stderr(stderr_buf):
        rust_daemon._emit_handler_logs({}, "bad-resp")
        rust_daemon._emit_handler_logs({}, {"stdout": "", "stderr": ""})
        rust_daemon._emit_handler_logs({}, {"stdout": None, "stderr": None})
        rust_daemon._emit_handler_logs({}, {})
    assert stdout_buf.getvalue() == ""
    assert stderr_buf.getvalue() == ""

    # _resolve_command: path-based, name-based, and missing.
    old_env_val = os.environ.get("FN_TEST_RESOLVE")
    old_which = rust_daemon.shutil.which
    try:
        os.environ["FN_TEST_RESOLVE"] = "/usr/bin/python3"
        if Path("/usr/bin/python3").is_file():
            result = rust_daemon._resolve_command("FN_TEST_RESOLVE", "python3")
            assert result == "/usr/bin/python3"

        os.environ["FN_TEST_RESOLVE"] = "/nonexistent/binary"
        try:
            rust_daemon._resolve_command("FN_TEST_RESOLVE", "python3")
        except RuntimeError as exc:
            assert "not executable" in str(exc).lower()
        else:
            raise AssertionError("expected not executable error")

        os.environ["FN_TEST_RESOLVE"] = "nonexistent-binary-name"
        rust_daemon.shutil.which = lambda _name: None
        try:
            rust_daemon._resolve_command("FN_TEST_RESOLVE", "python3")
        except RuntimeError as exc:
            assert "not found" in str(exc).lower()
        else:
            raise AssertionError("expected not found error")

        os.environ.pop("FN_TEST_RESOLVE", None)
        rust_daemon.shutil.which = lambda _name: None
        try:
            rust_daemon._resolve_command("FN_TEST_RESOLVE", "nonexistent-default")
        except RuntimeError as exc:
            assert "not found" in str(exc).lower()
        else:
            raise AssertionError("expected default not found error")

        os.environ.pop("FN_TEST_RESOLVE", None)
        rust_daemon.shutil.which = lambda _name: "/usr/bin/python3"
        result = rust_daemon._resolve_command("FN_TEST_RESOLVE", "python3")
        assert result == "/usr/bin/python3"
    finally:
        if old_env_val is None:
            os.environ.pop("FN_TEST_RESOLVE", None)
        else:
            os.environ["FN_TEST_RESOLVE"] = old_env_val
        rust_daemon.shutil.which = old_which

    # _recvall: partial read with connection close.
    left, right = socket.socketpair()
    with left, right:
        right.sendall(b"\x01\x02")
        right.shutdown(socket.SHUT_WR)
        data = rust_daemon._recvall(left, 4)
        assert len(data) == 2

    # _error_response shape check.
    err = rust_daemon._error_response("test error", status=418)
    assert err["status"] == 418
    assert "test error" in err["body"]

    # _patched_process_env with empty dict and None (no-op yield).
    with rust_daemon._patched_process_env({}):
        pass
    with rust_daemon._patched_process_env(None):
        pass

    # _normalize_worker_pool_settings: context is not dict.
    s = rust_daemon._normalize_worker_pool_settings({"event": {"context": "bad"}})
    assert s["enabled"] is False
    assert s["max_workers"] == 0

    # _normalize_worker_pool_settings: worker_pool is not dict.
    s2 = rust_daemon._normalize_worker_pool_settings({"event": {"context": {"worker_pool": "bad"}}})
    assert s2["enabled"] is False

    # _normalize_worker_pool_settings: enabled explicitly False.
    s3 = rust_daemon._normalize_worker_pool_settings(
        {"event": {"context": {"worker_pool": {"enabled": False, "max_workers": 2}}}}
    )
    assert s3["enabled"] is False

    # _ensure_rust_binary: non-native binary after successful build.
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "app.rs"
        handler.write_text("pub fn handler(_e: serde_json::Value) -> serde_json::Value { serde_json::json!({}) }\n", encoding="utf-8")
        old_which = rust_daemon.shutil.which
        old_run = rust_daemon.subprocess.run
        old_cache = dict(rust_daemon._BINARY_CACHE)
        try:
            rust_daemon._BINARY_CACHE.clear()
            rust_daemon.shutil.which = lambda _name: "/usr/bin/cargo"

            class Proc:
                returncode = 0
                stdout = ""
                stderr = ""

            def fake_run(cmd, capture_output, text, cwd, timeout, check):
                out = Path(cwd) / "target" / "release"
                out.mkdir(parents=True, exist_ok=True)
                bin_path = out / "fn_handler"
                bin_path.write_text("not-a-real-binary", encoding="utf-8")
                bin_path.chmod(0o755)
                return Proc()

            rust_daemon.subprocess.run = fake_run
            try:
                rust_daemon._ensure_rust_binary(handler)
            except RuntimeError as exc:
                assert "non-native" in str(exc).lower()
            else:
                raise AssertionError("expected non-native binary error")
        finally:
            rust_daemon.shutil.which = old_which
            rust_daemon.subprocess.run = old_run
            rust_daemon._BINARY_CACHE.clear()
            rust_daemon._BINARY_CACHE.update(old_cache)

    # _runtime_pool_key coverage.
    assert rust_daemon._runtime_pool_key("x", None) == "x@default"
    assert rust_daemon._runtime_pool_key(None, None) == "unknown@default"
    assert rust_daemon._runtime_pool_key("fn", "v2") == "fn@v2"


def test_remaining_coverage_gaps() -> None:
    """Cover remaining uncovered lines to reach 100% coverage."""
    import threading as _threading
    import time as _time

    # Line 206: _resolve_command where env is a bare name and shutil.which succeeds.
    old_env = os.environ.get("FN_TEST_RESOLVE_BARE")
    old_which = rust_daemon.shutil.which
    try:
        os.environ["FN_TEST_RESOLVE_BARE"] = "some-bare-cmd"
        rust_daemon.shutil.which = lambda _name: "/usr/bin/found-it"
        result = rust_daemon._resolve_command("FN_TEST_RESOLVE_BARE", "default")
        assert result == "/usr/bin/found-it"
    finally:
        os.environ.pop("FN_TEST_RESOLVE_BARE", None)
        if old_env is not None:
            os.environ["FN_TEST_RESOLVE_BARE"] = old_env
        rust_daemon.shutil.which = old_which

    # Lines 307-309: _build_subprocess_env with extra dict.
    env = rust_daemon._build_subprocess_env(extra={"MY_EXTRA_VAR": "hello", "": "skip", "ANOTHER": None})
    assert env.get("MY_EXTRA_VAR") == "hello"
    assert env.get("ANOTHER") == ""
    assert "" not in env

    # Lines 473-474: _load_metadata returns None on invalid JSON.
    # We trigger this by writing bad JSON to the metadata file and calling _ensure_rust_binary.
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "app.rs"
        handler.write_text("pub fn handler(_e: serde_json::Value) -> serde_json::Value { serde_json::json!({}) }\n", encoding="utf-8")
        build_dir = Path(tmp) / ".rust-build"
        src_dir = build_dir / "src"
        src_dir.mkdir(parents=True, exist_ok=True)
        meta_path = build_dir / ".fastfn-build-meta.json"
        meta_path.write_text("{{{invalid json", encoding="utf-8")

        old_which = rust_daemon.shutil.which
        old_run = rust_daemon.subprocess.run
        old_cache = dict(rust_daemon._BINARY_CACHE)
        try:
            rust_daemon._BINARY_CACHE.clear()
            rust_daemon.shutil.which = lambda _name: "/usr/bin/cargo"

            class Proc:
                returncode = 0
                stdout = ""
                stderr = ""

            def fake_run(cmd, capture_output, text, cwd, timeout, check):
                out = Path(cwd) / "target" / "release"
                out.mkdir(parents=True, exist_ok=True)
                bin_path = out / "fn_handler"
                bin_path.write_bytes(b"\x7fELF" + b"\x00" * 100)
                bin_path.chmod(0o755)
                return Proc()

            rust_daemon.subprocess.run = fake_run
            result = rust_daemon._ensure_rust_binary(handler)
            assert result.name == "fn_handler"
        finally:
            rust_daemon.shutil.which = old_which
            rust_daemon.subprocess.run = old_run
            rust_daemon._BINARY_CACHE.clear()
            rust_daemon._BINARY_CACHE.update(old_cache)

    # Lines 956, 958: _ensure_persistent_runtime_pool min_warm clamping.
    old_pools = rust_daemon._PERSISTENT_RUNTIME_POOLS
    old_lock = rust_daemon._PERSISTENT_RUNTIME_POOLS_LOCK
    old_start_reaper = rust_daemon._start_persistent_runtime_pool_reaper
    old_warmup = rust_daemon._warmup_persistent_runtime_pool
    old_shutdown = rust_daemon._shutdown_persistent_runtime_pool
    try:
        rust_daemon._PERSISTENT_RUNTIME_POOLS = {}
        rust_daemon._PERSISTENT_RUNTIME_POOLS_LOCK = _threading.Lock()
        rust_daemon._start_persistent_runtime_pool_reaper = lambda: None
        rust_daemon._warmup_persistent_runtime_pool = lambda _pool: None
        rust_daemon._shutdown_persistent_runtime_pool = lambda _p: None

        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "app.rs"
            handler.write_text("fn main(){}", encoding="utf-8")
            binary = Path(tmp) / "fn_handler"
            binary.write_text("bin", encoding="utf-8")

            # min_warm < 0 => clamped to 0 (line 956)
            p = rust_daemon._ensure_persistent_runtime_pool(
                "clamp-neg@v1", handler, binary,
                {"max_workers": 2, "min_warm": -5, "idle_ttl_ms": 1000, "acquire_timeout_ms": 5000}
            )
            assert p["min_warm"] == 0

            # min_warm > max_workers => clamped to max_workers (line 958)
            rust_daemon._PERSISTENT_RUNTIME_POOLS = {}
            p2 = rust_daemon._ensure_persistent_runtime_pool(
                "clamp-high@v1", handler, binary,
                {"max_workers": 2, "min_warm": 10, "idle_ttl_ms": 1000, "acquire_timeout_ms": 5000}
            )
            assert p2["min_warm"] == 2
    finally:
        rust_daemon._PERSISTENT_RUNTIME_POOLS = old_pools
        rust_daemon._PERSISTENT_RUNTIME_POOLS_LOCK = old_lock
        rust_daemon._start_persistent_runtime_pool_reaper = old_start_reaper
        rust_daemon._warmup_persistent_runtime_pool = old_warmup
        rust_daemon._shutdown_persistent_runtime_pool = old_shutdown

    # Line 805: _shutdown_persistent_runtime_pool with a real _FakeRustWorker that passes isinstance.
    _OrigRustWorker = rust_daemon._PersistentRustWorker

    class _FakeRustWorker2(_OrigRustWorker):
        __slots__ = ()

        def __init__(self):
            self._dead = False
            self.lock = _threading.Lock()

        @property
        def alive(self):
            return not self._dead

        def shutdown(self):
            self._dead = True

    fake_w = _FakeRustWorker2()
    assert not fake_w._dead
    rust_daemon._shutdown_persistent_runtime_pool({"workers": [{"worker": fake_w}]})
    assert fake_w._dead

    # Lines 1125-1128, 1131-1132, 1136-1137, 1141: _run_prepared_request_persistent paths.
    old_ensure = rust_daemon._ensure_persistent_runtime_pool
    old_checkout = rust_daemon._checkout_persistent_runtime_worker
    old_release = rust_daemon._release_persistent_runtime_worker
    old_pools_2 = rust_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        fake_pool = {
            "cond": _threading.Condition(_threading.Lock()),
            "workers": [],
            "max_workers": 1,
            "pending": 0,
            "last_used": 0.0,
        }
        rust_daemon._ensure_persistent_runtime_pool = lambda *_a, **_k: fake_pool
        rust_daemon._PERSISTENT_RUNTIME_POOLS = {"test-key-2": fake_pool}

        # Success path (lines 1125-1128, 1141): checkout returns an entry with a working fake worker.
        class _FakeWorkerSuccess(_OrigRustWorker):
            __slots__ = ()

            def __init__(self):
                self._dead = False
                self.lock = _threading.Lock()

            @property
            def alive(self):
                return not self._dead

            def send_request(self, event, timeout_ms):
                return {"status": 200, "body": "ok"}

            def shutdown(self):
                self._dead = True

        fake_send_worker = _FakeWorkerSuccess()
        fake_entry = {"worker": fake_send_worker, "busy": True, "last_used": 0.0}
        released = {"called": False, "discard": None}

        def track_release(pool, entry, discard=False):
            released["called"] = True
            released["discard"] = discard

        rust_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: fake_entry
        rust_daemon._release_persistent_runtime_worker = track_release

        resp = rust_daemon._run_prepared_request_persistent(
            "test-key-2", Path("/tmp/handler.rs"), Path("/tmp/fn_handler"), {}, 2500, {"acquire_timeout_ms": 5000}
        )
        assert resp["status"] == 200
        assert released["called"]
        assert released["discard"] is False  # finally block releases without discard

        # Timeout path with entry not None (lines 1131-1132).
        class _FakeWorkerTimeout(_OrigRustWorker):
            __slots__ = ()

            def __init__(self):
                self._dead = False
                self.lock = _threading.Lock()

            @property
            def alive(self):
                return not self._dead

            def send_request(self, event, timeout_ms):
                raise TimeoutError("test timeout")

            def shutdown(self):
                self._dead = True

        release_calls = []

        def track_release_2(pool, entry, discard=False):
            release_calls.append(("release", discard))

        timeout_worker = _FakeWorkerTimeout()
        timeout_entry = {"worker": timeout_worker, "busy": True, "last_used": 0.0}
        rust_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: timeout_entry
        rust_daemon._release_persistent_runtime_worker = track_release_2

        resp2 = rust_daemon._run_prepared_request_persistent(
            "test-key-2", Path("/tmp/handler.rs"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp2["status"] == 504
        assert any(d for _, d in release_calls if d is True)

        # Exception path with entry not None (lines 1136-1137).
        class _FakeWorkerError(_OrigRustWorker):
            __slots__ = ()

            def __init__(self):
                self._dead = False
                self.lock = _threading.Lock()

            @property
            def alive(self):
                return not self._dead

            def send_request(self, event, timeout_ms):
                raise RuntimeError("boom")

            def shutdown(self):
                self._dead = True

        release_calls.clear()
        exc_worker = _FakeWorkerError()
        exc_entry = {"worker": exc_worker, "busy": True, "last_used": 0.0}
        rust_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: exc_entry

        resp3 = rust_daemon._run_prepared_request_persistent(
            "test-key-2", Path("/tmp/handler.rs"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp3["status"] == 500
        assert any(d for _, d in release_calls if d is True)

        # Invalid worker type (line 1126-1127): entry has no valid worker object.
        release_calls.clear()
        bad_entry = {"worker": "not-a-worker", "busy": True, "last_used": 0.0}
        rust_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: bad_entry

        resp4 = rust_daemon._run_prepared_request_persistent(
            "test-key-2", Path("/tmp/handler.rs"), Path("/tmp/fn_handler"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp4["status"] == 500
        assert "invalid persistent worker" in resp4["body"]
    finally:
        rust_daemon._ensure_persistent_runtime_pool = old_ensure
        rust_daemon._checkout_persistent_runtime_worker = old_checkout
        rust_daemon._release_persistent_runtime_worker = old_release
        rust_daemon._PERSISTENT_RUNTIME_POOLS = old_pools_2


def main() -> None:
    test_read_function_env_and_resolve_path()
    test_read_write_frame_and_normalize_response()
    test_ensure_rust_binary_paths()
    test_run_handler_direct_pool_and_serve_conn()
    test_reaper_and_main_paths()
    test_additional_edge_branches()
    test_rust_main_rs_merges_params_into_event()
    test_rust_handle_request_passes_params_through()
    test_persistent_pool_lifecycle()
    test_remaining_coverage_gaps()
    print("rust daemon unit tests passed")


if __name__ == "__main__":
    main()
