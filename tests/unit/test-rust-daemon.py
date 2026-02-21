#!/usr/bin/env python3
import importlib.util
import json
import socket
import struct
import tempfile
from concurrent.futures import Future, TimeoutError as FutureTimeoutError
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
        assert _read_frame(right) == expected

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
                (out / "fn_handler").write_text("#!/bin/sh\necho ok\n", encoding="utf-8")
                return Proc(returncode=0)

            rust_daemon.subprocess.run = fake_run
            b1 = rust_daemon._ensure_rust_binary(handler)
            assert b1.is_file(), b1
            b2 = rust_daemon._ensure_rust_binary(handler)
            assert b2 == b1
            assert calls["n"] == 1, calls

            rust_daemon._BINARY_CACHE.clear()
            rust_daemon.subprocess.run = lambda *_a, **_k: Proc(returncode=1, stderr="compile failed")
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

    old_resolve = rust_daemon._resolve_handler_path
    old_binary = rust_daemon._ensure_rust_binary
    old_env = rust_daemon._read_function_env
    old_run = rust_daemon._run_rust_handler
    old_enabled = rust_daemon.ENABLE_RUNTIME_WORKER_POOL
    old_direct = rust_daemon._handle_request_direct
    old_ensure_pool = rust_daemon._ensure_runtime_pool
    old_submit = rust_daemon._submit_runtime_pool_request
    old_read = rust_daemon._read_frame
    old_handle_pool = rust_daemon._handle_request_with_pool

    try:
        rust_daemon._resolve_handler_path = lambda *_a, **_k: Path("/tmp/handler.rs")
        rust_daemon._ensure_rust_binary = lambda _p: Path("/tmp/fn_handler")
        rust_daemon._read_function_env = lambda _p: {"FN_ENV": "1"}
        seen = {}

        def fake_run_handler(_binary, event, timeout_ms):
            seen["event"] = event
            seen["timeout_ms"] = timeout_ms
            return {"status": 200, "headers": {}, "body": "ok"}

        rust_daemon._run_rust_handler = fake_run_handler
        direct_resp = rust_daemon._handle_request_direct(
            {"fn": "demo", "event": {"env": {"A": "2"}, "context": {"timeout_ms": 10}}}
        )
        assert direct_resp["status"] == 200
        assert seen["event"]["env"]["A"] == "2"
        assert seen["event"]["env"]["FN_ENV"] == "1"
        assert seen["timeout_ms"] == 510

        rust_daemon.ENABLE_RUNTIME_WORKER_POOL = False
        rust_daemon._handle_request_direct = lambda _req: {"status": 200, "headers": {}, "body": "direct"}
        fallback_resp = rust_daemon._handle_request_with_pool({"fn": "demo", "event": {}})
        assert fallback_resp["body"] == "direct"

        rust_daemon.ENABLE_RUNTIME_WORKER_POOL = True
        rust_daemon._ensure_runtime_pool = lambda *_a, **_k: {"executor": object()}

        class SlowFuture:
            def result(self, timeout=None):  # noqa: ARG002
                raise FutureTimeoutError()

        rust_daemon._submit_runtime_pool_request = lambda *_a, **_k: SlowFuture()
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
        rust_daemon._run_rust_handler = old_run
        rust_daemon.ENABLE_RUNTIME_WORKER_POOL = old_enabled
        rust_daemon._handle_request_direct = old_direct
        rust_daemon._ensure_runtime_pool = old_ensure_pool
        rust_daemon._submit_runtime_pool_request = old_submit
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


def main() -> None:
    test_read_function_env_and_resolve_path()
    test_read_write_frame_and_normalize_response()
    test_ensure_rust_binary_paths()
    test_run_handler_direct_pool_and_serve_conn()
    test_reaper_and_main_paths()
    test_additional_edge_branches()
    print("rust daemon unit tests passed")


if __name__ == "__main__":
    main()
