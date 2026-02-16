#!/usr/bin/env python3
import importlib.util
import json
import base64
import os
import re
import socket
import struct
import subprocess
import sys
import builtins
import io
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError as FutureTimeoutError
from pathlib import Path
from contextlib import contextmanager
from typing import Any, Callable, Dict

SOCKET_PATH = os.environ.get("FN_PY_SOCKET", "/tmp/fastfn/fn-python.sock")
MAX_FRAME_BYTES = int(os.environ.get("FN_MAX_FRAME_BYTES", str(2 * 1024 * 1024)))
HOT_RELOAD = os.environ.get("FN_HOT_RELOAD", "1").lower() not in {"0", "false", "off", "no"}
STRICT_FS = os.environ.get("FN_STRICT_FS", "1").lower() not in {"0", "false", "off", "no"}
STRICT_FS_EXTRA_ALLOW = os.environ.get("FN_STRICT_FS_ALLOW", "")
PREINSTALL_PY_DEPS_ON_START = os.environ.get("FN_PREINSTALL_PY_DEPS_ON_START", "0").lower() not in {"0", "false", "off", "no"}
ENABLE_RUNTIME_WORKER_POOL = os.environ.get("FN_PY_RUNTIME_WORKER_POOL", "1").lower() not in {"0", "false", "off", "no"}
RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = int(os.environ.get("FN_PY_POOL_ACQUIRE_TIMEOUT_MS", "5000"))
RUNTIME_POOL_IDLE_TTL_MS = int(os.environ.get("FN_PY_POOL_IDLE_TTL_MS", "300000"))
RUNTIME_POOL_REAPER_INTERVAL_MS = int(os.environ.get("FN_PY_POOL_REAPER_INTERVAL_MS", "2000"))

BASE_DIR = Path(__file__).resolve().parents[1]
FUNCTIONS_DIR = Path(os.environ.get("FN_FUNCTIONS_ROOT", str(BASE_DIR / "functions" / "python")))
RUNTIME_FUNCTIONS_DIR = FUNCTIONS_DIR / "python"
PACKS_DIR = BASE_DIR / "functions" / ".fastfn" / "packs" / "python"

_NAME_RE = re.compile(r"^[A-Za-z0-9._/\-\[\]]+$")
_VERSION_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_HANDLER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

_HANDLER_CACHE: Dict[str, Dict[str, Any]] = {}
_REQ_CACHE: Dict[str, bool] = {}
_PACK_REQ_CACHE: Dict[str, bool] = {}
_PROTECTED_FN_FILES = {"fn.config.json", "fn.env.json", "fn.test_events.json"}
_RUNTIME_POOLS: Dict[str, Dict[str, Any]] = {}
_RUNTIME_POOLS_LOCK = threading.Lock()
_RUNTIME_POOL_REAPER_STARTED = False

# Keep an unpatched reference to subprocess.run so the worker subprocess
# launcher still works when _strict_fs_guard patches subprocess globally.
_REAL_SUBPROCESS_RUN = subprocess.run


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


def _auto_requirements_enabled() -> bool:
    return os.environ.get("FN_AUTO_REQUIREMENTS", "1").lower() not in {"0", "false", "off", "no"}


def _read_function_env(handler_path: Path) -> Dict[str, str]:
    env_path = handler_path.with_name("fn.env.json")
    if not env_path.is_file():
        return {}

    try:
        raw = env_path.read_text(encoding="utf-8")
        data = json.loads(raw)
    except Exception:
        return {}

    if not isinstance(data, dict):
        return {}

    out: Dict[str, str] = {}
    for k, v in data.items():
        if not isinstance(k, str):
            continue
        if isinstance(v, dict) and "value" in v:
            value = v.get("value")
            if value is None:
                continue
            out[k] = str(value)
            continue
        if v is None:
            continue
        out[k] = str(v)
    return out


def _extract_requirements(handler_path: Path) -> list[str]:
    try:
        with handler_path.open("r", encoding="utf-8", errors="ignore") as f:
            for _ in range(30):
                line = f.readline()
                if not line:
                    break
                m = re.match(r"^\s*#@?requirements\s+(.+?)\s*$", line)
                if m:
                    raw = m.group(1).replace(",", " ")
                    reqs = [x.strip() for x in raw.split() if x.strip()]
                    return reqs
    except Exception:
        return []
    return []


def _ensure_requirements(handler_path: Path) -> None:
    inline_reqs = _extract_requirements(handler_path)
    req_file = handler_path.with_name("requirements.txt")
    if (not inline_reqs and not req_file.is_file()) or not _auto_requirements_enabled():
        return

    deps_dir = handler_path.parent / ".deps"

    req_file_sig = "none"
    if req_file.is_file():
        req_file_sig = str(req_file.stat().st_mtime_ns)

    marker = f"{handler_path}:{handler_path.stat().st_mtime_ns}:{req_file_sig}:{'|'.join(inline_reqs)}"
    if marker in _REQ_CACHE:
        if deps_dir.is_dir():
            try:
                has_any = next(deps_dir.iterdir(), None) is not None
            except Exception:
                has_any = False
            if has_any:
                return
        _REQ_CACHE.pop(marker, None)

    deps_dir.mkdir(parents=True, exist_ok=True)

    # If target folder is empty/corrupt from a previous run, force a clean install.
    try:
        if next(deps_dir.iterdir(), None) is None:
            pass
    except Exception:
        pass

    cmd = [
        sys.executable,
        "-m",
        "pip",
        "install",
        "--disable-pip-version-check",
        "--no-input",
        "-q",
        "-t",
        str(deps_dir),
    ]
    if req_file.is_file():
        cmd.extend(["-r", str(req_file)])
    if inline_reqs:
        cmd.extend(inline_reqs)

    result = _REAL_SUBPROCESS_RUN(
        cmd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=180,
        text=True,
    )
    if result.returncode != 0:
        _REQ_CACHE.pop(marker, None)
        stderr = (result.stderr or "").strip()
        tail = " | ".join(stderr.splitlines()[-4:]) if stderr else "unknown error"
        raise RuntimeError(f"pip dependencies install failed for {handler_path.parent}: {tail}")

    _REQ_CACHE[marker] = True


def _read_function_config(handler_path: Path) -> Dict[str, Any]:
    cfg_path = handler_path.with_name("fn.config.json")
    if not cfg_path.is_file():
        return {}
    try:
        raw = cfg_path.read_text(encoding="utf-8")
        parsed = json.loads(raw)
    except Exception:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _extract_shared_deps(fn_config: Dict[str, Any]) -> list[str]:
    raw = fn_config.get("shared_deps")
    if not isinstance(raw, list):
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in raw:
        if not isinstance(item, str):
            continue
        name = item.strip()
        if not name or not _NAME_RE.match(name):
            continue
        if name not in seen:
            seen.add(name)
            out.append(name)
    return out


def _resolve_handler_name(fn_config: Dict[str, Any]) -> str:
    invoke = fn_config.get("invoke")
    if not isinstance(invoke, dict):
        return "handler"
    raw = invoke.get("handler")
    if not isinstance(raw, str):
        return "handler"
    name = raw.strip()
    if not name:
        return "handler"
    if not _HANDLER_RE.match(name):
        raise ValueError("invoke.handler must be a valid identifier")
    return name


def _ensure_pack_requirements(pack_dir: Path) -> Path | None:
    req_file = pack_dir / "requirements.txt"
    if not req_file.is_file() or not _auto_requirements_enabled():
        return None

    deps_dir = pack_dir / ".deps"

    marker = f"pack:{pack_dir}:{req_file.stat().st_mtime_ns}"
    if marker in _PACK_REQ_CACHE:
        if deps_dir.is_dir():
            try:
                has_any = next(deps_dir.iterdir(), None) is not None
            except Exception:
                has_any = False
            if has_any:
                return deps_dir
        _PACK_REQ_CACHE.pop(marker, None)

    deps_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        sys.executable,
        "-m",
        "pip",
        "install",
        "--disable-pip-version-check",
        "--no-input",
        "-q",
        "-t",
        str(deps_dir),
        "-r",
        str(req_file),
    ]

    result = _REAL_SUBPROCESS_RUN(
        cmd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=180,
        text=True,
    )
    if result.returncode != 0:
        _PACK_REQ_CACHE.pop(marker, None)
        stderr = (result.stderr or "").strip()
        tail = " | ".join(stderr.splitlines()[-4:]) if stderr else "unknown error"
        raise RuntimeError(f"pip dependencies install failed for pack {pack_dir}: {tail}")

    _PACK_REQ_CACHE[marker] = True
    return deps_dir
def _resolve_candidate_path(target: Any) -> Path | None:
    if isinstance(target, int):
        return None
    if isinstance(target, bytes):
        target = target.decode("utf-8", errors="ignore")
    if isinstance(target, os.PathLike):
        target = os.fspath(target)
    if not isinstance(target, str) or target == "":
        return None
    return Path(target).expanduser().resolve(strict=False)


def _path_allowed(candidate: Path, allowed_roots: list[Path], function_dir: Path) -> tuple[bool, str]:
    if candidate.name in _PROTECTED_FN_FILES:
        if candidate.parent == function_dir:
            return False, "access to protected function config/env file denied"

    for root in allowed_roots:
        if candidate == root or root in candidate.parents:
            return True, ""

    return False, "path outside strict function sandbox"


def _build_allowed_roots(handler_path: Path, extra_roots: list[Path] | None = None) -> tuple[list[Path], Path]:
    function_dir = handler_path.parent.resolve(strict=False)
    roots: list[Path] = [function_dir]

    deps_dir = (function_dir / ".deps").resolve(strict=False)
    roots.append(deps_dir)
    if extra_roots:
        for root in extra_roots:
            try:
                roots.append(root.resolve(strict=False))
            except Exception:
                continue

    for root in _STRICT_SYSTEM_ROOTS:
        roots.append(root.resolve(strict=False))
    for root in _STRICT_EXTRA_ROOTS:
        roots.append(root)

    dedup: list[Path] = []
    seen = set()
    for root in roots:
        s = str(root)
        if s not in seen:
            seen.add(s)
            dedup.append(root)
    return dedup, function_dir


@contextmanager
def _strict_fs_guard(handler_path: Path, extra_roots: list[Path] | None = None):
    if not STRICT_FS:
        yield
        return

    allowed_roots, function_dir = _build_allowed_roots(handler_path, extra_roots=extra_roots)

    def check_target(target: Any) -> None:
        candidate = _resolve_candidate_path(target)
        if candidate is None:
            return
        ok, reason = _path_allowed(candidate, allowed_roots, function_dir)
        if not ok:
            raise PermissionError(reason + ": " + str(candidate))

    orig_open = builtins.open
    orig_io_open = io.open
    orig_os_open = os.open
    orig_listdir = os.listdir
    orig_scandir = os.scandir
    orig_system = os.system
    orig_subprocess_run = subprocess.run
    orig_subprocess_call = subprocess.call
    orig_subprocess_check_call = subprocess.check_call
    orig_subprocess_check_output = subprocess.check_output
    orig_subprocess_popen = subprocess.Popen
    orig_path_open = Path.open

    def guarded_open(file, *args, **kwargs):
        check_target(file)
        return orig_open(file, *args, **kwargs)

    def guarded_io_open(file, *args, **kwargs):
        check_target(file)
        return orig_io_open(file, *args, **kwargs)

    def guarded_os_open(file, *args, **kwargs):
        check_target(file)
        return orig_os_open(file, *args, **kwargs)

    def guarded_listdir(path="."):
        check_target(path)
        return orig_listdir(path)

    def guarded_scandir(path="."):
        check_target(path)
        return orig_scandir(path)

    def guarded_path_open(self, *args, **kwargs):
        check_target(self)
        return orig_path_open(self, *args, **kwargs)

    def blocked_subprocess(*args, **kwargs):
        raise PermissionError("subprocess disabled by strict function sandbox")

    def blocked_system(*args, **kwargs):
        raise PermissionError("os.system disabled by strict function sandbox")

    builtins.open = guarded_open
    io.open = guarded_io_open
    os.open = guarded_os_open
    os.listdir = guarded_listdir
    os.scandir = guarded_scandir
    os.system = blocked_system
    subprocess.run = blocked_subprocess
    subprocess.call = blocked_subprocess
    subprocess.check_call = blocked_subprocess
    subprocess.check_output = blocked_subprocess
    subprocess.Popen = blocked_subprocess
    Path.open = guarded_path_open

    try:
        yield
    finally:
        builtins.open = orig_open
        io.open = orig_io_open
        os.open = orig_os_open
        os.listdir = orig_listdir
        os.scandir = orig_scandir
        os.system = orig_system
        subprocess.run = orig_subprocess_run
        subprocess.call = orig_subprocess_call
        subprocess.check_call = orig_subprocess_check_call
        subprocess.check_output = orig_subprocess_check_output
        subprocess.Popen = orig_subprocess_popen
        Path.open = orig_path_open


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
         # 0. Next.js style: Check for direct file with extension (e.g. functions/hello.py)
         # This allows /fn/hello to resolve to functions/hello.py automatically
         direct_file = FUNCTIONS_DIR / (name + ".py")
         if direct_file.is_file():
             return direct_file

         # 1. From root (e.g. handlers/create.py)
         root_check = FUNCTIONS_DIR / name
         if root_check.is_file():
             return root_check
         
         # 2. From runtime dir (e.g. python/create.py)
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
    
    # 1. Check fn.config.json for explicit entrypoint
    config_path = target_dir / "fn.config.json"
    if config_path.is_file():
        try:
            with open(config_path, "rb") as f:
                config = json.load(f)
            if isinstance(config.get("entrypoint"), str):
                explicit_path = target_dir / config["entrypoint"]
                if explicit_path.is_file():
                    return explicit_path
        except Exception:
            pass

    # Order: app.py -> handler.py -> main.py
    candidates = ["app.py", "handler.py", "main.py"]
    
    for fname in candidates:
        candidate_path = target_dir / fname
        if candidate_path.is_file():
            return candidate_path

    raise FileNotFoundError("unknown function")


def _iter_handler_paths() -> list[Path]:
    out: list[Path] = []
    if not FUNCTIONS_DIR.is_dir():
        return out

    for fn_dir in sorted(FUNCTIONS_DIR.iterdir(), key=lambda p: p.name):
        if not fn_dir.is_dir() or not _NAME_RE.match(fn_dir.name):
            continue

        app_default = fn_dir / "app.py"
        handler_default = fn_dir / "handler.py"
        if app_default.is_file():
            out.append(app_default)
        elif handler_default.is_file():
            out.append(handler_default)

        for ver_dir in sorted(fn_dir.iterdir(), key=lambda p: p.name):
            if not ver_dir.is_dir() or not _VERSION_RE.match(ver_dir.name):
                continue
            app_ver = ver_dir / "app.py"
            handler_ver = ver_dir / "handler.py"
            if app_ver.is_file():
                out.append(app_ver)
            elif handler_ver.is_file():
                out.append(handler_ver)

    return out


def _preinstall_requirements_on_start() -> None:
    if not PREINSTALL_PY_DEPS_ON_START or not _auto_requirements_enabled():
        return
    for handler_path in _iter_handler_paths():
        try:
            _ensure_requirements(handler_path)
        except Exception:
            continue


def _load_handler(path: Path, handler_name: str) -> Callable[[Dict[str, Any]], Dict[str, Any]]:
    cache_key = f"{path}::{handler_name}"
    mtime_ns = path.stat().st_mtime_ns

    cached = _HANDLER_CACHE.get(cache_key)
    if cached is not None:
        if not HOT_RELOAD or cached.get("mtime_ns") == mtime_ns:
            return cached["handler"]

    module_name = f"fn_python_{abs(hash(cache_key))}_{mtime_ns}"
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("failed to load handler spec")

    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[attr-defined]

    handler = getattr(mod, handler_name, None)
    # Backward-compatible fallback for simple examples that export main(req).
    if not callable(handler) and handler_name == "handler":
        handler = getattr(mod, "main", None)
    if not callable(handler):
        raise RuntimeError(f"{handler_name}(event) is required")

    _HANDLER_CACHE[cache_key] = {
        "handler": handler,
        "mtime_ns": mtime_ns,
    }

    return handler


def _normalize_response(resp: Any) -> Dict[str, Any]:
    # Support tuple return: (body, status, headers) or (body, status) or (body,)
    if isinstance(resp, tuple):
        body = resp[0] if len(resp) > 0 else None
        status = resp[1] if len(resp) > 1 else 200
        headers = resp[2] if len(resp) > 2 else {}
        resp = {"body": body, "status": status, "headers": headers}

    if isinstance(resp, dict):
        # Node-like convenience: if it does not look like a response envelope,
        # treat it as JSON body payload with 200.
        is_raw = False
        if "status" in resp or "statusCode" in resp:
            is_raw = True
        elif "headers" in resp:
            is_raw = True
        elif "body" in resp or "body_base64" in resp or "is_base64" in resp or "isBase64Encoded" in resp:
            is_raw = True
        elif "proxy" in resp:
            is_raw = True

        if not is_raw:
            return {
                "status": 200,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps(resp, separators=(",", ":"), ensure_ascii=False),
            }

    if not isinstance(resp, dict):
        raise ValueError("handler response must be an object or tuple")

    proxy = resp.get("proxy")
    if proxy is not None and (not isinstance(proxy, dict)):
        raise ValueError("proxy must be an object when provided")

    status_key = "status"
    if "statusCode" in resp and "status" not in resp:
        status_key = "statusCode"
    headers_key = "headers"
    body_key = "body"
    is_base64_key = "is_base64"
    body_b64_key = "body_base64"
    if "isBase64Encoded" in resp and "is_base64" not in resp:
        is_base64_key = "isBase64Encoded"
        body_b64_key = "body"

    status = resp.get(status_key, 200)
    if not isinstance(status, int) or status < 100 or status > 599:
        raise ValueError("status must be a valid HTTP code")

    headers = resp.get(headers_key, {})
    if not isinstance(headers, dict):
        raise ValueError("headers must be an object")

    # Auto-detect binary body in dict or tuple
    raw_body = resp.get(body_key)
    if isinstance(raw_body, bytes):
        out = {
            "status": status,
            "headers": headers,
            "is_base64": True,
            "body_base64": base64.b64encode(raw_body).decode("utf-8"),
        }
        return out

    is_base64 = bool(resp.get(is_base64_key, False))
    out = {
        "status": status,
        "headers": headers,
    }
    if isinstance(proxy, dict):
        out["proxy"] = proxy

    if is_base64:
        body_base64 = resp.get(body_b64_key)
        if not isinstance(body_base64, str) or body_base64 == "":
            raise ValueError("body_base64 must be a non-empty string when is_base64=true")
        out["is_base64"] = True
        out["body_base64"] = body_base64
        return out

    body = resp.get(body_key, "")
    if body is None:
        body = ""
    if isinstance(body, (dict, list)):
        try:
            body = json.dumps(body, separators=(",", ":"), ensure_ascii=False)
            if "Content-Type" not in headers and "content-type" not in headers:
                headers["Content-Type"] = "application/json"
        except Exception:
            body = str(body)
    if not isinstance(body, str):
        body = str(body)
    out["body"] = body
    return out


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

    threading.Thread(target=_run_reaper, name="fn-py-runtime-pool-reaper", daemon=True).start()


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
            executor = ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix=f"fn-py-{abs(hash(pool_key))}")
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


_WORKER_SCRIPT = str(Path(__file__).with_name("python-function-worker.py"))

# ---------------------------------------------------------------------------
# Persistent worker pool for isolated Python function execution.
#
# Each function with deps gets its own long-lived subprocess that
# communicates via length-prefixed binary framing (4 bytes big-endian
# length + JSON payload) on stdin/stdout pipes — the same protocol
# used by the gateway↔daemon socket.
#
# Pool is keyed by (handler_path, handler_name, frozenset(deps_dirs))
# so each unique function config gets exactly one worker.
# ---------------------------------------------------------------------------

_SUBPROCESS_POOL: Dict[str, "_PersistentWorker"] = {}
_SUBPROCESS_POOL_LOCK = threading.Lock()


class _PersistentWorker:
    """A single persistent child process for one function."""

    __slots__ = ("key", "proc", "lock", "_dead")

    def __init__(self, key: str, handler_path: Path, deps_dirs: list[str]):
        self.key = key
        self.lock = threading.Lock()
        self._dead = False
        env = os.environ.copy()
        env["_FASTFN_WORKER_MODE"] = "persistent"
        # Pass deps dirs to the worker so it sets sys.path once at startup.
        if deps_dirs:
            env["_FASTFN_WORKER_DEPS"] = os.pathsep.join(deps_dirs)
        self.proc = subprocess.Popen(
            [sys.executable, _WORKER_SCRIPT],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=str(handler_path.parent),
            env=env,
        )

    @property
    def alive(self) -> bool:
        return not self._dead and self.proc.poll() is None

    def send_request(self, payload_bytes: bytes, timeout_s: float) -> Dict[str, Any]:
        """Send a frame and wait for the response frame."""
        with self.lock:
            if not self.alive:
                raise RuntimeError("worker process is dead")
            if self.proc.stdin is None or self.proc.stdout is None:
                self._mark_dead()
                raise RuntimeError("worker pipes are unavailable")
            try:
                # Write length-prefixed frame to stdin
                header = struct.pack(">I", len(payload_bytes))
                self.proc.stdin.write(header)
                self.proc.stdin.write(payload_bytes)
                self.proc.stdin.flush()

                # Read response: 4-byte header + payload
                stdout_fd = self.proc.stdout.fileno()
                resp_header = self._read_exact(stdout_fd, 4, timeout_s)
                if resp_header is None:
                    self._mark_dead()
                    raise RuntimeError("worker closed stdout (crashed?)")
                resp_len = struct.unpack(">I", resp_header)[0]
                if resp_len == 0:
                    return {"status": 200, "headers": {}, "body": ""}
                resp_data = self._read_exact(stdout_fd, resp_len, timeout_s)
                if resp_data is None:
                    self._mark_dead()
                    raise RuntimeError("incomplete worker response")
                return json.loads(resp_data)
            except TimeoutError:
                self._mark_dead()
                raise
            except (BrokenPipeError, OSError):
                self._mark_dead()
                raise RuntimeError("worker pipe broken")

    def _read_exact(self, fd: int, n: int, timeout_s: float) -> bytes | None:
        """Read exactly n bytes with a timeout using select+os.read."""
        import select
        buf = bytearray()
        deadline = time.monotonic() + timeout_s
        while len(buf) < n:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self._mark_dead()
                raise TimeoutError("worker read timeout")
            ready, _, _ = select.select([fd], [], [], min(remaining, 1.0))
            if not ready:
                continue
            chunk = os.read(fd, n - len(buf))
            if not chunk:
                return None
            buf.extend(chunk)
        return bytes(buf)

    def _mark_dead(self) -> None:
        self._dead = True
        try:
            self.proc.kill()
        except Exception:
            pass

    def shutdown(self) -> None:
        self._dead = True
        try:
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


def _worker_pool_key(handler_path: Path, handler_name: str, deps_dirs: list[str]) -> str:
    return f"{handler_path}::{handler_name}::{','.join(sorted(deps_dirs))}"


def _get_or_create_worker(
    handler_path: Path, handler_name: str, deps_dirs: list[str]
) -> _PersistentWorker:
    key = _worker_pool_key(handler_path, handler_name, deps_dirs)
    with _SUBPROCESS_POOL_LOCK:
        worker = _SUBPROCESS_POOL.get(key)
        if worker is not None and worker.alive:
            return worker
        # Clean up dead worker
        if worker is not None:
            try:
                worker.shutdown()
            except Exception:
                pass
        worker = _PersistentWorker(key, handler_path, deps_dirs)
        _SUBPROCESS_POOL[key] = worker
        return worker


def _has_function_deps(handler_path: Path) -> bool:
    """Return True if the function has external dependencies (requirements.txt
    or inline #@requirements) that would pollute sys.path."""
    fn_dir = handler_path.parent
    if (fn_dir / "requirements.txt").is_file():
        return True
    if (fn_dir / ".deps").is_dir():
        return True
    if _extract_requirements(handler_path):
        return True
    return False


def _run_in_subprocess(
    handler_path: Path,
    handler_name: str,
    deps_dirs: list[str],
    event: Dict[str, Any],
    timeout_s: float,
) -> Dict[str, Any]:
    """Execute a handler in a persistent isolated worker subprocess."""
    fn_env = _read_function_env(handler_path)
    event_with_env = dict(event)
    incoming_env = event_with_env.get("env")
    merged_env = dict(incoming_env) if isinstance(incoming_env, dict) else {}
    for k, v in fn_env.items():
        merged_env[k] = v
    if merged_env:
        event_with_env["env"] = merged_env

    payload = json.dumps({
        "handler_path": str(handler_path),
        "handler_name": handler_name,
        "deps_dirs": deps_dirs,
        "event": event_with_env,
    }, separators=(",", ":"), ensure_ascii=False).encode("utf-8")

    # Try the persistent worker first; fall back to one-shot if it dies.
    for attempt in range(2):
        try:
            worker = _get_or_create_worker(handler_path, handler_name, deps_dirs)
            return worker.send_request(payload, timeout_s)
        except TimeoutError:
            return _error_response("python handler timeout", status=504)
        except Exception:
            # Worker died — evict and retry once with a fresh worker.
            key = _worker_pool_key(handler_path, handler_name, deps_dirs)
            with _SUBPROCESS_POOL_LOCK:
                dead = _SUBPROCESS_POOL.pop(key, None)
                if dead is not None:
                    try:
                        dead.shutdown()
                    except Exception:
                        pass
            if attempt == 1:
                # Second attempt also failed — fall back to one-shot.
                return _run_in_subprocess_oneshot(
                    handler_path, handler_name, deps_dirs, event_with_env, timeout_s
                )

    return _error_response("worker pool exhausted", status=500)


def _run_in_subprocess_oneshot(
    handler_path: Path,
    handler_name: str,
    deps_dirs: list[str],
    event: Dict[str, Any],
    timeout_s: float,
) -> Dict[str, Any]:
    """Fallback: one-shot subprocess execution (original model)."""
    payload = json.dumps({
        "handler_path": str(handler_path),
        "handler_name": handler_name,
        "deps_dirs": deps_dirs,
        "event": event,
    }, separators=(",", ":"), ensure_ascii=False)

    try:
        proc = _REAL_SUBPROCESS_RUN(
            [sys.executable, _WORKER_SCRIPT],
            input=payload,
            text=True,
            capture_output=True,
            timeout=max(1.0, timeout_s),
            cwd=str(handler_path.parent),
            check=False,
        )
    except subprocess.TimeoutExpired:
        return _error_response("python handler timeout", status=504)

    raw = (proc.stdout or "").strip()
    if not raw:
        stderr = (proc.stderr or "").strip()
        msg = stderr.splitlines()[-1] if stderr else "handler produced empty response"
        return _error_response(msg, status=500)

    try:
        return json.loads(raw)
    except Exception:
        return _error_response("invalid handler response JSON", status=500)


def _handle_request_direct(req: Dict[str, Any]) -> Dict[str, Any]:
    fn_name = req.get("fn")
    version = req.get("version")
    event = req.get("event", {})

    if not isinstance(fn_name, str) or not fn_name:
        raise ValueError("fn is required")
    if not isinstance(event, dict):
        raise ValueError("event must be an object")

    path = _resolve_handler_path(fn_name, version)
    fn_config = _read_function_config(path)
    handler_name = _resolve_handler_name(fn_config)
    shared_deps = _extract_shared_deps(fn_config)

    # Install deps (idempotent, cached by mtime signature).
    shared_roots: list[Path] = []
    for pack in shared_deps:
        pack_dir = (PACKS_DIR / pack).resolve(strict=False)
        if not pack_dir.is_dir():
            raise RuntimeError(f"shared pack not found: {pack}")
        deps_root = _ensure_pack_requirements(pack_dir)
        if deps_root is not None:
            shared_roots.append(deps_root)
    _ensure_requirements(path)

    # Determine timeout from request context.
    timeout_ms = int(req.get("timeout_ms") or 0)
    timeout_s = max(5.0, timeout_ms / 1000.0) if timeout_ms > 0 else 30.0

    # Always use subprocess isolation for robust stability.
    # This ensures a CPU-heavy or crashing function does not kill the main daemon.
    # It also bypasses the GIL, allowing true parallelism across functions.
    deps_dirs: list[str] = []
    fn_deps = path.parent / ".deps"
    if fn_deps.is_dir():
        deps_dirs.append(str(fn_deps.resolve(strict=False)))
    for root in shared_roots:
        deps_dirs.append(str(root))
    resp = _run_in_subprocess(path, handler_name, deps_dirs, event, timeout_s)
    return _normalize_response(resp)


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
    _preinstall_requirements_on_start()

    if os.path.exists(SOCKET_PATH):
        os.remove(SOCKET_PATH)

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o666)
        server.listen(128)

        while True:
            conn, _ = server.accept()
            threading.Thread(target=_serve_conn, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
