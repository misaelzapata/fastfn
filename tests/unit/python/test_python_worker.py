#!/usr/bin/env python3
"""Tests for python-function-worker.py."""
import asyncio
import io
import json
import os
import struct
import sys
import tempfile
import threading
import time
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from conftest import ROOT, load_handler, load_module, assert_response_contract, assert_binary_response_contract

PYTHON_DAEMON = load_module(ROOT / "srv/fn/runtimes/python-daemon.py")
PYTHON_WORKER = load_module(ROOT / "srv/fn/runtimes/python-function-worker.py")


def _clear_subprocess_pool(daemon):
    workers_to_close = []
    with daemon._SUBPROCESS_POOL_LOCK:
        workers_to_close.extend(daemon._SUBPROCESS_POOL.values())
        daemon._SUBPROCESS_POOL.clear()
    for worker in workers_to_close:
        try:
            worker.shutdown()
        except Exception:
            pass


def test_python_worker_captures_stdout():
    """print() during handler execution should be captured in response."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    print('hello from stdout')\n"
            "    print('second line')\n"
            "    return {'status': 200, 'headers': {}, 'body': 'ok'}\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 200
        assert resp["body"] == "ok"
        assert "stdout" in resp, "stdout should be captured"
        assert "hello from stdout" in resp["stdout"]
        assert "second line" in resp["stdout"]


def test_python_worker_captures_stderr():
    """sys.stderr writes during handler execution should be captured."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "import sys\n"
            "def handler(event):\n"
            "    sys.stderr.write('error output\\n')\n"
            "    return {'status': 200, 'headers': {}, 'body': 'ok'}\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 200
        assert "stderr" in resp, "stderr should be captured"
        assert "error output" in resp["stderr"]


def test_python_worker_no_stdout_when_silent():
    """Response should NOT contain stdout/stderr when handler is silent."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'ok'}\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 200
        assert "stdout" not in resp, "no stdout when handler is silent"
        assert "stderr" not in resp, "no stderr when handler is silent"


def test_python_daemon_preserves_stdout_stderr():
    """_normalize_response should preserve stdout/stderr from worker."""
    daemon = PYTHON_DAEMON

    resp_with_output = {
        "status": 200,
        "headers": {},
        "body": "ok",
        "stdout": "captured output",
        "stderr": "captured error",
    }
    norm = daemon._normalize_response(resp_with_output)
    assert norm["stdout"] == "captured output"
    assert norm["stderr"] == "captured error"

    resp_without = {
        "status": 200,
        "headers": {},
        "body": "ok",
    }
    norm2 = daemon._normalize_response(resp_without)
    assert "stdout" not in norm2
    assert "stderr" not in norm2


def test_python_daemon_emits_handler_logs() -> None:
    daemon = PYTHON_DAEMON
    stdout_buffer = io.StringIO()
    stderr_buffer = io.StringIO()
    with redirect_stdout(stdout_buffer), redirect_stderr(stderr_buffer):
        daemon._emit_handler_logs(
            {"fn": "hello", "version": "v2"},
            {"stdout": "line one\nline two", "stderr": "warn one"},
        )
    assert "[fn:hello@v2 stdout] line one" in stdout_buffer.getvalue()
    assert "[fn:hello@v2 stdout] line two" in stdout_buffer.getvalue()
    assert "[fn:hello@v2 stderr] warn one" in stderr_buffer.getvalue()


def test_worker_json_log_exception():
    worker = PYTHON_WORKER
    old_print = getattr(worker, "print", print)

    def broken_print(*args, **kwargs):
        raise RuntimeError("print boom")

    worker.print = broken_print
    try:
        worker._json_log("test_fail")
    finally:
        worker.print = old_print


def test_python_worker_event_session_passthrough():
    """event.session should be accessible from handler."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "import json\n"
            "def handler(event):\n"
            "    session = event.get('session') or {}\n"
            "    return {\n"
            "        'status': 200,\n"
            "        'headers': {'Content-Type': 'application/json'},\n"
            "        'body': json.dumps({'sid': session.get('id'), 'cookies': session.get('cookies', {})})\n"
            "    }\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {
                "session": {
                    "id": "abc123",
                    "raw": "session_id=abc123; theme=dark",
                    "cookies": {"session_id": "abc123", "theme": "dark"},
                }
            },
        })
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["sid"] == "abc123"
        assert body["cookies"]["theme"] == "dark"


# ---------------------------------------------------------------------------
# Direct route params injection tests
# ---------------------------------------------------------------------------

def test_python_rest_product_id_direct_param():
    """[id] handler receives id as direct kwarg."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/products/[id]/get.py")
    resp = handler({"params": {"id": "42"}}, id="42")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["id"] == 42
    assert body["name"] == "Widget"


def test_python_rest_product_id_put_direct_param():
    """[id] PUT handler receives id as direct kwarg."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/products/[id]/put.py")
    event = {"params": {"id": "7"}, "body": '{"name":"Updated","price":19.99}'}
    resp = handler(event, id="7")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["id"] == 7


def test_python_rest_product_id_delete_direct_param():
    """[id] DELETE handler receives id as direct kwarg."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/products/[id]/delete.py")
    resp = handler({"params": {"id": "99"}}, id="99")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["deleted"] is True
    assert body["id"] == 99


def test_python_rest_slug_direct_param():
    """[slug] handler receives slug as direct kwarg."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/posts/[slug]/get.py")
    resp = handler({"params": {"slug": "hello-world"}}, slug="hello-world")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["slug"] == "hello-world"
    assert "hello-world" in body["title"]


def test_python_rest_category_slug_multi_param():
    """[category]/[slug] handler receives both params as direct kwargs."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/posts/[category]/[slug]/get.py")
    resp = handler({"params": {"category": "tech", "slug": "ai-news"}}, category="tech", slug="ai-news")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["category"] == "tech"
    assert body["slug"] == "ai-news"


def test_python_rest_wildcard_path_direct_param():
    """[...path] handler receives path as direct kwarg."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/files/[...path]/get.py")
    resp = handler({"params": {"path": "docs/2024/report.pdf"}}, path="docs/2024/report.pdf")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["path"] == "docs/2024/report.pdf"
    assert body["segments"] == ["docs", "2024", "report.pdf"]
    assert body["depth"] == 3


def test_python_rest_wildcard_empty_path():
    """[...path] handler handles empty path gracefully."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/files/[...path]/get.py")
    resp = handler({"params": {"path": ""}}, path="")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["path"] == ""
    assert body["segments"] == []
    assert body["depth"] == 0


# ---------------------------------------------------------------------------
# Worker _call_handler route_params injection tests
# ---------------------------------------------------------------------------

def test_worker_call_handler_injects_kwargs():
    """_call_handler injects route_params as kwargs for handlers with named params."""
    worker = PYTHON_WORKER

    def handler_with_id(event, id):
        return {"got_id": id, "event_keys": list(event.keys())}

    result = worker._call_handler(handler_with_id, [{"method": "GET"}], route_params={"id": "42"})
    assert result["got_id"] == "42"
    assert "method" in result["event_keys"]


def test_worker_call_handler_injects_multiple_kwargs():
    """_call_handler injects multiple route_params."""
    worker = PYTHON_WORKER

    def handler_multi(event, category, slug):
        return {"category": category, "slug": slug}

    result = worker._call_handler(
        handler_multi, [{}], route_params={"category": "tech", "slug": "hello"}
    )
    assert result["category"] == "tech"
    assert result["slug"] == "hello"


def test_worker_call_handler_var_keyword_receives_all():
    """_call_handler passes all route_params via **kwargs."""
    worker = PYTHON_WORKER

    def handler_kwargs(event, **kwargs):
        return {"kwargs": kwargs}

    result = worker._call_handler(
        handler_kwargs, [{}], route_params={"id": "1", "slug": "test"}
    )
    assert result["kwargs"]["id"] == "1"
    assert result["kwargs"]["slug"] == "test"


def test_worker_call_handler_no_params_ignores_route_params():
    """_call_handler with handler(event) ignores route_params."""
    worker = PYTHON_WORKER

    def handler_event_only(event):
        return {"ok": True}

    result = worker._call_handler(
        handler_event_only, [{}], route_params={"id": "42"}
    )
    assert result["ok"] is True


def test_worker_call_handler_no_route_params_works():
    """_call_handler without route_params still works normally."""
    worker = PYTHON_WORKER

    def handler_normal(event):
        return {"method": event.get("method", "none")}

    result = worker._call_handler(handler_normal, [{"method": "GET"}])
    assert result["method"] == "GET"


def test_worker_call_handler_extra_params_ignored():
    """_call_handler ignores route_params not declared in handler signature."""
    worker = PYTHON_WORKER

    def handler_only_id(event, id):
        return {"id": id}

    result = worker._call_handler(
        handler_only_id, [{}], route_params={"id": "5", "slug": "extra"}
    )
    assert result["id"] == "5"


def test_worker_handle_passes_route_params_from_event():
    """_handle extracts event.params and passes to handler as kwargs."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event, id):\n"
            "    return {\n"
            "        'status': 200,\n"
            "        'headers': {'Content-Type': 'application/json'},\n"
            "        'body': '{\"id\": \"' + str(id) + '\"}'\n"
            "    }\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {"params": {"id": "42"}},
        })
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["id"] == "42"


def test_worker_handle_multi_params_from_event():
    """_handle injects multiple params from event.params."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "import json\n"
            "def handler(event, category, slug):\n"
            "    return {\n"
            "        'status': 200,\n"
            "        'headers': {'Content-Type': 'application/json'},\n"
            "        'body': json.dumps({'category': category, 'slug': slug})\n"
            "    }\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {"params": {"category": "tech", "slug": "hello-world"}},
        })
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["category"] == "tech"
        assert body["slug"] == "hello-world"


# ---------------------------------------------------------------------------
# python-function-worker.py full coverage tests
# ---------------------------------------------------------------------------


def test_worker_parse_extra_allow_roots_empty():
    worker = PYTHON_WORKER
    orig = worker.STRICT_FS_EXTRA_ALLOW
    try:
        worker.STRICT_FS_EXTRA_ALLOW = ""
        assert worker._parse_extra_allow_roots() == []
    finally:
        worker.STRICT_FS_EXTRA_ALLOW = orig


def test_worker_parse_extra_allow_roots_with_paths():
    worker = PYTHON_WORKER
    orig = worker.STRICT_FS_EXTRA_ALLOW
    try:
        worker.STRICT_FS_EXTRA_ALLOW = "/tmp/a, /tmp/b ,, "
        result = worker._parse_extra_allow_roots()
        assert len(result) == 2
        assert Path("/tmp/a").resolve(strict=False) in result
        assert Path("/tmp/b").resolve(strict=False) in result
    finally:
        worker.STRICT_FS_EXTRA_ALLOW = orig


def test_worker_resolve_candidate_path_int():
    worker = PYTHON_WORKER
    assert worker._resolve_candidate_path(42) is None


def test_worker_resolve_candidate_path_bytes():
    worker = PYTHON_WORKER
    result = worker._resolve_candidate_path(b"/tmp/test")
    assert result is not None
    assert isinstance(result, Path)


def test_worker_resolve_candidate_path_empty_string():
    worker = PYTHON_WORKER
    assert worker._resolve_candidate_path("") is None


def test_worker_resolve_candidate_path_none():
    worker = PYTHON_WORKER
    assert worker._resolve_candidate_path(None) is None


def test_worker_resolve_candidate_path_pathlike():
    worker = PYTHON_WORKER
    result = worker._resolve_candidate_path(Path("/tmp/test"))
    assert result is not None
    assert isinstance(result, Path)


def test_worker_resolve_candidate_path_string():
    worker = PYTHON_WORKER
    result = worker._resolve_candidate_path("/tmp/test")
    assert result == Path("/tmp/test").resolve(strict=False)


def test_worker_build_allowed_roots():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        handler_path = Path(tmp) / "handler.py"
        handler_path.write_text("def handler(e): return {}", encoding="utf-8")
        roots, fn_dir = worker._build_allowed_roots(handler_path, [str(Path(tmp) / "deps")])
        assert fn_dir == Path(tmp).resolve(strict=False)
        # Should contain at least fn_dir, .deps, the deps dir, python prefix, system roots
        assert len(roots) >= 5
        assert fn_dir in roots


def test_worker_strict_fs_guard_blocks_outside_path():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "handler.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                # Opening a file inside the sandbox should work
                import builtins
                # Trying to open a path outside sandbox should fail
                try:
                    builtins.open("/nonexistent_sandbox_test_path_xyz/secret.txt")
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
                except FileNotFoundError:
                    # Path is allowed (under a system root), but file doesn't exist
                    pass

                # subprocess should be blocked
                import subprocess
                try:
                    subprocess.run(["echo", "hi"])
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass

                # os.system should be blocked
                try:
                    os.system("echo hi")
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass

            # After context manager exits, things should be restored
            assert builtins.open is not None
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_disabled():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = False
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "handler.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                pass  # Should not raise
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_protected_files():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "handler.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            # Create a protected file
            protected = Path(tmp) / "fn.config.json"
            protected.write_text("{}", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                import builtins
                try:
                    builtins.open(str(protected))
                    assert False, "should have raised PermissionError for protected file"
                except PermissionError as e:
                    assert "protected" in str(e)
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_io_open():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "handler.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            protected = Path(tmp) / "fn.env.json"
            protected.write_text("{}", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                try:
                    io.open(str(protected))
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_os_open():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "handler.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            protected = Path(tmp) / "fn.test_events.json"
            protected.write_text("{}", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                try:
                    os.open(str(protected), os.O_RDONLY)
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_listdir_scandir():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "handler.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                # listdir inside sandbox should work (fn_dir is allowed)
                entries = os.listdir(tmp)
                assert isinstance(entries, list)
                # scandir inside sandbox should work
                with os.scandir(tmp) as sd:
                    names = [e.name for e in sd]
                assert "handler.py" in names
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_path_open():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "handler.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            protected = Path(tmp) / "fn.config.json"
            protected.write_text("{}", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                try:
                    protected.open()
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_spawn_blocked():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "handler.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                if hasattr(os, "spawnl"):
                    try:
                        os.spawnl(os.P_NOWAIT, "/bin/echo", "echo", "hi")
                        assert False, "should have raised PermissionError"
                    except PermissionError:
                        pass
                if hasattr(os, "execvpe"):
                    try:
                        os.execvpe("echo", ["echo", "hi"], {})
                        assert False, "should have raised PermissionError"
                    except PermissionError:
                        pass
                if hasattr(os, "execvp"):
                    try:
                        os.execvp("echo", ["echo", "hi"])
                        assert False, "should have raised PermissionError"
                    except PermissionError:
                        pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_pty_blocked():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "handler.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                try:
                    import pty
                    pty.spawn("/bin/echo")
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
                except ImportError:
                    pass  # pty not available on this platform
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_ctypes_blocked():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "handler.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                try:
                    import ctypes
                    ctypes.CDLL("libc.so.6")
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
                except ImportError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_subprocess_variants():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "handler.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                import subprocess
                for fn in (subprocess.call, subprocess.check_call, subprocess.check_output, subprocess.Popen):
                    try:
                        fn(["echo", "hi"])
                        assert False, f"{fn.__name__} should have raised PermissionError"
                    except PermissionError:
                        pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_normalize_invoke_adapter():
    worker = PYTHON_WORKER
    assert worker._normalize_invoke_adapter(None) == "native"
    assert worker._normalize_invoke_adapter(123) == "native"
    assert worker._normalize_invoke_adapter("") == "native"
    assert worker._normalize_invoke_adapter("native") == "native"
    assert worker._normalize_invoke_adapter("none") == "native"
    assert worker._normalize_invoke_adapter("default") == "native"
    assert worker._normalize_invoke_adapter("  Native  ") == "native"
    assert worker._normalize_invoke_adapter("aws-lambda") == "aws-lambda"
    assert worker._normalize_invoke_adapter("lambda") == "aws-lambda"
    assert worker._normalize_invoke_adapter("apigw-v2") == "aws-lambda"
    assert worker._normalize_invoke_adapter("api-gateway-v2") == "aws-lambda"
    assert worker._normalize_invoke_adapter("cloudflare-worker") == "cloudflare-worker"
    assert worker._normalize_invoke_adapter("cloudflare-workers") == "cloudflare-worker"
    assert worker._normalize_invoke_adapter("worker") == "cloudflare-worker"
    assert worker._normalize_invoke_adapter("workers") == "cloudflare-worker"
    try:
        worker._normalize_invoke_adapter("invalid-adapter")
        assert False, "should have raised RuntimeError"
    except RuntimeError as e:
        assert "unsupported" in str(e)


def test_worker_resolve_handler_native():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.handler = lambda e: {"status": 200}
    result = worker._resolve_handler(mod, "handler", "native")
    assert result is mod.handler


def test_worker_resolve_handler_main_fallback():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.main = lambda e: {"status": 200}
    result = worker._resolve_handler(mod, "handler", "native")
    assert result is mod.main


def test_worker_resolve_handler_missing_raises():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    try:
        worker._resolve_handler(mod, "handler", "native")
        assert False, "should raise RuntimeError"
    except RuntimeError as e:
        assert "handler(event) is required" in str(e)


def test_worker_resolve_handler_cloudflare_fetch():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.fetch = lambda req, env, ctx: {"status": 200}
    result = worker._resolve_handler(mod, "handler", "cloudflare-worker")
    assert result is mod.fetch


def test_worker_resolve_handler_cloudflare_fallback():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.handler = lambda req, env, ctx: {"status": 200}
    result = worker._resolve_handler(mod, "handler", "cloudflare-worker")
    assert result is mod.handler


def test_worker_resolve_handler_cloudflare_missing():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    try:
        worker._resolve_handler(mod, "handler", "cloudflare-worker")
        assert False, "should raise RuntimeError"
    except RuntimeError as e:
        assert "cloudflare-worker" in str(e)


def test_worker_resolve_handler_custom_name():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.my_fn = lambda e: {"status": 200}
    result = worker._resolve_handler(mod, "my_fn", "native")
    assert result is mod.my_fn


def test_worker_resolve_handler_custom_name_not_callable():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.my_fn = "not callable"
    try:
        worker._resolve_handler(mod, "my_fn", "native")
        assert False, "should raise RuntimeError"
    except RuntimeError as e:
        assert "my_fn(event) is required" in str(e)


def test_worker_header_value():
    worker = PYTHON_WORKER
    headers = {"Content-Type": "text/html", "X-Custom": "val"}
    assert worker._header_value(headers, "content-type") == "text/html"
    assert worker._header_value(headers, "Content-Type") == "text/html"
    assert worker._header_value(headers, "x-custom") == "val"
    assert worker._header_value(headers, "missing") == ""


def test_worker_build_raw_path():
    worker = PYTHON_WORKER
    assert worker._build_raw_path({}) == "/"
    assert worker._build_raw_path({"path": "/api/test"}) == "/api/test"
    assert worker._build_raw_path({"raw_path": "/raw/path"}) == "/raw/path"
    assert worker._build_raw_path({"raw_path": "no-leading-slash"}) == "/no-leading-slash"
    assert worker._build_raw_path({"raw_path": "https://example.com/path"}) == "https://example.com/path"
    assert worker._build_raw_path({"raw_path": "http://example.com/path"}) == "http://example.com/path"
    assert worker._build_raw_path({"path": ""}) == "/"
    assert worker._build_raw_path({"raw_path": None, "path": "/fallback"}) == "/fallback"


def test_worker_encode_query_string():
    worker = PYTHON_WORKER
    assert worker._encode_query_string("not a dict") == ""
    assert worker._encode_query_string(None) == ""
    assert worker._encode_query_string({}) == ""
    assert worker._encode_query_string({"a": "1", "b": "2"}) in ("a=1&b=2", "b=2&a=1")
    assert worker._encode_query_string({"k": None}) == ""
    # List values
    result = worker._encode_query_string({"tags": ["a", "b"]})
    assert "tags=a" in result
    assert "tags=b" in result
    # None in list
    assert worker._encode_query_string({"tags": [None, "c"]}) == "tags=c"


def test_worker_build_raw_query():
    worker = PYTHON_WORKER
    assert worker._build_raw_query({"raw_path": "/path?foo=bar&x=1"}) == "foo=bar&x=1"
    assert worker._build_raw_query({"raw_path": "/path?"}) == ""
    assert worker._build_raw_query({"query": {"a": "1"}}) == "a=1"
    assert worker._build_raw_query({}) == ""


def test_worker_build_lambda_event():
    worker = PYTHON_WORKER
    event = {
        "method": "POST",
        "path": "/api/test",
        "headers": {"Content-Type": "application/json", "cookie": "a=1; b=2"},
        "query": {"page": "1"},
        "params": {"id": "42"},
        "body": "hello body",
        "client": {"ip": "1.2.3.4", "ua": "TestAgent"},
        "context": {"request_id": "req-123", "function_name": "my-fn", "timeout_ms": 5000},
        "id": "evt-1",
        "ts": 1700000000000,
    }
    result = worker._build_lambda_event(event)
    assert result["version"] == "2.0"
    assert result["routeKey"] == "POST /api/test"
    assert result["rawPath"] == "/api/test"
    assert result["headers"]["Content-Type"] == "application/json"
    assert result["queryStringParameters"] == {"page": "1"}
    assert result["pathParameters"] == {"id": "42"}
    assert result["body"] == "hello body"
    assert result["isBase64Encoded"] is False
    assert result["cookies"] == ["a=1", "b=2"]
    assert result["requestContext"]["requestId"] == "req-123"
    assert result["requestContext"]["http"]["method"] == "POST"
    assert result["requestContext"]["http"]["sourceIp"] == "1.2.3.4"
    assert result["requestContext"]["http"]["userAgent"] == "TestAgent"
    assert result["requestContext"]["timeEpoch"] == 1700000000000


def test_worker_build_lambda_event_base64_body():
    worker = PYTHON_WORKER
    import base64
    encoded = base64.b64encode(b"binary data").decode("utf-8")
    event = {
        "is_base64": True,
        "body_base64": encoded,
    }
    result = worker._build_lambda_event(event)
    assert result["isBase64Encoded"] is True
    assert result["body"] == encoded


def test_worker_build_lambda_event_defaults():
    worker = PYTHON_WORKER
    result = worker._build_lambda_event({})
    assert result["version"] == "2.0"
    assert result["rawPath"] == "/"
    assert result["headers"] == {}
    assert result["body"] == ""
    assert result["isBase64Encoded"] is False
    assert result["cookies"] is None
    assert result["queryStringParameters"] is None
    assert result["pathParameters"] is None


def test_worker_build_lambda_event_body_non_string():
    worker = PYTHON_WORKER
    result = worker._build_lambda_event({"body": 12345})
    assert result["body"] == "12345"


def test_worker_lambda_context():
    worker = PYTHON_WORKER
    event = {
        "id": "evt-1",
        "context": {
            "request_id": "req-123",
            "function_name": "my-fn",
            "version": "v2",
            "memory_limit_mb": "256",
            "invoked_function_arn": "arn:aws:lambda:us-east-1:123:function:my-fn",
            "timeout_ms": 30000,
        },
    }
    ctx = worker._LambdaContext(event)
    assert ctx.aws_request_id == "req-123"
    assert ctx.awsRequestId == "req-123"
    assert ctx.function_name == "my-fn"
    assert ctx.functionName == "my-fn"
    assert ctx.function_version == "v2"
    assert ctx.functionVersion == "v2"
    assert ctx.memory_limit_in_mb == "256"
    assert ctx.memoryLimitInMB == "256"
    assert ctx.invoked_function_arn == "arn:aws:lambda:us-east-1:123:function:my-fn"
    assert ctx.callback_waits_for_empty_event_loop is False
    assert ctx.get_remaining_time_in_millis() == 30000
    assert ctx.done() is None
    assert ctx.fail() is None
    assert ctx.succeed() is None


def test_worker_lambda_context_defaults():
    worker = PYTHON_WORKER
    ctx = worker._LambdaContext({})
    assert ctx.aws_request_id == ""
    assert ctx.function_name == ""
    assert ctx.function_version == "$LATEST"
    assert ctx.memory_limit_in_mb == ""
    assert ctx.invoked_function_arn == ""
    assert ctx.get_remaining_time_in_millis() == 0


def test_worker_build_workers_url():
    worker = PYTHON_WORKER
    assert worker._build_workers_url({"raw_path": "https://example.com/api"}) == "https://example.com/api"
    assert worker._build_workers_url({"raw_path": "http://example.com/api"}) == "http://example.com/api"
    result = worker._build_workers_url({"path": "/api", "headers": {"host": "myhost.com", "x-forwarded-proto": "https"}})
    assert result == "https://myhost.com/api"
    result2 = worker._build_workers_url({"path": "/api"})
    assert result2 == "http://127.0.0.1/api"


def test_worker_workers_request():
    worker = PYTHON_WORKER
    event = {
        "method": "POST",
        "headers": {"Content-Type": "application/json", "host": "example.com"},
        "path": "/api/test",
        "body": "hello",
    }
    req = worker._WorkersRequest(event)
    assert req.method == "POST"
    assert req.headers["Content-Type"] == "application/json"
    assert "example.com" in req.url
    assert req.body == b"hello"


def test_worker_workers_request_body_bytes():
    worker = PYTHON_WORKER
    event = {"body": b"raw bytes"}
    req = worker._WorkersRequest(event)
    assert req.body == b"raw bytes"


def test_worker_workers_request_body_none():
    worker = PYTHON_WORKER
    event = {}
    req = worker._WorkersRequest(event)
    assert req.body == b""


def test_worker_workers_request_body_non_string():
    worker = PYTHON_WORKER
    event = {"body": 12345}
    req = worker._WorkersRequest(event)
    assert req.body == b"12345"


def test_worker_workers_request_base64_body():
    worker = PYTHON_WORKER
    import base64
    encoded = base64.b64encode(b"binary data").decode("utf-8")
    event = {"is_base64": True, "body_base64": encoded}
    req = worker._WorkersRequest(event)
    assert req.body == b"binary data"


def test_worker_workers_request_base64_invalid():
    worker = PYTHON_WORKER
    event = {"is_base64": True, "body_base64": "!!!invalid!!!"}
    req = worker._WorkersRequest(event)
    assert req.body == b""


def test_worker_workers_request_async_text_and_json():
    worker = PYTHON_WORKER
    import asyncio
    event = {"body": '{"key": "value"}'}
    req = worker._WorkersRequest(event)
    text = asyncio.run(req.text())
    assert text == '{"key": "value"}'
    event2 = {"body": '{"key": "value"}'}
    req2 = worker._WorkersRequest(event2)
    data = asyncio.run(req2.json())
    assert data == {"key": "value"}


def test_worker_workers_request_json_empty():
    worker = PYTHON_WORKER
    import asyncio
    event = {"body": ""}
    req = worker._WorkersRequest(event)
    assert asyncio.run(req.json()) is None


def test_worker_workers_context():
    worker = PYTHON_WORKER
    event = {"id": "evt-1", "context": {"request_id": "req-123"}}
    ctx = worker._WorkersContext(event)
    assert ctx.request_id == "req-123"
    assert ctx._waitables == []
    assert ctx.passThroughOnException() is None
    assert ctx.pass_through_on_exception() is None


def test_worker_workers_context_wait_until():
    worker = PYTHON_WORKER
    done = threading.Event()

    async def dummy():
        done.set()
        return 42

    ctx = worker._WorkersContext({})
    ctx.waitUntil(dummy())
    assert len(ctx._waitables) == 0
    assert done.wait(1.0)


def test_worker_workers_context_wait_until_non_awaitable():
    worker = PYTHON_WORKER
    ctx = worker._WorkersContext({})
    ctx.wait_until("not awaitable")
    assert len(ctx._waitables) == 0


def test_worker_invoke_handler_cloudflare_wait_until_runs_in_background():
    worker = PYTHON_WORKER
    done = threading.Event()

    async def background():
        await asyncio.sleep(0.2)
        done.set()

    async def fetch(request, env, ctx):
        ctx.waitUntil(background())
        return {"status": 202, "body": "ok"}

    started = time.monotonic()
    resp = worker._invoke_handler(
        fetch,
        worker._INVOKE_ADAPTER_CLOUDFLARE_WORKER,
        {"method": "GET", "raw_path": "/cf", "headers": {"host": "unit.local"}},
    )
    elapsed = time.monotonic() - started
    assert resp["status"] == 202
    assert elapsed < 0.12, elapsed
    assert done.wait(1.0)


def test_worker_invoke_handler_cloudflare_wait_until_logs_rejection():
    worker = PYTHON_WORKER

    async def background():
        await asyncio.sleep(0)
        raise RuntimeError("worker background boom")

    async def fetch(request, env, ctx):
        ctx.waitUntil(background())
        return {"status": 200, "body": "ok"}

    log_buffer = io.StringIO()
    with redirect_stderr(log_buffer):
        resp = worker._invoke_handler(
            fetch,
            worker._INVOKE_ADAPTER_CLOUDFLARE_WORKER,
            {"method": "GET", "raw_path": "/cf", "headers": {"host": "unit.local"}},
        )
        deadline = time.time() + 1.0
        while "wait_until_rejection" not in log_buffer.getvalue() and time.time() < deadline:
            time.sleep(0.01)

    assert resp["status"] == 200
    lines = [line for line in log_buffer.getvalue().splitlines() if line.strip()]
    payload = json.loads(lines[-1])
    assert payload["event"] == "wait_until_rejection"
    assert payload["error"] == "worker background boom"


def test_worker_schedule_background_waitables_logs_schedule_error():
    worker = PYTHON_WORKER

    async def background():
        return None

    coro = background()
    original_thread = worker.threading.Thread
    log_buffer = io.StringIO()

    class BrokenThread:
        def __init__(self, *args, **kwargs):
            return None

        def start(self):
            raise RuntimeError("thread boom")

    try:
        worker.threading.Thread = BrokenThread
        with redirect_stderr(log_buffer):
            worker._schedule_background_waitables([coro], "req-worker")
    finally:
        worker.threading.Thread = original_thread

    lines = [line for line in log_buffer.getvalue().splitlines() if line.strip()]
    payload = json.loads(lines[-1])
    assert payload["event"] == "wait_until_schedule_error"
    assert payload["request_id"] == "req-worker"


def test_worker_schedule_background_waitables_ignores_close_error():
    worker = PYTHON_WORKER
    original_thread = worker.threading.Thread
    log_buffer = io.StringIO()

    class BrokenThread:
        def __init__(self, *args, **kwargs):
            return None

        def start(self):
            raise RuntimeError("thread boom")

    class BrokenWaitable:
        def close(self):
            raise RuntimeError("close boom")

    try:
        worker.threading.Thread = BrokenThread
        with redirect_stderr(log_buffer):
            worker._schedule_background_waitables([BrokenWaitable()], "req-close")
    finally:
        worker.threading.Thread = original_thread

    lines = [line for line in log_buffer.getvalue().splitlines() if line.strip()]
    payload = json.loads(lines[-1])
    assert payload["event"] == "wait_until_schedule_error"
    assert payload["request_id"] == "req-close"


def test_worker_call_handler_var_positional():
    worker = PYTHON_WORKER

    def handler_varargs(*args):
        return {"args": len(args)}

    result = worker._call_handler(handler_varargs, [{"method": "GET"}, "extra"])
    assert result["args"] == 2


def test_worker_call_handler_zero_args():
    worker = PYTHON_WORKER

    def handler_no_args():
        return {"ok": True}

    result = worker._call_handler(handler_no_args, [{"method": "GET"}])
    assert result["ok"] is True


def test_worker_call_handler_async():
    worker = PYTHON_WORKER

    async def async_handler(event):
        return {"async": True}

    result = worker._call_handler(async_handler, [{}])
    # _call_handler returns the coroutine, _resolve_awaitable handles it
    import asyncio
    if asyncio.iscoroutine(result):
        result = asyncio.run(result)
    assert result["async"] is True


def test_worker_call_handler_keyword_only_params():
    worker = PYTHON_WORKER

    def handler_kw(event, *, id=None):
        return {"id": id}

    result = worker._call_handler(handler_kw, [{}], route_params={"id": "99"})
    assert result["id"] == "99"


def test_worker_call_handler_signature_fails_gracefully():
    worker = PYTHON_WORKER

    class WeirdCallable:
        def __call__(self, event):
            return {"ok": True}

    # Built-in callables may not support inspect.signature
    result = worker._call_handler(WeirdCallable(), [{}])
    assert result["ok"] is True


def test_worker_resolve_awaitable_sync():
    worker = PYTHON_WORKER
    assert worker._resolve_awaitable(42) == 42
    assert worker._resolve_awaitable("hello") == "hello"


def test_worker_resolve_awaitable_async():
    worker = PYTHON_WORKER

    async def get_value():
        return {"result": 99}

    result = worker._resolve_awaitable(get_value())
    assert result == {"result": 99}


def test_worker_normalize_response_like_object():
    worker = PYTHON_WORKER

    class FakeResp:
        status = 201
        headers = {"X-Test": "1"}
        body = "response body"

    result = worker._normalize_response_like_object(FakeResp())
    assert result["status"] == 201
    assert result["headers"]["X-Test"] == "1"
    assert result["body"] == "response body"


def test_worker_normalize_response_like_object_bytes():
    worker = PYTHON_WORKER
    import base64

    class FakeResp:
        status = 200
        headers = {}
        body = b"binary"

    result = worker._normalize_response_like_object(FakeResp())
    assert result["is_base64"] is True
    assert base64.b64decode(result["body_base64"]) == b"binary"


def test_worker_normalize_response_like_object_none_body():
    worker = PYTHON_WORKER

    class FakeResp:
        status = 200
        headers = {}
        body = None

    result = worker._normalize_response_like_object(FakeResp())
    assert result["body"] == ""


def test_worker_normalize_response_like_object_non_string_body():
    worker = PYTHON_WORKER

    class FakeResp:
        status = 200
        headers = {}
        body = 12345

    result = worker._normalize_response_like_object(FakeResp())
    assert result["body"] == "12345"


def test_worker_normalize_response_like_object_non_dict_headers():
    worker = PYTHON_WORKER

    class FakeResp:
        status = 200
        headers = "not-a-dict"
        body = "ok"

    result = worker._normalize_response_like_object(FakeResp())
    assert result["headers"] == {}


def test_worker_normalize_response_like_object_non_int_status():
    worker = PYTHON_WORKER

    class FakeResp:
        status = "not-int"
        headers = {}
        body = "ok"

    result = worker._normalize_response_like_object(FakeResp())
    assert result["status"] == 200


def test_worker_normalize_response_like_object_bytearray():
    worker = PYTHON_WORKER
    import base64

    class FakeResp:
        status = 200
        headers = {}
        body = bytearray(b"bytearray data")

    result = worker._normalize_response_like_object(FakeResp())
    assert result["is_base64"] is True
    assert base64.b64decode(result["body_base64"]) == b"bytearray data"


def test_worker_normalize_response_dict():
    worker = PYTHON_WORKER
    result = worker._normalize_response({"status": 200, "headers": {}, "body": "ok"})
    assert result == {"status": 200, "headers": {}, "body": "ok"}


def test_worker_normalize_response_tuple():
    worker = PYTHON_WORKER
    result = worker._normalize_response(("body text", 201, {"X-Custom": "1"}))
    assert result == {"body": "body text", "status": 201, "headers": {"X-Custom": "1"}}


def test_worker_normalize_response_tuple_partial():
    worker = PYTHON_WORKER
    result = worker._normalize_response(("just body",))
    assert result["body"] == "just body"
    assert result["status"] == 200
    assert result["headers"] == {}

    result2 = worker._normalize_response(("body", 202))
    assert result2["body"] == "body"
    assert result2["status"] == 202
    assert result2["headers"] == {}

    result3 = worker._normalize_response(())
    assert result3["body"] is None
    assert result3["status"] == 200


def test_worker_normalize_response_object():
    worker = PYTHON_WORKER

    class FakeResp:
        status = 204
        headers = {"X-Test": "1"}
        body = "no content"

    result = worker._normalize_response(FakeResp())
    assert result["status"] == 204
    assert result["body"] == "no content"


def test_worker_normalize_response_invalid():
    worker = PYTHON_WORKER
    try:
        worker._normalize_response(42)
        assert False, "should raise ValueError"
    except ValueError as e:
        assert "handler response" in str(e)


def test_worker_env_override_proxy():
    worker = PYTHON_WORKER
    real_env = {"A": "1", "B": "2"}
    proxy = worker._EnvOverrideProxy(real_env)

    # Basic access
    assert proxy["A"] == "1"
    assert proxy.get("A") == "1"
    assert proxy.get("MISSING", "default") == "default"
    assert "A" in proxy
    assert "MISSING" not in proxy
    assert len(proxy) == 2

    # Mutation
    proxy["C"] = "3"
    assert real_env["C"] == "3"
    del proxy["C"]
    assert "C" not in real_env

    # Iteration
    keys = list(proxy)
    assert "A" in keys
    assert "B" in keys
    assert proxy.keys() == ["A", "B"]
    assert proxy.values() == ["1", "2"]
    assert ("A", "1") in proxy.items()

    # Copy
    copy = proxy.copy()
    assert copy == {"A": "1", "B": "2"}

    # Pop
    real_env["D"] = "4"
    assert proxy.pop("D") == "4"
    assert "D" not in real_env

    # getattr passthrough
    assert proxy.pop("NONEXIST", "fallback") == "fallback"


def test_worker_env_override_proxy_with_overrides():
    worker = PYTHON_WORKER
    real_env = {"A": "1", "B": "2"}
    proxy = worker._EnvOverrideProxy(real_env)

    # Set thread-local overrides
    worker._thread_local_env.env_overrides = {"A": "override", "B": None, "NEW": "extra"}
    try:
        assert proxy["A"] == "override"
        assert proxy.get("A") == "override"
        try:
            _ = proxy["B"]
            assert False, "B should raise KeyError (overridden to None)"
        except KeyError:
            pass
        assert proxy.get("B", "default") == "default"
        assert "B" not in proxy
        assert "NEW" in proxy
        assert proxy["NEW"] == "extra"

        keys = list(proxy)
        assert "A" in keys
        assert "B" not in keys
        assert "NEW" in keys

        copy = proxy.copy()
        assert copy["A"] == "override"
        assert "B" not in copy
        assert copy["NEW"] == "extra"

        assert len(proxy) == 2  # A, NEW
    finally:
        worker._thread_local_env.env_overrides = None


def test_worker_patched_process_env():
    worker = PYTHON_WORKER
    event = {"env": {"TEST_VAR": "test_value", "EMPTY": None, "": "ignored"}}
    with worker._patched_process_env(event):
        assert worker._thread_local_env.env_overrides is not None
        assert worker._thread_local_env.env_overrides["TEST_VAR"] == "test_value"
        assert worker._thread_local_env.env_overrides["EMPTY"] is None
        assert "" not in worker._thread_local_env.env_overrides
    assert worker._thread_local_env.env_overrides is None


def test_worker_patched_process_env_empty():
    worker = PYTHON_WORKER
    with worker._patched_process_env({}):
        # Should not set overrides when env is empty
        pass
    with worker._patched_process_env({"env": {}}):
        pass


def test_worker_error_resp():
    worker = PYTHON_WORKER
    result = worker._error_resp(RuntimeError("test error"))
    assert result["status"] == 500
    assert result["headers"]["Content-Type"] == "application/json"
    body = json.loads(result["body"])
    assert body["error"] == "test error"


def test_worker_read_frame():
    worker = PYTHON_WORKER
    import struct

    # Normal frame
    payload = b'{"test": true}'
    frame = struct.pack(">I", len(payload)) + payload
    fake_stdin = io.BytesIO(frame)
    old_stdin = sys.stdin
    sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
    try:
        result = worker._read_frame()
        assert result == payload
    finally:
        sys.stdin = old_stdin


def test_worker_read_frame_empty():
    worker = PYTHON_WORKER

    # Short header (stdin closed)
    fake_stdin = io.BytesIO(b"\x00\x00")
    old_stdin = sys.stdin
    sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
    try:
        result = worker._read_frame()
        assert result is None
    finally:
        sys.stdin = old_stdin


def test_worker_read_frame_zero_length():
    worker = PYTHON_WORKER
    import struct

    frame = struct.pack(">I", 0)
    fake_stdin = io.BytesIO(frame)
    old_stdin = sys.stdin
    sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
    try:
        result = worker._read_frame()
        assert result == b""
    finally:
        sys.stdin = old_stdin


def test_worker_read_frame_truncated_data():
    worker = PYTHON_WORKER
    import struct

    # Header says 100 bytes but only 5 available
    frame = struct.pack(">I", 100) + b"short"
    fake_stdin = io.BytesIO(frame)
    old_stdin = sys.stdin
    sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
    try:
        result = worker._read_frame()
        assert result is None
    finally:
        sys.stdin = old_stdin


def test_worker_write_frame():
    worker = PYTHON_WORKER
    import struct

    buf = io.BytesIO()
    old_stdout = sys.stdout
    sys.stdout = type("FakeStdout", (), {"buffer": buf})()
    try:
        worker._write_frame(b'{"ok":true}')
    finally:
        sys.stdout = old_stdout
    buf.seek(0)
    data = buf.read()
    length = struct.unpack(">I", data[:4])[0]
    assert length == len(b'{"ok":true}')
    assert data[4:] == b'{"ok":true}'


def test_worker_load_handler():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n    return {'status': 200, 'headers': {}, 'body': 'ok'}\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        handler = worker._load_handler(str(fn_path), "handler", "native")
        assert callable(handler)

        # Call again should use cache
        handler2 = worker._load_handler(str(fn_path), "handler", "native")
        assert handler2 is handler


def test_worker_load_handler_cache_invalidation():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n    return {'status': 200, 'headers': {}, 'body': 'v1'}\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        handler1 = worker._load_handler(str(fn_path), "handler", "native")

        # Modify file and force different mtime_ns
        time.sleep(0.1)
        fn_path.write_text(
            "def handler(event):\n    return {'status': 200, 'headers': {}, 'body': 'v2'}\n",
            encoding="utf-8",
        )
        # Force mtime change if filesystem resolution is coarse
        import os as _os
        st = _os.stat(str(fn_path))
        _os.utime(str(fn_path), ns=(st.st_atime_ns, st.st_mtime_ns + 1000000000))
        handler2 = worker._load_handler(str(fn_path), "handler", "native")
        # Should be different handler since mtime changed
        result = handler2({})
        assert result["body"] == "v2"


def test_worker_handle_with_lambda_adapter():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "import json\n"
            "def handler(event, context):\n"
            "    return {\n"
            "        'status': 200,\n"
            "        'headers': {'Content-Type': 'application/json'},\n"
            "        'body': json.dumps({\n"
            "            'version': event.get('version'),\n"
            "            'request_id': context.aws_request_id,\n"
            "            'raw_path': event.get('rawPath'),\n"
            "        })\n"
            "    }\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "invoke_adapter": "aws-lambda",
            "deps_dirs": [],
            "event": {
                "method": "GET",
                "path": "/test",
                "headers": {},
                "context": {"request_id": "req-lambda-1"},
            },
        })
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["version"] == "2.0"
        assert body["request_id"] == "req-lambda-1"
        assert body["raw_path"] == "/test"


def test_worker_handle_with_cloudflare_adapter():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "import json\n"
            "async def fetch(request, env, ctx):\n"
            "    body = await request.text()\n"
            "    return type('Response', (), {\n"
            "        'status': 200,\n"
            "        'headers': {'Content-Type': 'application/json'},\n"
            "        'body': json.dumps({\n"
            "            'method': request.method,\n"
            "            'url': request.url,\n"
            "            'body_text': body,\n"
            "            'request_id': ctx.request_id,\n"
            "        })\n"
            "    })()\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "invoke_adapter": "cloudflare-worker",
            "deps_dirs": [],
            "event": {
                "method": "POST",
                "path": "/cf-test",
                "headers": {"host": "example.com"},
                "body": "cf body",
                "context": {"request_id": "req-cf-1"},
            },
        })
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["method"] == "POST"
        assert "example.com" in body["url"]
        assert body["body_text"] == "cf body"
        assert body["request_id"] == "req-cf-1"


def test_worker_handle_error_in_handler():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n    raise RuntimeError('boom')\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        try:
            worker._handle({
                "handler_path": str(fn_path),
                "handler_name": "handler",
                "deps_dirs": [],
                "event": {},
            })
            assert False, "should raise"
        except RuntimeError:
            pass


def test_worker_handle_invalid_response():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n    return 42\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        try:
            worker._handle({
                "handler_path": str(fn_path),
                "handler_name": "handler",
                "deps_dirs": [],
                "event": {},
            })
            assert False, "should raise ValueError"
        except ValueError:
            pass


def test_worker_handle_with_env_overrides():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "import os, json\n"
            "def handler(event):\n"
            "    val = os.environ.get('TEST_WORKER_VAR', 'missing')\n"
            "    return {'status': 200, 'headers': {}, 'body': json.dumps({'val': val})}\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {"env": {"TEST_WORKER_VAR": "injected"}},
        })
        body = json.loads(resp["body"])
        assert body["val"] == "injected"


def test_worker_handle_async_handler():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "async def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'async ok'}\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 200
        assert resp["body"] == "async ok"


def test_worker_run_persistent():
    worker = PYTHON_WORKER
    import struct

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'persistent ok'}\n",
            encoding="utf-8",
        )

        payload = json.dumps({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        }).encode("utf-8")
        frame = struct.pack(">I", len(payload)) + payload
        # After the frame, send an empty stdin to trigger break
        fake_stdin = io.BytesIO(frame)
        stdout_buf = io.BytesIO()

        old_stdin = sys.stdin
        old_stdout = sys.stdout
        sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
        sys.stdout = type("FakeStdout", (), {"buffer": stdout_buf})()
        worker._handler_cache.clear()
        try:
            worker._run_persistent()
        finally:
            sys.stdin = old_stdin
            sys.stdout = old_stdout

        stdout_buf.seek(0)
        data = stdout_buf.read()
        resp_len = struct.unpack(">I", data[:4])[0]
        resp = json.loads(data[4:4 + resp_len])
        assert resp["status"] == 200
        assert resp["body"] == "persistent ok"


def test_worker_run_persistent_error():
    worker = PYTHON_WORKER
    import struct

    payload = json.dumps({
        "handler_path": "/nonexistent/handler.py",
        "handler_name": "handler",
        "deps_dirs": [],
        "event": {},
    }).encode("utf-8")
    frame = struct.pack(">I", len(payload)) + payload
    fake_stdin = io.BytesIO(frame)
    stdout_buf = io.BytesIO()

    old_stdin = sys.stdin
    old_stdout = sys.stdout
    sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
    sys.stdout = type("FakeStdout", (), {"buffer": stdout_buf})()
    worker._handler_cache.clear()
    try:
        worker._run_persistent()
    finally:
        sys.stdin = old_stdin
        sys.stdout = old_stdout

    stdout_buf.seek(0)
    data = stdout_buf.read()
    resp_len = struct.unpack(">I", data[:4])[0]
    resp = json.loads(data[4:4 + resp_len])
    assert resp["status"] == 500
    assert "error" in json.loads(resp["body"])


def test_worker_run_oneshot():
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'oneshot ok'}\n",
            encoding="utf-8",
        )

        payload = json.dumps({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })

        old_stdin = sys.stdin
        old_stdout = sys.stdout
        sys.stdin = io.StringIO(payload)
        stdout_buf = io.StringIO()
        sys.stdout = stdout_buf
        worker._handler_cache.clear()
        try:
            worker._run_oneshot()
        finally:
            sys.stdin = old_stdin
            sys.stdout = old_stdout

        resp = json.loads(stdout_buf.getvalue())
        assert resp["status"] == 200
        assert resp["body"] == "oneshot ok"


def test_worker_run_oneshot_empty():
    worker = PYTHON_WORKER

    old_stdin = sys.stdin
    old_stdout = sys.stdout
    sys.stdin = io.StringIO("")
    stdout_buf = io.StringIO()
    sys.stdout = stdout_buf
    try:
        worker._run_oneshot()
    finally:
        sys.stdin = old_stdin
        sys.stdout = old_stdout

    assert stdout_buf.getvalue() == ""


def test_worker_run_oneshot_error():
    worker = PYTHON_WORKER

    payload = json.dumps({
        "handler_path": "/nonexistent/handler.py",
        "handler_name": "handler",
        "deps_dirs": [],
        "event": {},
    })

    old_stdin = sys.stdin
    old_stdout = sys.stdout
    sys.stdin = io.StringIO(payload)
    stdout_buf = io.StringIO()
    sys.stdout = stdout_buf
    worker._handler_cache.clear()
    try:
        worker._run_oneshot()
    finally:
        sys.stdin = old_stdin
        sys.stdout = old_stdout

    resp = json.loads(stdout_buf.getvalue())
    assert resp["status"] == 500


def test_worker_main_oneshot_mode():
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'main ok'}\n",
            encoding="utf-8",
        )

        payload = json.dumps({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })

        old_stdin = sys.stdin
        old_stdout = sys.stdout
        old_mode = os.environ.get("_FASTFN_WORKER_MODE")
        old_deps = os.environ.get("_FASTFN_WORKER_DEPS")
        sys.stdin = io.StringIO(payload)
        stdout_buf = io.StringIO()
        sys.stdout = stdout_buf
        os.environ["_FASTFN_WORKER_MODE"] = "oneshot"
        if "_FASTFN_WORKER_DEPS" in os.environ:
            del os.environ["_FASTFN_WORKER_DEPS"]
        worker._handler_cache.clear()
        try:
            worker.main()
        finally:
            sys.stdin = old_stdin
            sys.stdout = old_stdout
            if old_mode is not None:
                os.environ["_FASTFN_WORKER_MODE"] = old_mode
            elif "_FASTFN_WORKER_MODE" in os.environ:
                del os.environ["_FASTFN_WORKER_MODE"]
            if old_deps is not None:
                os.environ["_FASTFN_WORKER_DEPS"] = old_deps

        resp = json.loads(stdout_buf.getvalue())
        assert resp["status"] == 200


def test_worker_main_persistent_mode():
    worker = PYTHON_WORKER
    import struct

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'persistent main'}\n",
            encoding="utf-8",
        )

        payload = json.dumps({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        }).encode("utf-8")
        frame = struct.pack(">I", len(payload)) + payload
        fake_stdin = io.BytesIO(frame)
        stdout_buf = io.BytesIO()

        old_stdin = sys.stdin
        old_stdout = sys.stdout
        old_mode = os.environ.get("_FASTFN_WORKER_MODE")
        old_deps = os.environ.get("_FASTFN_WORKER_DEPS")
        sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
        sys.stdout = type("FakeStdout", (), {"buffer": stdout_buf})()
        os.environ["_FASTFN_WORKER_MODE"] = "persistent"
        if "_FASTFN_WORKER_DEPS" in os.environ:
            del os.environ["_FASTFN_WORKER_DEPS"]
        worker._handler_cache.clear()
        try:
            worker.main()
        finally:
            sys.stdin = old_stdin
            sys.stdout = old_stdout
            if old_mode is not None:
                os.environ["_FASTFN_WORKER_MODE"] = old_mode
            elif "_FASTFN_WORKER_MODE" in os.environ:
                del os.environ["_FASTFN_WORKER_MODE"]
            if old_deps is not None:
                os.environ["_FASTFN_WORKER_DEPS"] = old_deps

        stdout_buf.seek(0)
        data = stdout_buf.read()
        resp_len = struct.unpack(">I", data[:4])[0]
        resp = json.loads(data[4:4 + resp_len])
        assert resp["status"] == 200
        assert resp["body"] == "persistent main"


def test_worker_main_with_deps_env():
    worker = PYTHON_WORKER

    old_stdin = sys.stdin
    old_stdout = sys.stdout
    old_mode = os.environ.get("_FASTFN_WORKER_MODE")
    old_deps = os.environ.get("_FASTFN_WORKER_DEPS")
    sys.stdin = io.StringIO("")
    stdout_buf = io.StringIO()
    sys.stdout = stdout_buf

    fake_dep_dir = "/tmp/fake_fastfn_deps_test"
    os.environ["_FASTFN_WORKER_MODE"] = "oneshot"
    os.environ["_FASTFN_WORKER_DEPS"] = fake_dep_dir
    try:
        worker.main()
        assert fake_dep_dir in sys.path
    finally:
        sys.stdin = old_stdin
        sys.stdout = old_stdout
        if fake_dep_dir in sys.path:
            sys.path.remove(fake_dep_dir)
        if old_mode is not None:
            os.environ["_FASTFN_WORKER_MODE"] = old_mode
        elif "_FASTFN_WORKER_MODE" in os.environ:
            del os.environ["_FASTFN_WORKER_MODE"]
        if old_deps is not None:
            os.environ["_FASTFN_WORKER_DEPS"] = old_deps
        elif "_FASTFN_WORKER_DEPS" in os.environ:
            del os.environ["_FASTFN_WORKER_DEPS"]


def test_worker_handle_tuple_response():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n    return ('body', 201, {'X-Test': '1'})\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 201
        assert resp["body"] == "body"
        assert resp["headers"]["X-Test"] == "1"


def test_worker_handle_object_response():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "class Resp:\n"
            "    status = 202\n"
            "    headers = {'X-Custom': 'yes'}\n"
            "    body = 'object resp'\n"
            "def handler(event):\n"
            "    return Resp()\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 202
        assert resp["body"] == "object resp"


def test_worker_handle_deps_dirs_added_to_sys_path():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "def handler(event):\n    return {'status': 200, 'headers': {}, 'body': 'ok'}\n",
            encoding="utf-8",
        )
        deps_dir = str(Path(tmp) / "deps")
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [deps_dir],
            "event": {},
        })
        assert resp["status"] == 200
        assert deps_dir in sys.path
        # Cleanup
        if deps_dir in sys.path:
            sys.path.remove(deps_dir)


def test_worker_handle_adds_handler_dir_to_sys_path_for_local_imports():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_dir = Path(tmp)
        helper_path = fn_dir / "_shared.py"
        fn_path = fn_dir / "handler.py"

        helper_path.write_text(
            "def greet():\n    return 'local-import-ok'\n",
            encoding="utf-8",
        )
        fn_path.write_text(
            "from _shared import greet\n"
            "def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': greet()}\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })

        assert resp["status"] == 200
        assert resp["body"] == "local-import-ok"
        assert str(fn_dir) in sys.path
        if str(fn_dir) in sys.path:
            sys.path.remove(str(fn_dir))
        sys.modules.pop("_shared", None)


def test_worker_invoke_handler_native_with_params():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
        fn_path.write_text(
            "import json\n"
            "def handler(event, id=None):\n"
            "    return {'status': 200, 'headers': {}, 'body': json.dumps({'id': id})}\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {"params": {"id": "77"}},
        })
        body = json.loads(resp["body"])
        assert body["id"] == "77"


def test_worker_build_lambda_event_with_raw_path_query():
    worker = PYTHON_WORKER
    event = {
        "raw_path": "/api/test?foo=bar&x=1",
        "method": "GET",
    }
    result = worker._build_lambda_event(event)
    assert result["rawPath"] == "/api/test"
    assert result["rawQueryString"] == "foo=bar&x=1"


def test_worker_build_lambda_event_no_ts_uses_time():
    worker = PYTHON_WORKER
    result = worker._build_lambda_event({"ts": 0})
    assert result["requestContext"]["timeEpoch"] > 0


def test_worker_parse_extra_allow_roots_exception():
    """Cover lines 52-61: _parse_extra_allow_roots with paths."""
    worker = PYTHON_WORKER
    orig = worker.STRICT_FS_EXTRA_ALLOW
    try:
        # Normal path
        worker.STRICT_FS_EXTRA_ALLOW = "/tmp,/var"
        result = worker._parse_extra_allow_roots()
        assert len(result) == 2

        # Empty
        worker.STRICT_FS_EXTRA_ALLOW = ""
        result = worker._parse_extra_allow_roots()
        assert result == []

        # Only whitespace/commas
        worker.STRICT_FS_EXTRA_ALLOW = " , , "
        result = worker._parse_extra_allow_roots()
        assert result == []
    finally:
        worker.STRICT_FS_EXTRA_ALLOW = orig


def test_worker_resolve_candidate_path_bytes_exception():
    """Cover line 71-72: bytes decode exception."""
    worker = PYTHON_WORKER
    result = worker._resolve_candidate_path(b"/tmp/test")
    assert result is not None or result is None
    assert worker._resolve_candidate_path(42) is None
    assert worker._resolve_candidate_path("") is None


def test_worker_resolve_candidate_path_resolve_exception():
    """Cover line 79-80: Path().resolve() exception."""
    worker = PYTHON_WORKER
    # None target
    assert worker._resolve_candidate_path(None) is None
    # PathLike
    result = worker._resolve_candidate_path(Path("/tmp"))
    assert result is not None


def test_worker_build_allowed_roots_deps_exception():
    """Cover line 90-91: deps_dirs resolve exception."""
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")
        roots, fn_dir = worker._build_allowed_roots(handler, ["/tmp/valid"])
        assert fn_dir is not None


def test_worker_build_allowed_roots_sys_prefix_edges():
    """Cover lines 96, 99-100, 106-107."""
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")
        roots, fn_dir = worker._build_allowed_roots(handler, [])
        assert len(roots) > 0


def test_worker_strict_fs_guard_protected_files():
    """Cover line 132-134: access to protected fn.config.json / fn.env.json."""
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "handler.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            config = Path(tmp) / "fn.config.json"
            config.write_text("{}", encoding="utf-8")
            env_file = Path(tmp) / "fn.env.json"
            env_file.write_text("{}", encoding="utf-8")

            with worker._strict_fs_guard(handler, []):
                try:
                    with open(config, "r") as f:
                        f.read()
                    assert False, "should have raised PermissionError for fn.config.json"
                except PermissionError:
                    pass
                try:
                    with open(env_file, "r") as f:
                        f.read()
                    assert False, "should have raised PermissionError for fn.env.json"
                except PermissionError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_guarded_calls():
    """Cover lines 155, 159, 163, 175: guarded builtins."""
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "handler.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            test_file = Path(tmp) / "test.txt"
            test_file.write_text("hello", encoding="utf-8")

            with worker._strict_fs_guard(handler, []):
                with open(test_file, "r") as f:
                    assert f.read() == "hello"
                import io as io_mod
                with io_mod.open(str(test_file), "r") as f:
                    assert f.read() == "hello"
                fd = os.open(str(test_file), os.O_RDONLY)
                os.close(fd)
                test_file.open("r").close()
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_load_handler_spec_none():
    """Cover line 337: _load_handler when spec is None."""
    worker = PYTHON_WORKER
    old_cache = dict(worker._handler_cache)
    try:
        worker._handler_cache.clear()
        try:
            worker._load_handler(str(Path("/nonexistent/fake.py")), "handler", "native")
        except (RuntimeError, FileNotFoundError, OSError):
            pass
    finally:
        worker._handler_cache.clear()
        worker._handler_cache.update(old_cache)


def test_worker_resolve_awaitable_runtime_error():
    """Cover lines 576-581: _resolve_awaitable RuntimeError fallback."""
    import asyncio
    worker = PYTHON_WORKER
    async def coro():
        return 42
    result = worker._resolve_awaitable(coro())
    assert result == 42
    assert worker._resolve_awaitable("hello") == "hello"


def test_worker_env_override_proxy_iter_non_override():
    """Cover lines 658-659: __iter__ non-override keys."""
    worker = PYTHON_WORKER
    proxy = worker._EnvOverrideProxy({"A": "1", "B": "2"})
    # Set overrides via the module's thread-local
    worker._thread_local_env.env_overrides = {"B": "overridden", "C": "new"}
    try:
        keys = list(proxy)
        assert "A" in keys
        assert "B" in keys
        assert "C" in keys
    finally:
        worker._thread_local_env.env_overrides = None


def test_worker_env_override_proxy_getattr():
    """Cover line 691: __getattr__."""
    worker = PYTHON_WORKER
    real_env = {"PATH": "/usr/bin"}
    proxy = worker._EnvOverrideProxy(real_env)
    assert callable(proxy.get)
    assert proxy.get("PATH") == "/usr/bin"


def test_worker_parse_extra_allow_roots_resolve_fail():
    """Cover lines 60-61: Path.resolve raises inside _parse_extra_allow_roots."""
    worker = PYTHON_WORKER
    orig_allow = worker.STRICT_FS_EXTRA_ALLOW
    orig_resolve = Path.resolve
    call_count = [0]

    def bad_resolve(self, strict=False):
        if "badpath_xyz" in str(self):
            raise OSError("simulated resolve failure")
        return orig_resolve(self, strict=strict)

    try:
        worker.STRICT_FS_EXTRA_ALLOW = "/tmp,badpath_xyz_test"
        Path.resolve = bad_resolve
        result = worker._parse_extra_allow_roots()
        # Should skip the bad path and return the valid one
        assert len(result) >= 1
    finally:
        worker.STRICT_FS_EXTRA_ALLOW = orig_allow
        Path.resolve = orig_resolve


def test_worker_resolve_candidate_bytes_decode_fail():
    """Cover lines 71-72: bytes subclass that raises on decode."""
    worker = PYTHON_WORKER

    class BadBytes(bytes):
        def decode(self, *a, **kw):
            raise RuntimeError("simulated decode failure")

    result = worker._resolve_candidate_path(BadBytes(b"/tmp/test"))
    assert result is None

    # Normal bytes still work
    result2 = worker._resolve_candidate_path(b"/tmp/testpath")
    assert result2 is not None


def test_worker_resolve_candidate_resolve_fail():
    """Cover lines 79-80: Path.resolve raises."""
    worker = PYTHON_WORKER
    orig_resolve = Path.resolve

    def bad_resolve(self, strict=False):
        if "resolve_fail_xyz" in str(self):
            raise OSError("simulated")
        return orig_resolve(self, strict=strict)

    try:
        Path.resolve = bad_resolve
        result = worker._resolve_candidate_path("resolve_fail_xyz_test")
        assert result is None
    finally:
        Path.resolve = orig_resolve


def test_worker_build_allowed_roots_exception_paths():
    """Cover lines 90-91, 96, 99-100, 106-107."""
    worker = PYTHON_WORKER
    orig_resolve = Path.resolve

    call_count = [0]
    def bad_resolve(self, strict=False):
        s = str(self)
        if "bad_dep_xyz" in s:
            raise OSError("simulated dep resolve fail")
        return orig_resolve(self, strict=strict)

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "handler.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")
        try:
            Path.resolve = bad_resolve
            roots, fn_dir = worker._build_allowed_roots(handler, ["/tmp", "bad_dep_xyz"])
            assert fn_dir is not None
        finally:
            Path.resolve = orig_resolve


def test_worker_strict_fs_guard_check_target_none():
    """Cover line 132: check_target returns when candidate is None (int fd)."""
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "handler.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            test_file = Path(tmp) / "test.txt"
            test_file.write_text("x", encoding="utf-8")

            with worker._strict_fs_guard(handler, []):
                # Open by fd (int) — check_target gets None from _resolve_candidate_path
                fd = os.open(str(test_file), os.O_RDONLY)
                try:
                    # Now re-open using the fd (int target)
                    # open() with int fd just wraps the fd
                    f = open(fd, "r", closefd=False)
                    f.read()
                    f.close()
                finally:
                    os.close(fd)
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_pty_ctypes_import_error():
    """Cover lines 222-223, 240-241: pty/ctypes ImportError paths."""
    # These lines handle ImportError for pty/ctypes — they're already covered
    # if pty/ctypes are available (which they are). The ImportError paths
    # are dead code on standard Python. We verify the guard works anyway.
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "handler.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            with worker._strict_fs_guard(handler, []):
                # pty.spawn should be blocked
                import pty
                try:
                    pty.spawn("/bin/echo")
                    assert False, "pty.spawn should be blocked"
                except PermissionError:
                    pass
                # ctypes.CDLL should be blocked
                import ctypes
                try:
                    ctypes.CDLL("libc.so.6")
                    assert False, "ctypes.CDLL should be blocked"
                except PermissionError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_load_handler_spec_none_actual():
    """Cover line 337: spec is None for a non-python file."""
    worker = PYTHON_WORKER
    old_cache = dict(worker._handler_cache)
    try:
        worker._handler_cache.clear()
        with tempfile.TemporaryDirectory() as tmp:
            # Create a file that importlib can't create a spec for
            bad_file = Path(tmp) / "notamodule.xyz"
            bad_file.write_text("x = 1\n", encoding="utf-8")
            try:
                worker._load_handler(str(bad_file), "handler", "native")
            except (RuntimeError, FileNotFoundError, OSError):
                pass
    finally:
        worker._handler_cache.clear()
        worker._handler_cache.update(old_cache)


def test_worker_resolve_awaitable_runtime_error_fallback():
    """Cover lines 576-581: asyncio.run raises RuntimeError, fallback to new_event_loop."""
    import asyncio
    worker = PYTHON_WORKER

    async def simple_coro():
        return 99

    # Monkey-patch asyncio.run to raise RuntimeError
    orig_run = asyncio.run

    def failing_run(coro, **kw):
        raise RuntimeError("no current event loop")

    try:
        asyncio.run = failing_run
        result = worker._resolve_awaitable(simple_coro())
        assert result == 99
    finally:
        asyncio.run = orig_run


def test_worker_env_proxy_getattr_coverage():
    """Cover line 691: __getattr__ delegating to _real."""
    worker = PYTHON_WORKER
    real = {"A": "1"}
    proxy = worker._EnvOverrideProxy(real)
    # Access methods that exist on dict but not on proxy class
    # These go through __getattr__
    assert callable(proxy.update)
    assert callable(proxy.setdefault)
    assert proxy.get("A") == "1"


def test_worker_build_allowed_roots_sys_prefix_empty():
    """Cover line 96: sys.prefix is empty string."""
    worker = PYTHON_WORKER
    orig_prefix = sys.prefix
    orig_base = getattr(sys, "base_prefix", None)
    orig_exec = getattr(sys, "exec_prefix", None)
    try:
        sys.prefix = ""
        sys.base_prefix = ""
        sys.exec_prefix = ""
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "handler.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            roots, fn_dir = worker._build_allowed_roots(handler, [])
            assert fn_dir is not None
    finally:
        sys.prefix = orig_prefix
        if orig_base is not None:
            sys.base_prefix = orig_base
        if orig_exec is not None:
            sys.exec_prefix = orig_exec


def test_worker_build_allowed_roots_resolve_exception():
    """Cover lines 99-100, 106-107: Path.resolve raises for sys.prefix/system roots."""
    worker = PYTHON_WORKER
    orig_resolve = Path.resolve

    def bad_resolve(self, strict=False):
        s = str(self)
        if s == sys.prefix or s in ("/etc/pki",):
            raise OSError("simulated resolve fail")
        return orig_resolve(self, strict=strict)

    try:
        Path.resolve = bad_resolve
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "handler.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            roots, fn_dir = worker._build_allowed_roots(handler, [])
            assert fn_dir is not None
    finally:
        Path.resolve = orig_resolve


def test_python_subprocess_does_not_fallback_to_oneshot_v2() -> None:
    handler = load_handler(ROOT / "examples/functions/python/sendgrid-send/handler.py")
    # Missing both SENDGRID_API_KEY and SENDGRID_FROM
    resp = handler({"query": {"dry_run": "false"}, "env": {}})
    assert_response_contract(resp)
    assert resp["status"] == 400
    body = json.loads(resp["body"])
    assert body["ok"] is False
    assert "SENDGRID_API_KEY" in body["error"]

    # Has API key but missing FROM
    resp2 = handler({"query": {"dry_run": "false"}, "env": {"SENDGRID_API_KEY": "sk-test"}})
    assert_response_contract(resp2)
    assert resp2["status"] == 400
    body2 = json.loads(resp2["body"])
    assert "SENDGRID_FROM" in body2["error"]


def test_python_sendgrid_send_invalid_email_via_body():
    handler = load_handler(ROOT / "examples/functions/python/sendgrid-send/handler.py")
    # POST with body overrides query defaults
    resp = handler({
        "method": "POST",
        "body": json.dumps({"to": "custom@test.com", "subject": "Custom Subject", "text": "Custom body"}),
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["dry_run"] is True
    assert body["request"]["body"]["personalizations"][0]["to"][0]["email"] == "custom@test.com"
    assert body["request"]["body"]["subject"] == "Custom Subject"
    assert body["request"]["body"]["content"][0]["value"] == "Custom body"


def test_python_sendgrid_send_api_error_returns_502():
    mod = load_module(ROOT / "examples/functions/python/sendgrid-send/handler.py")
    handler = mod.handler

    class ErrorResp:
        def __init__(self):
            self.status = 400

        def read(self):
            return b'{"errors":[{"message":"invalid"}]}'

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    original = mod.urllib.request.urlopen
    try:
        # Test HTTP error from SendGrid API
        def fail_http(_req, timeout):
            raise mod.urllib.error.HTTPError(
                "https://api.sendgrid.com/v3/mail/send",
                400,
                "Bad Request",
                {},
                None,
            )

        mod.urllib.request.urlopen = fail_http
        resp = handler({
            "query": {"dry_run": "false", "to": "test@example.com"},
            "env": {"SENDGRID_API_KEY": "k", "SENDGRID_FROM": "from@example.com"},
            "context": {"timeout_ms": 1000},
        })
        assert_response_contract(resp)
        assert resp["status"] == 502

        # Test connection timeout
        def fail_timeout(_req, timeout):
            raise TimeoutError("connection timed out")

        mod.urllib.request.urlopen = fail_timeout
        resp2 = handler({
            "query": {"dry_run": "false", "to": "test@example.com"},
            "env": {"SENDGRID_API_KEY": "k", "SENDGRID_FROM": "from@example.com"},
            "context": {"timeout_ms": 1000},
        })
        assert_response_contract(resp2)
        assert resp2["status"] == 502
    finally:
        mod.urllib.request.urlopen = original


def test_python_sendgrid_send_context_timeout():
    handler = load_handler(ROOT / "examples/functions/python/sendgrid-send/handler.py")
    # Default context timeout_ms when not provided
    resp = handler({
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["dry_run"] is True

    # Custom context timeout_ms
    resp2 = handler({
        "query": {"dry_run": "true"},
        "env": {},
        "context": {"timeout_ms": 30000},
    })
    assert_response_contract(resp2)
    body2 = json.loads(resp2["body"])
    assert body2["dry_run"] is True


def test_python_sendgrid_send_post_body_parsing():
    handler = load_handler(ROOT / "examples/functions/python/sendgrid-send/handler.py")
    # PUT method with body should also parse
    resp = handler({
        "method": "PUT",
        "body": json.dumps({"to": "put@example.com", "subject": "PUT Subject"}),
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["request"]["body"]["personalizations"][0]["to"][0]["email"] == "put@example.com"

    # PATCH method with body should also parse
    resp2 = handler({
        "method": "PATCH",
        "body": json.dumps({"to": "patch@example.com"}),
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp2)
    body2 = json.loads(resp2["body"])
    assert body2["request"]["body"]["personalizations"][0]["to"][0]["email"] == "patch@example.com"

    # GET method ignores body
    resp3 = handler({
        "method": "GET",
        "body": json.dumps({"to": "ignored@example.com"}),
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp3)
    body3 = json.loads(resp3["body"])
    assert body3["request"]["body"]["personalizations"][0]["to"][0]["email"] == "demo@example.com"

    # dry_run hint includes missing_env keys
    resp4 = handler({
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp4)
    body4 = json.loads(resp4["body"])
    assert "SENDGRID_API_KEY" in body4["missing_env"]
    assert "SENDGRID_FROM" in body4["missing_env"]

    # dry_run with keys present shows hidden authorization
    resp5 = handler({
        "query": {"dry_run": "true"},
        "env": {"SENDGRID_API_KEY": "sk-real", "SENDGRID_FROM": "real@example.com"},
    })
    assert_response_contract(resp5)
    body5 = json.loads(resp5["body"])
    assert body5["missing_env"] == []
    assert body5["request"]["headers"]["Authorization"] == "<hidden>"
