#!/usr/bin/env python3
import json
import os
import re
import shutil
import socket
import struct
import subprocess
from pathlib import Path
from typing import Any, Dict

SOCKET_PATH = os.environ.get("FN_PHP_SOCKET", "/tmp/fastfn/fn-php.sock")
MAX_FRAME_BYTES = int(os.environ.get("FN_MAX_FRAME_BYTES", str(2 * 1024 * 1024)))
STRICT_FS = os.environ.get("FN_STRICT_FS", "1").lower() not in {"0", "false", "off", "no"}
STRICT_FS_EXTRA_ALLOW = os.environ.get("FN_STRICT_FS_ALLOW", "")
AUTO_COMPOSER_DEPS = os.environ.get("FN_AUTO_PHP_DEPS", "1").lower() not in {"0", "false", "off", "no"}

BASE_DIR = Path(__file__).resolve().parents[1]
FUNCTIONS_DIR = BASE_DIR / "functions" / "php"
WORKER_FILE = Path(__file__).resolve().with_name("php_worker.php")

_NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
_VERSION_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_COMPOSER_CACHE: Dict[str, str] = {}


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


def _ensure_composer_deps(handler_path: Path) -> None:
    if not AUTO_COMPOSER_DEPS:
        return

    fn_dir = handler_path.parent
    composer_json = fn_dir / "composer.json"
    if not composer_json.is_file():
        return

    composer = shutil.which("composer")
    if not composer:
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
    if not isinstance(name, str) or not _NAME_RE.match(name):
        raise ValueError("invalid function name")

    base = FUNCTIONS_DIR / name

    if version is None or version == "":
        app_path = base / "app.php"
        handler_path = base / "handler.php"
        path = app_path if app_path.is_file() else handler_path
    else:
        if not isinstance(version, str) or not _VERSION_RE.match(version):
            raise ValueError("invalid function version")
        app_path = base / version / "app.php"
        handler_path = base / version / "handler.php"
        path = app_path if app_path.is_file() else handler_path

    if not path.is_file():
        raise FileNotFoundError("unknown function")

    return path


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
    cmd = ["php", "-d", "display_errors=0", "-d", "log_errors=0"]
    if STRICT_FS:
        cmd.extend(["-d", f"open_basedir={_strict_open_basedir(handler_path.parent)}"])
    cmd.extend([str(WORKER_FILE), str(handler_path)])

    env = os.environ.copy()
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

    return _normalize_response(parsed)


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

    return _run_php_handler(path, event_with_env, timeout_ms)


def _ensure_socket_dir(path: str) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)


def main() -> None:
    _ensure_socket_dir(SOCKET_PATH)

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
    if not WORKER_FILE.is_file():
        raise SystemExit("missing php_worker.php")
    main()
