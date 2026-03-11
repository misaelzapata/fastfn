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
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Optional

SOCKET_PATH = os.environ.get("FN_GO_SOCKET", "/tmp/fastfn/fn-go.sock")
MAX_FRAME_BYTES = int(os.environ.get("FN_MAX_FRAME_BYTES", str(2 * 1024 * 1024)))
HOT_RELOAD = os.environ.get("FN_HOT_RELOAD", "1").lower() not in {"0", "false", "off", "no"}
GO_BUILD_TIMEOUT_S = float(os.environ.get("FN_GO_BUILD_TIMEOUT_S", "180"))

BASE_DIR = Path(__file__).resolve().parents[1]
FUNCTIONS_DIR = Path(os.environ.get("FN_FUNCTIONS_ROOT", str(BASE_DIR / "functions")))
RUNTIME_FUNCTIONS_DIR = FUNCTIONS_DIR / "go"

_VERSION_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_FILE_TOKEN_RE = re.compile(r"^[A-Za-z0-9._/\-\[\]]+$")

_BINARY_CACHE: Dict[str, Dict[str, Any]] = {}
_BINARY_CACHE_LOCK = threading.Lock()

_WRAPPER_TEMPLATE = """package main

import (
  "encoding/json"
  "fmt"
  "io"
  "os"
)

func _fastfnError(msg string) {
  payload := map[string]interface{}{
    "status": 500,
    "headers": map[string]interface{}{"Content-Type": "application/json"},
    "body": fmt.Sprintf("{\\"error\\":%q}", msg),
  }
  enc, err := json.Marshal(payload)
  if err != nil {
    fmt.Print("{\\"status\\":500,\\"headers\\":{\\"Content-Type\\":\\"application/json\\"},\\"body\\":\\"{\\\\\\"error\\\\\\":\\\\\\"go runtime fatal error\\\\\\"}\\"}")
    return
  }
  fmt.Print(string(enc))
}

func main() {
  raw, err := io.ReadAll(os.Stdin)
  if err != nil {
    _fastfnError("failed to read stdin")
    return
  }

  req := map[string]interface{}{}
  if len(raw) > 0 {
    _ = json.Unmarshal(raw, &req)
  }

  event := map[string]interface{}{}
  if req != nil {
    if ev, ok := req["event"].(map[string]interface{}); ok && ev != nil {
      event = ev
    }
  }

  if params, ok := event["params"].(map[string]interface{}); ok {
    for k, v := range params {
      if _, exists := event[k]; !exists {
        event[k] = v
      }
    }
  }
  out := __FASTFN_HANDLER__(event)
  enc, err := json.Marshal(out)
  if err != nil {
    _fastfnError("failed to marshal handler output")
    return
  }
  fmt.Print(string(enc))
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
            if scalar is not None:
                out[key] = str(scalar)
            continue
        if value is not None:
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
    try:
        decoded = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"invalid utf-8 payload: {exc}") from exc
    try:
        req = json.loads(decoded)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid json payload: {exc.msg}") from exc
    if not isinstance(req, dict):
        raise ValueError("request must be an object")
    return req


def _write_frame(conn: socket.socket, obj: Dict[str, Any]) -> None:
    try:
        payload = json.dumps(obj, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    except Exception as exc:
        fallback = {
            "status": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": f"go runtime encode failure: {exc}"}, separators=(",", ":"), ensure_ascii=True),
        }
        payload = json.dumps(fallback, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    if len(payload) > MAX_FRAME_BYTES:
        fallback = {
            "status": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {"error": f"go runtime response too large: {len(payload)} bytes (max {MAX_FRAME_BYTES})"},
                separators=(",", ":"),
                ensure_ascii=True,
            ),
        }
        payload = json.dumps(fallback, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    conn.sendall(struct.pack("!I", len(payload)) + payload)


def _normalize_name(name: str) -> str:
    return name.replace("\\", "/")


def _resolve_handler_path(name: str, version: Any) -> Path:
    if not isinstance(name, str) or not name.strip():
        raise ValueError("invalid function name")
    normalized_name = _normalize_name(name)
    if not _FILE_TOKEN_RE.match(normalized_name):
        raise ValueError("invalid function name")
    if (
        normalized_name.startswith("/")
        or normalized_name == ".."
        or normalized_name.startswith("../")
        or normalized_name.endswith("/..")
        or "/../" in normalized_name
    ):
        raise ValueError("invalid function name")

    # direct-file mode (functions root / runtime dir)
    if not version:
        root_check = FUNCTIONS_DIR / normalized_name
        if root_check.is_file() and root_check.suffix == ".go":
            return root_check
        runtime_check = RUNTIME_FUNCTIONS_DIR / normalized_name
        if runtime_check.is_file() and runtime_check.suffix == ".go":
            return runtime_check

    base = FUNCTIONS_DIR / normalized_name
    if not base.exists():
        runtime_base = RUNTIME_FUNCTIONS_DIR / normalized_name
        if runtime_base.exists():
            base = runtime_base

    target_dir = base
    if version is not None and version != "":
        if not isinstance(version, str) or not _VERSION_RE.match(version):
            raise ValueError("invalid function version")
        target_dir = base / version

    for candidate in ("app.go", "handler.go", "main.go"):
        path = target_dir / candidate
        if path.is_file():
            return path

    raise FileNotFoundError("unknown function")


def _detect_handler_symbol(source: str) -> Optional[str]:
    # Keep runtime contract simple and explicit.
    for symbol in ("handler", "Handler"):
        if re.search(r"\bfunc\s+" + re.escape(symbol) + r"\s*\(", source):
            return symbol
    return None


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

    out: Dict[str, Any] = {
        "status": status,
        "headers": headers,
        "body": body,
    }
    if isinstance(resp.get("proxy"), dict):
        out["proxy"] = resp.get("proxy")
    return out


def _ensure_go_binary(handler_path: Path) -> Path:
    go_cmd = shutil.which("go")
    if go_cmd is None:
        raise RuntimeError("go not found in PATH")

    source = handler_path.read_text(encoding="utf-8")
    symbol = _detect_handler_symbol(source)
    if not symbol:
        raise RuntimeError("go handler symbol not found (expected func handler(event map[string]interface{}) ...)")

    cache_key = str(handler_path)
    source_mtime = handler_path.stat().st_mtime_ns
    with _BINARY_CACHE_LOCK:
        cached = _BINARY_CACHE.get(cache_key)
    if cached and cached.get("mtime_ns") == source_mtime and cached.get("symbol") == symbol:
        binary = Path(str(cached.get("binary", "")))
        if binary.is_file() and (not HOT_RELOAD or HOT_RELOAD):
            return binary

    fn_dir = handler_path.parent
    build_dir = fn_dir / ".go-build"
    build_dir.mkdir(parents=True, exist_ok=True)

    user_go = build_dir / "user_handler.go"
    wrapper_go = build_dir / "fastfn_entry.go"
    binary = build_dir / "fn_handler"

    user_go.write_text(source, encoding="utf-8")
    wrapper_go.write_text(_WRAPPER_TEMPLATE.replace("__FASTFN_HANDLER__", symbol), encoding="utf-8")

    # Optional module/dependency support for per-function dependencies.
    go_mod_src = fn_dir / "go.mod"
    go_sum_src = fn_dir / "go.sum"
    go_mod_dst = build_dir / "go.mod"
    go_sum_dst = build_dir / "go.sum"
    if go_mod_src.is_file():
        go_mod_dst.write_text(go_mod_src.read_text(encoding="utf-8"), encoding="utf-8")
    elif go_mod_dst.exists():
        go_mod_dst.unlink()
    if go_sum_src.is_file():
        go_sum_dst.write_text(go_sum_src.read_text(encoding="utf-8"), encoding="utf-8")
    elif go_sum_dst.exists():
        go_sum_dst.unlink()

    cmd = [go_cmd, "build", "-o", str(binary), str(wrapper_go), str(user_go)]
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(build_dir),
            capture_output=True,
            text=True,
            timeout=max(1.0, GO_BUILD_TIMEOUT_S),
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"go build timeout after {max(1.0, GO_BUILD_TIMEOUT_S):.1f}s: {exc}") from exc

    if proc.returncode != 0:
        detail = (proc.stderr or "").strip() or (proc.stdout or "").strip() or "unknown go build error"
        raise RuntimeError(f"go build failed: {detail}")
    if not binary.is_file():
        raise RuntimeError("go build did not produce binary")

    with _BINARY_CACHE_LOCK:
        _BINARY_CACHE[cache_key] = {
            "mtime_ns": source_mtime,
            "binary": str(binary),
            "symbol": symbol,
        }
    return binary


def _run_go_handler(binary: Path, event: Dict[str, Any], timeout_ms: int) -> Dict[str, Any]:
    payload = {"event": event}
    timeout_s = max(0.05, float(timeout_ms) / 1000.0)
    try:
        proc = subprocess.run(
            [str(binary)],
            input=json.dumps(payload, separators=(",", ":")),
            capture_output=True,
            text=True,
            timeout=timeout_s,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        return {
            "status": 504,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": f"go handler timeout: {exc}"}, separators=(",", ":")),
        }

    raw = (proc.stdout or "").strip()
    if proc.returncode != 0:
        msg = (proc.stderr or raw or f"go handler exited with code {proc.returncode}").strip()
        return {
            "status": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": msg}, separators=(",", ":")),
        }
    if raw == "":
        return {
            "status": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "go handler produced empty response"}, separators=(",", ":")),
        }
    try:
        parsed = json.loads(raw)
    except Exception:
        return {
            "status": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "invalid go handler response", "raw": raw[:400]}, separators=(",", ":")),
        }
    try:
        result = _normalize_response(parsed)
    except Exception as exc:
        return {
            "status": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": str(exc)}, separators=(",", ":")),
        }
    stderr_str = (proc.stderr or "").strip()
    if stderr_str:
        result["stderr"] = stderr_str
    return result


def _handle_request(req: Dict[str, Any]) -> Dict[str, Any]:
    fn_name = req.get("fn")
    version = req.get("version")
    event = req.get("event", {})
    if not isinstance(event, dict):
        raise ValueError("event must be an object")

    handler_path = _resolve_handler_path(fn_name, version)

    event_with_env = dict(event)
    incoming_env = event_with_env.get("env")
    merged_env = {}
    if isinstance(incoming_env, dict):
        for k, v in incoming_env.items():
            if isinstance(k, str):
                merged_env[k] = str(v)
    merged_env.update(_read_function_env(handler_path))
    event_with_env["env"] = merged_env

    timeout_ms = 2500
    context = event_with_env.get("context")
    if isinstance(context, dict):
        try:
            timeout_ms = int(context.get("timeout_ms") or timeout_ms)
        except Exception:
            timeout_ms = 2500
    timeout_ms = max(50, timeout_ms)

    binary = _ensure_go_binary(handler_path)
    with _patched_process_env(event_with_env.get("env", {})):
        return _run_go_handler(binary, event_with_env, timeout_ms)


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
            resp = _handle_request(req)
        except FileNotFoundError:
            resp = {"status": 404, "headers": {"Content-Type": "application/json"}, "body": json.dumps({"error": "unknown function"})}
        except ValueError as exc:
            resp = {"status": 400, "headers": {"Content-Type": "application/json"}, "body": json.dumps({"error": str(exc)})}
        except RuntimeError as exc:
            resp = {"status": 500, "headers": {"Content-Type": "application/json"}, "body": json.dumps({"error": str(exc)})}
        except Exception as exc:
            resp = {"status": 500, "headers": {"Content-Type": "application/json"}, "body": json.dumps({"error": f"go runtime failure: {exc}"})}
        try:
            _write_frame(conn, resp)
        except OSError:
            # Client disconnected before response write.
            pass


def main() -> None:
    _ensure_socket_dir(SOCKET_PATH)
    _prepare_socket_path(SOCKET_PATH)

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o666)
        server.listen(256)
        while True:
            conn, _ = server.accept()
            t = threading.Thread(target=_serve_conn, args=(conn,), daemon=True)
            t.start()


if __name__ == "__main__":
    main()
