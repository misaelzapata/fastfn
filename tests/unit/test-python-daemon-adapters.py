#!/usr/bin/env python3
import importlib.util
import json
import os
import tempfile
from types import SimpleNamespace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PY_DAEMON_PATH = ROOT / "srv/fn/runtimes/python-daemon.py"

_PY_SPEC = importlib.util.spec_from_file_location("fastfn_python_daemon_adapter_cov", PY_DAEMON_PATH)
if _PY_SPEC is None or _PY_SPEC.loader is None:
    raise RuntimeError(f"failed to load runtime module: {PY_DAEMON_PATH}")
python_daemon = importlib.util.module_from_spec(_PY_SPEC)  # type: ignore
_PY_SPEC.loader.exec_module(python_daemon)  # type: ignore


def _shutdown_subprocess_pool() -> None:
    with python_daemon._SUBPROCESS_POOL_LOCK:
        workers = list(python_daemon._SUBPROCESS_POOL.values())
        python_daemon._SUBPROCESS_POOL.clear()
    for worker in workers:
        try:
            worker.shutdown()
        except Exception:
            pass


def _set_functions_root(root: Path):
    old_functions = python_daemon.FUNCTIONS_DIR
    old_runtime = python_daemon.RUNTIME_FUNCTIONS_DIR
    python_daemon.FUNCTIONS_DIR = root
    python_daemon.RUNTIME_FUNCTIONS_DIR = root / "python"
    return old_functions, old_runtime


def test_aws_lambda_adapter() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fn_dir = root / "aws-py"
        fn_dir.mkdir(parents=True, exist_ok=True)

        (fn_dir / "app.py").write_text(
            """
import json

def handler(event, context):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "method": ((event.get("requestContext") or {}).get("http") or {}).get("method"),
            "path": event.get("rawPath"),
            "request_id": getattr(context, "aws_request_id", ""),
            "trace": (event.get("headers") or {}).get("x-trace-id", ""),
        }, separators=(",", ":")),
    }
""".strip()
            + "\n",
            encoding="utf-8",
        )
        (fn_dir / "fn.config.json").write_text(
            json.dumps({"invoke": {"adapter": "aws-lambda"}}),
            encoding="utf-8",
        )

        old_functions, old_runtime = _set_functions_root(root)
        prev_auto = os.environ.get("FN_AUTO_REQUIREMENTS")
        os.environ["FN_AUTO_REQUIREMENTS"] = "0"
        try:
            resp = python_daemon._handle_request_direct(
                {
                    "fn": "aws-py",
                    "event": {
                        "id": "req-py-aws-1",
                        "method": "POST",
                        "path": "/aws-py",
                        "raw_path": "/aws-py?x=1",
                        "headers": {
                            "host": "127.0.0.1:8080",
                            "x-trace-id": "trace-py",
                        },
                        "body": "{}",
                        "client": {
                            "ip": "127.0.0.1",
                            "ua": "pytest",
                        },
                    },
                }
            )
            assert resp["status"] == 200, resp
            body = json.loads(resp["body"])
            assert body["method"] == "POST", body
            assert body["path"] == "/aws-py", body
            assert body["request_id"] == "req-py-aws-1", body
            assert body["trace"] == "trace-py", body
        finally:
            _shutdown_subprocess_pool()
            python_daemon.FUNCTIONS_DIR = old_functions
            python_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime
            if prev_auto is None:
                os.environ.pop("FN_AUTO_REQUIREMENTS", None)
            else:
                os.environ["FN_AUTO_REQUIREMENTS"] = prev_auto


def test_cloudflare_worker_adapter() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fn_dir = root / "cf-py"
        fn_dir.mkdir(parents=True, exist_ok=True)

        (fn_dir / "app.py").write_text(
            """
import asyncio
import json

async def fetch(request, env, ctx):
    body = await request.text()
    ctx.waitUntil(asyncio.sleep(0))
    return {
        "status": 202,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "method": request.method,
            "url": request.url,
            "who": str((env or {}).get("WHO", "")),
            "body": body,
        }, separators=(",", ":")),
    }
""".strip()
            + "\n",
            encoding="utf-8",
        )
        (fn_dir / "fn.config.json").write_text(
            json.dumps({"invoke": {"adapter": "cloudflare-worker"}}),
            encoding="utf-8",
        )

        old_functions, old_runtime = _set_functions_root(root)
        prev_auto = os.environ.get("FN_AUTO_REQUIREMENTS")
        os.environ["FN_AUTO_REQUIREMENTS"] = "0"
        try:
            resp = python_daemon._handle_request_direct(
                {
                    "fn": "cf-py",
                    "event": {
                        "method": "PUT",
                        "raw_path": "/cf-py?y=9",
                        "headers": {"host": "unit.local:8080"},
                        "body": "payload",
                        "env": {"WHO": "PyAdapter"},
                    },
                }
            )
            assert resp["status"] == 202, resp
            body = json.loads(resp["body"])
            assert body["method"] == "PUT", body
            assert "http://unit.local:8080/cf-py?y=9" in body["url"], body
            assert body["who"] == "PyAdapter", body
            assert body["body"] == "payload", body
        finally:
            _shutdown_subprocess_pool()
            python_daemon.FUNCTIONS_DIR = old_functions
            python_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime
            if prev_auto is None:
                os.environ.pop("FN_AUTO_REQUIREMENTS", None)
            else:
                os.environ["FN_AUTO_REQUIREMENTS"] = prev_auto


def test_unknown_adapter_raises() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fn_dir = root / "bad-py"
        fn_dir.mkdir(parents=True, exist_ok=True)
        (fn_dir / "app.py").write_text(
            "def handler(event):\n    return {'status': 200, 'body': 'ok'}\n",
            encoding="utf-8",
        )
        (fn_dir / "fn.config.json").write_text(
            json.dumps({"invoke": {"adapter": "nope"}}),
            encoding="utf-8",
        )

        old_functions, old_runtime = _set_functions_root(root)
        prev_auto = os.environ.get("FN_AUTO_REQUIREMENTS")
        os.environ["FN_AUTO_REQUIREMENTS"] = "0"
        try:
            failed = False
            try:
                python_daemon._handle_request_direct({"fn": "bad-py", "event": {"method": "GET"}})
            except ValueError as exc:
                failed = True
                assert "invoke.adapter unsupported" in str(exc)
            assert failed, "expected unknown adapter to fail"
        finally:
            _shutdown_subprocess_pool()
            python_daemon.FUNCTIONS_DIR = old_functions
            python_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime
            if prev_auto is None:
                os.environ.pop("FN_AUTO_REQUIREMENTS", None)
            else:
                os.environ["FN_AUTO_REQUIREMENTS"] = prev_auto


def test_native_event_env_is_visible_in_os_environ() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fn_dir = root / "env-py"
        fn_dir.mkdir(parents=True, exist_ok=True)

        (fn_dir / "app.py").write_text(
            """
import json
import os

def handler(event):
    env = event.get("env") or {}
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "event_env": env.get("m"),
            "process_env": os.environ.get("m"),
        }, separators=(",", ":")),
    }
""".strip()
            + "\n",
            encoding="utf-8",
        )
        (fn_dir / "fn.env.json").write_text(
            json.dumps({"m": "test"}),
            encoding="utf-8",
        )

        old_functions, old_runtime = _set_functions_root(root)
        prev_auto = os.environ.get("FN_AUTO_REQUIREMENTS")
        os.environ["FN_AUTO_REQUIREMENTS"] = "0"
        try:
            resp = python_daemon._handle_request_direct(
                {
                    "fn": "env-py",
                    "event": {"method": "GET"},
                }
            )
            assert resp["status"] == 200, resp
            body = json.loads(resp["body"])
            assert body["event_env"] == "test", body
            assert body["process_env"] == "test", body
        finally:
            _shutdown_subprocess_pool()
            python_daemon.FUNCTIONS_DIR = old_functions
            python_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime
            if prev_auto is None:
                os.environ.pop("FN_AUTO_REQUIREMENTS", None)
            else:
                os.environ["FN_AUTO_REQUIREMENTS"] = prev_auto


def test_auto_infer_python_generates_manifest_state_and_lockfile() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fn_dir = root / "infer-py"
        fn_dir.mkdir(parents=True, exist_ok=True)
        (fn_dir / "app.py").write_text(
            """
import json

def _deps_marker():
    import requests
    from PIL import Image
    return str(Image)

def handler(event):
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"ok": True}, separators=(",", ":")),
    }
""".strip()
            + "\n",
            encoding="utf-8",
        )

        old_functions, old_runtime = _set_functions_root(root)
        prev_auto = os.environ.get("FN_AUTO_REQUIREMENTS")
        prev_infer = os.environ.get("FN_AUTO_INFER_PY_DEPS")
        prev_write = os.environ.get("FN_AUTO_INFER_WRITE_MANIFEST")
        prev_strict = os.environ.get("FN_AUTO_INFER_STRICT")
        old_run = python_daemon._REAL_SUBPROCESS_RUN
        python_daemon._REQ_CACHE.clear()
        os.environ["FN_AUTO_REQUIREMENTS"] = "1"
        os.environ["FN_AUTO_INFER_PY_DEPS"] = "1"
        os.environ["FN_AUTO_INFER_WRITE_MANIFEST"] = "1"
        os.environ["FN_AUTO_INFER_STRICT"] = "1"

        install_calls = {"count": 0}

        def fake_run(cmd, **_kwargs):
            if "freeze" in cmd:
                return SimpleNamespace(returncode=0, stdout="Pillow==10.0.0\nrequests==2.31.0\n", stderr="")
            install_calls["count"] += 1
            target = None
            if "-t" in cmd:
                idx = cmd.index("-t")
                if idx + 1 < len(cmd):
                    target = Path(cmd[idx + 1])
            if target:
                target.mkdir(parents=True, exist_ok=True)
                (target / ".keep").write_text("ok\n", encoding="utf-8")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        try:
            python_daemon._REAL_SUBPROCESS_RUN = fake_run

            first = python_daemon._handle_request_direct({"fn": "infer-py", "event": {"method": "GET"}})
            assert first["status"] == 200, first

            # Cache hit: should not re-run pip install because .deps is already populated.
            second = python_daemon._handle_request_direct({"fn": "infer-py", "event": {"method": "GET"}})
            assert second["status"] == 200, second
            assert install_calls["count"] == 1

            req_text = (fn_dir / "requirements.txt").read_text(encoding="utf-8")
            assert "requests" in req_text
            assert "Pillow" in req_text

            lock_text = (fn_dir / "requirements.lock.txt").read_text(encoding="utf-8")
            assert "requests==" in lock_text
            assert "Pillow==" in lock_text

            state = json.loads((fn_dir / ".fastfn-deps-state.json").read_text(encoding="utf-8"))
            assert state.get("runtime") == "python"
            assert state.get("mode") == "inferred"
            assert state.get("manifest_generated") is True
            assert state.get("last_install_status") == "ok"
            assert "requests" in (state.get("resolved_packages") or [])
            assert "Pillow" in (state.get("resolved_packages") or [])
        finally:
            _shutdown_subprocess_pool()
            python_daemon._REAL_SUBPROCESS_RUN = old_run
            python_daemon._REQ_CACHE.clear()
            python_daemon.FUNCTIONS_DIR = old_functions
            python_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime
            if prev_auto is None:
                os.environ.pop("FN_AUTO_REQUIREMENTS", None)
            else:
                os.environ["FN_AUTO_REQUIREMENTS"] = prev_auto
            if prev_infer is None:
                os.environ.pop("FN_AUTO_INFER_PY_DEPS", None)
            else:
                os.environ["FN_AUTO_INFER_PY_DEPS"] = prev_infer
            if prev_write is None:
                os.environ.pop("FN_AUTO_INFER_WRITE_MANIFEST", None)
            else:
                os.environ["FN_AUTO_INFER_WRITE_MANIFEST"] = prev_write
            if prev_strict is None:
                os.environ.pop("FN_AUTO_INFER_STRICT", None)
            else:
                os.environ["FN_AUTO_INFER_STRICT"] = prev_strict


def test_auto_infer_python_strict_unresolved_fails() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fn_dir = root / "infer-py-fail"
        fn_dir.mkdir(parents=True, exist_ok=True)
        (fn_dir / "app.py").write_text(
            """
import json

def _deps_marker():
    import MyInternalSDK
    return MyInternalSDK

def handler(event):
    return {"status": 200, "body": json.dumps({"ok": True})}
""".strip()
            + "\n",
            encoding="utf-8",
        )

        old_functions, old_runtime = _set_functions_root(root)
        prev_auto = os.environ.get("FN_AUTO_REQUIREMENTS")
        prev_infer = os.environ.get("FN_AUTO_INFER_PY_DEPS")
        prev_write = os.environ.get("FN_AUTO_INFER_WRITE_MANIFEST")
        prev_strict = os.environ.get("FN_AUTO_INFER_STRICT")
        os.environ["FN_AUTO_REQUIREMENTS"] = "1"
        os.environ["FN_AUTO_INFER_PY_DEPS"] = "1"
        os.environ["FN_AUTO_INFER_WRITE_MANIFEST"] = "1"
        os.environ["FN_AUTO_INFER_STRICT"] = "1"
        python_daemon._REQ_CACHE.clear()

        try:
            failed = False
            try:
                python_daemon._handle_request_direct({"fn": "infer-py-fail", "event": {"method": "GET"}})
            except RuntimeError as exc:
                failed = True
                assert "unresolved imports" in str(exc)
            assert failed, "expected unresolved import inference to fail"

            state = json.loads((fn_dir / ".fastfn-deps-state.json").read_text(encoding="utf-8"))
            assert state.get("last_install_status") == "error"
            assert "MyInternalSDK" in str(state.get("last_error"))
        finally:
            _shutdown_subprocess_pool()
            python_daemon._REQ_CACHE.clear()
            python_daemon.FUNCTIONS_DIR = old_functions
            python_daemon.RUNTIME_FUNCTIONS_DIR = old_runtime
            if prev_auto is None:
                os.environ.pop("FN_AUTO_REQUIREMENTS", None)
            else:
                os.environ["FN_AUTO_REQUIREMENTS"] = prev_auto
            if prev_infer is None:
                os.environ.pop("FN_AUTO_INFER_PY_DEPS", None)
            else:
                os.environ["FN_AUTO_INFER_PY_DEPS"] = prev_infer
            if prev_write is None:
                os.environ.pop("FN_AUTO_INFER_WRITE_MANIFEST", None)
            else:
                os.environ["FN_AUTO_INFER_WRITE_MANIFEST"] = prev_write
            if prev_strict is None:
                os.environ.pop("FN_AUTO_INFER_STRICT", None)
            else:
                os.environ["FN_AUTO_INFER_STRICT"] = prev_strict


def main() -> None:
    test_aws_lambda_adapter()
    test_cloudflare_worker_adapter()
    test_unknown_adapter_raises()
    test_native_event_env_is_visible_in_os_environ()
    test_auto_infer_python_generates_manifest_state_and_lockfile()
    test_auto_infer_python_strict_unresolved_fails()
    print("python daemon adapter tests passed")


if __name__ == "__main__":
    main()
