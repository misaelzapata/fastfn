#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import socket
import stat
import struct
import tempfile
from concurrent.futures import Future, TimeoutError as FutureTimeoutError
from contextlib import redirect_stderr, redirect_stdout
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
        assert php_daemon._read_frame(right) == expected

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
    old_run_prepared = php_daemon._run_prepared_request_persistent
    try:
        php_daemon._resolve_handler_path = lambda *_a, **_k: Path("/tmp/unit.php")
        php_daemon._ensure_composer_deps = lambda _p: None
        php_daemon._read_function_env = lambda _p: {"FN_ENV": "1", "UNIT_PROCESS_ENV": "yes"}
        seen = {}

        def fake_run(_pool_key, _path, event, timeout_ms, settings):
            seen["event"] = event
            seen["timeout_ms"] = timeout_ms
            seen["settings"] = settings
            return {"status": 200, "headers": {}, "body": "ok"}

        php_daemon._run_prepared_request_persistent = fake_run
        resp = php_daemon._handle_request_direct(
            {"fn": "demo", "event": {"env": {"A": "2"}, "context": {"timeout_ms": 100}}}
        )
        assert resp["status"] == 200
        assert seen["event"]["env"]["A"] == "2"
        assert seen["event"]["env"]["FN_ENV"] == "1"
        assert seen["timeout_ms"] == 350
        assert seen["settings"]["max_workers"] == 1

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
        php_daemon._run_prepared_request_persistent = old_run_prepared


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
    old_prepare = php_daemon._prepare_request
    old_run_prepared = php_daemon._run_prepared_request_persistent
    try:
        php_daemon._handle_request_direct = lambda _req: {"status": 200, "headers": {}, "body": "direct"}
        php_daemon.ENABLE_RUNTIME_WORKER_POOL = False
        direct_resp = php_daemon._handle_request_with_pool({"fn": "demo", "event": {}})
        assert direct_resp["body"] == "direct"

        php_daemon.ENABLE_RUNTIME_WORKER_POOL = True
        php_daemon._prepare_request = lambda _req: (Path("/tmp/demo.php"), {}, 260)
        php_daemon._run_prepared_request_persistent = lambda *_a, **_k: {"status": 504, "headers": {}, "body": "timeout"}
        timeout_resp = php_daemon._handle_request_with_pool(
            {"fn": "demo", "event": {"context": {"timeout_ms": 10, "worker_pool": {"enabled": True, "max_workers": 1}}}}
        )
        assert timeout_resp["status"] == 504
    finally:
        php_daemon.ENABLE_RUNTIME_WORKER_POOL = old_enabled
        php_daemon._handle_request_direct = old_direct
        php_daemon._prepare_request = old_prepare
        php_daemon._run_prepared_request_persistent = old_run_prepared

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

    # _prepare_socket_path tolerates stat race (socket removed between checks)
    old_stat = php_daemon.os.stat
    try:
        php_daemon.os.stat = lambda _p: (_ for _ in ()).throw(FileNotFoundError("gone"))
        php_daemon._prepare_socket_path("/tmp/fastfn/fn-php.sock")
    finally:
        php_daemon.os.stat = old_stat

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

    # _parse_extra_allow_roots catches bad path entries.
    old_extra = php_daemon.STRICT_FS_EXTRA_ALLOW
    try:
        php_daemon.STRICT_FS_EXTRA_ALLOW = "\x00bad"
        assert php_daemon._parse_extra_allow_roots() == []
    finally:
        php_daemon.STRICT_FS_EXTRA_ALLOW = old_extra

    # _read_function_env: non-string keys are skipped.
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "app.php"
        handler.write_text("<?php", encoding="utf-8")
        env_path = fn_dir / "fn.env.json"
        env_path.write_text("{}", encoding="utf-8")
        old_loads = php_daemon.json.loads
        try:
            php_daemon.json.loads = lambda _raw: {1: "x", "OK": "1"}
            assert php_daemon._read_function_env(handler) == {"OK": "1"}
        finally:
            php_daemon.json.loads = old_loads

    # _patched_process_env stores per-request env in thread-local storage
    # instead of mutating global os.environ (security fix for concurrency).
    old_prev = os.environ.get("UNIT_PREV")
    os.environ["UNIT_PREV"] = "old"
    try:
        with php_daemon._patched_process_env({1: "x", "": "y", "UNIT_PREV": "new", "UNIT_NONE": None}):
            # Overrides are in thread-local, visible via _build_subprocess_env
            sub_env = php_daemon._build_subprocess_env()
            assert sub_env.get("UNIT_PREV") == "new"
            assert "UNIT_NONE" not in sub_env
            # Global os.environ is NOT mutated (security invariant)
            assert os.environ.get("UNIT_PREV") == "old"
        # After context exit, overrides are cleared
        sub_env_after = php_daemon._build_subprocess_env()
        assert sub_env_after.get("UNIT_PREV") == "old"
    finally:
        if old_prev is None:
            os.environ.pop("UNIT_PREV", None)
        else:
            os.environ["UNIT_PREV"] = old_prev

    # _resolve_handler_path fallback + invalid version + unknown function.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        old_functions = php_daemon.FUNCTIONS_DIR
        old_runtime = php_daemon.RUNTIME_FUNCTIONS_DIR
        try:
            php_daemon.FUNCTIONS_DIR = root
            php_daemon.RUNTIME_FUNCTIONS_DIR = root / "php"
            try:
                php_daemon._resolve_handler_path("missing", "bad/version")
            except ValueError as exc:
                assert "version" in str(exc).lower()
            else:
                raise AssertionError("expected invalid version error")
            try:
                php_daemon._resolve_handler_path("missing", None)
            except FileNotFoundError:
                pass
            else:
                raise AssertionError("expected unknown function error")
        finally:
            php_daemon.FUNCTIONS_DIR = old_functions
            php_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime

    try:
        php_daemon._normalize_response({"status": 200, "headers": {}, "is_base64": True, "body_base64": ""})
    except ValueError as exc:
        assert "body_base64" in str(exc)
    else:
        raise AssertionError("expected invalid body_base64")

    # _run_php_handler includes stderr when present.
    class _Proc:
        def __init__(self, stdout: str, stderr: str):
            self.stdout = stdout
            self.stderr = stderr
            self.returncode = 0

    old_run = php_daemon.subprocess.run
    try:
        php_daemon.subprocess.run = lambda *_a, **_k: _Proc(json.dumps({"status": 200, "headers": {}, "body": "ok"}), "warn")
        out = php_daemon._run_php_handler(Path("/tmp/x.php"), {}, 200)
        assert out.get("stderr") == "warn"
    finally:
        php_daemon.subprocess.run = old_run

    stdout_buffer = io.StringIO()
    stderr_buffer = io.StringIO()
    with redirect_stdout(stdout_buffer), redirect_stderr(stderr_buffer):
        php_daemon._emit_handler_logs(
            {"fn": "hello", "version": "v2"},
            {"stdout": "line one", "stderr": "warn one\nwarn two"},
        )
    assert "[fn:hello@v2 stdout] line one" in stdout_buffer.getvalue()
    assert "[fn:hello@v2 stderr] warn one" in stderr_buffer.getvalue()
    assert "[fn:hello@v2 stderr] warn two" in stderr_buffer.getvalue()

    # _normalize_worker_pool_settings acquire_timeout floor branch.
    old_acquire = php_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS
    try:
        php_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = 0
        settings = php_daemon._normalize_worker_pool_settings({"event": {"context": {"worker_pool": {"max_workers": 1}}}})
        assert settings["acquire_timeout_ms"] == 100
    finally:
        php_daemon.RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = old_acquire

    # _start_runtime_pool_reaper early exits.
    old_started = php_daemon._RUNTIME_POOL_REAPER_STARTED
    old_interval = php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    try:
        php_daemon._RUNTIME_POOL_REAPER_STARTED = True
        php_daemon._start_runtime_pool_reaper()
        php_daemon._RUNTIME_POOL_REAPER_STARTED = False
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 0
        php_daemon._start_runtime_pool_reaper()
    finally:
        php_daemon._RUNTIME_POOL_REAPER_STARTED = old_started
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval

    # _warmup_runtime_pool tolerates future failures.
    exec3 = php_daemon.ThreadPoolExecutor(max_workers=1)
    old_submit = exec3.submit
    try:
        class _BadFuture:
            def result(self, timeout=None):  # noqa: ARG002
                raise RuntimeError("boom")

        exec3.submit = lambda *_a, **_k: _BadFuture()
        php_daemon._warmup_runtime_pool({"min_warm": 1, "executor": exec3})
    finally:
        exec3.submit = old_submit
        exec3.shutdown(wait=False, cancel_futures=False)

    # _submit_runtime_pool_request invalid executor + missing current pool callback.
    try:
        php_daemon._submit_runtime_pool_request("x", {"executor": object()}, {"fn": "demo", "event": {}})
    except RuntimeError as exc:
        assert "executor" in str(exc).lower()
    else:
        raise AssertionError("expected invalid executor error")

    old_pools = php_daemon._RUNTIME_POOLS
    old_direct = php_daemon._handle_request_direct
    exec4 = php_daemon.ThreadPoolExecutor(max_workers=1)
    try:
        started = php_daemon.threading.Event()
        release = php_daemon.threading.Event()

        def _slow_ok(_req):
            started.set()
            release.wait(timeout=2)
            return {"status": 200, "headers": {}, "body": "ok"}

        pool = {"executor": exec4, "pending": 0, "last_used": 0.0}
        php_daemon._RUNTIME_POOLS = {"gone@v1": pool}
        php_daemon._handle_request_direct = _slow_ok
        fut = php_daemon._submit_runtime_pool_request("gone@v1", pool, {"fn": "demo", "event": {}})
        assert started.wait(timeout=2)
        php_daemon._RUNTIME_POOLS = {}
        release.set()
        assert fut.result(timeout=2)["status"] == 200
    finally:
        php_daemon._RUNTIME_POOLS = old_pools
        php_daemon._handle_request_direct = old_direct
        exec4.shutdown(wait=False, cancel_futures=False)

    # _start_runtime_pool_reaper inner-loop continue branch (pending/min_warm > 0).
    old_started = php_daemon._RUNTIME_POOL_REAPER_STARTED
    old_interval = php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread_cls = php_daemon.threading.Thread
    old_sleep = php_daemon.time.sleep
    old_mono = php_daemon.time.monotonic
    old_shutdown_pool = php_daemon._shutdown_runtime_pool
    old_pools = php_daemon._RUNTIME_POOLS
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

        php_daemon._RUNTIME_POOLS = {
            "pending@v1": {"pending": 1, "min_warm": 0, "idle_ttl_ms": 1, "last_used": 0.0},
            "warm@v1": {"pending": 0, "min_warm": 1, "idle_ttl_ms": 1, "last_used": 0.0},
        }
        php_daemon._RUNTIME_POOL_REAPER_STARTED = False
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        php_daemon.threading.Thread = _InlineThread
        php_daemon.time.sleep = _fake_sleep
        php_daemon.time.monotonic = lambda: 10.0
        php_daemon._shutdown_runtime_pool = _fake_shutdown
        php_daemon._start_runtime_pool_reaper()
        assert shutdown_calls["n"] == 0
    finally:
        php_daemon._RUNTIME_POOLS = old_pools
        php_daemon._RUNTIME_POOL_REAPER_STARTED = old_started
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        php_daemon.threading.Thread = old_thread_cls
        php_daemon.time.sleep = old_sleep
        php_daemon.time.monotonic = old_mono
        php_daemon._shutdown_runtime_pool = old_shutdown_pool

    # _prepare_socket_path non-socket / stale socket / in-use socket branches.
    with tempfile.TemporaryDirectory() as tmp:
        not_socket = Path(tmp) / "plain.file"
        not_socket.write_text("x", encoding="utf-8")
        try:
            php_daemon._prepare_socket_path(str(not_socket))
        except RuntimeError as exc:
            assert "not a unix socket" in str(exc).lower()
        else:
            raise AssertionError("expected non-socket error")

    old_stat = php_daemon.os.stat
    old_socket_ctor = php_daemon.socket.socket
    old_remove = php_daemon.os.remove
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

        php_daemon.os.stat = lambda _p: _SockStat()
        php_daemon.socket.socket = lambda *_a, **_k: _Probe(False)
        php_daemon.os.remove = lambda _p: (_ for _ in ()).throw(FileNotFoundError())
        php_daemon._prepare_socket_path("/tmp/fn-php.sock")

        php_daemon.socket.socket = lambda *_a, **_k: _Probe(True)
        try:
            php_daemon._prepare_socket_path("/tmp/fn-php.sock")
        except RuntimeError as exc:
            assert "already in use" in str(exc).lower()
        else:
            raise AssertionError("expected in-use socket error")
    finally:
        php_daemon.os.stat = old_stat
        php_daemon.socket.socket = old_socket_ctor
        php_daemon.os.remove = old_remove

    # _entrypoint validates worker existence and calls main.
    old_worker = php_daemon.WORKER_FILE
    old_main = php_daemon.main
    try:
        php_daemon.WORKER_FILE = Path("/tmp/does-not-exist-worker.php")
        try:
            php_daemon._entrypoint()
        except SystemExit as exc:
            assert "missing php-worker.php" in str(exc)
        else:
            raise AssertionError("expected missing worker SystemExit")

        hit = {"ok": False}
        with tempfile.TemporaryDirectory() as tmp:
            worker = Path(tmp) / "php-worker.php"
            worker.write_text("<?php", encoding="utf-8")
            php_daemon.WORKER_FILE = worker
            php_daemon.main = lambda: hit.update(ok=True)
            php_daemon._entrypoint()
            assert hit["ok"] is True
    finally:
        php_daemon.WORKER_FILE = old_worker
        php_daemon.main = old_main


def test_php_worker_has_reflection_param_injection() -> None:
    """php-worker.php uses ReflectionFunction to inject route params as second arg."""
    worker_path = RUNTIME_DIR / "php-worker.php"
    assert worker_path.exists(), "php-worker.php must exist"
    content = worker_path.read_text(encoding="utf-8")
    assert "ReflectionFunction" in content, \
        "worker must use ReflectionFunction for param inspection"
    assert "getNumberOfParameters" in content, \
        "worker must check handler param count"
    assert "$params" in content, \
        "worker must extract params from event"
    assert "$handlerName($event, $params)" in content or "handler($event, $params)" in content, \
        "worker must pass params as second arg when handler accepts it"


def test_php_handle_request_passes_params_through() -> None:
    """Params in event should be passed through to the PHP handler."""
    old_resolve = php_daemon._resolve_handler_path
    old_env = php_daemon._read_function_env
    old_run_prepared = php_daemon._run_prepared_request_persistent
    seen = {}
    try:
        php_daemon._resolve_handler_path = lambda *_a, **_k: Path("/tmp/handler.php")
        php_daemon._read_function_env = lambda _p: {}

        def fake_run(_pool_key, _handler_path, event, timeout_ms, settings):
            seen["event"] = event
            seen["settings"] = settings
            return {"status": 200, "headers": {}, "body": "ok"}

        php_daemon._run_prepared_request_persistent = fake_run
        resp = php_daemon._handle_request_direct(
            {"fn": "demo", "event": {"params": {"id": "42"}}}
        )
        assert resp["status"] == 200
        assert seen["event"]["params"]["id"] == "42"
        assert seen["settings"]["max_workers"] == 1
    finally:
        php_daemon._resolve_handler_path = old_resolve
        php_daemon._read_function_env = old_env
        php_daemon._run_prepared_request_persistent = old_run_prepared


def test_persistent_pool_lifecycle() -> None:
    """Cover persistent pool: create, checkout, release, discard, shutdown, reaper."""
    import threading as _threading

    # _handler_signature covers existing and missing file branches.
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "app.php"
        handler.write_text("<?php", encoding="utf-8")
        sig = php_daemon._handler_signature(handler)
        assert isinstance(sig, str)
        assert "app.php:" in sig
        assert "missing" in sig  # fn.env.json, composer.json, composer.lock are missing

    # _shutdown_persistent_runtime_pool with non-list workers, non-dict entries, and non-worker objects.
    php_daemon._shutdown_persistent_runtime_pool({"workers": "bad"})
    php_daemon._shutdown_persistent_runtime_pool({"workers": [None, "not-dict", {"worker": "not-a-worker"}]})
    php_daemon._shutdown_persistent_runtime_pool({"workers": []})

    # _warmup_persistent_runtime_pool branches: target <= 0, bad cond, bad workers.
    php_daemon._warmup_persistent_runtime_pool({"min_warm": 0})
    php_daemon._warmup_persistent_runtime_pool({"min_warm": 1, "cond": "bad"})
    lock = _threading.Lock()
    cond = _threading.Condition(lock)
    php_daemon._warmup_persistent_runtime_pool({"min_warm": 1, "cond": cond, "workers": "bad"})

    # _checkout_persistent_runtime_worker: bad cond and bad workers.
    try:
        php_daemon._checkout_persistent_runtime_worker({"cond": "bad"}, 100)
    except RuntimeError as exc:
        assert "invalid persistent" in str(exc).lower()
    else:
        raise AssertionError("expected invalid persistent runtime pool error")

    lock2 = _threading.Lock()
    cond2 = _threading.Condition(lock2)
    try:
        php_daemon._checkout_persistent_runtime_worker({"cond": cond2, "workers": "bad"}, 100)
    except RuntimeError as exc:
        assert "workers" in str(exc).lower()
    else:
        raise AssertionError("expected invalid workers error")

    # _checkout_persistent_runtime_worker: timeout when all workers are busy and max reached.
    lock3 = _threading.Lock()
    cond3 = _threading.Condition(lock3)

    # Create a fake worker that passes isinstance check by subclassing.
    _OrigPhpWorker = php_daemon._PersistentPhpWorker

    class _FakePhpWorker(_OrigPhpWorker):
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

    alive_worker = _FakePhpWorker(True)
    busy_entry = {"worker": alive_worker, "busy": True, "last_used": 0.0}
    pool = {"cond": cond3, "workers": [busy_entry], "max_workers": 1, "last_used": 0.0, "handler_path": Path("/tmp/test.php")}
    try:
        php_daemon._checkout_persistent_runtime_worker(pool, 50)
    except TimeoutError:
        pass
    else:
        raise AssertionError("expected timeout on busy pool")

    # _checkout_persistent_runtime_worker: stale worker cleanup.
    lock4 = _threading.Lock()
    cond4 = _threading.Condition(lock4)
    dead_worker = _FakePhpWorker(False)
    alive_worker2 = _FakePhpWorker(True)
    stale_entry = {"worker": dead_worker, "busy": False, "last_used": 0.0}
    free_entry = {"worker": alive_worker2, "busy": False, "last_used": 0.0}
    pool2 = {"cond": cond4, "workers": [stale_entry, free_entry], "max_workers": 2, "last_used": 0.0}
    result = php_daemon._checkout_persistent_runtime_worker(pool2, 1000)
    assert result is free_entry
    assert result["busy"] is True

    # _release_persistent_runtime_worker: normal release, discard, bad cond, bad workers, entry not in workers.
    php_daemon._release_persistent_runtime_worker({"cond": "bad"}, {})
    lock5 = _threading.Lock()
    cond5 = _threading.Condition(lock5)
    php_daemon._release_persistent_runtime_worker({"cond": cond5, "workers": "bad"}, {})

    alive_worker3 = _FakePhpWorker(True)
    entry3 = {"worker": alive_worker3, "busy": True, "last_used": 0.0}
    pool3 = {"cond": cond5, "workers": [entry3], "last_used": 0.0}
    php_daemon._release_persistent_runtime_worker(pool3, entry3, discard=False)
    assert entry3["busy"] is False

    alive_worker4 = _FakePhpWorker(True)
    entry4 = {"worker": alive_worker4, "busy": True, "last_used": 0.0}
    pool4 = {"cond": cond5, "workers": [entry4], "last_used": 0.0}
    php_daemon._release_persistent_runtime_worker(pool4, entry4, discard=True)
    assert entry4 not in pool4["workers"]

    # _release_persistent_runtime_worker: dead worker gets discarded even without discard=True.
    dead_worker2 = _FakePhpWorker(False)
    entry5 = {"worker": dead_worker2, "busy": True, "last_used": 0.0}
    pool5 = {"cond": cond5, "workers": [entry5], "last_used": 0.0}
    php_daemon._release_persistent_runtime_worker(pool5, entry5, discard=False)
    assert entry5 not in pool5["workers"]

    # _release_persistent_runtime_worker: entry not in workers list (no-op).
    pool6 = {"cond": cond5, "workers": [], "last_used": 0.0}
    php_daemon._release_persistent_runtime_worker(pool6, {"worker": _FakePhpWorker(True), "busy": True})

    # _start_persistent_runtime_pool_reaper: early exits and reaper run.
    old_started = php_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED
    old_interval = php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    try:
        php_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = True
        php_daemon._start_persistent_runtime_pool_reaper()
        php_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 0
        php_daemon._start_persistent_runtime_pool_reaper()
    finally:
        php_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = old_started
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval

    # _start_persistent_runtime_pool_reaper: actual eviction.
    old_started = php_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED
    old_interval = php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread = php_daemon.threading.Thread
    old_sleep = php_daemon.time.sleep
    old_monotonic = php_daemon.time.monotonic
    old_shutdown = php_daemon._shutdown_persistent_runtime_pool
    old_pools = php_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        php_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        evicted_pools: list[str] = []

        persistent_pool = {
            "pending": 0,
            "min_warm": 0,
            "idle_ttl_ms": 1,
            "last_used": 1.0,
            "workers": [],
        }
        php_daemon._PERSISTENT_RUNTIME_POOLS = {"idle-persistent@v1": persistent_pool}
        php_daemon._shutdown_persistent_runtime_pool = lambda _p: evicted_pools.append("evicted")

        sleep_calls = {"n": 0}

        def fake_sleep(_seconds):
            sleep_calls["n"] += 1
            if sleep_calls["n"] > 1:
                raise StopIteration("stop")

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
        php_daemon._start_persistent_runtime_pool_reaper()
        assert php_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED is True
        assert evicted_pools, "persistent reaper should evict idle pools"
    finally:
        php_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = old_started
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        php_daemon.threading.Thread = old_thread
        php_daemon.time.sleep = old_sleep
        php_daemon.time.monotonic = old_monotonic
        php_daemon._shutdown_persistent_runtime_pool = old_shutdown
        php_daemon._PERSISTENT_RUNTIME_POOLS = old_pools

    # persistent reaper skips pools with pending > 0 or min_warm > 0.
    old_started = php_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED
    old_interval = php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS
    old_thread = php_daemon.threading.Thread
    old_sleep = php_daemon.time.sleep
    old_monotonic = php_daemon.time.monotonic
    old_shutdown = php_daemon._shutdown_persistent_runtime_pool
    old_pools = php_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        php_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = 1
        shutdown_calls_inner = {"n": 0}

        php_daemon._PERSISTENT_RUNTIME_POOLS = {
            "pending@v1": {"pending": 1, "min_warm": 0, "idle_ttl_ms": 1, "last_used": 0.0, "workers": []},
            "warm@v1": {"pending": 0, "min_warm": 1, "idle_ttl_ms": 1, "last_used": 0.0, "workers": []},
        }
        php_daemon._shutdown_persistent_runtime_pool = lambda _p: shutdown_calls_inner.update(n=shutdown_calls_inner["n"] + 1)

        sleep_calls2 = {"n": 0}

        def fake_sleep2(_seconds):
            sleep_calls2["n"] += 1
            if sleep_calls2["n"] > 1:
                raise RuntimeError("stop-reaper")

        php_daemon.time.sleep = fake_sleep2
        php_daemon.time.monotonic = lambda: 10.0

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

        php_daemon.threading.Thread = InlineThread2
        php_daemon._start_persistent_runtime_pool_reaper()
        assert shutdown_calls_inner["n"] == 0
    finally:
        php_daemon._PERSISTENT_RUNTIME_POOLS = old_pools
        php_daemon._PERSISTENT_RUNTIME_POOL_REAPER_STARTED = old_started
        php_daemon.RUNTIME_POOL_REAPER_INTERVAL_MS = old_interval
        php_daemon.threading.Thread = old_thread
        php_daemon.time.sleep = old_sleep
        php_daemon.time.monotonic = old_monotonic
        php_daemon._shutdown_persistent_runtime_pool = old_shutdown

    # _ensure_persistent_runtime_pool: create new, reuse existing, replace with different max_workers.
    old_pools = php_daemon._PERSISTENT_RUNTIME_POOLS
    old_lock = php_daemon._PERSISTENT_RUNTIME_POOLS_LOCK
    old_start_reaper = php_daemon._start_persistent_runtime_pool_reaper
    old_warmup = php_daemon._warmup_persistent_runtime_pool
    old_shutdown = php_daemon._shutdown_persistent_runtime_pool
    try:
        php_daemon._PERSISTENT_RUNTIME_POOLS = {}
        php_daemon._PERSISTENT_RUNTIME_POOLS_LOCK = _threading.Lock()
        php_daemon._start_persistent_runtime_pool_reaper = lambda: None
        php_daemon._warmup_persistent_runtime_pool = lambda _pool: None
        stale_shutdowns: list[str] = []
        php_daemon._shutdown_persistent_runtime_pool = lambda _p: stale_shutdowns.append("x")

        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "app.php"
            handler.write_text("<?php", encoding="utf-8")

            p1 = php_daemon._ensure_persistent_runtime_pool(
                "test@v1", handler,
                {"max_workers": 2, "min_warm": 0, "idle_ttl_ms": 1000, "acquire_timeout_ms": 5000}
            )
            assert p1["max_workers"] == 2

            p2 = php_daemon._ensure_persistent_runtime_pool(
                "test@v1", handler,
                {"max_workers": 2, "min_warm": 1, "idle_ttl_ms": 2000, "acquire_timeout_ms": 5000}
            )
            assert p2 is p1
            assert p2["min_warm"] == 1
            assert p2["idle_ttl_ms"] == 2000

            p3 = php_daemon._ensure_persistent_runtime_pool(
                "test@v1", handler,
                {"max_workers": 4, "min_warm": 0, "idle_ttl_ms": 1000, "acquire_timeout_ms": 5000}
            )
            assert p3 is not p1
            assert p3["max_workers"] == 4
            assert stale_shutdowns, "old pool should be shut down when max_workers changes"
    finally:
        php_daemon._PERSISTENT_RUNTIME_POOLS = old_pools
        php_daemon._PERSISTENT_RUNTIME_POOLS_LOCK = old_lock
        php_daemon._start_persistent_runtime_pool_reaper = old_start_reaper
        php_daemon._warmup_persistent_runtime_pool = old_warmup
        php_daemon._shutdown_persistent_runtime_pool = old_shutdown

    # _run_prepared_request_persistent: timeout and generic exception paths.
    old_ensure = php_daemon._ensure_persistent_runtime_pool
    old_checkout = php_daemon._checkout_persistent_runtime_worker
    old_release = php_daemon._release_persistent_runtime_worker
    old_pools = php_daemon._PERSISTENT_RUNTIME_POOLS
    try:
        fake_pool = {
            "cond": _threading.Condition(_threading.Lock()),
            "workers": [],
            "max_workers": 1,
            "pending": 0,
            "last_used": 0.0,
        }
        php_daemon._ensure_persistent_runtime_pool = lambda *_a, **_k: fake_pool
        php_daemon._PERSISTENT_RUNTIME_POOLS = {"test-key": fake_pool}

        php_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: (_ for _ in ()).throw(TimeoutError("timeout"))
        resp = php_daemon._run_prepared_request_persistent(
            "test-key", Path("/tmp/app.php"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp["status"] == 504

        php_daemon._checkout_persistent_runtime_worker = lambda *_a, **_k: (_ for _ in ()).throw(RuntimeError("generic error"))
        resp2 = php_daemon._run_prepared_request_persistent(
            "test-key", Path("/tmp/app.php"), {}, 100, {"acquire_timeout_ms": 50}
        )
        assert resp2["status"] == 500
    finally:
        php_daemon._ensure_persistent_runtime_pool = old_ensure
        php_daemon._checkout_persistent_runtime_worker = old_checkout
        php_daemon._release_persistent_runtime_worker = old_release
        php_daemon._PERSISTENT_RUNTIME_POOLS = old_pools

    # _append_runtime_log: cover writing to file and exception path.
    old_log = php_daemon.RUNTIME_LOG_FILE
    try:
        php_daemon.RUNTIME_LOG_FILE = ""
        php_daemon._append_runtime_log("php", "should no-op")

        with tempfile.TemporaryDirectory() as tmp:
            log_path = str(Path(tmp) / "test.log")
            php_daemon.RUNTIME_LOG_FILE = log_path
            php_daemon._append_runtime_log("php", "test line")
            assert Path(log_path).read_text(encoding="utf-8") == "[php] test line\n"

        php_daemon.RUNTIME_LOG_FILE = "/nonexistent/path/log.txt"
        php_daemon._append_runtime_log("php", "should not crash")
    finally:
        php_daemon.RUNTIME_LOG_FILE = old_log

    # _emit_handler_logs: non-dict resp and empty/missing stdout/stderr.
    stdout_buf = io.StringIO()
    stderr_buf = io.StringIO()
    with redirect_stdout(stdout_buf), redirect_stderr(stderr_buf):
        php_daemon._emit_handler_logs({}, "bad-resp")
        php_daemon._emit_handler_logs({}, {"stdout": "", "stderr": ""})
        php_daemon._emit_handler_logs({}, {"stdout": None, "stderr": None})
        php_daemon._emit_handler_logs({}, {})
    assert stdout_buf.getvalue() == ""
    assert stderr_buf.getvalue() == ""

    # _resolve_command: path-based, name-based, and missing.
    old_env = os.environ.get("FN_TEST_RESOLVE")
    old_which = php_daemon.shutil.which
    try:
        os.environ["FN_TEST_RESOLVE"] = "/usr/bin/python3"
        if Path("/usr/bin/python3").is_file():
            result = php_daemon._resolve_command("FN_TEST_RESOLVE", "python3")
            assert result == "/usr/bin/python3"

        os.environ["FN_TEST_RESOLVE"] = "/nonexistent/binary"
        try:
            php_daemon._resolve_command("FN_TEST_RESOLVE", "python3")
        except RuntimeError as exc:
            assert "not executable" in str(exc).lower()
        else:
            raise AssertionError("expected not executable error")

        os.environ["FN_TEST_RESOLVE"] = "nonexistent-binary-name"
        php_daemon.shutil.which = lambda _name: None
        try:
            php_daemon._resolve_command("FN_TEST_RESOLVE", "python3")
        except RuntimeError as exc:
            assert "not found" in str(exc).lower()
        else:
            raise AssertionError("expected not found error")

        os.environ.pop("FN_TEST_RESOLVE", None)
        php_daemon.shutil.which = lambda _name: None
        try:
            php_daemon._resolve_command("FN_TEST_RESOLVE", "nonexistent-default")
        except RuntimeError as exc:
            assert "not found" in str(exc).lower()
        else:
            raise AssertionError("expected default not found error")

        os.environ.pop("FN_TEST_RESOLVE", None)
        php_daemon.shutil.which = lambda _name: "/usr/bin/python3"
        result = php_daemon._resolve_command("FN_TEST_RESOLVE", "python3")
        assert result == "/usr/bin/python3"
    finally:
        if old_env is None:
            os.environ.pop("FN_TEST_RESOLVE", None)
        else:
            os.environ["FN_TEST_RESOLVE"] = old_env
        php_daemon.shutil.which = old_which

    # _recvall: partial read with connection close.
    left, right = socket.socketpair()
    with left, right:
        right.sendall(b"\x01\x02")
        right.shutdown(socket.SHUT_WR)
        data = php_daemon._recvall(left, 4)
        assert len(data) == 2

    # _error_response shape check.
    err = php_daemon._error_response("test error", status=418)
    assert err["status"] == 418
    assert "test error" in err["body"]

    # _patched_process_env with empty dict (no-op yield).
    with php_daemon._patched_process_env({}):
        pass
    with php_daemon._patched_process_env(None):
        pass

    # _normalize_worker_pool_settings: context is not dict.
    s = php_daemon._normalize_worker_pool_settings({"event": {"context": "bad"}})
    assert s["enabled"] is False
    assert s["max_workers"] == 0

    # _normalize_worker_pool_settings: worker_pool is not dict.
    s2 = php_daemon._normalize_worker_pool_settings({"event": {"context": {"worker_pool": "bad"}}})
    assert s2["enabled"] is False

    # _normalize_worker_pool_settings: enabled explicitly False.
    s3 = php_daemon._normalize_worker_pool_settings(
        {"event": {"context": {"worker_pool": {"enabled": False, "max_workers": 2}}}}
    )
    assert s3["enabled"] is False

    # _bool_env: empty string returns default.
    old_env_val = os.environ.get("UNIT_BOOL_EMPTY")
    try:
        os.environ["UNIT_BOOL_EMPTY"] = ""
        assert php_daemon._bool_env("UNIT_BOOL_EMPTY", True) is True
        assert php_daemon._bool_env("UNIT_BOOL_EMPTY", False) is False
    finally:
        if old_env_val is None:
            os.environ.pop("UNIT_BOOL_EMPTY", None)
        else:
            os.environ["UNIT_BOOL_EMPTY"] = old_env_val

    # _ensure_composer_deps: subprocess.TimeoutExpired path.
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        handler = fn_dir / "app.php"
        handler.write_text("<?php", encoding="utf-8")
        composer_json = fn_dir / "composer.json"
        composer_json.write_text(json.dumps({"require": {}}), encoding="utf-8")

        old_auto = php_daemon.AUTO_COMPOSER_DEPS
        old_which = php_daemon.shutil.which
        old_run = php_daemon.subprocess.run
        old_cache = dict(php_daemon._COMPOSER_CACHE)
        try:
            php_daemon.AUTO_COMPOSER_DEPS = True
            php_daemon.shutil.which = lambda _name: "/usr/bin/composer"
            php_daemon._COMPOSER_CACHE.clear()

            def timeout_run(*_a, **_k):
                raise php_daemon.subprocess.TimeoutExpired(cmd="composer", timeout=180)

            php_daemon.subprocess.run = timeout_run
            try:
                php_daemon._ensure_composer_deps(handler)
            except php_daemon.subprocess.TimeoutExpired:
                pass
        finally:
            php_daemon.AUTO_COMPOSER_DEPS = old_auto
            php_daemon.shutil.which = old_which
            php_daemon.subprocess.run = old_run
            php_daemon._COMPOSER_CACHE.clear()
            php_daemon._COMPOSER_CACHE.update(old_cache)


def main() -> None:
    test_bool_env()
    test_parse_extra_allow_roots_and_function_env()
    test_read_write_frame_paths()
    test_resolve_handler_path_and_normalize_response()
    test_run_php_handler_and_direct_request_paths()
    test_pool_and_serve_conn_paths()
    test_composer_deps_reaper_and_main_paths()
    test_additional_edge_branches()
    test_php_worker_has_reflection_param_injection()
    test_php_handle_request_passes_params_through()
    test_persistent_pool_lifecycle()
    print("php daemon unit tests passed")


if __name__ == "__main__":
    main()
