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
PHP_DAEMON_PATH = RUNTIME_DIR / "php-daemon.py"

_PHP_SPEC = importlib.util.spec_from_file_location("fastfn_php_daemon", PHP_DAEMON_PATH)
if _PHP_SPEC is None or _PHP_SPEC.loader is None:
    raise RuntimeError(f"failed to load runtime module: {PHP_DAEMON_PATH}")
php_daemon = importlib.util.module_from_spec(_PHP_SPEC)  # type: ignore
_PHP_SPEC.loader.exec_module(php_daemon)  # type: ignore


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


def test_bool_env() -> None:
    original = php_daemon.os.environ.get("UNIT_BOOL_ENV")
    try:
        php_daemon.os.environ["UNIT_BOOL_ENV"] = "0"
        assert php_daemon._bool_env("UNIT_BOOL_ENV", True) is False
        php_daemon.os.environ["UNIT_BOOL_ENV"] = "off"
        assert php_daemon._bool_env("UNIT_BOOL_ENV", True) is False
        php_daemon.os.environ["UNIT_BOOL_ENV"] = "true"
        assert php_daemon._bool_env("UNIT_BOOL_ENV", False) is True
        php_daemon.os.environ.pop("UNIT_BOOL_ENV", None)
        assert php_daemon._bool_env("UNIT_BOOL_ENV", True) is True
    finally:
        if original is None:
            php_daemon.os.environ.pop("UNIT_BOOL_ENV", None)
        else:
            php_daemon.os.environ["UNIT_BOOL_ENV"] = original


def test_parse_extra_allow_roots_and_function_env() -> None:
    original_extra = php_daemon.STRICT_FS_EXTRA_ALLOW
    try:
        php_daemon.STRICT_FS_EXTRA_ALLOW = "/tmp,/does/not/exist,,."
        roots = php_daemon._parse_extra_allow_roots()
        assert isinstance(roots, list)
        assert any("/tmp" in str(p) for p in roots), roots
    finally:
        php_daemon.STRICT_FS_EXTRA_ALLOW = original_extra

    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "app.php"
        handler.write_text("<?php", encoding="utf-8")
        env_path = fn_dir / "fn.env.json"
        env_path.write_text(
            json.dumps(
                {
                    "A": "1",
                    "B": {"value": 2},
                    "C": None,
                    "D": {"value": None},
                    "9": "kept",
                }
            ),
            encoding="utf-8",
        )
        env = php_daemon._read_function_env(handler)
        assert env == {"A": "1", "B": "2", "9": "kept"}, env


def test_read_write_frame_paths() -> None:
    left, right = socket.socketpair()
    with left, right:
        expected = {"ok": True, "nested": {"a": 1}}
        php_daemon._write_frame(left, expected)
        assert _read_frame(right) == expected

    left, right = socket.socketpair()
    with left, right:
        _write_raw_frame(right, b"\xff\xfe")
        try:
            php_daemon._read_frame(left)
        except Exception as exc:  # noqa: BLE001
            assert "utf-8" in str(exc).lower() or "decode" in str(exc).lower(), str(exc)
        else:
            raise AssertionError("expected invalid utf-8 payload error")

    left, right = socket.socketpair()
    with left, right:
        too_large = php_daemon.MAX_FRAME_BYTES + 1
        right.sendall(struct.pack("!I", too_large))
        try:
            php_daemon._read_frame(left)
        except ValueError as exc:
            assert "invalid frame length" in str(exc), str(exc)
        else:
            raise AssertionError("expected invalid frame length")


def test_resolve_handler_path_and_normalize_response() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "root-file.php").write_text("<?php", encoding="utf-8")
        (root / "pkg").mkdir()
        (root / "pkg" / "app.php").write_text("<?php", encoding="utf-8")
        (root / "php").mkdir()
        (root / "php" / "runtime-fn").mkdir()
        (root / "php" / "runtime-fn" / "handler.php").write_text("<?php", encoding="utf-8")
        (root / "versioned").mkdir()
        (root / "versioned" / "v2").mkdir(parents=True)
        (root / "versioned" / "v2" / "index.php").write_text("<?php", encoding="utf-8")

        old_functions = php_daemon.FUNCTIONS_DIR
        old_runtime = php_daemon.RUNTIME_FUNCTIONS_DIR
        try:
            php_daemon.FUNCTIONS_DIR = root
            php_daemon.RUNTIME_FUNCTIONS_DIR = root / "php"

            assert php_daemon._resolve_handler_path("root-file.php", None) == root / "root-file.php"
            assert php_daemon._resolve_handler_path("pkg", None) == root / "pkg" / "app.php"
            assert php_daemon._resolve_handler_path("runtime-fn", None) == root / "php" / "runtime-fn" / "handler.php"
            assert php_daemon._resolve_handler_path("versioned", "v2") == root / "versioned" / "v2" / "index.php"

            try:
                php_daemon._resolve_handler_path("../bad", None)
            except ValueError:
                pass
            else:
                raise AssertionError("expected invalid function name error")
        finally:
            php_daemon.FUNCTIONS_DIR = old_functions
            php_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime

    ok_resp = php_daemon._normalize_response({"status": 201, "headers": {"X-A": "1"}, "body": "ok"})
    assert ok_resp["status"] == 201 and ok_resp["body"] == "ok"
    b64_resp = php_daemon._normalize_response({"statusCode": 200, "headers": {}, "isBase64Encoded": True, "body": "aaa"})
    assert b64_resp["is_base64"] is True and b64_resp["body_base64"] == "aaa"
    try:
        php_daemon._normalize_response({"status": "200"})
    except ValueError:
        pass
    else:
        raise AssertionError("expected invalid status error")


def test_run_php_handler_and_direct_request_paths() -> None:
    class Proc:
        def __init__(self, stdout: str, stderr: str = ""):
            self.stdout = stdout
            self.stderr = stderr
            self.returncode = 0

    original_run = php_daemon.subprocess.run
    try:
        def run_timeout(*_args, **_kwargs):
            raise php_daemon.subprocess.TimeoutExpired(cmd="php", timeout=1)

        php_daemon.subprocess.run = run_timeout
        timeout_resp = php_daemon._run_php_handler(Path("/tmp/demo.php"), {}, 100)
        assert timeout_resp["status"] == 504

        php_daemon.subprocess.run = lambda *_a, **_k: Proc("", "php failed")
        empty_resp = php_daemon._run_php_handler(Path("/tmp/demo.php"), {}, 100)
        assert empty_resp["status"] == 500

        php_daemon.subprocess.run = lambda *_a, **_k: Proc("{bad")
        bad_json_resp = php_daemon._run_php_handler(Path("/tmp/demo.php"), {}, 100)
        assert bad_json_resp["status"] == 500

        php_daemon.subprocess.run = lambda *_a, **_k: Proc(json.dumps({"status": 200, "headers": {}, "body": "ok"}))
        ok_resp = php_daemon._run_php_handler(Path("/tmp/demo.php"), {}, 100)
        assert ok_resp["status"] == 200
        assert ok_resp["body"] == "ok"
    finally:
        php_daemon.subprocess.run = original_run

    old_resolve = php_daemon._resolve_handler_path
    old_deps = php_daemon._ensure_composer_deps
    old_env = php_daemon._read_function_env
    old_run = php_daemon._run_php_handler
    try:
        php_daemon._resolve_handler_path = lambda *_a, **_k: Path("/tmp/unit.php")
        php_daemon._ensure_composer_deps = lambda _p: None
        php_daemon._read_function_env = lambda _p: {"FN_ENV": "1"}
        seen = {}

        def fake_run(_path, event, timeout_ms):
            seen["event"] = event
            seen["timeout_ms"] = timeout_ms
            return {"status": 200, "headers": {}, "body": "ok"}

        php_daemon._run_php_handler = fake_run
        resp = php_daemon._handle_request_direct(
            {"fn": "demo", "event": {"env": {"A": "2"}, "context": {"timeout_ms": 100}}}
        )
        assert resp["status"] == 200
        assert seen["event"]["env"]["A"] == "2"
        assert seen["event"]["env"]["FN_ENV"] == "1"
        assert seen["timeout_ms"] == 350

        try:
            php_daemon._handle_request_direct({"fn": "", "event": {}})
        except ValueError:
            pass
        else:
            raise AssertionError("expected missing fn error")
    finally:
        php_daemon._resolve_handler_path = old_resolve
        php_daemon._ensure_composer_deps = old_deps
        php_daemon._read_function_env = old_env
        php_daemon._run_php_handler = old_run


def test_pool_and_serve_conn_paths() -> None:
    settings = php_daemon._normalize_worker_pool_settings(
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
    assert settings["min_warm"] == 4
    assert settings["idle_ttl_ms"] == php_daemon.RUNTIME_POOL_IDLE_TTL_MS
    assert settings["acquire_timeout_ms"] >= php_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS
    assert php_daemon._runtime_pool_key("x", None) == "x@default"
    assert php_daemon._runtime_pool_key(None, None) == "unknown@default"

    old_enabled = php_daemon.ENABLE_RUNTIME_WORKER_POOL
    old_direct = php_daemon._handle_request_direct
    old_ensure_pool = php_daemon._ensure_runtime_pool
    old_submit = php_daemon._submit_runtime_pool_request
    try:
        php_daemon._handle_request_direct = lambda _req: {"status": 200, "headers": {}, "body": "direct"}
        php_daemon.ENABLE_RUNTIME_WORKER_POOL = False
        direct_resp = php_daemon._handle_request_with_pool({"fn": "demo", "event": {}})
        assert direct_resp["body"] == "direct"

        php_daemon.ENABLE_RUNTIME_WORKER_POOL = True
        php_daemon._ensure_runtime_pool = lambda *_a, **_k: {"executor": object()}

        class SlowFuture:
            def result(self, timeout=None):  # noqa: ARG002
                raise FutureTimeoutError()

        php_daemon._submit_runtime_pool_request = lambda *_a, **_k: SlowFuture()
        timeout_resp = php_daemon._handle_request_with_pool(
            {"fn": "demo", "event": {"context": {"timeout_ms": 10, "worker_pool": {"enabled": True, "max_workers": 1}}}}
        )
        assert timeout_resp["status"] == 504
    finally:
        php_daemon.ENABLE_RUNTIME_WORKER_POOL = old_enabled
        php_daemon._handle_request_direct = old_direct
        php_daemon._ensure_runtime_pool = old_ensure_pool
        php_daemon._submit_runtime_pool_request = old_submit

    old_read = php_daemon._read_frame
    old_handle = php_daemon._handle_request_with_pool
    try:
        left, right = socket.socketpair()
        with left, right:
            php_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            php_daemon._handle_request_with_pool = lambda _r: {"status": 200, "headers": {}, "body": "ok"}
            php_daemon._serve_conn(left)
            assert _read_frame(right)["status"] == 200

        left, right = socket.socketpair()
        with left, right:
            php_daemon._read_frame = lambda _c: (_ for _ in ()).throw(ValueError("bad frame"))
            php_daemon._serve_conn(left)
            err = _read_frame(right)
            assert err["status"] == 400
    finally:
        php_daemon._read_frame = old_read
        php_daemon._handle_request_with_pool = old_handle

    # validate real pool submission callback decrements pending
    executor = php_daemon.ThreadPoolExecutor(max_workers=1)
    try:
        pool = {"executor": executor, "pending": 0, "last_used": 0.0}
        key = "unit@default"
        old_pools = php_daemon._RUNTIME_POOLS
        php_daemon._RUNTIME_POOLS = {key: pool}
        old_direct = php_daemon._handle_request_direct
        php_daemon._handle_request_direct = lambda _req: {"status": 200, "headers": {}, "body": "ok"}
        fut = php_daemon._submit_runtime_pool_request(key, pool, {"fn": "demo", "event": {}})
        assert isinstance(fut, Future)
        out = fut.result(timeout=2)
        assert out["status"] == 200
        assert pool["pending"] == 0
    finally:
        php_daemon._handle_request_direct = old_direct
        php_daemon._RUNTIME_POOLS = old_pools
        executor.shutdown(wait=False, cancel_futures=False)


def test_composer_deps_reaper_and_main_paths() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "app.php"
        handler.write_text("<?php", encoding="utf-8")
        composer_json = fn_dir / "composer.json"
        composer_json.write_text(json.dumps({"require": {"a/b": "1.0.0"}}), encoding="utf-8")
        lock_file = fn_dir / "composer.lock"
        lock_file.write_text("{}", encoding="utf-8")
        vendor_dir = fn_dir / "vendor"
        vendor_dir.mkdir()

        old_auto = php_daemon.AUTO_COMPOSER_DEPS
        old_which = php_daemon.shutil.which
        old_run = php_daemon.subprocess.run
        old_cache = dict(php_daemon._COMPOSER_CACHE)
        old_extra_roots = list(php_daemon._STRICT_EXTRA_ROOTS)
        try:
            php_daemon.AUTO_COMPOSER_DEPS = False
            php_daemon._ensure_composer_deps(handler)  # disabled no-op

            php_daemon.AUTO_COMPOSER_DEPS = True
            php_daemon.shutil.which = lambda _name: None
            php_daemon._ensure_composer_deps(handler)  # missing composer no-op

            calls = {"n": 0}

            class Proc:
                def __init__(self, rc=0, stderr=""):
                    self.returncode = rc
                    self.stdout = ""
                    self.stderr = stderr

            php_daemon.shutil.which = lambda _name: "/usr/bin/composer"

            def fake_run(*_args, **_kwargs):
                calls["n"] += 1
                return Proc(0)

            php_daemon.subprocess.run = fake_run
            php_daemon._COMPOSER_CACHE.clear()
            php_daemon._ensure_composer_deps(handler)
            assert calls["n"] == 1, calls

            php_daemon._ensure_composer_deps(handler)
            assert calls["n"] == 1, "cache+vendor should skip rerun"

            vendor_dir.rmdir()
            php_daemon._ensure_composer_deps(handler)
            assert calls["n"] == 2, "missing vendor should force rerun"

            php_daemon.subprocess.run = lambda *_a, **_k: Proc(1, "composer failed line1\nline2")
            try:
                php_daemon._ensure_composer_deps(handler)
            except RuntimeError as exc:
                assert "composer install failed" in str(exc), str(exc)
            else:
                raise AssertionError("expected composer failure")

            php_daemon._STRICT_EXTRA_ROOTS = [Path("/opt/custom")]
            open_basedir = php_daemon._strict_open_basedir(fn_dir)
            assert str(fn_dir.resolve(strict=False)) in open_basedir
            assert str((fn_dir / "vendor").resolve(strict=False)) in open_basedir
            assert "/opt/custom" in open_basedir
        finally:
            php_daemon.AUTO_COMPOSER_DEPS = old_auto
            php_daemon.shutil.which = old_which
            php_daemon.subprocess.run = old_run
            php_daemon._COMPOSER_CACHE.clear()
            php_daemon._COMPOSER_CACHE.update(old_cache)
            php_daemon._STRICT_EXTRA_ROOTS = old_extra_roots

    # reaper path: evict idle pool and shutdown executor
    old_started = php_daemon._RUNTIME_POOL_REAPER_STARTED
    old_interval = php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread = php_daemon.threading.Thread
    old_sleep = php_daemon.time.sleep
    old_monotonic = php_daemon.time.monotonic
    old_shutdown = php_daemon._shutdown_runtime_pool
    old_pools = php_daemon._RUNTIME_POOLS
    try:
        php_daemon._RUNTIME_POOL_REAPER_STARTED = False
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        pool = {
            "executor": php_daemon.ThreadPoolExecutor(max_workers=1),
            "pending": 0,
            "min_warm": 0,
            "idle_ttl_ms": 1,
            "last_used": 1.0,
        }
        php_daemon._RUNTIME_POOLS = {"idle@default": pool}
        shutdown_calls: list[str] = []
        php_daemon._shutdown_runtime_pool = lambda _pool: shutdown_calls.append("x")

        sleep_calls = {"n": 0}

        def fake_sleep(_seconds):
            sleep_calls["n"] += 1
            if sleep_calls["n"] > 1:
                raise StopIteration("stop reaper loop")

        php_daemon.time.sleep = fake_sleep
        php_daemon.time.monotonic = lambda: 9999.0

        class InlineThread:
            def __init__(self, target=None, **_kwargs):
                self._target = target

            def start(self):
                try:
                    if self._target:
                        self._target()
                except StopIteration:
                    pass

        php_daemon.threading.Thread = InlineThread
        php_daemon._start_runtime_pool_reaper()
        assert php_daemon._RUNTIME_POOL_REAPER_STARTED is True
        assert php_daemon._RUNTIME_POOLS == {} or "idle@default" not in php_daemon._RUNTIME_POOLS
        assert shutdown_calls, "reaper should shutdown evicted pools"
    finally:
        try:
            executor = pool.get("executor") if isinstance(pool, dict) else None
            if isinstance(executor, php_daemon.ThreadPoolExecutor):
                executor.shutdown(wait=False, cancel_futures=False)
        except Exception:
            pass
        php_daemon._RUNTIME_POOL_REAPER_STARTED = old_started
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        php_daemon.threading.Thread = old_thread
        php_daemon.time.sleep = old_sleep
        php_daemon.time.monotonic = old_monotonic
        php_daemon._shutdown_runtime_pool = old_shutdown
        php_daemon._RUNTIME_POOLS = old_pools

    # cover main socket bootstrap/loop with inline fakes
    old_socket = php_daemon.socket.socket
    old_remove = php_daemon.os.remove
    old_exists = php_daemon.os.path.exists
    old_chmod = php_daemon.os.chmod
    old_thread = php_daemon.threading.Thread
    old_serve_conn = php_daemon._serve_conn
    old_ensure_dir = php_daemon._ensure_socket_dir
    try:
        served: list[str] = []
        php_daemon._serve_conn = lambda _conn: served.append("conn")
        php_daemon._ensure_socket_dir = lambda _path: None
        php_daemon.os.path.exists = lambda _p: True
        php_daemon.os.remove = lambda _p: None
        php_daemon.os.chmod = lambda _p, _m: None

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

        php_daemon.socket.socket = DummyServer
        php_daemon.threading.Thread = InlineThread
        try:
            php_daemon.main()
        except KeyboardInterrupt:
            pass
        else:
            raise AssertionError("expected KeyboardInterrupt to break main loop")
        assert served == ["conn"], served
    finally:
        php_daemon.socket.socket = old_socket
        php_daemon.os.remove = old_remove
        php_daemon.os.path.exists = old_exists
        php_daemon.os.chmod = old_chmod
        php_daemon.threading.Thread = old_thread
        php_daemon._serve_conn = old_serve_conn
        php_daemon._ensure_socket_dir = old_ensure_dir


def test_additional_edge_branches() -> None:
    # _read_function_env: missing/invalid/non-object cases
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "app.php"
        handler.write_text("<?php", encoding="utf-8")
        assert php_daemon._read_function_env(handler) == {}

        env_path = fn_dir / "fn.env.json"
        env_path.write_text("{bad", encoding="utf-8")
        assert php_daemon._read_function_env(handler) == {}

        env_path.write_text(json.dumps(["bad"]), encoding="utf-8")
        assert php_daemon._read_function_env(handler) == {}

        env_path.write_text(json.dumps({"A": "1", "B": {"value": None}, "C": None}), encoding="utf-8")
        assert php_daemon._read_function_env(handler) == {"A": "1"}

    # _read_frame: incomplete header/payload and non-object request
    left, right = socket.socketpair()
    with left, right:
        right.sendall(b"\x00\x00")
        right.shutdown(socket.SHUT_WR)
        try:
            php_daemon._read_frame(left)
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
            php_daemon._read_frame(left)
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
            php_daemon._read_frame(left)
        except ValueError as exc:
            assert "object" in str(exc).lower()
        else:
            raise AssertionError("expected object validation error")

    # _resolve_handler_path empty name and _normalize_response edge branches
    try:
        php_daemon._resolve_handler_path("", None)
    except ValueError:
        pass
    else:
        raise AssertionError("expected invalid empty function name")

    try:
        php_daemon._normalize_response("bad")
    except ValueError as exc:
        assert "object" in str(exc).lower()
    else:
        raise AssertionError("expected object response error")

    try:
        php_daemon._normalize_response({"status": 200, "headers": []})
    except ValueError as exc:
        assert "headers" in str(exc).lower()
    else:
        raise AssertionError("expected headers object error")

    norm_body = php_daemon._normalize_response({"status": 200, "headers": {}, "body": None})
    assert norm_body["body"] == ""
    norm_body2 = php_daemon._normalize_response({"status": 200, "headers": {}, "body": 123})
    assert norm_body2["body"] == "123"

    # worker-pool helper branches
    s = php_daemon._normalize_worker_pool_settings(
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

    exec1 = php_daemon.ThreadPoolExecutor(max_workers=1)
    try:
        php_daemon._shutdown_runtime_pool({"executor": exec1})
        php_daemon._shutdown_runtime_pool({"executor": object()})
    finally:
        exec1.shutdown(wait=False, cancel_futures=False)

    # _warmup_runtime_pool branches
    php_daemon._warmup_runtime_pool({"min_warm": 0, "executor": object()})
    php_daemon._warmup_runtime_pool({"min_warm": 1, "executor": object()})
    exec2 = php_daemon.ThreadPoolExecutor(max_workers=1)
    try:
        php_daemon._warmup_runtime_pool({"min_warm": 2, "executor": exec2})
    finally:
        exec2.shutdown(wait=False, cancel_futures=False)

    # _ensure_runtime_pool existing pool reuse and replace
    old_pools = php_daemon._RUNTIME_POOLS
    old_lock = php_daemon._RUNTIME_POOLS_LOCK
    old_start_reaper = php_daemon._start_runtime_pool_reaper
    old_warmup = php_daemon._warmup_runtime_pool
    try:
        php_daemon._RUNTIME_POOLS = {}
        php_daemon._RUNTIME_POOLS_LOCK = php_daemon.threading.Lock()
        php_daemon._start_runtime_pool_reaper = lambda: None
        php_daemon._warmup_runtime_pool = lambda _pool: None

        p1 = php_daemon._ensure_runtime_pool("unit@v1", {"max_workers": 1, "min_warm": 0, "idle_ttl_ms": 1000})
        assert p1["max_workers"] == 1
        p2 = php_daemon._ensure_runtime_pool("unit@v1", {"max_workers": 1, "min_warm": 1, "idle_ttl_ms": 2000})
        assert p2 is p1 and p2["min_warm"] == 1 and p2["idle_ttl_ms"] == 2000
        p3 = php_daemon._ensure_runtime_pool("unit@v1", {"max_workers": 2, "min_warm": 0, "idle_ttl_ms": 1000})
        assert p3 is not p2 and p3["max_workers"] == 2
    finally:
        for pool in php_daemon._RUNTIME_POOLS.values():
            ex = pool.get("executor")
            if isinstance(ex, php_daemon.ThreadPoolExecutor):
                ex.shutdown(wait=False, cancel_futures=False)
        php_daemon._RUNTIME_POOLS = old_pools
        php_daemon._RUNTIME_POOLS_LOCK = old_lock
        php_daemon._start_runtime_pool_reaper = old_start_reaper
        php_daemon._warmup_runtime_pool = old_warmup

    # _handle_request_direct invalid event and ensure_socket_dir
    try:
        php_daemon._handle_request_direct({"fn": "demo", "event": "bad"})
    except ValueError as exc:
        assert "event" in str(exc).lower()
    else:
        raise AssertionError("expected event object validation")

    with tempfile.TemporaryDirectory() as tmp:
        path = str(Path(tmp) / "sock" / "fn.sock")
        php_daemon._ensure_socket_dir(path)
        assert (Path(tmp) / "sock").is_dir()

    # _serve_conn FileNotFoundError / generic / write failure
    old_read = php_daemon._read_frame
    old_handle = php_daemon._handle_request_with_pool
    old_write = php_daemon._write_frame
    try:
        left, right = socket.socketpair()
        with left, right:
            php_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            php_daemon._handle_request_with_pool = lambda _r: (_ for _ in ()).throw(FileNotFoundError("missing"))
            php_daemon._serve_conn(left)
            resp = _read_frame(right)
            assert resp["status"] == 404

        left, right = socket.socketpair()
        with left, right:
            php_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            php_daemon._handle_request_with_pool = lambda _r: (_ for _ in ()).throw(RuntimeError("boom"))
            php_daemon._serve_conn(left)
            resp = _read_frame(right)
            assert resp["status"] == 500

        left, right = socket.socketpair()
        with left, right:
            php_daemon._read_frame = lambda _c: {"fn": "demo", "event": {}}
            php_daemon._handle_request_with_pool = lambda _r: {"status": 200, "headers": {}, "body": "ok"}
            php_daemon._write_frame = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("write failed"))
            php_daemon._serve_conn(left)
    finally:
        php_daemon._read_frame = old_read
        php_daemon._handle_request_with_pool = old_handle
        php_daemon._write_frame = old_write


def main() -> None:
    test_bool_env()
    test_parse_extra_allow_roots_and_function_env()
    test_read_write_frame_paths()
    test_resolve_handler_path_and_normalize_response()
    test_run_php_handler_and_direct_request_paths()
    test_pool_and_serve_conn_paths()
    test_composer_deps_reaper_and_main_paths()
    test_additional_edge_branches()
    print("php daemon unit tests passed")


if __name__ == "__main__":
    main()
