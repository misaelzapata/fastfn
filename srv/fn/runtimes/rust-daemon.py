#!/usr/bin/env python3
import json
import os
import re
import select
import shutil
import socket
import stat
import struct
import subprocess
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError as FutureTimeoutError
from contextlib import contextmanager
import fcntl
import hashlib
import sys
from pathlib import Path
from typing import Any, Dict, Optional

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
_PERSISTENT_RUNTIME_POOLS: Dict[str, Dict[str, Any]] = {}
_PERSISTENT_RUNTIME_POOLS_LOCK = threading.Lock()
_PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False

_CARGO_TOML = """[package]
name = \"fn_handler\"
version = \"0.1.0\"
edition = \"2021\"

[dependencies]
serde_json = \"1\"
"""

_MAIN_RS = """use serde_json::{json, Map, Value};
use std::env;
use std::io::{self, Read, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};

mod user_handler;

fn error_response(message: &str) -> Value {
    json!({
        "status": 500,
        "headers": {"Content-Type": "application/json"},
        "body": json!({"error": message}).to_string()
    })
}

fn read_frame<R: Read>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0u8; 4];
    match reader.read_exact(&mut header) {
        Ok(()) => {}
        Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(err),
    }
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 {
        return Ok(None);
    }
    let mut payload = vec![0u8; length];
    reader.read_exact(&mut payload)?;
    Ok(Some(payload))
}

fn write_frame<W: Write>(writer: &mut W, payload: &Value) -> io::Result<()> {
    let encoded = serde_json::to_vec(payload).unwrap_or_else(|_| serde_json::to_vec(&error_response("failed to encode rust handler output")).unwrap());
    let header = (encoded.len() as u32).to_be_bytes();
    writer.write_all(&header)?;
    writer.write_all(&encoded)?;
    writer.flush()
}

fn merge_params_into_event(event: &mut Value) {
    let params = event.get("params").cloned();
    if let Some(params_value) = params {
        if let (Some(event_map), Some(params_map)) = (event.as_object_mut(), params_value.as_object()) {
            for (key, value) in params_map {
                if !event_map.contains_key(key) {
                    event_map.insert(key.clone(), value.clone());
                }
            }
        }
    }
}

fn apply_runtime_env(event: &Value) -> Vec<(String, Option<String>)> {
    let mut previous: Vec<(String, Option<String>)> = Vec::new();
    let Some(env_map) = event.get("env").and_then(|value| value.as_object()) else {
        return previous;
    };

    for (key, value) in env_map {
        let prior = env::var(key).ok();
        previous.push((key.clone(), prior));
        if value.is_null() {
            env::remove_var(key);
        } else {
            let string_value = value.as_str().map(|item| item.to_string()).unwrap_or_else(|| value.to_string());
            env::set_var(key, string_value);
        }
    }
    previous
}

fn restore_runtime_env(previous: Vec<(String, Option<String>)>) {
    for (key, value) in previous {
        if let Some(item) = value {
            env::set_var(key, item);
        } else {
            env::remove_var(key);
        }
    }
}

fn handle_event(mut event: Value) -> Value {
    merge_params_into_event(&mut event);
    match catch_unwind(AssertUnwindSafe(|| user_handler::handler(event))) {
        Ok(out) => out,
        Err(_) => error_response("rust handler panicked"),
    }
}

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = stdout.lock();

    loop {
        let frame = match read_frame(&mut reader) {
            Ok(Some(payload)) => payload,
            Ok(None) => break,
            Err(_) => {
                let _ = write_frame(&mut writer, &error_response("failed to read stdin"));
                break;
            }
        };

        let req: Value = serde_json::from_slice(&frame).unwrap_or_else(|_| json!({}));
        let event = req.get("event").cloned().unwrap_or_else(|| Value::Object(Map::new()));
        let previous_env = apply_runtime_env(&event);
        let out = handle_event(event);
        restore_runtime_env(previous_env);
        if write_frame(&mut writer, &out).is_err() {
            break;
        }
    }
}
"""
_MAIN_RS_DIGEST = hashlib.sha256(_MAIN_RS.encode("utf-8")).hexdigest()
_CARGO_TOML_DIGEST = hashlib.sha256(_CARGO_TOML.encode("utf-8")).hexdigest()


def _resolve_command(env_name: str, default: str) -> str:
    configured = str(os.environ.get(env_name, "")).strip()
    if configured:
        if "/" in configured or "\\" in configured:
            candidate = Path(configured)
            if candidate.is_file() and os.access(str(candidate), os.X_OK):
                return str(candidate)
            raise RuntimeError(f"{env_name} is not executable: {configured}")
        resolved = shutil.which(configured)
        if resolved:
            return resolved
        raise RuntimeError(f"{env_name} not found in PATH: {configured}")
    resolved = shutil.which(default)
    if resolved:
        return resolved
    raise RuntimeError(f"{default} not found in PATH")


def _file_signature(path: Path) -> Optional[tuple[int, int]]:
    try:
        stat_info = path.stat()
    except FileNotFoundError:
        return None
    return (stat_info.st_mtime_ns, stat_info.st_size)


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
    cargo = _resolve_command("FN_CARGO_BIN", "cargo")

    cache_key = str(handler_path)
    source_mtime = handler_path.stat().st_mtime_ns
    signature = {
        "source_mtime_ns": source_mtime,
        "main_rs_hash": _MAIN_RS_DIGEST,
        "cargo_toml_hash": _CARGO_TOML_DIGEST,
    }
    with _BINARY_CACHE_LOCK:
        cached = _BINARY_CACHE.get(cache_key)

    fn_dir = handler_path.parent
    build_dir = fn_dir / ".rust-build"
    src_dir = build_dir / "src"
    src_dir.mkdir(parents=True, exist_ok=True)
    binary = build_dir / "target" / "release" / "fn_handler"
    meta_path = build_dir / ".fastfn-build-meta.json"
    lock_path = build_dir / ".fastfn-build.lock"

    if cached is not None:
        cached_binary = Path(str(cached.get("binary", "")))
        if cached_binary.is_file() and cached.get("signature") == signature:
            return cached_binary

    cargo_toml = build_dir / "Cargo.toml"
    main_rs = src_dir / "main.rs"
    user_rs = src_dir / "user_handler.rs"

    def _load_metadata() -> Optional[Dict[str, Any]]:
        try:
            raw = meta_path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return None
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, dict) else None

    def _write_metadata() -> None:
        meta_path.write_text(
            json.dumps({"signature": signature, "binary": str(binary)}, separators=(",", ":"), sort_keys=True),
            encoding="utf-8",
        )

    with lock_path.open("a+", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            metadata = _load_metadata()
            if (
                isinstance(metadata, dict)
                and metadata.get("signature") == signature
                and binary.is_file()
            ):
                with _BINARY_CACHE_LOCK:
                    _BINARY_CACHE[cache_key] = {
                        "signature": signature,
                        "binary": str(binary),
                    }
                return binary

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

            if not binary.is_file():
                raise RuntimeError("rust build produced no binary")
            _write_metadata()
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)

    with _BINARY_CACHE_LOCK:
        _BINARY_CACHE[cache_key] = {
            "signature": signature,
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


class _PersistentRustWorker:
    __slots__ = ("binary", "proc", "lock", "_dead")

    def __init__(self, binary: Path):
        self.binary = binary
        self.lock = threading.Lock()
        self._dead = False
        self.proc = subprocess.Popen(
            [str(binary)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
            cwd=str(binary.parent),
        )

    @property
    def alive(self) -> bool:
        return not self._dead and self.proc.poll() is None

    def send_request(self, event: Dict[str, Any], timeout_ms: int) -> Dict[str, Any]:
        timeout_s = max(1.0, float(timeout_ms) / 1000.0)
        payload = json.dumps({"event": event}, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        with self.lock:
            if not self.alive:
                raise RuntimeError("worker process is dead")
            if self.proc.stdin is None or self.proc.stdout is None:
                self._mark_dead()
                raise RuntimeError("worker pipes are unavailable")
            try:
                self.proc.stdin.write(struct.pack("!I", len(payload)))
                self.proc.stdin.write(payload)
                self.proc.stdin.flush()

                stdout_fd = self.proc.stdout.fileno()
                resp_header = self._read_exact(stdout_fd, 4, timeout_s)
                if resp_header is None:
                    self._mark_dead()
                    raise RuntimeError("worker closed stdout")
                (resp_len,) = struct.unpack("!I", resp_header)
                if resp_len <= 0 or resp_len > MAX_FRAME_BYTES:
                    self._mark_dead()
                    raise RuntimeError("invalid worker frame length")
                resp_payload = self._read_exact(stdout_fd, resp_len, timeout_s)
                if resp_payload is None:
                    self._mark_dead()
                    raise RuntimeError("incomplete worker response")
                parsed = json.loads(resp_payload.decode("utf-8"))
                if not isinstance(parsed, dict):
                    raise RuntimeError("worker response must be an object")
                return parsed
            except TimeoutError:
                self._mark_dead()
                raise
            except (BrokenPipeError, OSError):
                self._mark_dead()
                raise RuntimeError("worker pipe broken")

    def _read_exact(self, fd: int, size: int, timeout_s: float) -> Optional[bytes]:
        data = bytearray()
        deadline = time.monotonic() + timeout_s
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self._mark_dead()
                raise TimeoutError("rust worker read timeout")
            ready, _, _ = select.select([fd], [], [], min(remaining, 1.0))
            if not ready:
                continue
            chunk = os.read(fd, size - len(data))
            if not chunk:
                return None
            data.extend(chunk)
        return bytes(data)

    def _mark_dead(self) -> None:
        self._dead = True
        try:
            self.proc.kill()
        except Exception:
            pass

    def shutdown(self) -> None:
        self._dead = True
        try:
            if self.proc.stdin is not None:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=2.0)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


def _error_response(message: str, status: int = 500) -> Dict[str, Any]:
    return {
        "status": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}, separators=(",", ":")),
    }


def _emit_handler_logs(req: Dict[str, Any], resp: Dict[str, Any]) -> None:
    if not isinstance(resp, dict):
        return
    fn_name = req.get("fn") if isinstance(req, dict) else None
    version = req.get("version") if isinstance(req, dict) else None
    label = str(fn_name or "unknown")
    version_label = str(version or "default")

    stdout_value = resp.get("stdout")
    if isinstance(stdout_value, str) and stdout_value != "":
        for line in stdout_value.splitlines():
            print(f"[fn:{label}@{version_label} stdout] {line}", flush=True)

    stderr_value = resp.get("stderr")
    if isinstance(stderr_value, str) and stderr_value != "":
        for line in stderr_value.splitlines():
            print(f"[fn:{label}@{version_label} stderr] {line}", file=sys.stderr, flush=True)


def _runtime_pool_key(fn_name: Any, version: Any) -> str:
    key_fn = fn_name if isinstance(fn_name, str) and fn_name else "unknown"
    key_ver = version if isinstance(version, str) and version else "default"
    return f"{key_fn}@{key_ver}"


def _persistent_runtime_pool_key(fn_name: Any, version: Any, handler_path: Path) -> str:
    return f"{_runtime_pool_key(fn_name, version)}::{_handler_signature(handler_path)}"


def _handler_signature(handler_path: Path) -> str:
    files = [
        handler_path,
        handler_path.with_name("fn.env.json"),
    ]
    parts: list[str] = [str(_file_signature(path) or "missing") for path in files]
    parts.append(str(hash(_MAIN_RS)))
    parts.append(str(hash(_CARGO_TOML)))
    return "|".join(parts)


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


def _shutdown_persistent_runtime_pool(pool: Dict[str, Any]) -> None:
    workers = pool.get("workers")
    if not isinstance(workers, list):
        return
    for entry in list(workers):
        worker = entry.get("worker") if isinstance(entry, dict) else None
        if isinstance(worker, _PersistentRustWorker):
            worker.shutdown()


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


def _start_persistent_runtime_pool_reaper() -> None:
    global _PERSISTENT_RUNTIME_POOL_REAPER_STARTED
    if _PERSISTENT_RUNTIME_POOL_REAPER_STARTED or RUNTIME_POOL_REAPER_INTERVAL_MS <= 0:
        return
    _PERSISTENT_RUNTIME_POOL_REAPER_STARTED = True

    def _run_reaper() -> None:
        interval_s = max(0.5, float(RUNTIME_POOL_REAPER_INTERVAL_MS) / 1000.0)
        while True:
            time.sleep(interval_s)
            now = time.monotonic()
            evicted: list[Dict[str, Any]] = []
            with _PERSISTENT_RUNTIME_POOLS_LOCK:
                for key, pool in list(_PERSISTENT_RUNTIME_POOLS.items()):
                    pending = int(pool.get("pending") or 0)
                    min_warm = int(pool.get("min_warm") or 0)
                    idle_ttl_ms = int(pool.get("idle_ttl_ms") or RUNTIME_POOL_IDLE_TTL_MS)
                    last_used = float(pool.get("last_used") or now)
                    if pending > 0 or min_warm > 0:
                        continue
                    idle_for_ms = int((now - last_used) * 1000)
                    if idle_for_ms >= idle_ttl_ms:
                        evicted.append(pool)
                        _PERSISTENT_RUNTIME_POOLS.pop(key, None)
            for pool in evicted:
                _shutdown_persistent_runtime_pool(pool)

    threading.Thread(target=_run_reaper, name="fn-rust-persistent-pool-reaper", daemon=True).start()


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


def _create_persistent_runtime_worker(pool: Dict[str, Any]) -> Dict[str, Any]:
    worker = _PersistentRustWorker(pool["binary"])
    return {
        "worker": worker,
        "busy": False,
        "last_used": time.monotonic(),
    }


def _warmup_persistent_runtime_pool(pool: Dict[str, Any]) -> None:
    target = int(pool.get("min_warm") or 0)
    if target <= 0:
        return
    cond = pool.get("cond")
    if not isinstance(cond, threading.Condition):
        return
    with cond:
        workers = pool.get("workers")
        if not isinstance(workers, list):
            return
        while len(workers) < target and len(workers) < int(pool.get("max_workers") or 1):
            workers.append(_create_persistent_runtime_worker(pool))


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


def _ensure_persistent_runtime_pool(
    pool_key: str, handler_path: Path, binary: Path, settings: Dict[str, Any]
) -> Dict[str, Any]:
    stale: Optional[Dict[str, Any]] = None
    with _PERSISTENT_RUNTIME_POOLS_LOCK:
        existing = _PERSISTENT_RUNTIME_POOLS.get(pool_key)
        max_workers = max(1, int(settings.get("max_workers") or 1))
        min_warm = int(settings.get("min_warm") or 0)
        if min_warm < 0:
            min_warm = 0
        if min_warm > max_workers:
            min_warm = max_workers
        idle_ttl_ms = int(settings.get("idle_ttl_ms") or RUNTIME_POOL_IDLE_TTL_MS)

        if existing is not None and int(existing.get("max_workers") or 0) == max_workers:
            existing["min_warm"] = min_warm
            existing["idle_ttl_ms"] = idle_ttl_ms
            existing["last_used"] = time.monotonic()
            pool = existing
        else:
            if existing is not None:
                stale = existing
            pool = {
                "handler_path": handler_path,
                "binary": binary,
                "max_workers": max_workers,
                "min_warm": min_warm,
                "idle_ttl_ms": idle_ttl_ms,
                "workers": [],
                "pending": 0,
                "last_used": time.monotonic(),
            }
            lock = threading.Lock()
            pool["lock"] = lock
            pool["cond"] = threading.Condition(lock)
            _PERSISTENT_RUNTIME_POOLS[pool_key] = pool

    if stale is not None:
        _shutdown_persistent_runtime_pool(stale)
    _start_persistent_runtime_pool_reaper()
    _warmup_persistent_runtime_pool(pool)
    return pool


def _checkout_persistent_runtime_worker(pool: Dict[str, Any], acquire_timeout_ms: int) -> Dict[str, Any]:
    cond = pool.get("cond")
    if not isinstance(cond, threading.Condition):
        raise RuntimeError("invalid persistent runtime pool")
    deadline = time.monotonic() + max(0.1, float(acquire_timeout_ms) / 1000.0)
    stale_workers: list[_PersistentRustWorker] = []
    with cond:
        workers = pool.get("workers")
        if not isinstance(workers, list):
            raise RuntimeError("invalid persistent runtime pool workers")
        while True:
            alive_workers: list[Dict[str, Any]] = []
            for entry in workers:
                worker = entry.get("worker") if isinstance(entry, dict) else None
                if isinstance(worker, _PersistentRustWorker) and worker.alive:
                    alive_workers.append(entry)
                elif isinstance(worker, _PersistentRustWorker):
                    stale_workers.append(worker)
            workers[:] = alive_workers

            for entry in workers:
                if not bool(entry.get("busy")):
                    entry["busy"] = True
                    pool["last_used"] = time.monotonic()
                    for worker in stale_workers:
                        worker.shutdown()
                    return entry

            if len(workers) < int(pool.get("max_workers") or 1):
                entry = _create_persistent_runtime_worker(pool)
                entry["busy"] = True
                workers.append(entry)
                pool["last_used"] = time.monotonic()
                for worker in stale_workers:
                    worker.shutdown()
                return entry

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("runtime worker timeout")
            cond.wait(timeout=min(remaining, 0.2))


def _release_persistent_runtime_worker(pool: Dict[str, Any], entry: Dict[str, Any], discard: bool = False) -> None:
    cond = pool.get("cond")
    if not isinstance(cond, threading.Condition):
        return
    stale: Optional[_PersistentRustWorker] = None
    with cond:
        workers = pool.get("workers")
        if not isinstance(workers, list):
            return
        if entry in workers:
            worker = entry.get("worker")
            if discard or not isinstance(worker, _PersistentRustWorker) or not worker.alive:
                workers.remove(entry)
                if isinstance(worker, _PersistentRustWorker):
                    stale = worker
            else:
                entry["busy"] = False
                entry["last_used"] = time.monotonic()
            pool["last_used"] = time.monotonic()
            cond.notify()
    if stale is not None:
        stale.shutdown()


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


def _prepare_request(req: Dict[str, Any]) -> tuple[Path, Path, Dict[str, Any], int]:
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

    return path, binary, event_with_env, timeout_ms


def _run_prepared_request_persistent(
    pool_key: str, handler_path: Path, binary: Path, event: Dict[str, Any], timeout_ms: int, settings: Dict[str, Any]
) -> Dict[str, Any]:
    pool = _ensure_persistent_runtime_pool(pool_key, handler_path, binary, settings)
    acquire_timeout_ms = int(settings.get("acquire_timeout_ms") or RUNTIME_POOL_ACQUIRE_TIMEOUT_MS)
    with _PERSISTENT_RUNTIME_POOLS_LOCK:
        current = _PERSISTENT_RUNTIME_POOLS.get(pool_key)
        if current is pool:
            current["pending"] = int(current.get("pending") or 0) + 1
            current["last_used"] = time.monotonic()
    entry: Optional[Dict[str, Any]] = None
    try:
        entry = _checkout_persistent_runtime_worker(pool, acquire_timeout_ms)
        worker = entry.get("worker")
        if not isinstance(worker, _PersistentRustWorker):
            raise RuntimeError("invalid persistent worker")
        return _normalize_response(worker.send_request(event, timeout_ms))
    except TimeoutError:
        if entry is not None:
            _release_persistent_runtime_worker(pool, entry, discard=True)
            entry = None
        return _error_response("rust handler timeout", status=504)
    except Exception as exc:  # noqa: BLE001
        if entry is not None:
            _release_persistent_runtime_worker(pool, entry, discard=True)
            entry = None
        return _error_response(str(exc), status=500)
    finally:
        if entry is not None:
            _release_persistent_runtime_worker(pool, entry)
        with _PERSISTENT_RUNTIME_POOLS_LOCK:
            current = _PERSISTENT_RUNTIME_POOLS.get(pool_key)
            if current is pool:
                current["pending"] = max(0, int(current.get("pending") or 0) - 1)
                current["last_used"] = time.monotonic()


def _handle_request_direct(req: Dict[str, Any]) -> Dict[str, Any]:
    fn_name = req.get("fn")
    version = req.get("version")
    path, binary, event_with_env, timeout_ms = _prepare_request(req)
    settings = {
        "max_workers": 1,
        "min_warm": 0,
        "idle_ttl_ms": RUNTIME_POOL_IDLE_TTL_MS,
        "acquire_timeout_ms": max(timeout_ms + 250, RUNTIME_POOL_ACQUIRE_TIMEOUT_MS, 100),
    }
    pool_key = _persistent_runtime_pool_key(fn_name, version, path)
    return _run_prepared_request_persistent(pool_key, path, binary, event_with_env, timeout_ms, settings)


def _handle_request_with_pool(req: Dict[str, Any]) -> Dict[str, Any]:
    settings = _normalize_worker_pool_settings(req)
    if not ENABLE_RUNTIME_WORKER_POOL or not settings["enabled"] or settings["max_workers"] <= 0:
        return _handle_request_direct(req)
    path, binary, event_with_env, timeout_ms = _prepare_request(req)
    pool_key = _persistent_runtime_pool_key(req.get("fn"), req.get("version"), path)
    return _run_prepared_request_persistent(pool_key, path, binary, event_with_env, timeout_ms, settings)


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
        req: Dict[str, Any] = {}
        try:
            req = _read_frame(conn)
            resp = _handle_request_with_pool(req)
        except FileNotFoundError as exc:
            resp = _error_response(str(exc), status=404)
        except ValueError as exc:
            resp = _error_response(str(exc), status=400)
        except Exception as exc:  # noqa: BLE001
            resp = _error_response(str(exc), status=500)

        _emit_handler_logs(req, resp)
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


if __name__ == "__main__": main()
