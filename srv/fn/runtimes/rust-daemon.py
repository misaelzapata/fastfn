#!/usr/bin/env python3
import json
import os
import re
import shutil
import socket
import stat
import struct
import subprocess
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError as FutureTimeoutError
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict

SOCKET_PATH = os.environ.get("FN_RUST_SOCKET", "/tmp/fastfn/fn-rust.sock")
MAX_FRAME_BYTES = int(os.environ.get("FN_MAX_FRAME_BYTES", str(2 * 1024 * 1024)))
HOT_RELOAD = os.environ.get("FN_HOT_RELOAD", "1").lower() not in {"0", "false", "off", "no"}
RUST_BUILD_TIMEOUT_S = float(os.environ.get("FN_RUST_BUILD_TIMEOUT_S", "180"))
ENABLE_RUNTIME_WORKER_POOL = os.environ.get("FN_RUST_RUNTIME_WORKER_POOL", "1").lower() not in {"0", "false", "off", "no"}
RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = int(os.environ.get("FN_RUST_POOL_ACQUIRE_TIMEOUT_MS", "5000"))
RUNTIME_POOL_IDLE_TTL_MS = int(os.environ.get("FN_RUST_POOL_IDLE_TTL_MS", "300000"))
RUNTIME_POOL_REAPER_INTERVAL_MS = int(os.environ.get("FN_RUST_POOL_REAPER_INTERVAL_MS", "2000"))

BASE_DIR = Path(__file__).resolve().parents[1]
FUNCTIONS_DIR = Path(os.environ.get("FN_FUNCTIONS_ROOT", str(BASE_DIR / "functions" / "rust")))
RUNTIME_FUNCTIONS_DIR = FUNCTIONS_DIR / "rust"

_NAME_RE = re.compile(r"^[A-Za-z0-9._/\-\[\]]+$")
_VERSION_RE = re.compile(r"^[A-Za-z0-9_.-]+$")

_BINARY_CACHE: Dict[str, Dict[str, Any]] = {}
_BINARY_CACHE_LOCK = threading.Lock()
_RUNTIME_POOLS: Dict[str, Dict[str, Any]] = {}
_RUNTIME_POOLS_LOCK = threading.Lock()
_RUNTIME_POOL_REAPER_STARTED = False

_CARGO_TOML = """[package]
name = \"fn_handler\"
version = \"0.1.0\"
edition = \"2021\"

[dependencies]
serde_json = \"1\"
"""

_MAIN_RS = """use serde_json::{json, Value};
use std::io::{self, Read};

mod user_handler;

fn main() {
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        print!(\"{}\", json!({\"error\": \"failed to read stdin\"}).to_string());
        return;
    }

    let req: Value = serde_json::from_str(&input).unwrap_or_else(|_| json!({}));
    let mut event = req.get(\"event\").cloned().unwrap_or_else(|| json!({}));
    if let Some(params) = event.get(\"params\").cloned() {
        if let (Some(event_map), Some(params_map)) = (event.as_object_mut(), params.as_object()) {
            for (k, v) in params_map {
                event_map.entry(k.clone()).or_insert(v.clone());
            }
        }
    }
    let out = user_handler::handler(event);
    print!(\"{}\", out.to_string());
}
"""


def _read_function_env(handler_path: Path) -> Dict[str, str]:
    env_path = handler_path.with_name("fn.env.json")
    if not env_path.is_file():
        return {}

    try:
        data = json.loads(env_path.read_text(encoding="utf-8"))
    except Exception:
        return {}

    if not isinstance(data, dict):
        return {}

    out: Dict[str, str] = {}
    for key, value in data.items():
        if not isinstance(key, str):
            continue
        if isinstance(value, dict) and "value" in value:
            scalar = value.get("value")
            if scalar is None:
                continue
            out[key] = str(scalar)
            continue
        if value is None:
            continue
        out[key] = str(value)
    return out


@contextmanager
def _patched_process_env(env: Dict[str, Any]) -> Any:
    if not isinstance(env, dict) or not env:
        yield
        return

    tracked: list[str] = []
    previous: Dict[str, str] = {}
    for raw_key, raw_value in env.items():
        if not isinstance(raw_key, str) or not raw_key:
            continue
        tracked.append(raw_key)
        if raw_key in os.environ:
            previous[raw_key] = os.environ[raw_key]
        if raw_value is None:
            os.environ.pop(raw_key, None)
        else:
            os.environ[raw_key] = str(raw_value)

    try:
        yield
    finally:
        for key in tracked:
            if key in previous:
                os.environ[key] = previous[key]
            else:
                os.environ.pop(key, None)


def _recvall(conn: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def _read_frame(conn: socket.socket) -> Dict[str, Any]:
    header = _recvall(conn, 4)
    if len(header) != 4:
        raise ValueError("invalid frame header")

    (length,) = struct.unpack("!I", header)
    if length <= 0 or length > MAX_FRAME_BYTES:
        raise ValueError("invalid frame length")

    payload = _recvall(conn, length)
    if len(payload) != length:
        raise ValueError("incomplete frame")

    req = json.loads(payload.decode("utf-8"))
    if not isinstance(req, dict):
        raise ValueError("request must be an object")
    return req


def _write_frame(conn: socket.socket, obj: Dict[str, Any]) -> None:
    payload = json.dumps(obj, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    conn.sendall(struct.pack("!I", len(payload)) + payload)


def _resolve_handler_path(name: str, version: Any) -> Path:
    if not isinstance(name, str) or not name.strip():
        raise ValueError("invalid function name")
    normalized_name = name.replace("\\", "/")
    if (
        normalized_name.startswith("/")
        or normalized_name == ".."
        or normalized_name.startswith("../")
        or normalized_name.endswith("/..")
        or "/../" in normalized_name
    ):
        raise ValueError("invalid function name")

    # New Logic: Direct file check logic
    if not version or version == "":
         # 1. From root (e.g. src/delete.rs)
         root_check = FUNCTIONS_DIR / name
         if root_check.is_file():
             return root_check
         
         # 2. From runtime dir (e.g. rust/delete.rs)
         runtime_check = RUNTIME_FUNCTIONS_DIR / name
         if runtime_check.is_file():
             return runtime_check

    base = FUNCTIONS_DIR / name
    
    # Try falling back to RUNTIME_FUNCTIONS_DIR structure
    if not base.exists():
         runtime_base = RUNTIME_FUNCTIONS_DIR / name
         if runtime_base.exists():
             base = runtime_base

    target_dir = base
    if version is not None and version != "":
        if not isinstance(version, str) or not _VERSION_RE.match(version):
            raise ValueError("invalid function version")
        target_dir = base / version
    
    # 3. Look for standard cargo structure or single files inside target_dir
    candidates = ["app.rs", "handler.rs", "src/lib.rs", "lib.rs"]
    
    for fname in candidates:
        candidate_path = target_dir / fname
        if candidate_path.is_file():
            return candidate_path

    raise FileNotFoundError("unknown function")


def _normalize_response(resp: Any) -> Dict[str, Any]:
    if not isinstance(resp, dict):
        raise ValueError("handler response must be an object")

    status = resp.get("status", resp.get("statusCode", 200))
    if not isinstance(status, int) or status < 100 or status > 599:
        raise ValueError("status must be a valid HTTP code")

    headers = resp.get("headers", {})
    if not isinstance(headers, dict):
        raise ValueError("headers must be an object")

    is_base64 = bool(resp.get("is_base64", resp.get("isBase64Encoded", False)))
    if is_base64:
        body_base64 = resp.get("body_base64", resp.get("body"))
        if not isinstance(body_base64, str) or body_base64 == "":
            raise ValueError("body_base64 must be a non-empty string when is_base64=true")
        return {
            "status": status,
            "headers": headers,
            "is_base64": True,
            "body_base64": body_base64,
        }

    body = resp.get("body", "")
    if body is None:
        body = ""
    if not isinstance(body, str):
        body = str(body)

    return {
        "status": status,
        "headers": headers,
        "body": body,
    }


def _ensure_rust_binary(handler_path: Path) -> Path:
    cargo = shutil.which("cargo")
    if cargo is None:
        raise RuntimeError("cargo not found in PATH")

    cache_key = str(handler_path)
    source_mtime = handler_path.stat().st_mtime_ns
    with _BINARY_CACHE_LOCK:
        cached = _BINARY_CACHE.get(cache_key)
    if cached is not None and cached.get("mtime_ns") == source_mtime:
        binary = Path(cached.get("binary", ""))
        if binary.is_file() and not HOT_RELOAD:
            return binary
        if binary.is_file() and HOT_RELOAD:
            return binary

    fn_dir = handler_path.parent
    build_dir = fn_dir / ".rust-build"
    src_dir = build_dir / "src"
    src_dir.mkdir(parents=True, exist_ok=True)

    cargo_toml = build_dir / "Cargo.toml"
    main_rs = src_dir / "main.rs"
    user_rs = src_dir / "user_handler.rs"

    cargo_toml.write_text(_CARGO_TOML, encoding="utf-8")
    main_rs.write_text(_MAIN_RS, encoding="utf-8")
    user_rs.write_text(handler_path.read_text(encoding="utf-8"), encoding="utf-8")

    cmd = [cargo, "build", "--release", "--manifest-path", str(cargo_toml)]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            cwd=str(build_dir),
            timeout=max(1.0, RUST_BUILD_TIMEOUT_S),
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"rust build timeout after {max(1.0, RUST_BUILD_TIMEOUT_S):.1f}s: {exc}") from exc
    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip()
        stdout = (proc.stdout or "").strip()
        detail = stderr or stdout or "unknown cargo build error"
        raise RuntimeError(f"rust build failed: {detail[:1200]}")

    binary = build_dir / "target" / "release" / "fn_handler"
    if not binary.is_file():
        raise RuntimeError("rust build produced no binary")

    with _BINARY_CACHE_LOCK:
        _BINARY_CACHE[cache_key] = {
            "mtime_ns": source_mtime,
            "binary": str(binary),
        }
    return binary


def _run_rust_handler(binary: Path, event: Dict[str, Any], timeout_ms: int) -> Dict[str, Any]:
    payload = {"event": event}
    try:
        proc = subprocess.run(
            [str(binary)],
            input=json.dumps(payload, separators=(",", ":"), ensure_ascii=False),
            text=True,
            capture_output=True,
            timeout=max(1.0, timeout_ms / 1000.0),
            cwd=str(binary.parent),
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        return {
            "status": 504,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": f"rust handler timeout: {exc}"}, separators=(",", ":")),
        }

    raw = (proc.stdout or "").strip()
    if raw == "":
        message = (proc.stderr or "rust handler produced empty response").strip()
        return {
            "status": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": message}, separators=(",", ":")),
        }

    try:
        parsed = json.loads(raw)
    except Exception:
        return {
            "status": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "invalid rust handler response", "raw": raw[:400]}, separators=(",", ":")),
        }

    result = _normalize_response(parsed)
    stderr_str = (proc.stderr or "").strip()
    if stderr_str:
        result["stderr"] = stderr_str
    return result


def _error_response(message: str, status: int = 500) -> Dict[str, Any]:
    return {
        "status": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}, separators=(",", ":")),
    }


def _runtime_pool_key(fn_name: Any, version: Any) -> str:
    key_fn = fn_name if isinstance(fn_name, str) and fn_name else "unknown"
    key_ver = version if isinstance(version, str) and version else "default"
    return f"{key_fn}@{key_ver}"


def _normalize_worker_pool_settings(req: Dict[str, Any]) -> Dict[str, Any]:
    event = req.get("event")
    context = event.get("context") if isinstance(event, dict) else None
    if not isinstance(context, dict):
        context = {}
    raw = context.get("worker_pool")
    if not isinstance(raw, dict):
        raw = {}

    max_workers = int(raw.get("max_workers") or 0)
    if max_workers < 0:
        max_workers = 0
    min_warm = int(raw.get("min_warm") or 0)
    if min_warm < 0:
        min_warm = 0
    if max_workers > 0 and min_warm > max_workers:
        min_warm = max_workers

    idle_ttl_seconds = float(raw.get("idle_ttl_seconds") or 0)
    idle_ttl_ms = int(idle_ttl_seconds * 1000)
    if idle_ttl_ms < 1000:
        idle_ttl_ms = RUNTIME_POOL_IDLE_TTL_MS

    request_timeout_ms = int(context.get("timeout_ms") or 0)
    if request_timeout_ms < 0:
        request_timeout_ms = 0

    acquire_timeout_ms = max(
        request_timeout_ms + 500 if request_timeout_ms > 0 else RUNTIME_POOL_ACQUIRE_TIMEOUT_MS,
        RUNTIME_POOL_ACQUIRE_TIMEOUT_MS,
    )
    if acquire_timeout_ms < 100:
        acquire_timeout_ms = 100

    enabled = raw.get("enabled", True) is not False
    if max_workers <= 0:
        enabled = False

    return {
        "enabled": enabled,
        "max_workers": max_workers,
        "min_warm": min_warm,
        "idle_ttl_ms": idle_ttl_ms,
        "request_timeout_ms": request_timeout_ms,
        "acquire_timeout_ms": acquire_timeout_ms,
    }


def _shutdown_runtime_pool(pool: Dict[str, Any]) -> None:
    executor = pool.get("executor")
    if isinstance(executor, ThreadPoolExecutor):
        executor.shutdown(wait=False, cancel_futures=False)


def _start_runtime_pool_reaper() -> None:
    global _RUNTIME_POOL_REAPER_STARTED
    if _RUNTIME_POOL_REAPER_STARTED or RUNTIME_POOL_REAPER_INTERVAL_MS <= 0:
        return
    _RUNTIME_POOL_REAPER_STARTED = True

    def _run_reaper() -> None:
        interval_s = max(0.5, float(RUNTIME_POOL_REAPER_INTERVAL_MS) / 1000.0)
        while True:
            time.sleep(interval_s)
            now = time.monotonic()
            evicted: list[Dict[str, Any]] = []
            with _RUNTIME_POOLS_LOCK:
                for key, pool in list(_RUNTIME_POOLS.items()):
                    pending = int(pool.get("pending") or 0)
                    min_warm = int(pool.get("min_warm") or 0)
                    idle_ttl_ms = int(pool.get("idle_ttl_ms") or RUNTIME_POOL_IDLE_TTL_MS)
                    last_used = float(pool.get("last_used") or now)
                    if pending > 0 or min_warm > 0:
                        continue
                    idle_for_ms = int((now - last_used) * 1000)
                    if idle_for_ms >= idle_ttl_ms:
                        evicted.append(pool)
                        _RUNTIME_POOLS.pop(key, None)
            for pool in evicted:
                _shutdown_runtime_pool(pool)

    threading.Thread(target=_run_reaper, name="fn-rust-runtime-pool-reaper", daemon=True).start()


def _warmup_runtime_pool(pool: Dict[str, Any]) -> None:
    target = int(pool.get("min_warm") or 0)
    if target <= 0:
        return

    executor = pool.get("executor")
    if not isinstance(executor, ThreadPoolExecutor):
        return

    noop_futures: list[Future[Any]] = []
    for _ in range(target):
        noop_futures.append(executor.submit(lambda: None))
    for fut in noop_futures:
        try:
            fut.result(timeout=1.0)
        except Exception:
            continue


def _ensure_runtime_pool(pool_key: str, settings: Dict[str, Any]) -> Dict[str, Any]:
    with _RUNTIME_POOLS_LOCK:
        existing = _RUNTIME_POOLS.get(pool_key)
        max_workers = int(settings.get("max_workers") or 0)
        min_warm = int(settings.get("min_warm") or 0)
        idle_ttl_ms = int(settings.get("idle_ttl_ms") or RUNTIME_POOL_IDLE_TTL_MS)

        if existing is not None:
            if int(existing.get("max_workers") or 0) == max_workers:
                existing["min_warm"] = min_warm
                existing["idle_ttl_ms"] = idle_ttl_ms
                existing["last_used"] = time.monotonic()
                pool = existing
            else:
                _RUNTIME_POOLS.pop(pool_key, None)
                pool = None
        else:
            pool = None

        if pool is None:
            executor = ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix=f"fn-rust-{abs(hash(pool_key))}")
            pool = {
                "executor": executor,
                "max_workers": max_workers,
                "min_warm": min_warm,
                "idle_ttl_ms": idle_ttl_ms,
                "pending": 0,
                "last_used": time.monotonic(),
            }
            _RUNTIME_POOLS[pool_key] = pool

    _start_runtime_pool_reaper()
    _warmup_runtime_pool(pool)
    return pool


def _submit_runtime_pool_request(pool_key: str, pool: Dict[str, Any], req: Dict[str, Any]) -> Future[Dict[str, Any]]:
    executor = pool.get("executor")
    if not isinstance(executor, ThreadPoolExecutor):
        raise RuntimeError("invalid runtime pool executor")

    with _RUNTIME_POOLS_LOCK:
        pool["pending"] = int(pool.get("pending") or 0) + 1
        pool["last_used"] = time.monotonic()

    future: Future[Dict[str, Any]] = executor.submit(_handle_request_direct, req)

    def _done_callback(_fut: Future[Dict[str, Any]]) -> None:
        with _RUNTIME_POOLS_LOCK:
            current = _RUNTIME_POOLS.get(pool_key)
            if current is None:
                return
            current["pending"] = max(0, int(current.get("pending") or 0) - 1)
            current["last_used"] = time.monotonic()

    future.add_done_callback(_done_callback)
    return future


def _handle_request_direct(req: Dict[str, Any]) -> Dict[str, Any]:
    fn_name = req.get("fn")
    version = req.get("version")
    event = req.get("event", {})

    if not isinstance(fn_name, str) or not fn_name:
        raise ValueError("fn is required")
    if not isinstance(event, dict):
        raise ValueError("event must be an object")

    path = _resolve_handler_path(fn_name, version)
    binary = _ensure_rust_binary(path)

    event_with_env = dict(event)
    incoming_env = event_with_env.get("env")
    merged_env = dict(incoming_env) if isinstance(incoming_env, dict) else {}
    for key, value in _read_function_env(path).items():
        merged_env[key] = value
    if merged_env:
        event_with_env["env"] = merged_env

    timeout_ms = 2500
    context = event_with_env.get("context")
    if isinstance(context, dict):
        value = context.get("timeout_ms")
        if isinstance(value, (int, float)) and value > 0:
            timeout_ms = int(value) + 500

    with _patched_process_env(event_with_env.get("env", {})):
        return _run_rust_handler(binary, event_with_env, timeout_ms)


def _handle_request_with_pool(req: Dict[str, Any]) -> Dict[str, Any]:
    settings = _normalize_worker_pool_settings(req)
    if not ENABLE_RUNTIME_WORKER_POOL or not settings["enabled"] or settings["max_workers"] <= 0:
        return _handle_request_direct(req)

    pool_key = _runtime_pool_key(req.get("fn"), req.get("version"))
    pool = _ensure_runtime_pool(pool_key, settings)
    future = _submit_runtime_pool_request(pool_key, pool, req)

    timeout_ms = int(settings.get("request_timeout_ms") or 0)
    wait_seconds = max(1.0, timeout_ms / 1000.0 + 0.5) if timeout_ms > 0 else max(
        1.0, float(settings.get("acquire_timeout_ms") or RUNTIME_POOL_ACQUIRE_TIMEOUT_MS) / 1000.0
    )

    try:
        return future.result(timeout=wait_seconds)
    except FutureTimeoutError:
        return _error_response("runtime worker timeout", status=504)


def _ensure_socket_dir(path: str) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)

def _prepare_socket_path(path: str) -> None:
    try:
        mode = os.stat(path).st_mode
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(mode):
        raise RuntimeError(f"runtime socket path exists and is not a unix socket: {path}")

    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(0.2)
    try:
        probe.connect(path)
    except OSError:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    else:
        raise RuntimeError(f"runtime socket already in use: {path}")
    finally:
        probe.close()


def _serve_conn(conn: socket.socket) -> None:
    with conn:
        try:
            req = _read_frame(conn)
            resp = _handle_request_with_pool(req)
        except FileNotFoundError as exc:
            resp = _error_response(str(exc), status=404)
        except ValueError as exc:
            resp = _error_response(str(exc), status=400)
        except Exception as exc:  # noqa: BLE001
            resp = _error_response(str(exc), status=500)

        try:
            _write_frame(conn, resp)
        except Exception:
            pass


def main() -> None:
    _ensure_socket_dir(SOCKET_PATH)
    _prepare_socket_path(SOCKET_PATH)

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o666)
        server.listen(128)

        while True:
            conn, _ = server.accept()
            threading.Thread(target=_serve_conn, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
