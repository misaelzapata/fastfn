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


_handler_cache: dict = {}


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
