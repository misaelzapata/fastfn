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
import sys
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError as FutureTimeoutError
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Optional

SOCKET_PATH = os.environ.get("FN_PHP_SOCKET", "/tmp/fastfn/fn-php.sock")
MAX_FRAME_BYTES = int(os.environ.get("FN_MAX_FRAME_BYTES", str(2 * 1024 * 1024)))
STRICT_FS = os.environ.get("FN_STRICT_FS", "1").lower() not in {"0", "false", "off", "no"}
RUNTIME_LOG_FILE = os.environ.get("FN_RUNTIME_LOG_FILE", "").strip()
STRICT_FS_EXTRA_ALLOW = os.environ.get("FN_STRICT_FS_ALLOW", "")
AUTO_COMPOSER_DEPS = os.environ.get("FN_AUTO_PHP_DEPS", "1").lower() not in {"0", "false", "off", "no"}
ENABLE_RUNTIME_WORKER_POOL = os.environ.get("FN_PHP_RUNTIME_WORKER_POOL", "1").lower() not in {"0", "false", "off", "no"}
RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = int(os.environ.get("FN_PHP_POOL_ACQUIRE_TIMEOUT_MS", "5000"))
RUNTIME_POOL_IDLE_TTL_MS = int(os.environ.get("FN_PHP_POOL_IDLE_TTL_MS", "300000"))
RUNTIME_POOL_REAPER_INTERVAL_MS = int(os.environ.get("FN_PHP_POOL_REAPER_INTERVAL_MS", "2000"))

BASE_DIR = Path(__file__).resolve().parents[1]
FUNCTIONS_DIR = Path(os.environ.get("FN_FUNCTIONS_ROOT", str(BASE_DIR / "functions")))
# Also check if runtime specific folder exists, to behave like before
RUNTIME_FUNCTIONS_DIR = FUNCTIONS_DIR / "php"
WORKER_FILE = Path(__file__).resolve().with_name("php-worker.php")

# Env var prefixes that must NEVER be passed to user function worker processes.
_BLOCKED_ENV_PREFIXES = ("FN_ADMIN_", "FN_CONSOLE_", "FN_TRUSTED_")


def _sanitize_worker_env(env: Dict[str, str]) -> Dict[str, str]:
    """Remove sensitive system env vars from a worker process environment."""
    return {k: v for k, v in env.items() if not k.startswith(_BLOCKED_ENV_PREFIXES)}


_NAME_RE = re.compile(r"^[A-Za-z0-9._/\-\[\]]+$")
_VERSION_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_COMPOSER_CACHE: Dict[str, str] = {}
_RUNTIME_POOLS: Dict[str, Dict[str, Any]] = {}
_RUNTIME_POOLS_LOCK = threading.Lock()
_RUNTIME_POOL_REAPER_STARTED = False
_PERSISTENT_RUNTIME_POOLS: Dict[str, Dict[str, Any]] = {}
_PERSISTENT_RUNTIME_POOLS_LOCK = threading.Lock()
_PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False


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


def _bool_env(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.lower() not in {"0", "false", "off", "no"}


def _parse_extra_allow_roots() -> list[Path]:
    out: list[Path] = []
    for chunk in STRICT_FS_EXTRA_ALLOW.split(","):
        part = chunk.strip()
        if not part:
            continue
        try:
            out.append(Path(part).expanduser().resolve(strict=False))
        except Exception:
            continue
    return out


_STRICT_EXTRA_ROOTS = _parse_extra_allow_roots()
_STRICT_SYSTEM_ROOTS = [
    Path("/tmp"),
    Path("/etc/ssl"),
    Path("/etc/pki"),
    Path("/usr/share/zoneinfo"),
]


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


_thread_local_env = threading.local()


@contextmanager
def _patched_process_env(env: Dict[str, Any]) -> Any:
    """Store per-request env overrides in thread-local storage instead of
    mutating the global os.environ.  This prevents env var leakage between
    concurrent requests handled by different threads."""
    if not isinstance(env, dict) or not env:
        yield
        return

    overrides: Dict[str, str | None] = {}
    for raw_key, raw_value in env.items():
        if not isinstance(raw_key, str) or not raw_key:
            continue
        overrides[raw_key] = None if raw_value is None else str(raw_value)

    _thread_local_env.env_overrides = overrides
    try:
        yield
    finally:
        _thread_local_env.env_overrides = None


def _build_subprocess_env(extra: Dict[str, Any] | None = None) -> Dict[str, str]:
    """Build an env dict for subprocess calls that merges the real os.environ
    with any thread-local overrides and optional extra vars."""
    result = _sanitize_worker_env(os.environ.copy())
    overrides = getattr(_thread_local_env, "env_overrides", None)
    if overrides:
        for k, v in overrides.items():
            if v is None:
                result.pop(k, None)
            else:
                result[k] = v
    if extra and isinstance(extra, dict):
        for k, v in extra.items():
            if isinstance(k, str) and k:
                result[k] = str(v) if v is not None else ""
    return result


def _ensure_composer_deps(handler_path: Path) -> None:
    if not AUTO_COMPOSER_DEPS:
        return

    fn_dir = handler_path.parent
    composer_json = fn_dir / "composer.json"
    if not composer_json.is_file():
        return

    try:
        composer = _resolve_command("FN_COMPOSER_BIN", "composer")
    except RuntimeError:
        return

    lock_file = fn_dir / "composer.lock"
    vendor_dir = fn_dir / "vendor"
    sig = f"{composer_json.stat().st_mtime_ns}:{lock_file.stat().st_mtime_ns if lock_file.is_file() else 'none'}"
    key = str(fn_dir)
    if _COMPOSER_CACHE.get(key) == sig:
        if vendor_dir.is_dir():
            return
        _COMPOSER_CACHE.pop(key, None)

    cmd = [
        composer,
        "install",
        "--no-dev",
        "--no-interaction",
        "--no-progress",
        "--prefer-dist",
        "--no-scripts",
    ]
    result = subprocess.run(
        cmd,
        cwd=str(fn_dir),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=180,
        text=True,
    )
    if result.returncode != 0:
        _COMPOSER_CACHE.pop(key, None)
        stderr = (result.stderr or "").strip()
        tail = " | ".join(stderr.splitlines()[-4:]) if stderr else "unknown error"
        raise RuntimeError(f"composer install failed for {fn_dir}: {tail}")

    _COMPOSER_CACHE[key] = sig


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

    # Try resolving relative to root first (for handlers/get.php)
    target_dir = None
    
    # 1. Check relative to Function Root (e.g. handlers/something.php)
    root_check = FUNCTIONS_DIR / name
    if root_check.is_file() or root_check.is_dir():
        target_dir = root_check
    
    # 2. Check relative to Runtime Subdir (e.g. php/something)
    if not target_dir:
        runtime_check = RUNTIME_FUNCTIONS_DIR / name
        if runtime_check.is_file() or runtime_check.is_dir():
            target_dir = runtime_check
            
    if not target_dir:
         # Fallback to root construction logic (maybe it's a dir we missed?)
         target_dir = FUNCTIONS_DIR / name

    if version is not None and version != "":
        if not isinstance(version, str) or not _VERSION_RE.match(version):
            raise ValueError("invalid function version")
        target_dir = target_dir / version

    if target_dir.is_file():
         return target_dir

    # Order: app.php -> handler.php -> index.php
    candidates = ["app.php", "handler.php", "index.php"]
    
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


def _strict_open_basedir(fn_dir: Path) -> str:
    roots = [fn_dir.resolve(strict=False)]

    vendor = (fn_dir / "vendor").resolve(strict=False)
    roots.append(vendor)

    for root in _STRICT_SYSTEM_ROOTS:
        roots.append(root.resolve(strict=False))
    for root in _STRICT_EXTRA_ROOTS:
        roots.append(root)

    seen: set[str] = set()
    ordered: list[str] = []
    for root in roots:
        value = str(root)
        if value not in seen:
            seen.add(value)
            ordered.append(value)
    return ":".join(ordered)


def _run_php_handler(handler_path: Path, event: Dict[str, Any], timeout_ms: int) -> Dict[str, Any]:
    php_bin = _resolve_command("FN_PHP_BIN", "php")
    cmd = [php_bin, "-d", "display_errors=0", "-d", "log_errors=0"]
    if STRICT_FS:
        cmd.extend(["-d", f"open_basedir={_strict_open_basedir(handler_path.parent)}"])
    cmd.extend([str(WORKER_FILE), str(handler_path)])

    env = _sanitize_worker_env(os.environ.copy())
    env["FN_STRICT_FS"] = "1" if STRICT_FS else "0"

    try:
        proc = subprocess.run(
            cmd,
            input=json.dumps(event, separators=(",", ":"), ensure_ascii=False),
            text=True,
            capture_output=True,
            timeout=max(1.0, timeout_ms / 1000.0),
            cwd=str(handler_path.parent),
            env=env,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        return {
            "status": 504,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": f"php handler timeout: {exc}"}, separators=(",", ":")),
        }

    raw = (proc.stdout or "").strip()
    if raw == "":
        message = (proc.stderr or "php handler produced empty response").strip()
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
            "body": json.dumps({"error": "invalid php handler response", "raw": raw[:400]}, separators=(",", ":")),
        }

    result = _normalize_response(parsed)
    stderr_str = (proc.stderr or "").strip()
    if stderr_str:
        result["stderr"] = stderr_str
    return result


class _PersistentPhpWorker:
    __slots__ = ("handler_path", "proc", "lock", "_dead")

    def __init__(self, handler_path: Path):
        php_bin = _resolve_command("FN_PHP_BIN", "php")
        cmd = [php_bin, "-d", "display_errors=0", "-d", "log_errors=0"]
        if STRICT_FS:
            cmd.extend(["-d", f"open_basedir={_strict_open_basedir(handler_path.parent)}"])
        cmd.extend([str(WORKER_FILE), str(handler_path)])

        env = _sanitize_worker_env(os.environ.copy())
        env["FN_STRICT_FS"] = "1" if STRICT_FS else "0"
        env["_FASTFN_WORKER_MODE"] = "persistent"

        self.handler_path = handler_path
        self.lock = threading.Lock()
        self._dead = False
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
            cwd=str(handler_path.parent),
            env=env,
        )

    @property
    def alive(self) -> bool:
        return not self._dead and self.proc.poll() is None

    def send_request(self, event: Dict[str, Any], timeout_ms: int) -> Dict[str, Any]:
        timeout_s = max(1.0, float(timeout_ms) / 1000.0)
        payload = json.dumps(event, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
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
                raise TimeoutError("php worker read timeout")
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
            log_line = f"[fn:{label}@{version_label} stdout] {line}"
            print(log_line, flush=True)
            _append_runtime_log("php", log_line)

    stderr_value = resp.get("stderr")
    if isinstance(stderr_value, str) and stderr_value != "":
        for line in stderr_value.splitlines():
            log_line = f"[fn:{label}@{version_label} stderr] {line}"
            print(log_line, file=sys.stderr, flush=True)
            _append_runtime_log("php", log_line)


def _append_runtime_log(runtime_name: str, line: str) -> None:
    if not RUNTIME_LOG_FILE:
        return
    try:
        parent = Path(RUNTIME_LOG_FILE).parent
        parent.mkdir(parents=True, exist_ok=True)
        with open(RUNTIME_LOG_FILE, "a", encoding="utf-8") as handle:
            handle.write(f"[{runtime_name}] {line}\n")
    except Exception:
        return


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
        handler_path.parent / "composer.json",
        handler_path.parent / "composer.lock",
        WORKER_FILE,
    ]
    parts: list[str] = []
    for path in files:
        if path.is_file():
            stat_info = path.stat()
            parts.append(f"{path.name}:{stat_info.st_mtime_ns}:{stat_info.st_size}")
        else:
            parts.append(f"{path.name}:missing")
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
        if isinstance(worker, _PersistentPhpWorker):
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

    threading.Thread(target=_run_reaper, name="fn-php-runtime-pool-reaper", daemon=True).start()


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

    threading.Thread(target=_run_reaper, name="fn-php-persistent-pool-reaper", daemon=True).start()


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
    worker = _PersistentPhpWorker(pool["handler_path"])
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
            executor = ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix=f"fn-php-{abs(hash(pool_key))}")
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


def _ensure_persistent_runtime_pool(pool_key: str, handler_path: Path, settings: Dict[str, Any]) -> Dict[str, Any]:
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
    stale_workers: list[_PersistentPhpWorker] = []
    with cond:
        workers = pool.get("workers")
        if not isinstance(workers, list):
            raise RuntimeError("invalid persistent runtime pool workers")
        while True:
            alive_workers: list[Dict[str, Any]] = []
            for entry in workers:
                worker = entry.get("worker") if isinstance(entry, dict) else None
                if isinstance(worker, _PersistentPhpWorker) and worker.alive:
                    alive_workers.append(entry)
                elif isinstance(worker, _PersistentPhpWorker):
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
    for worker in stale_workers:  # pragma: no cover – unreachable after while True
        worker.shutdown()


def _release_persistent_runtime_worker(pool: Dict[str, Any], entry: Dict[str, Any], discard: bool = False) -> None:
    cond = pool.get("cond")
    if not isinstance(cond, threading.Condition):
        return
    stale: Optional[_PersistentPhpWorker] = None
    with cond:
        workers = pool.get("workers")
        if not isinstance(workers, list):
            return
        if entry in workers:
            worker = entry.get("worker")
            if discard or not isinstance(worker, _PersistentPhpWorker) or not worker.alive:
                workers.remove(entry)
                if isinstance(worker, _PersistentPhpWorker):
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


def _prepare_request(req: Dict[str, Any]) -> tuple[Path, Dict[str, Any], int]:
    fn_name = req.get("fn")
    version = req.get("version")
    event = req.get("event", {})

    if not isinstance(fn_name, str) or not fn_name:
        raise ValueError("fn is required")
    if not isinstance(event, dict):
        raise ValueError("event must be an object")

    path = _resolve_handler_path(fn_name, version)
    _ensure_composer_deps(path)

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
            timeout_ms = int(value) + 250

    return path, event_with_env, timeout_ms


def _run_prepared_request_persistent(
    pool_key: str, handler_path: Path, event: Dict[str, Any], timeout_ms: int, settings: Dict[str, Any]
) -> Dict[str, Any]:
    pool = _ensure_persistent_runtime_pool(pool_key, handler_path, settings)
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
        if not isinstance(worker, _PersistentPhpWorker):
            raise RuntimeError("invalid persistent worker")
        return _normalize_response(worker.send_request(event, timeout_ms))
    except TimeoutError:
        if entry is not None:
            _release_persistent_runtime_worker(pool, entry, discard=True)
            entry = None
        return _error_response("php handler timeout", status=504)
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
    path, event_with_env, timeout_ms = _prepare_request(req)
    settings = {
        "max_workers": 1,
        "min_warm": 0,
        "idle_ttl_ms": RUNTIME_POOL_IDLE_TTL_MS,
        "acquire_timeout_ms": max(timeout_ms + 250, RUNTIME_POOL_ACQUIRE_TIMEOUT_MS, 100),
    }
    pool_key = _persistent_runtime_pool_key(fn_name, version, path)
    return _run_prepared_request_persistent(pool_key, path, event_with_env, timeout_ms, settings)


def _handle_request_with_pool(req: Dict[str, Any]) -> Dict[str, Any]:
    settings = _normalize_worker_pool_settings(req)
    if not ENABLE_RUNTIME_WORKER_POOL or not settings["enabled"] or settings["max_workers"] <= 0:
        return _handle_request_direct(req)
    path, event_with_env, timeout_ms = _prepare_request(req)
    pool_key = _persistent_runtime_pool_key(req.get("fn"), req.get("version"), path)
    return _run_prepared_request_persistent(pool_key, path, event_with_env, timeout_ms, settings)


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


def _entrypoint() -> None:
    if not WORKER_FILE.is_file():
        raise SystemExit("missing php-worker.php")
    main()


if __name__ == "__main__": _entrypoint()
