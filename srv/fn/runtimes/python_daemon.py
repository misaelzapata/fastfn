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
from pathlib import Path
from contextlib import contextmanager
from typing import Any, Callable, Dict

SOCKET_PATH = os.environ.get("FN_PY_SOCKET", "/tmp/fastfn/fn-python.sock")
MAX_FRAME_BYTES = int(os.environ.get("FN_MAX_FRAME_BYTES", str(2 * 1024 * 1024)))
HOT_RELOAD = os.environ.get("FN_HOT_RELOAD", "1").lower() not in {"0", "false", "off", "no"}
STRICT_FS = os.environ.get("FN_STRICT_FS", "1").lower() not in {"0", "false", "off", "no"}
STRICT_FS_EXTRA_ALLOW = os.environ.get("FN_STRICT_FS_ALLOW", "")
PREINSTALL_PY_DEPS_ON_START = os.environ.get("FN_PREINSTALL_PY_DEPS_ON_START", "0").lower() not in {"0", "false", "off", "no"}

BASE_DIR = Path(__file__).resolve().parents[1]
FUNCTIONS_DIR = BASE_DIR / "functions" / "python"
PACKS_DIR = BASE_DIR / "functions" / ".fastfn" / "packs" / "python"

_NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
_VERSION_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_HANDLER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

_HANDLER_CACHE: Dict[str, Dict[str, Any]] = {}
_REQ_CACHE: Dict[str, bool] = {}
_PACK_REQ_CACHE: Dict[str, bool] = {}
_PROTECTED_FN_FILES = {"fn.config.json", "fn.env.json"}


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
                if str(deps_dir) not in sys.path:
                    sys.path.insert(0, str(deps_dir))
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

    result = subprocess.run(
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

    if str(deps_dir) not in sys.path:
        sys.path.insert(0, str(deps_dir))
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
                if str(deps_dir) not in sys.path:
                    sys.path.insert(0, str(deps_dir))
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

    result = subprocess.run(
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

    if str(deps_dir) not in sys.path:
        sys.path.insert(0, str(deps_dir))
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
    if not isinstance(name, str) or not _NAME_RE.match(name):
        raise ValueError("invalid function name")

    base = FUNCTIONS_DIR / name

    if version is None or version == "":
        app_path = base / "app.py"
        handler_path = base / "handler.py"
        path = app_path if app_path.is_file() else handler_path
    else:
        if not isinstance(version, str) or not _VERSION_RE.match(version):
            raise ValueError("invalid function version")
        app_path = base / version / "app.py"
        handler_path = base / version / "handler.py"
        path = app_path if app_path.is_file() else handler_path

    if not path.is_file():
        raise FileNotFoundError("unknown function")

    return path


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


def _handle_request(req: Dict[str, Any]) -> Dict[str, Any]:
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
    shared_roots: list[Path] = []
    for pack in shared_deps:
        pack_dir = (PACKS_DIR / pack).resolve(strict=False)
        if not pack_dir.is_dir():
            raise RuntimeError(f"shared pack not found: {pack}")
        deps_root = _ensure_pack_requirements(pack_dir)
        if deps_root is not None:
            shared_roots.append(deps_root)
    _ensure_requirements(path)
    handler = _load_handler(path, handler_name)
    fn_env = _read_function_env(path)
    event_with_env = dict(event)
    incoming_env = event_with_env.get("env")
    merged_env = dict(incoming_env) if isinstance(incoming_env, dict) else {}
    for k, v in fn_env.items():
        merged_env[k] = v
    if merged_env:
        event_with_env["env"] = merged_env
    with _strict_fs_guard(path, extra_roots=shared_roots):
        resp = handler(event_with_env)
    return _normalize_response(resp)


def _ensure_socket_dir(path: str) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)


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
            with conn:
                try:
                    req = _read_frame(conn)
                    resp = _handle_request(req)
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


if __name__ == "__main__":
    main()
