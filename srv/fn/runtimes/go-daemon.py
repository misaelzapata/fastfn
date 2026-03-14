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
import fcntl
import hashlib
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

SOCKET_PATH = os.environ.get("FN_GO_SOCKET", "/tmp/fastfn/fn-go.sock")
MAX_FRAME_BYTES = int(os.environ.get("FN_MAX_FRAME_BYTES", str(2 * 1024 * 1024)))
HOT_RELOAD = os.environ.get("FN_HOT_RELOAD", "1").lower() not in {"0", "false", "off", "no"}
GO_BUILD_TIMEOUT_S = float(os.environ.get("FN_GO_BUILD_TIMEOUT_S", "180"))
ENABLE_RUNTIME_WORKER_POOL = os.environ.get("FN_GO_RUNTIME_WORKER_POOL", "1").lower() not in {"0", "false", "off", "no"}
RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = int(os.environ.get("FN_GO_POOL_ACQUIRE_TIMEOUT_MS", "5000"))
RUNTIME_POOL_IDLE_TTL_MS = int(os.environ.get("FN_GO_POOL_IDLE_TTL_MS", "300000"))
RUNTIME_POOL_REAPER_INTERVAL_MS = int(os.environ.get("FN_GO_POOL_REAPER_INTERVAL_MS", "2000"))

BASE_DIR = Path(__file__).resolve().parents[1]
FUNCTIONS_DIR = Path(os.environ.get("FN_FUNCTIONS_ROOT", str(BASE_DIR / "functions")))
RUNTIME_FUNCTIONS_DIR = FUNCTIONS_DIR / "go"

_VERSION_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_FILE_TOKEN_RE = re.compile(r"^[A-Za-z0-9._/\-\[\]]+$")

_BINARY_CACHE: Dict[str, Dict[str, Any]] = {}
_BINARY_CACHE_LOCK = threading.Lock()
_PERSISTENT_RUNTIME_POOLS: Dict[str, Dict[str, Any]] = {}
_PERSISTENT_RUNTIME_POOLS_LOCK = threading.Lock()
_PERSISTENT_RUNTIME_POOL_REAPER_STARTED = False

_WRAPPER_TEMPLATE = """package main

import (
  "bufio"
  "encoding/binary"
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
  reader := bufio.NewReader(os.Stdin)
  writer := bufio.NewWriter(os.Stdout)
  for {
    payload, ok, err := _fastfnReadFrame(reader)
    if err != nil {
      _fastfnWriteFrame(writer, map[string]interface{}{
        "status": 500,
        "headers": map[string]interface{}{"Content-Type": "application/json"},
        "body": fmt.Sprintf("{\"error\":%q}", "failed to read stdin"),
      })
      return
    }
    if !ok {
      return
    }
    req := map[string]interface{}{}
    if len(payload) > 0 {
      _ = json.Unmarshal(payload, &req)
    }
    event := map[string]interface{}{}
    if req != nil {
      if ev, ok := req["event"].(map[string]interface{}); ok && ev != nil {
        event = ev
      }
    }
    restore := _fastfnApplyEnv(event["env"])
    if params, ok := event["params"].(map[string]interface{}); ok {
      for k, v := range params {
        if _, exists := event[k]; !exists {
          event[k] = v
        }
      }
    }
    out := func() (result interface{}) {
      defer func() {
        if recover() != nil {
          result = map[string]interface{}{
            "status": 500,
            "headers": map[string]interface{}{"Content-Type": "application/json"},
            "body": fmt.Sprintf("{\"error\":%q}", "go handler panicked"),
          }
        }
      }()
      result = __FASTFN_HANDLER__(event)
      return result
    }()
    restore()
    if err := _fastfnWriteFrame(writer, out); err != nil {
      return
    }
  }
}

func _fastfnReadFrame(reader *bufio.Reader) ([]byte, bool, error) {
  header := make([]byte, 4)
  if _, err := io.ReadFull(reader, header); err != nil {
    if err == io.EOF {
      return nil, false, nil
    }
    return nil, false, err
  }
  length := binary.BigEndian.Uint32(header)
  if length == 0 {
    return nil, false, nil
  }
  payload := make([]byte, int(length))
  if _, err := io.ReadFull(reader, payload); err != nil {
    return nil, false, err
  }
  return payload, true, nil
}

func _fastfnWriteFrame(writer *bufio.Writer, payload interface{}) error {
  enc, err := json.Marshal(payload)
  if err != nil {
    enc = []byte("{\"status\":500,\"headers\":{\"Content-Type\":\"application/json\"},\"body\":\"{\\\"error\\\":\\\"failed to marshal handler output\\\"}\"}")
  }
  header := make([]byte, 4)
  binary.BigEndian.PutUint32(header, uint32(len(enc)))
  if _, err := writer.Write(header); err != nil {
    return err
  }
  if _, err := writer.Write(enc); err != nil {
    return err
  }
  return writer.Flush()
}

func _fastfnApplyEnv(raw interface{}) func() {
  envMap, ok := raw.(map[string]interface{})
  if !ok || envMap == nil {
    return func() {}
  }

  previous := map[string]*string{}
  for key, value := range envMap {
    if current, exists := os.LookupEnv(key); exists {
      copied := current
      previous[key] = &copied
    } else {
      previous[key] = nil
    }
    if value == nil {
      _ = os.Unsetenv(key)
      continue
    }
    _ = os.Setenv(key, fmt.Sprint(value))
  }

  return func() {
    for key, value := range previous {
      if value == nil {
        _ = os.Unsetenv(key)
      } else {
        _ = os.Setenv(key, *value)
      }
    }
  }
}
"""
_WRAPPER_TEMPLATE_DIGEST = hashlib.sha256(_WRAPPER_TEMPLATE.encode("utf-8")).hexdigest()


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


def _build_process_env(env: Any) -> Dict[str, str]:
    merged = dict(os.environ)
    if not isinstance(env, dict):
        return merged

    for raw_key, raw_value in env.items():
        if not isinstance(raw_key, str) or not raw_key:
            continue
        if raw_value is None:
            merged.pop(raw_key, None)
            continue
        merged[raw_key] = str(raw_value)
    return merged


def _resolve_go_command() -> str:
    configured = str(os.environ.get("FN_GO_BIN", "")).strip()
    if configured:
        if "/" in configured or "\\" in configured:
            candidate = Path(configured)
            if candidate.is_file() and os.access(str(candidate), os.X_OK):
                return str(candidate)
            raise RuntimeError(f"FN_GO_BIN is not executable: {configured}")
        resolved = shutil.which(configured)
        if resolved:
            return resolved
        raise RuntimeError(f"FN_GO_BIN not found in PATH: {configured}")

    go_cmd = shutil.which("go")
    if go_cmd is None:
        raise RuntimeError("go not found in PATH")
    return go_cmd


def _file_signature(path: Path) -> Optional[Tuple[int, int]]:
    try:
        st = path.stat()
    except FileNotFoundError:
        return None
    return (st.st_mtime_ns, st.st_size)


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
        handler_path.parent / "go.mod",
        handler_path.parent / "go.sum",
    ]
    parts = [str(_file_signature(path) or "missing") for path in files]
    parts.append(str(hash(_WRAPPER_TEMPLATE)))
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
    go_cmd = _resolve_go_command()

    source = handler_path.read_text(encoding="utf-8")
    symbol = _detect_handler_symbol(source)
    if not symbol:
        raise RuntimeError("go handler symbol not found (expected func handler(event map[string]interface{}) ...)")

    fn_dir = handler_path.parent
    go_mod_src = fn_dir / "go.mod"
    go_sum_src = fn_dir / "go.sum"
    deps_signature = {
        "go_mod": _file_signature(go_mod_src),
        "go_sum": _file_signature(go_sum_src),
    }
    signature = {
        "source_mtime_ns": handler_path.stat().st_mtime_ns,
        "symbol": symbol,
        "deps_signature": deps_signature,
        "wrapper_hash": _WRAPPER_TEMPLATE_DIGEST,
    }
    cache_key = str(handler_path)
    with _BINARY_CACHE_LOCK:
        cached = _BINARY_CACHE.get(cache_key)

    build_dir = fn_dir / ".go-build"
    build_dir.mkdir(parents=True, exist_ok=True)

    user_go = build_dir / "user_handler.go"
    wrapper_go = build_dir / "fastfn_entry.go"
    binary = build_dir / "fn_handler"
    meta_path = build_dir / ".fastfn-build-meta.json"
    lock_path = build_dir / ".fastfn-build.lock"

    if cached:
        cached_binary = Path(str(cached.get("binary", "")))
        if cached_binary.is_file() and cached.get("signature") == signature:
            return cached_binary

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
            if isinstance(metadata, dict) and metadata.get("signature") == signature and binary.is_file():
                with _BINARY_CACHE_LOCK:
                    _BINARY_CACHE[cache_key] = {
                        "signature": signature,
                        "binary": str(binary),
                    }
                return binary

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
            _write_metadata()
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)

    with _BINARY_CACHE_LOCK:
        _BINARY_CACHE[cache_key] = {
            "signature": signature,
            "binary": str(binary),
        }
    return binary


def _run_go_handler(
    binary: Path,
    event: Dict[str, Any],
    timeout_ms: int,
    process_env: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
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
            env=process_env,
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


class _PersistentGoWorker:
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
                raise TimeoutError("go worker read timeout")
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


def _shutdown_persistent_runtime_pool(pool: Dict[str, Any]) -> None:
    workers = pool.get("workers")
    if not isinstance(workers, list):
        return
    for entry in list(workers):
        worker = entry.get("worker") if isinstance(entry, dict) else None
        if isinstance(worker, _PersistentGoWorker):
            worker.shutdown()


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

    threading.Thread(target=_run_reaper, name="fn-go-persistent-pool-reaper", daemon=True).start()


def _create_persistent_runtime_worker(pool: Dict[str, Any]) -> Dict[str, Any]:
    worker = _PersistentGoWorker(pool["binary"])
    return {"worker": worker, "busy": False, "last_used": time.monotonic()}


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
    stale_workers: list[_PersistentGoWorker] = []
    with cond:
        workers = pool.get("workers")
        if not isinstance(workers, list):
            raise RuntimeError("invalid persistent runtime pool workers")
        while True:
            alive_workers: list[Dict[str, Any]] = []
            for entry in workers:
                worker = entry.get("worker") if isinstance(entry, dict) else None
                if isinstance(worker, _PersistentGoWorker) and worker.alive:
                    alive_workers.append(entry)
                elif isinstance(worker, _PersistentGoWorker):
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
    stale: Optional[_PersistentGoWorker] = None
    with cond:
        workers = pool.get("workers")
        if not isinstance(workers, list):
            return
        if entry in workers:
            worker = entry.get("worker")
            if discard or not isinstance(worker, _PersistentGoWorker) or not worker.alive:
                workers.remove(entry)
                if isinstance(worker, _PersistentGoWorker):
                    stale = worker
            else:
                entry["busy"] = False
                entry["last_used"] = time.monotonic()
            pool["last_used"] = time.monotonic()
            cond.notify()
    if stale is not None:
        stale.shutdown()


def _prepare_request(req: Dict[str, Any]) -> tuple[Path, Path, Dict[str, Any], int]:
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
    return handler_path, binary, event_with_env, timeout_ms


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
        if not isinstance(worker, _PersistentGoWorker):
            raise RuntimeError("invalid persistent worker")
        return _normalize_response(worker.send_request(event, timeout_ms))
    except TimeoutError:
        if entry is not None:
            _release_persistent_runtime_worker(pool, entry, discard=True)
            entry = None
        return {
            "status": 504,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "go handler timeout"}, separators=(",", ":")),
        }
    except Exception as exc:
        if entry is not None:
            _release_persistent_runtime_worker(pool, entry, discard=True)
            entry = None
        return {
            "status": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": str(exc)}, separators=(",", ":")),
        }
    finally:
        if entry is not None:
            _release_persistent_runtime_worker(pool, entry)
        with _PERSISTENT_RUNTIME_POOLS_LOCK:
            current = _PERSISTENT_RUNTIME_POOLS.get(pool_key)
            if current is pool:
                current["pending"] = max(0, int(current.get("pending") or 0) - 1)
                current["last_used"] = time.monotonic()


def _handle_request(req: Dict[str, Any]) -> Dict[str, Any]:
    handler_path, binary, event_with_env, timeout_ms = _prepare_request(req)
    settings = _normalize_worker_pool_settings(req)
    if not ENABLE_RUNTIME_WORKER_POOL or not settings["enabled"] or settings["max_workers"] <= 0:
        settings = {
            "max_workers": 1,
            "min_warm": 0,
            "idle_ttl_ms": RUNTIME_POOL_IDLE_TTL_MS,
            "acquire_timeout_ms": max(timeout_ms + 250, RUNTIME_POOL_ACQUIRE_TIMEOUT_MS, 100),
        }
    pool_key = _persistent_runtime_pool_key(req.get("fn"), req.get("version"), handler_path)
    return _run_prepared_request_persistent(pool_key, handler_path, binary, event_with_env, timeout_ms, settings)


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
