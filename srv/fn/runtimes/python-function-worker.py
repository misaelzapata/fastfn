#!/usr/bin/env python3
"""Isolated worker for Python function invocations.

Supports two modes controlled by env var _FASTFN_WORKER_MODE:

  "persistent" (default when launched by pool):
    Loop receiving length-prefixed JSON frames on stdin:
      4 bytes big-endian length + JSON payload
    Responds with the same framing on stdout.
    Stays alive across requests.

  "oneshot" (fallback):
    Read a single JSON blob from stdin, write response JSON to stdout, exit.

Each payload contains:
  - handler_path: absolute path to the handler .py file
  - handler_name: name of the handler callable (default "handler")
  - deps_dirs:    list of directories to prepend to sys.path
  - event:        the event dict to pass to the handler

Since each worker runs in its own process, sys.path / sys.modules
are fully isolated from other functions — no leaks, no locks.
"""
import importlib.util
import json
import os
import struct
import sys
import builtins
import io
import subprocess
from contextlib import contextmanager
from pathlib import Path


_handler_cache: dict = {}

STRICT_FS = os.environ.get("FN_STRICT_FS", "1").lower() not in {"0", "false", "off", "no"}
STRICT_FS_EXTRA_ALLOW = os.environ.get("FN_STRICT_FS_ALLOW", "")
_PROTECTED_FN_FILES = {"fn.config.json", "fn.env.json", "fn.test_events.json"}


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


def _resolve_candidate_path(target) -> Path | None:
    if isinstance(target, int):
        return None
    if isinstance(target, bytes):
        try:
            target = target.decode("utf-8", errors="ignore")
        except Exception:
            return None
    if isinstance(target, os.PathLike):
        target = os.fspath(target)
    if not isinstance(target, str) or target == "":
        return None
    try:
        return Path(target).expanduser().resolve(strict=False)
    except Exception:
        return None


def _build_allowed_roots(handler_path: Path, deps_dirs: list[str]) -> tuple[list[Path], Path]:
    fn_dir = handler_path.parent.resolve(strict=False)
    roots: list[Path] = [fn_dir, (fn_dir / ".deps").resolve(strict=False)]

    for d in deps_dirs:
        try:
            roots.append(Path(d).expanduser().resolve(strict=False))
        except Exception:
            continue

    # Allow Python runtime + stdlib locations.
    for p in {sys.prefix, getattr(sys, "base_prefix", ""), getattr(sys, "exec_prefix", "")}:
        if not p:
            continue
        try:
            roots.append(Path(p).resolve(strict=False))
        except Exception:
            continue

    # Minimal system roots (certs, temp, tzdata) and common stdlib paths.
    for p in ("/tmp", "/etc/ssl", "/etc/pki", "/usr/share/zoneinfo", "/usr", "/lib", "/usr/local"):
        try:
            roots.append(Path(p).resolve(strict=False))
        except Exception:
            continue

    roots.extend(_parse_extra_allow_roots())

    dedup: list[Path] = []
    seen = set()
    for root in roots:
        s = str(root)
        if s not in seen:
            seen.add(s)
            dedup.append(root)
    return dedup, fn_dir


@contextmanager
def _strict_fs_guard(handler_path: Path, deps_dirs: list[str]):
    if not STRICT_FS:
        yield
        return

    allowed_roots, fn_dir = _build_allowed_roots(handler_path, deps_dirs)

    def check_target(target) -> None:
        candidate = _resolve_candidate_path(target)
        if candidate is None:
            return
        if candidate.name in _PROTECTED_FN_FILES and candidate.parent == fn_dir:
            raise PermissionError("access to protected function config/env file denied: " + str(candidate))
        for root in allowed_roots:
            if candidate == root or root in candidate.parents:
                return
        raise PermissionError("path outside strict function sandbox: " + str(candidate))

    orig_open = builtins.open
    orig_io_open = io.open
    orig_os_open = os.open
    orig_listdir = os.listdir
    orig_scandir = os.scandir
    orig_system = os.system
    orig_path_open = Path.open
    orig_subprocess_run = subprocess.run
    orig_subprocess_call = subprocess.call
    orig_subprocess_check_call = subprocess.check_call
    orig_subprocess_check_output = subprocess.check_output
    orig_subprocess_popen = subprocess.Popen

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

    def blocked_subprocess(*_args, **_kwargs):
        raise PermissionError("subprocess disabled by strict function sandbox")

    def blocked_system(*_args, **_kwargs):
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


def _read_frame() -> bytes | None:
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        return None
    length = struct.unpack(">I", header)[0]
    if length == 0:
        return b""
    data = sys.stdin.buffer.read(length)
    if len(data) < length:
        return None
    return data


def _write_frame(data: bytes) -> None:
    sys.stdout.buffer.write(struct.pack(">I", len(data)))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def _load_handler(handler_path: str, handler_name: str):
    mtime_ns = os.stat(handler_path).st_mtime_ns
    cache_key = f"{handler_path}::{handler_name}"
    cached = _handler_cache.get(cache_key)
    if cached is not None and cached["mtime_ns"] == mtime_ns:
        return cached["handler"]

    module_name = f"fn_worker_{abs(hash(cache_key))}_{mtime_ns}"
    spec = importlib.util.spec_from_file_location(module_name, handler_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("failed to load handler spec")

    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    handler = getattr(mod, handler_name, None)
    if not callable(handler) and handler_name == "handler":
        handler = getattr(mod, "main", None)
    if not callable(handler):
        raise RuntimeError(f"{handler_name}(event) is required")

    _handler_cache[cache_key] = {"handler": handler, "mtime_ns": mtime_ns}
    return handler


def _normalize_response(resp):
    if isinstance(resp, tuple):
        body = resp[0] if len(resp) > 0 else None
        status = resp[1] if len(resp) > 1 else 200
        headers = resp[2] if len(resp) > 2 else {}
        return {"body": body, "status": status, "headers": headers}
    if isinstance(resp, dict):
        return resp
    raise ValueError("handler response must be an object or tuple")


def _handle(payload: dict) -> dict:
    handler_path = payload["handler_path"]
    handler_name = payload.get("handler_name", "handler")
    deps_dirs = payload.get("deps_dirs", [])
    event = payload.get("event", {})

    # Set up sys.path for this function's deps (only once per worker).
    for d in reversed(deps_dirs):
        if d not in sys.path:
            sys.path.insert(0, d)

    handler_path_p = Path(handler_path).resolve(strict=False)
    with _strict_fs_guard(handler_path_p, deps_dirs):
        handler = _load_handler(handler_path, handler_name)
        resp = handler(event)
        return _normalize_response(resp)


def _error_resp(exc: Exception) -> dict:
    return {
        "status": 500,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": str(exc)}, separators=(",", ":")),
    }


def _run_persistent() -> None:
    """Frame-based persistent loop."""
    while True:
        raw = _read_frame()
        if raw is None:
            break  # stdin closed → parent died or shutdown
        try:
            payload = json.loads(raw)
            resp = _handle(payload)
        except Exception as exc:
            resp = _error_resp(exc)
        _write_frame(json.dumps(resp, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def _run_oneshot() -> None:
    """Read single JSON from stdin, write response JSON to stdout."""
    raw = sys.stdin.read().strip()
    if not raw:
        return
    try:
        payload = json.loads(raw)
        resp = _handle(payload)
    except Exception as exc:
        resp = _error_resp(exc)
    sys.stdout.write(json.dumps(resp, separators=(",", ":"), ensure_ascii=False))
    sys.stdout.flush()


def main() -> None:
    # Set up sys.path from env if parent passed deps dirs.
    deps_env = os.environ.get("_FASTFN_WORKER_DEPS", "")
    if deps_env:
        for d in reversed(deps_env.split(os.pathsep)):
            d = d.strip()
            if d and d not in sys.path:
                sys.path.insert(0, d)

    mode = os.environ.get("_FASTFN_WORKER_MODE", "oneshot")
    if mode == "persistent":
        _run_persistent()
    else:
        _run_oneshot()


if __name__ == "__main__":
    main()
