#!/usr/bin/env python3
import importlib.util
import json
import asyncio
import base64
import ast
import inspect
import os
import re
import socket
import stat
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
from typing import Any, Callable, Dict, Optional
from urllib.parse import urlencode

SOCKET_PATH = os.environ.get("FN_PY_SOCKET", "/tmp/fastfn/fn-python.sock")
MAX_FRAME_BYTES = int(os.environ.get("FN_MAX_FRAME_BYTES", str(2 * 1024 * 1024)))
HOT_RELOAD = os.environ.get("FN_HOT_RELOAD", "1").lower() not in {"0", "false", "off", "no"}
RUNTIME_LOG_FILE = os.environ.get("FN_RUNTIME_LOG_FILE", "").strip()
STRICT_FS = os.environ.get("FN_STRICT_FS", "1").lower() not in {"0", "false", "off", "no"}
STRICT_FS_EXTRA_ALLOW = os.environ.get("FN_STRICT_FS_ALLOW", "")
PREINSTALL_PY_DEPS_ON_START = os.environ.get("FN_PREINSTALL_PY_DEPS_ON_START", "1").lower() not in {"0", "false", "off", "no"}
AUTO_INFER_PY_DEPS = os.environ.get("FN_AUTO_INFER_PY_DEPS", "1").lower() not in {"0", "false", "off", "no"}
AUTO_INFER_WRITE_MANIFEST = os.environ.get("FN_AUTO_INFER_WRITE_MANIFEST", "1").lower() not in {"0", "false", "off", "no"}
AUTO_INFER_STRICT = os.environ.get("FN_AUTO_INFER_STRICT", "1").lower() not in {"0", "false", "off", "no"}
PY_INFER_BACKEND = (os.environ.get("FN_PY_INFER_BACKEND", "native") or "native").strip().lower()
ENABLE_RUNTIME_WORKER_POOL = os.environ.get("FN_PY_RUNTIME_WORKER_POOL", "1").lower() not in {"0", "false", "off", "no"}

RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = int(os.environ.get("FN_PY_POOL_ACQUIRE_TIMEOUT_MS", "5000"))
RUNTIME_POOL_IDLE_TTL_MS = int(os.environ.get("FN_PY_POOL_IDLE_TTL_MS", "300000"))
RUNTIME_POOL_REAPER_INTERVAL_MS = int(os.environ.get("FN_PY_POOL_REAPER_INTERVAL_MS", "2000"))

BASE_DIR = Path(__file__).resolve().parents[1]
FUNCTIONS_DIR = Path(os.environ.get("FN_FUNCTIONS_ROOT", str(BASE_DIR / "functions" / "python")))
RUNTIME_FUNCTIONS_DIR = FUNCTIONS_DIR / "python"
PACKS_RUNTIME = "python"

_NAME_RE = re.compile(r"^[A-Za-z0-9._/\-\[\]]+$")
_VERSION_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_HANDLER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_PY_PACKAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
_INVOKE_ADAPTER_NATIVE = "native"
_INVOKE_ADAPTER_AWS_LAMBDA = "aws-lambda"
_INVOKE_ADAPTER_CLOUDFLARE_WORKER = "cloudflare-worker"
_DEPS_STATE_BASENAME = ".fastfn-deps-state.json"
_PY_INFER_BACKENDS = {"native", "pipreqs"}

# Worker subprocesses get a conservative env allowlist. User-defined secrets
# should come from fn.env.json or request-scoped event.env, not ambient host env.
_ALLOWED_WORKER_ENV_KEYS = {
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "TMPDIR",
    "TMP",
    "TEMP",
    "LANG",
    "TERM",
    "TZ",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "REQUESTS_CA_BUNDLE",
    "CURL_CA_BUNDLE",
    "NODE_EXTRA_CA_CERTS",
    "PYTHONHOME",
    "PYTHONPATH",
    "PYTHONUNBUFFERED",
    "PYTHONDONTWRITEBYTECODE",
    "PIP_CACHE_DIR",
    "GOPATH",
    "GOCACHE",
    "GOMODCACHE",
    "GOENV",
    "GOFLAGS",
    "CGO_ENABLED",
    "CC",
    "CXX",
    "PKG_CONFIG",
    "PKG_CONFIG_PATH",
    "CARGO_HOME",
    "RUSTUP_HOME",
    "RUSTFLAGS",
    "CARGO_TARGET_DIR",
    "RUSTC_WRAPPER",
    "COMPOSER_HOME",
    "HOSTNAME",
    "SYSTEMROOT",
}
_ALLOWED_WORKER_ENV_PREFIXES = ("LC_",)


def _worker_env_key_allowed(key: Any) -> bool:
    if not isinstance(key, str) or key == "":
        return False
    upper_key = key.upper()
    if upper_key in _ALLOWED_WORKER_ENV_KEYS:
        return True
    return any(upper_key.startswith(prefix) for prefix in _ALLOWED_WORKER_ENV_PREFIXES)


def _sanitize_worker_env(env: Dict[str, str]) -> Dict[str, str]:
    """Keep only the small set of ambient env vars required by runtime workers."""
    return {k: v for k, v in env.items() if _worker_env_key_allowed(k)}

_PY_STDLIB_MODULES = set(getattr(sys, "stdlib_module_names", set()))

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

# ---------------------------------------------------------------------------
# In-process execution state
# ---------------------------------------------------------------------------
_INPROCESS_CACHE: Dict[str, Dict[str, Any]] = {}
_IMPORT_LOCK = threading.Lock()
_capture_tls = threading.local()
_env_tls = threading.local()
_strict_fs_tls = threading.local()
_strict_fs_hooks_installed = False
_strict_fs_install_lock = threading.Lock()


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


def _is_safe_root_relative_path(raw_path: str) -> bool:
    path = str(raw_path or "").strip()
    if not path or path.startswith("/") or "\\" in path:
        return False
    for segment in path.split("/"):
        if not segment or segment in {".", ".."}:
            return False
    return True


def _read_root_assets_directory() -> str:
    cfg_path = FUNCTIONS_DIR / "fn.config.json"
    if not cfg_path.is_file():
        return ""

    try:
        parsed = json.loads(cfg_path.read_text(encoding="utf-8"))
    except Exception:
        return ""

    if not isinstance(parsed, dict):
        return ""
    assets = parsed.get("assets")
    if not isinstance(assets, dict):
        return ""

    directory = assets.get("directory")
    if not isinstance(directory, str):
        directory = str(directory or "")
    directory = directory.strip()
    if not _is_safe_root_relative_path(directory):
        return ""
    return directory.strip("/")


_ROOT_ASSETS_DIRECTORY = _read_root_assets_directory()


def _path_is_in_assets_directory(abs_path: Path) -> bool:
    if not _ROOT_ASSETS_DIRECTORY:
        return False
    try:
        rel = abs_path.relative_to(FUNCTIONS_DIR)
    except ValueError:
        return False
    normalized = rel.as_posix().strip("/")
    return normalized == _ROOT_ASSETS_DIRECTORY or normalized.startswith(_ROOT_ASSETS_DIRECTORY + "/")


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


def _json_log(event: str, **fields: Any) -> None:
    payload: Dict[str, Any] = {
        "t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "component": "python_daemon",
        "event": event,
    }
    payload.update(fields)
    try:
        print(json.dumps(payload, separators=(",", ":"), ensure_ascii=True), flush=True)
    except Exception:
        return


def _deps_state_path(handler_path: Path) -> Path:
    return handler_path.parent / _DEPS_STATE_BASENAME


def _read_deps_state(handler_path: Path) -> Dict[str, Any]:
    path = _deps_state_path(handler_path)
    if not path.is_file():
        return {}
    try:
        raw = path.read_text(encoding="utf-8")
        parsed = json.loads(raw)
    except Exception:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _write_deps_state(handler_path: Path, payload: Dict[str, Any]) -> None:
    state = dict(payload or {})
    state["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        _deps_state_path(handler_path).write_text(
            json.dumps(state, indent=2, ensure_ascii=True) + "\n",
            encoding="utf-8",
        )
    except Exception:
        return


def _normalize_requirement_name(line: str) -> Optional[str]:
    raw = (line or "").strip()
    if not raw or raw.startswith("#"):
        return None
    if raw.startswith("-"):
        return None
    lower = raw.lower()
    if lower.startswith("git+") or lower.startswith("http://") or lower.startswith("https://") or lower.startswith("file:"):
        return None
    m = re.match(r"^([A-Za-z0-9_.-]+)", raw)
    if not m:
        return None
    return m.group(1).lower()


def _read_requirements_lines_and_packages(req_file: Path) -> tuple[list[str], set[str]]:
    if not req_file.is_file():
        return [], set()
    try:
        lines = req_file.read_text(encoding="utf-8").splitlines()
    except Exception:
        return [], set()
    names: set[str] = set()
    for line in lines:
        name = _normalize_requirement_name(line)
        if name:
            names.add(name)
    return lines, names


def _has_effective_requirement_specs(lines: list[str]) -> bool:
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        return True
    return False


def _deps_dir_has_entries(deps_dir: Path) -> bool:
    if not deps_dir.is_dir():
        return False
    try:
        return next(deps_dir.iterdir(), None) is not None
    except Exception:
        return False


def _event_version_label(event: Dict[str, Any], version: Any) -> str:
    event_version = event.get("version") if isinstance(event, dict) else None
    if isinstance(event_version, str) and event_version.strip():
        return event_version.strip()
    if isinstance(version, str) and version.strip():
        return version.strip()
    return "default"


def _with_event_runtime_metadata(event: Dict[str, Any], version: Any) -> Dict[str, Any]:
    event_with_meta = dict(event)
    event_with_meta["version"] = _event_version_label(event_with_meta, version)
    return event_with_meta


def _is_local_python_module(fn_dir: Path, module_root: str) -> bool:
    if not module_root:
        return False
    if (fn_dir / f"{module_root}.py").is_file():
        return True
    module_dir = fn_dir / module_root
    if module_dir.is_dir():
        return True
    return False


def _infer_python_imports(handler_path: Path) -> list[str]:
    try:
        source = handler_path.read_text(encoding="utf-8")
        tree = ast.parse(source, filename=str(handler_path))
    except Exception:
        return []

    imports: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                raw = getattr(alias, "name", "")
                if isinstance(raw, str) and raw:
                    imports.add(raw.split(".", 1)[0])
        elif isinstance(node, ast.ImportFrom):
            level = int(getattr(node, "level", 0) or 0)
            if level > 0:
                continue
            raw = getattr(node, "module", None)
            if isinstance(raw, str) and raw:
                imports.add(raw.split(".", 1)[0])

    filtered: list[str] = []
    fn_dir = handler_path.parent
    for name in sorted(imports):
        if not name:  # pragma: no cover
            continue
        if name in _PY_STDLIB_MODULES or name in sys.builtin_module_names:
            continue
        if name == handler_path.stem:
            continue
        if _is_local_python_module(fn_dir, name):
            continue
        filtered.append(name)
    return filtered


def _map_python_import_to_package(import_name: str) -> tuple[Optional[str], Optional[str]]:
    candidate = import_name.strip().lower()
    if not candidate or not _PY_PACKAGE_RE.match(candidate):
        return None, import_name
    if any(ch.isupper() for ch in import_name):
        return None, import_name
    return candidate, None


def _resolve_inferred_python_packages(imports: list[str]) -> tuple[list[str], list[str]]:
    resolved: list[str] = []
    unresolved: list[str] = []
    seen_resolved: set[str] = set()
    seen_unresolved: set[str] = set()

    for name in imports:
        pkg, unresolved_name = _map_python_import_to_package(name)
        if pkg is not None:
            key = pkg.lower()
            if key not in seen_resolved:
                seen_resolved.add(key)
                resolved.append(pkg)
            continue
        if unresolved_name and unresolved_name not in seen_unresolved:
            seen_unresolved.add(unresolved_name)
            unresolved.append(unresolved_name)

    return resolved, unresolved


def _resolve_python_infer_backend() -> str:
    backend = (PY_INFER_BACKEND or "native").strip().lower()
    if backend in _PY_INFER_BACKENDS:
        return backend
    raise RuntimeError(
        "python dependency inference backend unsupported: "
        f"{backend}. Supported values: native, pipreqs."
    )


def _parse_inferred_requirement_specs(lines: list[str]) -> tuple[list[str], list[str]]:
    resolved_specs: list[str] = []
    resolved_names: list[str] = []
    seen_names: set[str] = set()

    for raw in lines:
        line = str(raw or "").strip()
        if not line or line.startswith("#"):
            continue
        name = _normalize_requirement_name(line)
        if not name:
            continue
        if name in seen_names:
            continue
        seen_names.add(name)
        resolved_specs.append(line)
        resolved_names.append(name)
    return resolved_specs, resolved_names


def _infer_python_packages_with_pipreqs(handler_path: Path) -> tuple[list[str], list[str], list[str]]:
    inferred_imports = _infer_python_imports(handler_path)
    cmd = [
        sys.executable,
        "-m",
        "pipreqs",
        str(handler_path.parent),
        "--print",
        "--mode",
        "no-pin",
        "--ignore",
        ".deps,__pycache__",
    ]
    try:
        result = _REAL_SUBPROCESS_RUN(
            cmd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
            text=True,
        )
    except Exception as exc:
        raise RuntimeError(
            "python dependency inference backend 'pipreqs' is unavailable. "
            "Install it with 'pip install pipreqs' or switch FN_PY_INFER_BACKEND=native."
        ) from exc

    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        normalized = detail.lower()
        if "no module named pipreqs" in normalized or "pipreqs" in normalized and "not found" in normalized:
            raise RuntimeError(
                "python dependency inference backend 'pipreqs' is unavailable. "
                "Install it with 'pip install pipreqs' or switch FN_PY_INFER_BACKEND=native."
            )
        tail = " | ".join(detail.splitlines()[-4:]) if detail else "unknown error"
        raise RuntimeError(f"python dependency inference via pipreqs failed: {tail}")

    resolved_specs, resolved_names = _parse_inferred_requirement_specs((result.stdout or "").splitlines())
    if AUTO_INFER_STRICT and inferred_imports and not resolved_specs:
        raise RuntimeError(
            "python dependency inference via pipreqs did not resolve packages for imports "
            + ", ".join(inferred_imports)
            + ". Add explicit requirements.txt entries or switch FN_PY_INFER_BACKEND=native."
        )
    return inferred_imports, resolved_specs, resolved_names


def _write_python_lockfile(handler_path: Path, deps_dir: Path) -> Optional[Path]:
    lock_file = handler_path.with_name("requirements.lock.txt")
    cmd = [
        sys.executable,
        "-m",
        "pip",
        "freeze",
        "--disable-pip-version-check",
        "--path",
        str(deps_dir),
    ]
    try:
        result = _REAL_SUBPROCESS_RUN(
            cmd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
            text=True,
        )
    except Exception:
        return None
    if result.returncode != 0:
        return None

    lines = [line.strip() for line in (result.stdout or "").splitlines() if line.strip()]
    if not lines:
        try:
            lock_file.write_text("", encoding="utf-8")
        except Exception:
            return None
        return lock_file

    lines = sorted(set(lines), key=lambda x: x.lower())
    try:
        lock_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    except Exception:
        return None
    return lock_file


def _ensure_requirements(handler_path: Path) -> None:
    inline_reqs = _extract_requirements(handler_path)
    req_file = handler_path.with_name("requirements.txt")
    deps_dir = handler_path.parent / ".deps"
    lock_file_path = handler_path.with_name("requirements.lock.txt")
    fn_dir = str(handler_path.parent)
    manifest_existed = req_file.is_file()
    previous_state = _read_deps_state(handler_path)
    previous_manifest_generated = previous_state.get("manifest_generated") is True

    state: Dict[str, Any] = {
        "runtime": "python",
        "mode": "manifest",
        "manifest_path": str(req_file),
        "manifest_generated": previous_manifest_generated,
        "infer_backend": (PY_INFER_BACKEND or "native").strip().lower() if AUTO_INFER_PY_DEPS else "native",
        "inference_duration_ms": 0,
        "inferred_imports": [],
        "resolved_packages": [],
        "unresolved_imports": [],
        "last_install_status": "skipped",
        "last_error": None,
        "lockfile_path": str(lock_file_path),
    }

    if not _auto_requirements_enabled():
        state["last_error"] = "FN_AUTO_REQUIREMENTS is disabled"
        _write_deps_state(handler_path, state)
        _json_log(
            "deps_install_skip",
            runtime="python",
            fn_dir=fn_dir,
            mode=state["mode"],
            reason="auto_requirements_disabled",
        )
        return

    req_lines, req_packages = _read_requirements_lines_and_packages(req_file)
    has_explicit_specs = bool(inline_reqs or _has_effective_requirement_specs(req_lines))
    inferred_imports: list[str] = []
    resolved_specs: list[str] = []
    resolved_packages: list[str] = []
    unresolved_imports: list[str] = []

    if AUTO_INFER_PY_DEPS:
        infer_backend = _resolve_python_infer_backend()
        started_at = time.monotonic()
        _json_log("deps_inference_start", runtime="python", fn_dir=fn_dir, backend=infer_backend)
        if infer_backend == "native":
            inferred_imports = _infer_python_imports(handler_path)
            resolved_packages, unresolved_imports = _resolve_inferred_python_packages(inferred_imports)
            resolved_specs = list(resolved_packages)
        else:
            inferred_imports, resolved_specs, resolved_packages = _infer_python_packages_with_pipreqs(handler_path)
            unresolved_imports = []
        state["infer_backend"] = infer_backend
        state["inference_duration_ms"] = int((time.monotonic() - started_at) * 1000)
        _json_log(
            "deps_inference_done",
            runtime="python",
            fn_dir=fn_dir,
            backend=state["infer_backend"],
            duration_ms=state["inference_duration_ms"],
            inferred=len(inferred_imports),
            resolved=len(resolved_packages),
            unresolved=len(unresolved_imports),
        )
        state["inferred_imports"] = inferred_imports
        state["resolved_packages"] = resolved_packages
        state["unresolved_imports"] = unresolved_imports

        if unresolved_imports and AUTO_INFER_STRICT and not has_explicit_specs:
            msg = (
                "python dependency inference failed: unresolved imports "
                + ", ".join(unresolved_imports)
                + ". Add explicit requirements.txt entries or disable FN_AUTO_INFER_STRICT."
            )
            state["mode"] = "inferred"
            state["last_install_status"] = "error"
            state["last_error"] = msg
            _write_deps_state(handler_path, state)
            _json_log("deps_install_error", runtime="python", fn_dir=fn_dir, stage="inference", error=msg)
            raise RuntimeError(msg)

        if resolved_specs and AUTO_INFER_WRITE_MANIFEST:
            missing = [spec for spec in resolved_specs if _normalize_requirement_name(spec) not in req_packages]
            if missing:
                out_lines = list(req_lines)
                if not out_lines:
                    out_lines = [
                        "# Auto-generated by FastFN dependency inference.",
                        f"# Backend: {state['infer_backend']}. Explicit manifests remain faster and more predictable.",
                        "",
                    ]
                elif out_lines[-1].strip():
                    out_lines.append("")
                out_lines.extend(missing)
                req_file.write_text("\n".join(out_lines).rstrip() + "\n", encoding="utf-8")
                req_packages.update(
                    name for name in (_normalize_requirement_name(spec) for spec in missing) if name
                )
                req_lines = out_lines

        if resolved_packages or unresolved_imports:
            state["mode"] = "inferred"
    else:
        state["inferred_imports"] = []
        state["resolved_packages"] = []
        state["unresolved_imports"] = []

    state["manifest_generated"] = previous_manifest_generated or (not manifest_existed and req_file.is_file())

    req_file_sig = "none"
    if req_file.is_file():
        req_file_sig = str(req_file.stat().st_mtime_ns)
    marker = f"{handler_path}:{handler_path.stat().st_mtime_ns}:{req_file_sig}:{'|'.join(inline_reqs)}"
    state["install_signature"] = marker

    has_effective_manifest = _has_effective_requirement_specs(req_lines)
    if not inline_reqs and not has_effective_manifest:
        _REQ_CACHE[marker] = True
        if previous_state.get("install_signature") == marker and previous_state.get("last_install_status") == "skipped":
            _json_log(
                "deps_install_skip",
                runtime="python",
                fn_dir=fn_dir,
                mode=state["mode"],
                reason="no_effective_requirements",
            )
            return
        state["last_install_status"] = "skipped"
        _write_deps_state(handler_path, state)
        _json_log(
            "deps_install_skip",
            runtime="python",
            fn_dir=fn_dir,
            mode=state["mode"],
            reason="no_effective_requirements",
        )
        return

    if marker in _REQ_CACHE:
        if _deps_dir_has_entries(deps_dir):
            state["last_install_status"] = "ok"
            _write_deps_state(handler_path, state)
            _json_log(
                "deps_install_reuse",
                runtime="python",
                fn_dir=fn_dir,
                mode=state["mode"],
                source="memory_cache",
            )
            return
        _REQ_CACHE.pop(marker, None)

    if previous_state.get("install_signature") == marker and previous_state.get("last_install_status") == "ok":
        if _deps_dir_has_entries(deps_dir):
            _REQ_CACHE[marker] = True
            _json_log(
                "deps_install_reuse",
                runtime="python",
                fn_dir=fn_dir,
                mode=state["mode"],
                source="persisted_state",
            )
            return

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

    _json_log("deps_install_start", runtime="python", fn_dir=fn_dir, mode=state["mode"])
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
        msg = (
            f"pip dependencies install failed for {handler_path.parent}: {tail}. "
            "Check inferred imports or add explicit requirements.txt pins."
        )
        state["last_install_status"] = "error"
        state["last_error"] = msg
        _write_deps_state(handler_path, state)
        _json_log("deps_install_error", runtime="python", fn_dir=fn_dir, stage="install", error=tail)
        raise RuntimeError(msg)

    _REQ_CACHE[marker] = True
    lock_path = _write_python_lockfile(handler_path, deps_dir)
    if lock_path is not None:
        state["lockfile_path"] = str(lock_path)
    state["last_install_status"] = "ok"
    state["last_error"] = None
    _write_deps_state(handler_path, state)
    _json_log("deps_install_done", runtime="python", fn_dir=fn_dir, mode=state["mode"])


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


def _shared_pack_candidate_dirs(pack_name: str) -> list[Path]:
    candidates: list[Path] = []
    roots: list[Path] = [FUNCTIONS_DIR]
    if FUNCTIONS_DIR.name == PACKS_RUNTIME:
        roots.append(FUNCTIONS_DIR.parent)
    for root in roots:
        candidate = (root / ".fastfn" / "packs" / PACKS_RUNTIME / pack_name).resolve(strict=False)
        if candidate not in candidates:
            candidates.append(candidate)
    return candidates


def _resolve_shared_pack_dir(pack_name: str) -> Path:
    candidates = _shared_pack_candidate_dirs(pack_name)
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    searched = ", ".join(str(candidate) for candidate in candidates) or "<none>"
    raise RuntimeError(f"shared pack not found: {pack_name} (looked in: {searched})")


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


def _resolve_invoke_adapter(fn_config: Dict[str, Any]) -> str:
    invoke = fn_config.get("invoke")
    if not isinstance(invoke, dict):
        return _INVOKE_ADAPTER_NATIVE

    raw = invoke.get("adapter")
    if not isinstance(raw, str):
        return _INVOKE_ADAPTER_NATIVE

    normalized = raw.strip().lower()
    if normalized in {"", "native", "none", "default"}:
        return _INVOKE_ADAPTER_NATIVE
    if normalized in {"aws-lambda", "lambda", "apigw-v2", "api-gateway-v2"}:
        return _INVOKE_ADAPTER_AWS_LAMBDA
    if normalized in {"cloudflare-worker", "cloudflare-workers", "worker", "workers"}:
        return _INVOKE_ADAPTER_CLOUDFLARE_WORKER
    raise ValueError(f"invoke.adapter unsupported: {raw}")


def _ensure_pack_requirements(pack_dir: Path) -> Optional[Path]:
    req_file = pack_dir / "requirements.txt"
    if not req_file.is_file() or not _auto_requirements_enabled():
        return None
    req_lines, _ = _read_requirements_lines_and_packages(req_file)
    if not _has_effective_requirement_specs(req_lines):
        _json_log(
            "pack_deps_install_skip",
            runtime="python",
            pack_dir=str(pack_dir),
            reason="no_effective_requirements",
        )
        return None

    deps_dir = pack_dir / ".deps"

    marker = f"pack:{pack_dir}:{req_file.stat().st_mtime_ns}"
    if marker in _PACK_REQ_CACHE:
        if _deps_dir_has_entries(deps_dir):
            _json_log(
                "pack_deps_install_reuse",
                runtime="python",
                pack_dir=str(pack_dir),
                source="memory_cache",
            )
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
def _resolve_candidate_path(target: Any) -> Optional[Path]:
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


def _build_allowed_roots(handler_path: Path, extra_roots: Optional[list[Path]] = None) -> tuple[list[Path], Path]:
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
def _strict_fs_guard(handler_path: Path, extra_roots: Optional[list[Path]] = None):
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


def _normalize_source_dir(source_dir: Any) -> Optional[str]:
    if source_dir is None:
        return None
    if not isinstance(source_dir, str):
        raise ValueError("invalid function source dir")
    normalized = source_dir.strip().replace("\\", "/")
    if not normalized:
        raise ValueError("invalid function source dir")
    if (
        normalized.startswith("/")
        or normalized == ".."
        or normalized.startswith("../")
        or normalized.endswith("/..")
        or "/../" in normalized
    ):
        raise ValueError("invalid function source dir")
    return normalized


def _resolve_source_dir_base(source_dir: Any) -> Optional[Path]:
    normalized = _normalize_source_dir(source_dir)
    if normalized is None:
        return None

    root_dir = FUNCTIONS_DIR.resolve(strict=False)
    if normalized == ".":
        base = root_dir
    else:
        base = (FUNCTIONS_DIR / normalized).resolve(strict=False)

    if base != root_dir and not str(base).startswith(str(root_dir) + os.sep):
        raise ValueError("invalid function source dir")
    if not base.is_dir():
        raise FileNotFoundError("unknown function source dir")
    return base


def _safe_entrypoint_value(raw: Any) -> Optional[str]:
    if not isinstance(raw, str):
        return None
    value = raw.strip().replace("\\", "/")
    if not value or value.startswith("/") or value == ".." or value.startswith("../") or value.endswith("/..") or "/../" in value:
        return None
    return value


def _path_is_within_root(candidate: Path, root: Path) -> bool:
    return candidate == root or root in candidate.parents


def _resolve_existing_path_within_root(
    root: Path,
    candidate: Path,
    *,
    want_dir: bool = False,
    want_file: bool = False,
) -> Optional[Path]:
    if not candidate.exists():
        return None
    root_resolved = root.resolve(strict=False)
    candidate_resolved = candidate.resolve(strict=False)
    if not _path_is_within_root(candidate_resolved, root_resolved):
        return None
    if want_dir and not candidate_resolved.is_dir():
        return None
    if want_file and not candidate_resolved.is_file():
        return None
    return candidate_resolved


def _resolve_config_entrypoint_path(target_dir: Path) -> Optional[Path]:
    config_path = target_dir / "fn.config.json"
    if not config_path.is_file():
        return None
    try:
        with open(config_path, "rb") as f:
            config = json.load(f)
    except Exception:
        return None
    if not isinstance(config, dict):
        return None
    entrypoint = _safe_entrypoint_value(config.get("entrypoint"))
    if not entrypoint:
        return None
    return _resolve_existing_path_within_root(target_dir, target_dir / entrypoint, want_file=True)


def _resolve_handler_path(name: str, version: Any, source_dir: Any = None) -> Path:
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

    source_base = _resolve_source_dir_base(source_dir)

    # Direct file check logic
    if source_base is None and (not version or version == ""):
        # 0. Next-style: Check for direct file with extension (e.g. functions/hello.py)
        # This allows /hello to resolve to functions/hello.py automatically.
        direct_file = FUNCTIONS_DIR / (name + ".py")
        resolved_direct_file = _resolve_existing_path_within_root(FUNCTIONS_DIR, direct_file, want_file=True)
        if resolved_direct_file is not None:
            return resolved_direct_file

        # 1. From root (e.g. handlers/create.py)
        root_check = FUNCTIONS_DIR / name
        resolved_root_check = _resolve_existing_path_within_root(FUNCTIONS_DIR, root_check, want_file=True)
        if resolved_root_check is not None:
            return resolved_root_check

        # 2. From runtime dir (e.g. python/create.py)
        runtime_check = RUNTIME_FUNCTIONS_DIR / name
        resolved_runtime_check = _resolve_existing_path_within_root(RUNTIME_FUNCTIONS_DIR, runtime_check, want_file=True)
        if resolved_runtime_check is not None:
            return resolved_runtime_check

    if source_base is not None:
        base = source_base
    else:
        base = _resolve_existing_path_within_root(FUNCTIONS_DIR, FUNCTIONS_DIR / name, want_dir=True)

        # Try falling back to RUNTIME_FUNCTIONS_DIR structure
        if base is None:
            base = _resolve_existing_path_within_root(RUNTIME_FUNCTIONS_DIR, RUNTIME_FUNCTIONS_DIR / name, want_dir=True)

    target_dir = base
    if version is not None and version != "":
        if not isinstance(version, str) or not _VERSION_RE.match(version):
            raise ValueError("invalid function version")
        if target_dir is None:
            raise FileNotFoundError("unknown function")
        target_dir = _resolve_existing_path_within_root(target_dir, target_dir / version, want_dir=True)
    if target_dir is None:
        raise FileNotFoundError("unknown function")
    
    # 1. Check fn.config.json for explicit entrypoint
    explicit_path = _resolve_config_entrypoint_path(target_dir)
    if explicit_path is not None:
        return explicit_path

    # Order: handler.py -> main.py
    candidates = ["handler.py", "main.py"]
    
    for fname in candidates:
        candidate_path = _resolve_existing_path_within_root(target_dir, target_dir / fname, want_file=True)
        if candidate_path is not None:
            return candidate_path

    raise FileNotFoundError("unknown function")


def _iter_handler_paths() -> list[Path]:
    out: list[Path] = []
    if not FUNCTIONS_DIR.is_dir():
        return out

    for fn_dir in sorted(FUNCTIONS_DIR.iterdir(), key=lambda p: p.name):
        if not fn_dir.is_dir() or not _NAME_RE.match(fn_dir.name):
            continue
        if _path_is_in_assets_directory(fn_dir):
            continue

        for fname in ("handler.py", "main.py"):
            candidate = fn_dir / fname
            if candidate.is_file():
                out.append(candidate)
                break

        for ver_dir in sorted(fn_dir.iterdir(), key=lambda p: p.name):
            if not ver_dir.is_dir() or not _VERSION_RE.match(ver_dir.name):
                continue
            for fname in ("handler.py", "main.py"):
                candidate = ver_dir / fname
                if candidate.is_file():
                    out.append(candidate)
                    break

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
    # Preserve stdout/stderr from worker subprocess.
    if isinstance(resp, dict):
        if resp.get("stdout"):
            out["stdout"] = resp["stdout"]
        if resp.get("stderr"):
            out["stderr"] = resp["stderr"]
    return out


def _error_response(message: str, status: int = 500) -> Dict[str, Any]:
    return {
        "status": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}, separators=(",", ":")),
    }


# ---------------------------------------------------------------------------
# In-process execution — thread-safe stdout/stderr capture
# ---------------------------------------------------------------------------

class _ThreadLocalCapturingStream:
    """Wraps a real stream; redirects writes to a thread-local buffer when active."""

    def __init__(self, real_stream: Any, attr_name: str) -> None:
        self._real = real_stream
        self._attr = attr_name

    def write(self, s: str) -> int:
        buf = getattr(_capture_tls, self._attr, None)
        if buf is not None:
            buf.write(s)
            return len(s)
        return self._real.write(s)

    def flush(self) -> None:
        self._real.flush()

    def fileno(self) -> int:
        return self._real.fileno()

    def __getattr__(self, name: str) -> Any:
        return getattr(self._real, name)


@contextmanager
def _capture_output():
    _capture_tls.stdout_buf = io.StringIO()
    _capture_tls.stderr_buf = io.StringIO()
    try:
        yield _capture_tls.stdout_buf, _capture_tls.stderr_buf
    finally:
        _capture_tls.stdout_buf = None
        _capture_tls.stderr_buf = None


def _install_capture_streams() -> None:
    """Replace sys.stdout/stderr once with thread-local-aware wrappers."""
    if isinstance(sys.stdout, _ThreadLocalCapturingStream):
        return
    sys.stdout = _ThreadLocalCapturingStream(sys.__stdout__, "stdout_buf")  # type: ignore[assignment]
    sys.stderr = _ThreadLocalCapturingStream(sys.__stderr__, "stderr_buf")  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# In-process execution — thread-safe per-request env override
# ---------------------------------------------------------------------------

class _EnvOverrideProxy:
    """Proxy over os.environ that applies thread-local overrides transparently."""

    def __init__(self, real: Any) -> None:
        object.__setattr__(self, "_real", real)

    def _get_overrides(self) -> Optional[Dict[str, Optional[str]]]:
        return getattr(_env_tls, "env_overrides", None)

    def __contains__(self, key: object) -> bool:
        overrides = self._get_overrides()
        if overrides is not None and isinstance(key, str) and key in overrides:
            return overrides[key] is not None
        return key in self._real

    def __getitem__(self, key: str) -> str:
        overrides = self._get_overrides()
        if overrides is not None and key in overrides:
            val = overrides[key]
            if val is None:
                raise KeyError(key)
            return val
        return self._real[key]

    def __setitem__(self, key: str, value: str) -> None:
        self._real[key] = value

    def __delitem__(self, key: str) -> None:
        del self._real[key]

    def get(self, key: str, default: Any = None) -> Any:
        try:
            return self[key]
        except KeyError:
            return default

    def __iter__(self):
        overrides = self._get_overrides()
        if overrides is None:
            yield from self._real
            return
        seen: set[str] = set()
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

    def __len__(self) -> int:
        return sum(1 for _ in self)

    def pop(self, key: str, *args: Any) -> Any:
        return self._real.pop(key, *args)

    def copy(self) -> Dict[str, str]:
        result = self._real.copy()
        overrides = self._get_overrides()
        if overrides:
            for k, v in overrides.items():
                if v is None:
                    result.pop(k, None)
                else:
                    result[k] = v
        return result

    def __getattr__(self, name: str) -> Any:
        return getattr(self._real, name)


@contextmanager
def _patched_process_env(event: Dict[str, Any]):
    env = event.get("env") if isinstance(event.get("env"), dict) else {}
    if not env:
        yield
        return
    overrides: Dict[str, Optional[str]] = {}
    for raw_key, raw_value in env.items():
        if not isinstance(raw_key, str) or raw_key == "":
            continue
        overrides[raw_key] = None if raw_value is None else str(raw_value)
    _env_tls.env_overrides = overrides
    try:
        yield
    finally:
        _env_tls.env_overrides = None


def _install_env_proxy() -> None:
    """Install the thread-local env proxy over os.environ once."""
    if not isinstance(os.environ, _EnvOverrideProxy):
        os.environ = _EnvOverrideProxy(os.environ)  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# In-process execution — thread-safe strict FS guard
# ---------------------------------------------------------------------------

def _active_strict_policy() -> Optional[Dict[str, Any]]:
    return getattr(_strict_fs_tls, "policy", None)


def _install_strict_fs_hooks() -> None:
    """Patch builtins/os/subprocess ONCE with thread-local-aware guards."""
    global _strict_fs_hooks_installed
    with _strict_fs_install_lock:
        if _strict_fs_hooks_installed:
            return
        _strict_fs_hooks_installed = True

    orig_open = builtins.open
    orig_io_open = io.open
    orig_os_open = os.open
    orig_listdir = os.listdir
    orig_scandir = os.scandir
    orig_system = os.system
    orig_path_open = Path.open
    orig_subprocess_run = _REAL_SUBPROCESS_RUN
    orig_subprocess_call = subprocess.call
    orig_subprocess_check_call = subprocess.check_call
    orig_subprocess_check_output = subprocess.check_output
    orig_subprocess_popen = subprocess.Popen

    def _check_path(target: Any) -> None:
        policy = _active_strict_policy()
        if policy is None:
            return
        candidate = _resolve_candidate_path(target)
        if candidate is None:
            return
        allowed_roots = policy["allowed_roots"]
        fn_dir = policy["fn_dir"]
        ok, reason = _path_allowed(candidate, allowed_roots, fn_dir)
        if not ok:
            raise PermissionError(reason + ": " + str(candidate))

    def guarded_open(file: Any, *args: Any, **kwargs: Any) -> Any:
        _check_path(file)
        return orig_open(file, *args, **kwargs)

    def guarded_io_open(file: Any, *args: Any, **kwargs: Any) -> Any:
        _check_path(file)
        return orig_io_open(file, *args, **kwargs)

    def guarded_os_open(file: Any, *args: Any, **kwargs: Any) -> Any:
        _check_path(file)
        return orig_os_open(file, *args, **kwargs)

    def guarded_listdir(path: Any = ".") -> Any:
        _check_path(path)
        return orig_listdir(path)

    def guarded_scandir(path: Any = ".") -> Any:
        _check_path(path)
        return orig_scandir(path)

    def guarded_path_open(self: Any, *args: Any, **kwargs: Any) -> Any:
        _check_path(self)
        return orig_path_open(self, *args, **kwargs)

    def blocked_subprocess(*_args: Any, **_kwargs: Any) -> Any:
        policy = _active_strict_policy()
        if policy is None:
            return orig_subprocess_run(*_args, **_kwargs)
        raise PermissionError("subprocess disabled by strict function sandbox")

    def blocked_subprocess_call(*_args: Any, **_kwargs: Any) -> Any:
        policy = _active_strict_policy()
        if policy is None:
            return orig_subprocess_call(*_args, **_kwargs)
        raise PermissionError("subprocess disabled by strict function sandbox")

    def blocked_subprocess_check_call(*_args: Any, **_kwargs: Any) -> Any:
        policy = _active_strict_policy()
        if policy is None:
            return orig_subprocess_check_call(*_args, **_kwargs)
        raise PermissionError("subprocess disabled by strict function sandbox")

    def blocked_subprocess_check_output(*_args: Any, **_kwargs: Any) -> Any:
        policy = _active_strict_policy()
        if policy is None:
            return orig_subprocess_check_output(*_args, **_kwargs)
        raise PermissionError("subprocess disabled by strict function sandbox")

    def blocked_subprocess_popen(*_args: Any, **_kwargs: Any) -> Any:
        policy = _active_strict_policy()
        if policy is None:
            return orig_subprocess_popen(*_args, **_kwargs)
        raise PermissionError("subprocess disabled by strict function sandbox")

    def blocked_system(*_args: Any, **_kwargs: Any) -> Any:
        policy = _active_strict_policy()
        if policy is None:
            return orig_system(*_args, **_kwargs)
        raise PermissionError("os.system disabled by strict function sandbox")

    builtins.open = guarded_open  # type: ignore[assignment]
    io.open = guarded_io_open  # type: ignore[assignment]
    os.open = guarded_os_open  # type: ignore[assignment]
    os.listdir = guarded_listdir  # type: ignore[assignment]
    os.scandir = guarded_scandir  # type: ignore[assignment]
    os.system = blocked_system  # type: ignore[assignment]
    subprocess.run = blocked_subprocess  # type: ignore[assignment]
    subprocess.call = blocked_subprocess_call  # type: ignore[assignment]
    subprocess.check_call = blocked_subprocess_check_call  # type: ignore[assignment]
    subprocess.check_output = blocked_subprocess_check_output  # type: ignore[assignment]
    subprocess.Popen = blocked_subprocess_popen  # type: ignore[assignment]
    Path.open = guarded_path_open  # type: ignore[assignment]


@contextmanager
def _inprocess_strict_fs(handler_path: Path, extra_roots: Optional[list[Path]] = None):
    if not STRICT_FS:
        yield
        return
    _install_strict_fs_hooks()
    allowed_roots, fn_dir = _build_allowed_roots(handler_path, extra_roots=extra_roots)
    _strict_fs_tls.policy = {"allowed_roots": allowed_roots, "fn_dir": fn_dir}
    try:
        yield
    finally:
        _strict_fs_tls.policy = None


# ---------------------------------------------------------------------------
# In-process execution — adapter support (ported from python-function-worker)
# ---------------------------------------------------------------------------

def _ip_header_value(headers: Dict[str, Any], name: str) -> str:
    target = name.lower()
    for k, v in headers.items():
        if str(k).lower() == target:
            return str(v)
    return ""


def _ip_build_raw_path(event: Dict[str, Any]) -> str:
    raw = event.get("raw_path") if isinstance(event.get("raw_path"), str) else event.get("path")
    if not isinstance(raw, str) or not raw:
        return "/"
    if raw.startswith("http://") or raw.startswith("https://"):
        return raw
    if raw.startswith("/"):
        return raw
    return "/" + raw


def _ip_encode_query_string(query: Any) -> str:
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


def _ip_build_raw_query(event: Dict[str, Any]) -> str:
    raw_path = event.get("raw_path")
    if isinstance(raw_path, str):
        idx = raw_path.find("?")
        if idx >= 0 and idx < len(raw_path) - 1:
            return raw_path[idx + 1:]
    return _ip_encode_query_string(event.get("query"))


def _ip_build_lambda_event(event: Dict[str, Any]) -> Dict[str, Any]:
    headers = event.get("headers") if isinstance(event.get("headers"), dict) else {}
    headers = {str(k): str(v) for k, v in headers.items()}
    raw_path_q = _ip_build_raw_path(event)
    q_idx = raw_path_q.find("?")
    raw_path = raw_path_q[:q_idx] if q_idx >= 0 else raw_path_q
    raw_query = _ip_build_raw_query(event)
    query = event.get("query") if isinstance(event.get("query"), dict) else None
    params = event.get("params") if isinstance(event.get("params"), dict) else None
    cookie_header = _ip_header_value(headers, "cookie")
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


class _IPLambdaContext:
    def __init__(self, event: Dict[str, Any]) -> None:
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

    def done(self, *_a: Any, **_k: Any) -> None:
        return None

    def fail(self, *_a: Any, **_k: Any) -> None:
        return None

    def succeed(self, *_a: Any, **_k: Any) -> None:
        return None


def _ip_build_workers_url(event: Dict[str, Any]) -> str:
    raw_path = _ip_build_raw_path(event)
    if raw_path.startswith("http://") or raw_path.startswith("https://"):
        return raw_path
    headers = event.get("headers") if isinstance(event.get("headers"), dict) else {}
    proto = _ip_header_value({str(k): str(v) for k, v in headers.items()}, "x-forwarded-proto") or "http"
    host = _ip_header_value({str(k): str(v) for k, v in headers.items()}, "host") or "127.0.0.1"
    return f"{proto}://{host}{raw_path}"


class _IPWorkersRequest:
    def __init__(self, event: Dict[str, Any]) -> None:
        self.method = str(event.get("method") or "GET").upper()
        headers_raw = event.get("headers") if isinstance(event.get("headers"), dict) else {}
        self.headers = {str(k): str(v) for k, v in headers_raw.items()}
        self.url = _ip_build_workers_url(event)
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

    async def json(self) -> Any:
        raw = await self.text()
        if not raw:
            return None
        return json.loads(raw)


class _IPWorkersContext:
    def __init__(self, event: Dict[str, Any]) -> None:
        context = event.get("context") if isinstance(event.get("context"), dict) else {}
        self.request_id = str(context.get("request_id") or event.get("id") or "")
        self._waitables: list[Any] = []

    def waitUntil(self, awaitable: Any) -> None:
        return self.wait_until(awaitable)

    def wait_until(self, awaitable: Any) -> None:
        if inspect.isawaitable(awaitable):
            _schedule_background_waitables([awaitable], self.request_id)

    def passThroughOnException(self) -> None:
        return None

    def pass_through_on_exception(self) -> None:
        return None


# ---------------------------------------------------------------------------
# In-process execution — handler loading, invocation, and dispatch
# ---------------------------------------------------------------------------

def _ip_resolve_handler(mod: Any, handler_name: str, invoke_adapter: str) -> Any:
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


def _ip_call_handler(handler: Any, args: list[Any], route_params: Optional[Dict[str, Any]] = None) -> Any:
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
        if route_params and argc >= 1:
            has_var_keyword = any(p.kind == inspect.Parameter.VAR_KEYWORD for p in params)
            keyword_only = [p for p in params if p.kind == inspect.Parameter.KEYWORD_ONLY]
            if has_var_keyword:
                return handler(args[0], **route_params)
            injectable: Dict[str, Any] = {}
            for p in positional[1:]:
                if p.name in route_params:
                    injectable[p.name] = route_params[p.name]
            for p in keyword_only:
                if p.name in route_params:
                    injectable[p.name] = route_params[p.name]
            if injectable:
                return handler(args[0], **injectable)
        return handler(*args[:min(argc, len(args))])
    except Exception:
        return handler(*args)


def _ip_resolve_awaitable(value: Any) -> Any:
    if not inspect.isawaitable(value):
        return value
    try:
        return asyncio.run(value)
    except RuntimeError as exc:
        message = str(exc).lower()
        if "running event loop" not in message and "no current" not in message:
            raise
        loop = asyncio.new_event_loop()
        try:
            return loop.run_until_complete(value)
        finally:
            loop.close()


def _close_waitable(awaitable: Any) -> None:
    close_fn = getattr(awaitable, "close", None)
    if callable(close_fn):
        try:
            close_fn()
        except Exception:
            return


def _run_waitable_in_background(waitable: Any, request_id: str) -> None:
    try:
        _ip_resolve_awaitable(waitable)
    except Exception as exc:
        _json_log("wait_until_rejection", request_id=request_id, error=str(exc))


def _schedule_background_waitables(waitables: list[Any], request_id: str) -> None:
    for waitable in waitables:
        try:
            thread = threading.Thread(
                target=_run_waitable_in_background,
                args=(waitable, request_id),
                daemon=True,
            )
            thread.start()
        except Exception as exc:
            _close_waitable(waitable)
            _json_log("wait_until_schedule_error", request_id=request_id, error=str(exc))


def _ip_invoke_handler(handler: Any, invoke_adapter: str, event: Dict[str, Any]) -> Any:
    with _patched_process_env(event):
        if invoke_adapter == _INVOKE_ADAPTER_AWS_LAMBDA:
            lambda_event = _ip_build_lambda_event(event)
            lambda_context = _IPLambdaContext(event)
            return _ip_resolve_awaitable(_ip_call_handler(handler, [lambda_event, lambda_context]))
        if invoke_adapter == _INVOKE_ADAPTER_CLOUDFLARE_WORKER:
            req = _IPWorkersRequest(event)
            env = event.get("env") if isinstance(event.get("env"), dict) else {}
            ctx = _IPWorkersContext(event)
            return _ip_resolve_awaitable(_ip_call_handler(handler, [req, env, ctx]))
        route_params = event.get("params") if isinstance(event.get("params"), dict) else {}
        return _ip_resolve_awaitable(_ip_call_handler(handler, [event], route_params=route_params))


def _ip_normalize_response_like_object(resp: Any) -> Dict[str, Any]:
    status = getattr(resp, "status", 200)
    headers = getattr(resp, "headers", {})
    body = getattr(resp, "body", "")
    out_headers = dict(headers) if isinstance(headers, dict) else {}
    out: Dict[str, Any] = {"status": int(status) if isinstance(status, int) else 200, "headers": out_headers}
    if isinstance(body, (bytes, bytearray)):
        out["is_base64"] = True
        out["body_base64"] = base64.b64encode(bytes(body)).decode("utf-8")
        return out
    if body is None:
        body = ""
    out["body"] = body if isinstance(body, str) else str(body)
    return out


# Per-function module snapshots for deps isolation.
# Key: deps_dirs tuple -> {module_name: module} snapshot of modules loaded from those dirs.
_DEPS_MODULE_SNAPSHOTS: Dict[tuple, Dict[str, Any]] = {}


def _is_module_from_dirs(mod: Any, dirs: list[str]) -> bool:
    """Check if a module was loaded from any of the given directories."""
    origin = getattr(mod, "__file__", None) or getattr(getattr(mod, "__spec__", None), "origin", None)
    if not isinstance(origin, str):
        return False
    for d in dirs:
        if origin.startswith(d):
            return True
    return False


def _collect_all_deps_dirs() -> set[str]:
    """Collect all .deps directories known to the cache."""
    all_dirs: set[str] = set()
    for entry in _INPROCESS_CACHE.values():
        for d in entry.get("deps_dirs", []):
            all_dirs.add(d)
    return all_dirs


def _load_handler_inprocess(
    handler_path: str, handler_name: str, deps_dirs: list[str], invoke_adapter: str,
) -> Any:
    mtime_ns = os.stat(handler_path).st_mtime_ns
    cache_key = f"{handler_path}::{handler_name}::{invoke_adapter}"

    cached = _INPROCESS_CACHE.get(cache_key)
    if cached is not None:
        if not HOT_RELOAD or cached["mtime_ns"] == mtime_ns:
            return cached["handler"]

    with _IMPORT_LOCK:
        cached = _INPROCESS_CACHE.get(cache_key)
        if cached is not None:
            if not HOT_RELOAD or cached["mtime_ns"] == mtime_ns:
                return cached["handler"]

        deps_key = tuple(sorted(deps_dirs))

        # --- sys.modules isolation ---
        # 1. Save modules loaded from ANY .deps/ dir (other functions' deps)
        other_deps_dirs = [d for d in _collect_all_deps_dirs() if d not in deps_dirs]
        evicted: Dict[str, Any] = {}
        if other_deps_dirs:
            for name, mod in list(sys.modules.items()):
                if mod is not None and _is_module_from_dirs(mod, other_deps_dirs):
                    evicted[name] = mod

        # 2. Evict other functions' deps modules from sys.modules
        for name in evicted:
            del sys.modules[name]

        # 3. Restore THIS function's deps modules from snapshot (if any)
        saved_snapshot = _DEPS_MODULE_SNAPSHOTS.get(deps_key, {})
        for name, mod in saved_snapshot.items():
            sys.modules[name] = mod

        original_path = sys.path[:]
        handler_dir = str(Path(handler_path).parent)
        paths_to_add = []
        if handler_dir not in sys.path:
            paths_to_add.append(handler_dir)
        for d in deps_dirs:
            if d not in sys.path:
                paths_to_add.append(d)
        for p in reversed(paths_to_add):
            sys.path.insert(0, p)
        try:
            module_name = f"fn_inproc_{abs(hash(cache_key))}_{mtime_ns}"
            spec = importlib.util.spec_from_file_location(module_name, handler_path)
            if spec is None or spec.loader is None:
                raise RuntimeError("failed to load handler spec")
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)  # type: ignore[attr-defined]
            handler = _ip_resolve_handler(mod, handler_name, invoke_adapter)
        finally:
            # 4. Snapshot THIS function's deps modules for future restores
            if deps_dirs:
                new_snapshot: Dict[str, Any] = {}
                for name, m in sys.modules.items():
                    if m is not None and _is_module_from_dirs(m, deps_dirs):
                        new_snapshot[name] = m
                _DEPS_MODULE_SNAPSHOTS[deps_key] = new_snapshot

            # 5. Restore evicted modules back
            for name, m in evicted.items():
                if name not in sys.modules:
                    sys.modules[name] = m

            sys.path[:] = original_path

        _INPROCESS_CACHE[cache_key] = {
            "handler": handler, "mtime_ns": mtime_ns, "deps_dirs": deps_dirs,
        }
        return handler


_inprocess_initialized = False
_inprocess_init_lock = threading.Lock()


def _ensure_inprocess_init() -> None:
    global _inprocess_initialized
    if _inprocess_initialized:
        return
    with _inprocess_init_lock:
        if _inprocess_initialized:
            return
        _install_capture_streams()
        _install_env_proxy()
        _inprocess_initialized = True


def _handle_request_inprocess(
    handler_path: Path,
    handler_name: str,
    deps_dirs: list[str],
    event: Dict[str, Any],
    invoke_adapter: str,
) -> Dict[str, Any]:
    _ensure_inprocess_init()
    fn_env = _read_function_env(handler_path)
    event_with_env = dict(event)
    incoming_env = event_with_env.get("env")
    merged_env = dict(incoming_env) if isinstance(incoming_env, dict) else {}
    for k, v in fn_env.items():
        merged_env[k] = v
    if merged_env:
        event_with_env["env"] = merged_env

    handler = _load_handler_inprocess(str(handler_path), handler_name, deps_dirs, invoke_adapter)

    # Keep deps_dirs and handler dir in sys.path during execution so that
    # lazy imports inside the handler (e.g. `import requests`) can resolve.
    # Also swap sys.modules to this function's snapshot so other functions'
    # deps don't leak (e.g. py-no-deps must NOT see py-with-deps' requests).
    handler_dir = str(handler_path.parent)
    paths_to_add = []
    if handler_dir not in sys.path:
        paths_to_add.append(handler_dir)
    for d in deps_dirs:
        if d not in sys.path:
            paths_to_add.append(d)

    deps_key = tuple(sorted(deps_dirs))
    other_deps_dirs = [d for d in _collect_all_deps_dirs() if d not in deps_dirs]
    evicted: Dict[str, Any] = {}
    if other_deps_dirs:
        for name, mod in list(sys.modules.items()):
            if mod is not None and _is_module_from_dirs(mod, other_deps_dirs):
                evicted[name] = mod
        for name in evicted:
            del sys.modules[name]
    saved_snapshot = _DEPS_MODULE_SNAPSHOTS.get(deps_key, {})
    for name, mod in saved_snapshot.items():
        sys.modules[name] = mod

    for p in reversed(paths_to_add):
        sys.path.insert(0, p)

    extra_roots = [Path(d) for d in deps_dirs]
    try:
        with _inprocess_strict_fs(handler_path, extra_roots):
            with _capture_output() as (out_buf, err_buf):
                resp = _ip_invoke_handler(handler, invoke_adapter, event_with_env)
    finally:
        # Snapshot this function's deps modules after execution.
        if deps_dirs:
            new_snapshot: Dict[str, Any] = {}
            for name, m in sys.modules.items():
                if m is not None and _is_module_from_dirs(m, deps_dirs):
                    new_snapshot[name] = m
            _DEPS_MODULE_SNAPSHOTS[deps_key] = new_snapshot
        # Restore evicted modules.
        for name, m in evicted.items():
            if name not in sys.modules:
                sys.modules[name] = m
        # Remove modules from OTHER functions that leaked during execution.
        if other_deps_dirs:
            for name, mod in list(sys.modules.items()):
                if mod is not None and _is_module_from_dirs(mod, other_deps_dirs):
                    if name not in evicted:
                        del sys.modules[name]
        for p in paths_to_add:
            try:
                sys.path.remove(p)
            except ValueError:
                pass

    # Handle response-like objects (e.g. objects with .status, .headers, .body).
    if not isinstance(resp, (dict, tuple)) and any(hasattr(resp, k) for k in ("status", "headers", "body")):
        resp = _ip_normalize_response_like_object(resp)

    result = _normalize_response(resp)
    stdout_str = out_buf.getvalue()
    stderr_str = err_buf.getvalue()
    if stdout_str:
        result["stdout"] = stdout_str
    if stderr_str:
        result["stderr"] = stderr_str
    return result


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
            _append_runtime_log("python", log_line)

    stderr_value = resp.get("stderr")
    if isinstance(stderr_value, str) and stderr_value != "":
        for line in stderr_value.splitlines():
            log_line = f"[fn:{label}@{version_label} stderr] {line}"
            print(log_line, file=sys.stderr, flush=True)
            _append_runtime_log("python", log_line)


def _append_runtime_log(runtime_name: str, line: str) -> None:
    if not RUNTIME_LOG_FILE:
        return
    try:
        parent = Path(RUNTIME_LOG_FILE).parent
        parent.mkdir(parents=True, exist_ok=True)
        with open(RUNTIME_LOG_FILE, "a", encoding="utf-8") as handle:
            handle.write(f"[{runtime_name}] {line}\n")
    except Exception:  # pragma: no cover
        return


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

    def __init__(self, key: str, handler_path: Path, deps_dirs: list[str]):  # pragma: no cover
        self.key = key
        self.lock = threading.Lock()
        self._dead = False
        env = _sanitize_worker_env(os.environ.copy())
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

    def send_request(self, payload_bytes: bytes, timeout_s: float) -> Dict[str, Any]:  # pragma: no cover
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

    def _read_exact(self, fd: int, n: int, timeout_s: float) -> Optional[bytes]:  # pragma: no cover
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

    def _mark_dead(self) -> None:  # pragma: no cover
        self._dead = True
        try:
            self.proc.kill()
        except Exception:
            pass

    def shutdown(self) -> None:  # pragma: no cover
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


def _worker_pool_key(
    handler_path: Path,
    handler_name: str,
    deps_dirs: list[str],
    invoke_adapter: str = _INVOKE_ADAPTER_NATIVE,
) -> str:
    return f"{handler_path}::{handler_name}::{invoke_adapter}::{','.join(sorted(deps_dirs))}"


def _get_or_create_worker(  # pragma: no cover
    handler_path: Path,
    handler_name: str,
    deps_dirs: list[str],
    invoke_adapter: str = _INVOKE_ADAPTER_NATIVE,
) -> _PersistentWorker:
    key = _worker_pool_key(handler_path, handler_name, deps_dirs, invoke_adapter)
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


def _run_in_subprocess(  # pragma: no cover
    handler_path: Path,
    handler_name: str,
    deps_dirs: list[str],
    event: Dict[str, Any],
    timeout_s: float,
    invoke_adapter: str = _INVOKE_ADAPTER_NATIVE,
    version: Any = None,
) -> Dict[str, Any]:
    """Execute a handler in a persistent isolated worker subprocess."""
    fn_env = _read_function_env(handler_path)
    event_with_env = _with_event_runtime_metadata(event, version)
    incoming_env = event_with_env.get("env")
    merged_env = dict(incoming_env) if isinstance(incoming_env, dict) else {}
    for k, v in fn_env.items():
        merged_env[k] = v
    if merged_env:
        event_with_env["env"] = merged_env

    payload = json.dumps({
        "handler_path": str(handler_path),
        "handler_name": handler_name,
        "invoke_adapter": invoke_adapter,
        "deps_dirs": deps_dirs,
        "event": event_with_env,
    }, separators=(",", ":"), ensure_ascii=False).encode("utf-8")

    # Try the persistent worker first; if it dies, evict it and retry once
    # with a fresh persistent worker. Do not fall back to one-shot execution.
    for attempt in range(2):
        try:
            worker = _get_or_create_worker(handler_path, handler_name, deps_dirs, invoke_adapter)
            return worker.send_request(payload, timeout_s)
        except TimeoutError:
            return _error_response("python handler timeout", status=504)
        except Exception:
            # Worker died — evict and retry once with a fresh worker.
            key = _worker_pool_key(handler_path, handler_name, deps_dirs, invoke_adapter)
            with _SUBPROCESS_POOL_LOCK:
                dead = _SUBPROCESS_POOL.pop(key, None)
                if dead is not None:
                    try:
                        dead.shutdown()
                    except Exception:
                        pass
            if attempt == 1:
                return _error_response("persistent worker restart failed", status=503)

    return _error_response("worker pool exhausted", status=500)


def _run_in_subprocess_oneshot(
    handler_path: Path,
    handler_name: str,
    deps_dirs: list[str],
    event: Dict[str, Any],
    timeout_s: float,
    invoke_adapter: str = _INVOKE_ADAPTER_NATIVE,
) -> Dict[str, Any]:
    """Fallback: one-shot subprocess execution (original model)."""
    payload = json.dumps({
        "handler_path": str(handler_path),
        "handler_name": handler_name,
        "invoke_adapter": invoke_adapter,
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
    event_with_metadata = _with_event_runtime_metadata(event, version)

    path = _resolve_handler_path(fn_name, version, req.get("fn_source_dir"))
    fn_config = _read_function_config(path)
    handler_name = _resolve_handler_name(fn_config)
    invoke_adapter = _resolve_invoke_adapter(fn_config)
    shared_deps = _extract_shared_deps(fn_config)

    # Install deps (idempotent, cached by mtime signature).
    shared_roots: list[Path] = []
    for pack in shared_deps:
        pack_dir = _resolve_shared_pack_dir(pack)
        deps_root = _ensure_pack_requirements(pack_dir)
        if deps_root is not None:
            shared_roots.append(deps_root)
    _ensure_requirements(path)

    # Determine timeout from request context.
    timeout_ms = int(req.get("timeout_ms") or 0)
    timeout_s = max(5.0, timeout_ms / 1000.0) if timeout_ms > 0 else 30.0

    deps_dirs: list[str] = []
    fn_deps = path.parent / ".deps"
    if fn_deps.is_dir():
        deps_dirs.append(str(fn_deps.resolve(strict=False)))
    for root in shared_roots:
        deps_dirs.append(str(root))

    return _handle_request_inprocess(path, handler_name, deps_dirs, event_with_metadata, invoke_adapter)


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
        # Not connectable: stale socket path from a previous crash/run.
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
    _install_capture_streams()
    _install_env_proxy()
    _ensure_socket_dir(SOCKET_PATH)
    _preinstall_requirements_on_start()

    _prepare_socket_path(SOCKET_PATH)

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o666)
        server.listen(128)

        while True:
            conn, _ = server.accept()
            threading.Thread(target=_serve_conn, args=(conn,), daemon=True).start()


if __name__ == "__main__":  # pragma: no cover
    main()
