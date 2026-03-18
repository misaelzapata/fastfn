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
import asyncio
import base64
import json
import os
import struct
import sys
import builtins
import io
import inspect
import subprocess
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import urlencode


_handler_cache: dict = {}

STRICT_FS = os.environ.get("FN_STRICT_FS", "1").lower() not in {"0", "false", "off", "no"}
STRICT_FS_EXTRA_ALLOW = os.environ.get("FN_STRICT_FS_ALLOW", "")
_PROTECTED_FN_FILES = {"fn.config.json", "fn.env.json", "fn.test_events.json"}
_INVOKE_ADAPTER_NATIVE = "native"
_INVOKE_ADAPTER_AWS_LAMBDA = "aws-lambda"
_INVOKE_ADAPTER_CLOUDFLARE_WORKER = "cloudflare-worker"


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
        except Exception:  # pragma: no cover
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

    def blocked_spawn(*_args, **_kwargs):
        raise PermissionError("os.spawn* disabled by strict function sandbox")

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

    # Block os.spawn* family — additional process-creation vectors beyond
    # subprocess and os.system.
    _orig_spawn_fns = {}
    for _spawn_name in ("spawnl", "spawnle", "spawnlp", "spawnlpe",
                        "spawnv", "spawnve", "spawnvp", "spawnvpe"):
        fn = getattr(os, _spawn_name, None)
        if fn is not None:
            _orig_spawn_fns[_spawn_name] = fn
            setattr(os, _spawn_name, blocked_spawn)
    _orig_execvpe = getattr(os, "execvpe", None)
    if _orig_execvpe is not None:
        setattr(os, "execvpe", blocked_spawn)
    _orig_execvp = getattr(os, "execvp", None)
    if _orig_execvp is not None:
        setattr(os, "execvp", blocked_spawn)

    # Block pty.spawn (pseudo-terminal process creation).
    _orig_pty_spawn = None
    try:
        import pty as _pty_mod
        _orig_pty_spawn = getattr(_pty_mod, "spawn", None)
        if _orig_pty_spawn is not None:
            _pty_mod.spawn = blocked_spawn
    except ImportError:  # pragma: no cover
        _pty_mod = None

    # Block ctypes.CDLL / ctypes.cdll.LoadLibrary — prevents loading arbitrary
    # shared libraries to call system functions directly.
    _orig_ctypes_cdll = None
    _orig_ctypes_cdll_load = None
    try:
        import ctypes as _ctypes_mod
        _orig_ctypes_cdll = _ctypes_mod.CDLL

        def blocked_cdll(*_a, **_kw):
            raise PermissionError("ctypes.CDLL disabled by strict function sandbox")

        _ctypes_mod.CDLL = blocked_cdll
        if hasattr(_ctypes_mod, "cdll") and hasattr(_ctypes_mod.cdll, "LoadLibrary"):
            _orig_ctypes_cdll_load = _ctypes_mod.cdll.LoadLibrary
            _ctypes_mod.cdll.LoadLibrary = blocked_cdll
    except ImportError:  # pragma: no cover
        _ctypes_mod = None

    # NOTE: Full multi-tenant isolation requires OS-level sandboxing (seccomp,
    # namespaces, containers).  Application-level monkey-patching blocks common
    # escape vectors but cannot prevent all bypasses (e.g., direct syscalls via
    # inline assembly or mmap tricks).

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
        for _spawn_name, _fn in _orig_spawn_fns.items():
            setattr(os, _spawn_name, _fn)
        if _orig_execvpe is not None:
            os.execvpe = _orig_execvpe
        if _orig_execvp is not None:
            os.execvp = _orig_execvp
        if _orig_pty_spawn is not None and _pty_mod is not None:
            _pty_mod.spawn = _orig_pty_spawn
        if _orig_ctypes_cdll is not None and _ctypes_mod is not None:
            _ctypes_mod.CDLL = _orig_ctypes_cdll
            if _orig_ctypes_cdll_load is not None and hasattr(_ctypes_mod, "cdll"):
                _ctypes_mod.cdll.LoadLibrary = _orig_ctypes_cdll_load


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


def _normalize_invoke_adapter(raw: object) -> str:
    if not isinstance(raw, str):
        return _INVOKE_ADAPTER_NATIVE
    normalized = raw.strip().lower()
    if normalized in {"", "native", "none", "default"}:
        return _INVOKE_ADAPTER_NATIVE
    if normalized in {"aws-lambda", "lambda", "apigw-v2", "api-gateway-v2"}:
        return _INVOKE_ADAPTER_AWS_LAMBDA
    if normalized in {"cloudflare-worker", "cloudflare-workers", "worker", "workers"}:
        return _INVOKE_ADAPTER_CLOUDFLARE_WORKER
    raise RuntimeError(f"invoke.adapter unsupported: {raw}")


def _resolve_handler(mod, handler_name: str, invoke_adapter: str):
    if invoke_adapter == _INVOKE_ADAPTER_CLOUDFLARE_WORKER:
        fetch_fn = getattr(mod, "fetch", None)
        if callable(fetch_fn):
            return fetch_fn
        fallback = getattr(mod, handler_name, None)
        if callable(fallback):
            return fallback
        raise RuntimeError("cloudflare-worker adapter requires fetch(request, env, ctx)")

    handler = getattr(mod, handler_name, None)
    if not callable(handler) and handler_name == "handler":
        handler = getattr(mod, "main", None)
    if not callable(handler):
        raise RuntimeError(f"{handler_name}(event) is required")
    return handler


def _load_handler(handler_path: str, handler_name: str, invoke_adapter: str):
    mtime_ns = os.stat(handler_path).st_mtime_ns
    cache_key = f"{handler_path}::{handler_name}::{invoke_adapter}"
    cached = _handler_cache.get(cache_key)
    if cached is not None and cached["mtime_ns"] == mtime_ns:
        return cached["handler"]

    module_name = f"fn_worker_{abs(hash(cache_key))}_{mtime_ns}"
    spec = importlib.util.spec_from_file_location(module_name, handler_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("failed to load handler spec")

    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    handler = _resolve_handler(mod, handler_name, invoke_adapter)

    _handler_cache[cache_key] = {"handler": handler, "mtime_ns": mtime_ns}
    return handler


def _header_value(headers: dict[str, object], name: str) -> str:
    target = name.lower()
    for k, v in headers.items():
        if str(k).lower() == target:
            return str(v)
    return ""


def _build_raw_path(event: dict[str, object]) -> str:
    raw = event.get("raw_path") if isinstance(event.get("raw_path"), str) else event.get("path")
    if not isinstance(raw, str) or not raw:
        return "/"
    if raw.startswith("http://") or raw.startswith("https://"):
        return raw
    if raw.startswith("/"):
        return raw
    return "/" + raw


def _encode_query_string(query: object) -> str:
    if not isinstance(query, dict):
        return ""
    pairs: list[tuple[str, str]] = []
    for k, v in query.items():
        if v is None:
            continue
        if isinstance(v, list):
            for item in v:
                if item is None:
                    continue
                pairs.append((str(k), str(item)))
            continue
        pairs.append((str(k), str(v)))
    return urlencode(pairs, doseq=True)


def _build_raw_query(event: dict[str, object]) -> str:
    raw_path = event.get("raw_path")
    if isinstance(raw_path, str):
        idx = raw_path.find("?")
        if idx >= 0 and idx < len(raw_path) - 1:
            return raw_path[idx + 1 :]
    return _encode_query_string(event.get("query"))


def _build_lambda_event(event: dict[str, object]) -> dict:
    headers = event.get("headers") if isinstance(event.get("headers"), dict) else {}
    headers = {str(k): str(v) for k, v in headers.items()}
    raw_path_q = _build_raw_path(event)
    q_idx = raw_path_q.find("?")
    raw_path = raw_path_q[:q_idx] if q_idx >= 0 else raw_path_q
    raw_query = _build_raw_query(event)
    query = event.get("query") if isinstance(event.get("query"), dict) else None
    params = event.get("params") if isinstance(event.get("params"), dict) else None
    cookie_header = _header_value(headers, "cookie")
    cookies = [x.strip() for x in cookie_header.split(";") if x.strip()] if cookie_header else None

    has_b64_body = bool(event.get("is_base64") is True and isinstance(event.get("body_base64"), str))
    if has_b64_body:
        body = str(event.get("body_base64"))
    else:
        body_raw = event.get("body")
        body = body_raw if isinstance(body_raw, str) else ("" if body_raw is None else str(body_raw))

    method = str(event.get("method") or "GET").upper()
    client = event.get("client") if isinstance(event.get("client"), dict) else {}
    context = event.get("context") if isinstance(event.get("context"), dict) else {}

    return {
        "version": "2.0",
        "routeKey": f"{method} {raw_path}",
        "rawPath": raw_path,
        "rawQueryString": raw_query,
        "cookies": cookies,
        "headers": headers,
        "queryStringParameters": query,
        "pathParameters": params,
        "requestContext": {
            "requestId": str(context.get("request_id") or event.get("id") or ""),
            "http": {
                "method": method,
                "path": raw_path,
                "sourceIp": str(client.get("ip") or ""),
                "userAgent": str(client.get("ua") or ""),
            },
            "timeEpoch": int(event.get("ts") or 0) or int(time.time() * 1000),
        },
        "body": body,
        "isBase64Encoded": has_b64_body,
    }


class _LambdaContext:
    def __init__(self, event: dict[str, object]):
        context = event.get("context") if isinstance(event.get("context"), dict) else {}
        timeout_ms = int(context.get("timeout_ms") or 0)
        self.aws_request_id = str(context.get("request_id") or event.get("id") or "")
        self.awsRequestId = self.aws_request_id
        self.function_name = str(context.get("function_name") or "")
        self.functionName = self.function_name
        self.function_version = str(context.get("version") or "$LATEST")
        self.functionVersion = self.function_version
        self.memory_limit_in_mb = str(context.get("memory_limit_mb") or "")
        self.memoryLimitInMB = self.memory_limit_in_mb
        self.invoked_function_arn = str(context.get("invoked_function_arn") or "")
        self.callback_waits_for_empty_event_loop = False
        self.fastfn = context
        self._timeout_ms = timeout_ms

    def get_remaining_time_in_millis(self) -> int:
        return max(0, int(self._timeout_ms))

    def done(self, *_args, **_kwargs) -> None:
        return None

    def fail(self, *_args, **_kwargs) -> None:
        return None

    def succeed(self, *_args, **_kwargs) -> None:
        return None


def _build_workers_url(event: dict[str, object]) -> str:
    raw_path = _build_raw_path(event)
    if raw_path.startswith("http://") or raw_path.startswith("https://"):
        return raw_path
    headers = event.get("headers") if isinstance(event.get("headers"), dict) else {}
    proto = _header_value({str(k): str(v) for k, v in headers.items()}, "x-forwarded-proto") or "http"
    host = _header_value({str(k): str(v) for k, v in headers.items()}, "host") or "127.0.0.1"
    return f"{proto}://{host}{raw_path}"


class _WorkersRequest:
    def __init__(self, event: dict[str, object]):
        self.method = str(event.get("method") or "GET").upper()
        headers_raw = event.get("headers") if isinstance(event.get("headers"), dict) else {}
        self.headers = {str(k): str(v) for k, v in headers_raw.items()}
        self.url = _build_workers_url(event)
        if event.get("is_base64") is True and isinstance(event.get("body_base64"), str):
            try:
                self.body = base64.b64decode(str(event.get("body_base64")))
            except Exception:
                self.body = b""
        else:
            body_raw = event.get("body")
            if isinstance(body_raw, bytes):
                self.body = body_raw
            elif isinstance(body_raw, str):
                self.body = body_raw.encode("utf-8")
            elif body_raw is None:
                self.body = b""
            else:
                self.body = str(body_raw).encode("utf-8")

    async def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")

    async def json(self):
        raw = await self.text()
        if not raw:
            return None
        return json.loads(raw)


class _WorkersContext:
    def __init__(self, event: dict[str, object]):
        context = event.get("context") if isinstance(event.get("context"), dict) else {}
        self.request_id = str(context.get("request_id") or event.get("id") or "")
        self._waitables = []

    def waitUntil(self, awaitable):
        return self.wait_until(awaitable)

    def wait_until(self, awaitable):
        if inspect.isawaitable(awaitable):
            self._waitables.append(awaitable)
        return None

    def passThroughOnException(self):
        return None

    def pass_through_on_exception(self):
        return None


def _call_handler(handler, args: list[object], route_params: dict | None = None):
    try:
        sig = inspect.signature(handler)
        params = list(sig.parameters.values())
        if any(p.kind == inspect.Parameter.VAR_POSITIONAL for p in params):
            return handler(*args)
        positional = [
            p for p in params if p.kind in (inspect.Parameter.POSITIONAL_ONLY, inspect.Parameter.POSITIONAL_OR_KEYWORD)
        ]
        argc = len(positional)
        if argc <= 0:
            return handler()

        # Inject route params as kwargs when handler declares extra parameters.
        # e.g. def handler(event, id): ... receives id="42" from event.params
        if route_params and argc >= 1:
            has_var_keyword = any(p.kind == inspect.Parameter.VAR_KEYWORD for p in params)
            keyword_only = [p for p in params if p.kind == inspect.Parameter.KEYWORD_ONLY]

            if has_var_keyword:
                return handler(args[0], **route_params)

            injectable = {}
            for p in positional[1:]:
                if p.name in route_params:
                    injectable[p.name] = route_params[p.name]
            for p in keyword_only:
                if p.name in route_params:
                    injectable[p.name] = route_params[p.name]

            if injectable:
                return handler(args[0], **injectable)

        return handler(*args[: min(argc, len(args))])
    except Exception:
        return handler(*args)


def _resolve_awaitable(value):
    if not inspect.isawaitable(value):
        return value
    try:
        return asyncio.run(value)
    except RuntimeError:
        loop = asyncio.new_event_loop()
        try:
            return loop.run_until_complete(value)
        finally:
            loop.close()


def _normalize_response_like_object(resp):
    status = getattr(resp, "status", 200)
    headers = getattr(resp, "headers", {})
    body = getattr(resp, "body", "")
    out_headers = dict(headers) if isinstance(headers, dict) else {}
    out: dict = {"status": int(status) if isinstance(status, int) else 200, "headers": out_headers}
    if isinstance(body, (bytes, bytearray)):
        out["is_base64"] = True
        out["body_base64"] = base64.b64encode(bytes(body)).decode("utf-8")
        return out
    if body is None:
        body = ""
    out["body"] = body if isinstance(body, str) else str(body)
    return out


_thread_local_env = threading.local()


class _EnvOverrideProxy:
    """A proxy for os.environ that checks thread-local overrides first.

    This prevents environment variable leakage between concurrent requests
    in persistent worker mode, where multiple requests may be handled by the
    same process (and potentially different threads in the future).
    Instead of mutating the global os.environ, per-request env vars are stored
    in threading.local() and looked up transparently.
    """

    def __init__(self, real_environ):
        object.__setattr__(self, "_real", real_environ)

    def _get_overrides(self):
        return getattr(_thread_local_env, "env_overrides", None)

    def __getitem__(self, key):
        overrides = self._get_overrides()
        if overrides is not None and key in overrides:
            val = overrides[key]
            if val is None:
                raise KeyError(key)
            return val
        return self._real[key]

    def __setitem__(self, key, value):
        self._real[key] = value

    def __delitem__(self, key):
        del self._real[key]

    def __contains__(self, key):
        overrides = self._get_overrides()
        if overrides is not None and key in overrides:
            return overrides[key] is not None
        return key in self._real

    def get(self, key, default=None):
        try:
            return self[key]
        except KeyError:
            return default

    def __iter__(self):
        overrides = self._get_overrides()
        if overrides is None:
            yield from self._real
            return
        seen = set()
        for k in self._real:
            if k in overrides:
                if overrides[k] is not None:
                    seen.add(k)
                    yield k
            else:
                seen.add(k)
                yield k
        for k, v in overrides.items():
            if k not in seen and v is not None:
                yield k

    def keys(self):
        return list(self)

    def values(self):
        return [self[k] for k in self]

    def items(self):
        return [(k, self[k]) for k in self]

    def __len__(self):
        return sum(1 for _ in self.__iter__())

    def pop(self, key, *args):
        return self._real.pop(key, *args)

    def copy(self):
        result = self._real.copy()
        overrides = self._get_overrides()
        if overrides:
            for k, v in overrides.items():
                if v is None:
                    result.pop(k, None)
                else:
                    result[k] = v
        return result

    def __getattr__(self, name):
        return getattr(self._real, name)


# Install the proxy over os.environ so handler code transparently sees
# per-request overrides without any global mutation.
if not isinstance(os.environ, _EnvOverrideProxy):
    os.environ = _EnvOverrideProxy(os.environ)


@contextmanager
def _patched_process_env(event: dict):
    env = event.get("env") if isinstance(event.get("env"), dict) else {}
    if not env:
        yield
        return

    overrides: dict[str, str | None] = {}
    for raw_key, raw_value in env.items():
        if not isinstance(raw_key, str) or raw_key == "":
            continue
        overrides[raw_key] = None if raw_value is None else str(raw_value)

    _thread_local_env.env_overrides = overrides
    try:
        yield
    finally:
        _thread_local_env.env_overrides = None


def _invoke_handler(handler, invoke_adapter: str, event: dict):
    with _patched_process_env(event):
        if invoke_adapter == _INVOKE_ADAPTER_AWS_LAMBDA:
            lambda_event = _build_lambda_event(event)
            lambda_context = _LambdaContext(event)
            return _resolve_awaitable(_call_handler(handler, [lambda_event, lambda_context]))
        if invoke_adapter == _INVOKE_ADAPTER_CLOUDFLARE_WORKER:
            req = _WorkersRequest(event)
            env = event.get("env") if isinstance(event.get("env"), dict) else {}
            ctx = _WorkersContext(event)
            return _resolve_awaitable(_call_handler(handler, [req, env, ctx]))
        route_params = event.get("params") if isinstance(event.get("params"), dict) else {}
        return _resolve_awaitable(_call_handler(handler, [event], route_params=route_params))


def _normalize_response(resp):
    if isinstance(resp, tuple):
        body = resp[0] if len(resp) > 0 else None
        status = resp[1] if len(resp) > 1 else 200
        headers = resp[2] if len(resp) > 2 else {}
        return {"body": body, "status": status, "headers": headers}
    if isinstance(resp, dict):
        return resp
    if any(hasattr(resp, key) for key in ("status", "headers", "body")):
        return _normalize_response_like_object(resp)
    raise ValueError("handler response must be an object or tuple")


def _handle(payload: dict) -> dict:
    handler_path = payload["handler_path"]
    handler_name = payload.get("handler_name", "handler")
    invoke_adapter = _normalize_invoke_adapter(payload.get("invoke_adapter", "native"))
    deps_dirs = payload.get("deps_dirs", [])
    event = payload.get("event", {})

    # Set up sys.path for this function's deps (only once per worker).
    for d in reversed(deps_dirs):
        if d not in sys.path:
            sys.path.insert(0, d)

    handler_path_p = Path(handler_path).resolve(strict=False)
    with _strict_fs_guard(handler_path_p, deps_dirs):
        handler = _load_handler(handler_path, handler_name, invoke_adapter)

        # Capture stdout/stderr during handler execution.
        captured_out = io.StringIO()
        captured_err = io.StringIO()
        old_stdout, old_stderr = sys.stdout, sys.stderr
        sys.stdout = captured_out
        sys.stderr = captured_err
        try:
            resp = _invoke_handler(handler, invoke_adapter, event)
        finally:
            sys.stdout = old_stdout
            sys.stderr = old_stderr

        result = _normalize_response(resp)
        stdout_str = captured_out.getvalue()
        stderr_str = captured_err.getvalue()
        if stdout_str:
            result["stdout"] = stdout_str
        if stderr_str:
            result["stderr"] = stderr_str
        return result


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


if __name__ == "__main__":  # pragma: no cover
    main()
