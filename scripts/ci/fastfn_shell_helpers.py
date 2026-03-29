#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import socket
import sys
from pathlib import Path
from typing import Any


REQUIRED_INTERNAL_PATHS = [
    "/_fn/function",
    "/_fn/function-config",
    "/_fn/function-env",
    "/_fn/function-code",
    "/_fn/invoke",
    "/_fn/jobs",
    "/_fn/jobs/{id}/result",
    "/_fn/logs",
    "/_fn/ui-state",
]


def fail(message: str) -> None:
    raise SystemExit(message)


def load_text(file_path: str | None = None, raw: str | None = None, stdin_default: bool = False) -> str:
    if raw is not None:
        return raw
    if file_path:
        return Path(file_path).read_text(encoding="utf-8")
    if stdin_default:
        return sys.stdin.read()
    fail("missing JSON input")


def load_json(file_path: str | None = None, raw: str | None = None, stdin_default: bool = False) -> Any:
    text = load_text(file_path=file_path, raw=raw, stdin_default=stdin_default)
    return json.loads(text or "{}")


def get_param(params: Any, name: str) -> dict[str, Any] | None:
    for param in params or []:
        if isinstance(param, dict) and param.get("name") == name:
            return param
    return None


def route_to_openapi_path(route: str | None) -> str | None:
    raw = str(route or "")
    if raw == "":
        return None
    if raw == "/":
        return "/"
    out: list[str] = []
    used: set[str] = set()
    for seg in [segment for segment in raw.split("/") if segment]:
        if seg.startswith(":"):
            name = seg[1:]
            if name.endswith("*"):
                name = name[:-1]
            if not name:
                name = "wildcard"
            out.append("{" + name + "}")
            used.add(name)
            continue
        if seg == "*":
            name = "wildcard"
            i = 2
            while name in used:
                name = f"wildcard{i}"
                i += 1
            used.add(name)
            out.append("{" + name + "}")
            continue
        out.append(seg)
    return "/" + "/".join(out) if out else "/"


def iter_runtime_function_names(functions: Any) -> set[str]:
    if isinstance(functions, dict):
        return {str(name) for name in functions.keys()}
    if isinstance(functions, list):
        names = set()
        for item in functions:
            if isinstance(item, dict) and item.get("name"):
                names.add(str(item["name"]))
        return names
    return set()


def normalize_header_map(headers: Any) -> dict[str, Any]:
    if not isinstance(headers, dict):
        return {}
    return {str(k).lower(): v for k, v in headers.items()}


def command_pick_free_port(_: argparse.Namespace) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    try:
        print(sock.getsockname()[1])
    finally:
        sock.close()


def command_health_all_up(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    runtimes = obj.get("runtimes", {})
    runtime_order = obj.get("runtime_order")
    if isinstance(runtime_order, list) and runtime_order:
        required = [str(item) for item in runtime_order if isinstance(item, str) and item.strip()]
    else:
        required = [str(item) for item in runtimes.keys() if isinstance(item, str)]
    if not required:
        raise SystemExit(1)
    for name in required:
        if (((runtimes.get(name) or {}).get("health") or {}).get("up")) is not True:
            raise SystemExit(1)


def command_health_runtime_up(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    runtime = ((obj.get("runtimes") or {}).get(args.runtime) or {})
    health = runtime.get("health") or {}
    raise SystemExit(0 if health.get("up") is True else 1)


def command_health_missing_runtimes(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    runtimes = obj.get("runtimes") or {}
    for name in args.runtimes:
        if name in runtimes:
            fail(f"{name} should be absent from runtimes")


def command_health_daemon_stack_ready(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    runtimes = obj.get("runtimes") or {}
    for name in [part.strip() for part in args.runtimes.split(",") if part.strip()]:
        entry = runtimes.get(name) or {}
        health = entry.get("health") or {}
        if health.get("up") is not True:
            raise SystemExit(1)
        sockets = entry.get("sockets") or []
        if len(sockets) < args.min_sockets:
            raise SystemExit(1)


def command_catalog_signature(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    mapped = obj.get("mapped_routes")
    runtimes = obj.get("runtimes")
    if not isinstance(mapped, dict) or not isinstance(runtimes, dict) or not runtimes:
        raise SystemExit(1)
    fn_total = 0
    for entry in runtimes.values():
        if not isinstance(entry, dict):
            continue
        fns = entry.get("functions")
        if isinstance(fns, list):
            fn_total += len(fns)
        elif isinstance(fns, dict):
            fn_total += len(fns)
    print(f"{len(mapped)}:{fn_total}")


def command_catalog_has_function(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    rt = (obj.get("runtimes") or {}).get(args.runtime) or {}
    functions = rt.get("functions")
    names = iter_runtime_function_names(functions)
    raise SystemExit(0 if args.name in names else 1)


def command_catalog_has_functions(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    rt = (obj.get("runtimes") or {}).get(args.runtime) or {}
    names = iter_runtime_function_names(rt.get("functions"))
    missing = [name for name in args.names if name not in names]
    if missing:
        fail(f"missing functions in catalog: {missing}")


def command_catalog_route_no_conflicts(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    mapped = obj.get("mapped_routes") or {}
    route = args.route
    entries = mapped.get(route) or []
    if isinstance(entries, dict):
        entries = [entries]
    if not isinstance(entries, list) or len(entries) < args.min_entries:
        fail(f"route {route} missing expected entries")
    conflicts = obj.get("mapped_route_conflicts") or {}
    if route in conflicts:
        fail(f"route {route} should not have conflicts")


def command_extract_json_field(args: argparse.Namespace) -> None:
    obj = load_json(raw=args.json, stdin_default=args.stdin)
    cur: Any = obj
    for part in args.field.split("."):
        if isinstance(cur, dict):
            cur = cur.get(part)
        else:
            cur = None
            break
    if cur is None:
        raise SystemExit(1)
    if isinstance(cur, (dict, list)):
        print(json.dumps(cur))
    else:
        print(cur)


def command_hmac_sha256(args: argparse.Namespace) -> None:
    secret = args.secret.encode("utf-8")
    body = args.body.encode("utf-8")
    print("sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest())


def command_remove_json_key(args: argparse.Namespace) -> None:
    path = Path(args.file)
    obj = json.loads(path.read_text(encoding="utf-8"))
    cur: Any = obj
    parts = args.key.split(".")
    for part in parts[:-1]:
        if not isinstance(cur, dict):
            fail(f"cannot descend into non-object for key path {args.key}")
        cur = cur.get(part)
        if cur is None:
            path.write_text(json.dumps(obj, indent=2) + "\n", encoding="utf-8")
            return
    if isinstance(cur, dict):
        cur.pop(parts[-1], None)
    path.write_text(json.dumps(obj, indent=2) + "\n", encoding="utf-8")


def command_seconds_to_ms(args: argparse.Namespace) -> None:
    print(int(float(args.value) * 1000))


def command_dependency_resolution_error(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    dep = ((obj.get("metadata") or {}).get("dependency_resolution") or {})
    if dep.get("runtime") != args.runtime:
        fail(f"unexpected runtime in dependency_resolution: {dep}")
    if dep.get("last_install_status") != "error":
        fail(f"dependency resolution did not fail: {dep}")
    err = str(dep.get("last_error") or "")
    if args.expected.lower() not in err.lower():
        fail(err)


def command_runtime_socket_path(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    sockets = (((obj.get("runtimes") or {}).get(args.runtime) or {}).get("sockets") or [])
    for item in sockets:
        if int(item.get("index") or 0) == args.index:
            uri = str(item.get("uri") or "")
            print(uri[5:] if uri.startswith("unix:") else uri)
            return
    fail(f"missing socket index {args.index} for runtime {args.runtime}")


def command_runtime_degraded(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    entry = ((obj.get("runtimes") or {}).get(args.runtime) or {})
    health = entry.get("health") or {}
    sockets = entry.get("sockets") or []
    if health.get("up") is not True:
        raise SystemExit(1)
    if not any(item.get("up") is False for item in sockets):
        raise SystemExit(1)
    if sum(1 for item in sockets if item.get("up") is True) < args.min_healthy:
        raise SystemExit(1)


def command_runtime_recovered(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    entry = ((obj.get("runtimes") or {}).get(args.runtime) or {})
    health = entry.get("health") or {}
    sockets = entry.get("sockets") or []
    if health.get("up") is not True or not sockets or not all(item.get("up") is True for item in sockets):
        raise SystemExit(1)


def command_schedule_has_success(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    target = None
    for item in obj.get("schedules") or []:
        if item.get("runtime") == args.runtime and item.get("name") == args.name:
            target = item
            break
    if target is None:
        raise SystemExit(1)
    state = target.get("state") or {}
    if state.get("last") and int(state.get("last_status") or 0) == 200:
        return
    raise SystemExit(1)


def command_scheduler_probe_valid(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    trigger = obj.get("trigger") or {}
    pool = obj.get("worker_pool") or {}
    if trigger.get("type") != "schedule":
        raise SystemExit(1)
    required_ints = {
        "max_workers": 3,
        "max_queue": 2,
        "queue_timeout_ms": 1500,
        "queue_poll_ms": 15,
        "overflow_status": 503,
    }
    if pool.get("enabled") is not True:
        raise SystemExit(1)
    for key, expected in required_ints.items():
        if int(pool.get(key) or 0) != expected:
            raise SystemExit(1)


def command_keep_warm_visible(args: argparse.Namespace) -> None:
    snap = load_json(raw=args.snapshot_json)
    health = load_json(raw=args.health_json)
    catalog = load_json(raw=args.catalog_json)

    keep_items = snap.get("keep_warm") or []
    target = None
    for item in keep_items:
        if item.get("runtime") == "node" and item.get("name") == "ping" and item.get("version") in (None, "", "default"):
            target = item
            break
    if target is None:
        raise SystemExit(1)
    state = target.get("state") or {}
    if int(state.get("last_status") or 0) != 200:
        raise SystemExit(1)
    if state.get("warm_state") not in ("warm", "stale"):
        raise SystemExit(1)

    summary = ((health.get("functions") or {}).get("summary") or {})
    if int(summary.get("keep_warm_enabled") or 0) < 1:
        raise SystemExit(1)

    states = ((health.get("functions") or {}).get("states") or [])
    h_target = None
    for row in states:
        if row.get("key") == "node/ping@default":
            h_target = row
            break
    if h_target is None or h_target.get("state") not in ("warm", "stale"):
        raise SystemExit(1)

    node_rt = (catalog.get("runtimes") or {}).get("node") or {}
    functions = node_rt.get("functions") or []
    c_target = None
    for fn in functions:
        if isinstance(fn, dict) and fn.get("name") == "ping":
            c_target = fn
            break
    if c_target is None:
        raise SystemExit(1)
    default_state = c_target.get("default_state") or {}
    keep_cfg = default_state.get("keep_warm") or {}
    if keep_cfg.get("enabled") is not True:
        raise SystemExit(1)
    if default_state.get("state") not in ("warm", "stale"):
        raise SystemExit(1)


def command_logs_runtime_line(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    if obj.get("file") != "runtime":
        fail("unexpected log file kind")
    if obj.get("runtime") != args.runtime:
        fail("unexpected runtime")
    if obj.get("fn") != args.fn:
        fail("unexpected function name")
    if obj.get("version") != args.version:
        fail("unexpected version")
    if obj.get("stream") != args.stream:
        fail("unexpected stream")
    lines = obj.get("data") or []
    if not isinstance(lines, list) or not lines:
        fail("missing runtime log lines")
    for line in lines:
        if not isinstance(line, str):
            continue
        if all(fragment in line for fragment in args.contains) and all(fragment not in line for fragment in args.not_contains):
            return
    fail("matching runtime log line not found")


def command_logs_stream_empty(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    if obj.get("stream") != args.stream:
        fail("unexpected stream")
    if (obj.get("data") or []) != []:
        fail("expected empty log data")


def command_openapi_route_present(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    paths = obj.get("paths") or {}
    if args.route not in paths:
        fail(f"missing route in OpenAPI: {args.route}")
    if args.method:
        if args.method.lower() not in (paths.get(args.route) or {}):
            fail(f"missing method {args.method} on route {args.route}")


def command_openapi_route_absent(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    paths = obj.get("paths") or {}
    if args.route in paths:
        fail(f"unexpected route in OpenAPI: {args.route}")


def command_openapi_route_param(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    paths = obj.get("paths") or {}
    ops = paths.get(args.route) or {}
    method = args.method.lower()
    op = ops.get(method) or {}
    for param in op.get("parameters") or []:
        if not isinstance(param, dict):
            continue
        if param.get("name") == args.name and param.get("in") == args.location:
            return
    fail(f"missing parameter {args.name} in={args.location} on {args.method.upper()} {args.route}")


def command_openapi_server_url(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file, raw=args.json)
    servers = obj.get("servers") or []
    if not servers or not isinstance(servers[0], dict):
        fail("missing servers[0]")
    if servers[0].get("url") != args.expected:
        fail(str(servers[0].get("url")))


def assert_openapi_catalog_alignment(paths: dict[str, Any], catalog: dict[str, Any]) -> None:
    mapped = catalog.get("mapped_routes") or {}
    expected_paths: set[str] = set()
    expected_methods_by_path: dict[str, set[str]] = {}
    for route, entries in mapped.items():
        if not isinstance(route, str) or not route.startswith("/") or route.startswith("/_fn/"):
            continue
        openapi_path = route_to_openapi_path(route)
        if not openapi_path:
            continue
        expected_paths.add(openapi_path)
        if openapi_path not in paths:
            fail(f"catalog route missing from OpenAPI: {route} -> {openapi_path}")
        if isinstance(entries, dict):
            entries = [entries]
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            methods = entry.get("methods") or ["GET"]
            if not isinstance(methods, list) or not methods:
                methods = ["GET"]
            for method in methods:
                op = str(method or "GET").lower()
                expected_methods_by_path.setdefault(openapi_path, set()).add(str(method or "GET").upper())
                if op not in (paths.get(openapi_path) or {}):
                    fail(f"missing method {op.upper()} for {openapi_path}")

    public_paths = {
        path for path in paths.keys()
        if isinstance(path, str) and path.startswith("/") and not path.startswith("/_fn/")
    }
    unexpected_paths = sorted(public_paths - expected_paths)
    if unexpected_paths:
        fail(f"unexpected extra OpenAPI paths not in catalog mapping: {unexpected_paths[:10]}")
    missing_paths = sorted(expected_paths - public_paths)
    if missing_paths:
        fail(f"missing OpenAPI paths for mapped routes: {missing_paths[:10]}")
    for openapi_path, expected_methods in expected_methods_by_path.items():
        ops = paths.get(openapi_path) or {}
        actual_methods = {key.upper() for key, value in ops.items() if isinstance(value, dict)}
        if actual_methods != expected_methods:
            fail(
                "method mismatch on "
                + openapi_path
                + f": expected={sorted(expected_methods)} actual={sorted(actual_methods)}"
            )


def command_openapi_functions_default_admin(args: argparse.Namespace) -> None:
    obj = load_json(raw=args.openapi_json)
    paths = obj.get("paths") or {}
    if args.require_path not in paths:
        fail(f"missing required OpenAPI path: {args.require_path}")
    internal = [path for path in paths if isinstance(path, str) and path.startswith("/_fn/")]
    if internal:
        fail(f"internal paths must be hidden by default: {internal[:10]}")


def command_openapi_native_default_admin(args: argparse.Namespace) -> None:
    spec = load_json(raw=args.openapi_json)
    catalog = load_json(raw=args.catalog_json)
    paths = spec.get("paths") or {}
    internal = [path for path in paths if isinstance(path, str) and path.startswith("/_fn/")]
    if internal:
        fail(f"internal paths should be hidden by default: {internal[:10]}")
    public_paths = [path for path in paths if isinstance(path, str) and path.startswith("/") and not path.startswith("/_fn/")]
    if not public_paths:
        fail("expected at least one public function path in OpenAPI")
    mapped = catalog.get("mapped_routes") or {}
    if not isinstance(mapped, dict):
        fail("missing mapped_routes")
    if not any(isinstance(key, str) and key.startswith("/") and not key.startswith("/_fn/") for key in mapped.keys()):
        fail("catalog has no public mapped routes")
    assert_openapi_catalog_alignment(paths, catalog)


def command_openapi_internal_paths_present(args: argparse.Namespace) -> None:
    obj = load_json(raw=args.openapi_json)
    paths = obj.get("paths") or {}
    for path in REQUIRED_INTERNAL_PATHS:
        if path not in paths:
            fail(f"missing internal path in opt-in mode: {path}")


def command_openapi_internal_contract(args: argparse.Namespace) -> None:
    obj = load_json(raw=args.openapi_json)
    catalog = load_json(raw=args.catalog_json)
    paths = obj.get("paths") or {}
    for path in REQUIRED_INTERNAL_PATHS:
        if path not in paths:
            fail(f"missing internal path {path}")

    fn_get = paths["/_fn/function"]["get"]
    fn_params = fn_get.get("parameters") or []
    runtime = get_param(fn_params, "runtime")
    name = get_param(fn_params, "name")
    version = get_param(fn_params, "version")
    include_code = get_param(fn_params, "include_code")
    if not (runtime and runtime.get("in") == "query" and runtime.get("required") is True):
        fail("invalid runtime query param on /_fn/function")
    if not (name and name.get("in") == "query" and name.get("required") is True):
        fail("invalid name query param on /_fn/function")
    if not (version and version.get("in") == "query" and version.get("required") is False):
        fail("invalid version query param on /_fn/function")
    if not (include_code and include_code.get("schema", {}).get("default") == "1"):
        fail("invalid include_code default on /_fn/function")

    jobs_get = paths["/_fn/jobs"]["get"]
    limit = get_param(jobs_get.get("parameters"), "limit")
    if not (limit and limit.get("schema", {}).get("default") == 50):
        fail("invalid jobs limit default")

    jobs_post_schema = paths["/_fn/jobs"]["post"]["requestBody"]["content"]["application/json"]["schema"]
    required = set(jobs_post_schema.get("required") or [])
    if not {"runtime", "name"}.issubset(required):
        fail("jobs schema missing required runtime/name")
    props = jobs_post_schema.get("properties") or {}
    if props.get("method", {}).get("default") != "GET":
        fail("jobs method default mismatch")
    if props.get("max_attempts", {}).get("default") != 1:
        fail("jobs max_attempts default mismatch")
    if props.get("retry_delay_ms", {}).get("default") != 1000:
        fail("jobs retry_delay_ms default mismatch")
    if "route" not in props or "params" not in props:
        fail("jobs schema missing route/params")
    if "202" not in (paths["/_fn/jobs/{id}/result"]["get"].get("responses") or {}):
        fail("jobs result missing 202 response")

    invoke_schema = paths["/_fn/invoke"]["post"]["requestBody"]["content"]["application/json"]["schema"]
    invoke_required = set(invoke_schema.get("required") or [])
    if not {"runtime", "name"}.issubset(invoke_required):
        fail("invoke schema missing required runtime/name")
    invoke_props = invoke_schema.get("properties") or {}
    if invoke_props.get("method", {}).get("default") != "GET" or "route" not in invoke_props or "params" not in invoke_props:
        fail("invoke schema mismatch")

    logs_get = paths["/_fn/logs"]["get"]
    logs_params = logs_get.get("parameters") or []
    expected_defaults = {
        "file": "error",
        "lines": 200,
        "format": "text",
        "stream": "all",
    }
    for key, expected in expected_defaults.items():
        param = get_param(logs_params, key)
        if not param or param.get("in") != "query" or param.get("schema", {}).get("default") != expected:
            fail(f"invalid logs query param {key}")
    for key in ("runtime", "fn", "version"):
        param = get_param(logs_params, key)
        if not param or param.get("in") != "query":
            fail(f"invalid logs query param {key}")

    for path, ops in paths.items():
        if ":" in path:
            fail(f"unexpected raw dynamic route token in path: {path}")
        if not isinstance(ops, dict):
            continue
        for op in ops.values():
            if not isinstance(op, dict):
                continue
            for param in op.get("parameters") or []:
                if isinstance(param, dict):
                    if "in" not in param:
                        fail(f"parameter missing in on path {path}")
                    if "in_" in param:
                        fail(f"invalid in_ key on path {path}")

    if "/blog/{slug}" not in paths:
        fail("catch-all mapped path not exported")
    if any(str(path).startswith("/fn/") for path in paths):
        fail("OpenAPI exported /fn/* routes")

    assert_openapi_catalog_alignment(paths, catalog)


def command_openapi_assert_paths(args: argparse.Namespace) -> None:
    obj = load_json(raw=args.openapi_json)
    catalog = load_json(raw=args.catalog_json)
    paths = obj.get("paths") or {}
    if args.mode == "next-style":
        required = [
            "/users",
            "/users/{id}",
            "/hello",
            "/html",
            "/showcase",
            "/showcase/form",
            "/blog",
            "/blog/{slug}",
            "/php/profile/{id}",
            "/rust/health",
            "/rust/version",
            "/admin/users/{id}",
            "/hello-demo/{name}",
        ]
    elif args.mode == "multi_root":
        required = [
            "/nextstyle-clean/users",
            "/nextstyle-clean/api/orders/{id}",
            "/items",
            "/items/{id}",
        ]
    else:
        fail(f"unknown mode: {args.mode}")
    missing = [path for path in required if path not in paths]
    if missing:
        fail(f"missing OpenAPI paths: {missing}")
    internal_paths = [path for path in paths if isinstance(path, str) and path.startswith("/_fn/")]
    if internal_paths:
        fail(f"internal API paths must be hidden by default: {internal_paths[:10]}")
    fn_prefixed_paths = [path for path in paths if path.startswith("/fn/")]
    if fn_prefixed_paths:
        fail(f"unexpected /fn OpenAPI paths still present: {fn_prefixed_paths[:10]}")
    if args.mode == "next-style":
        if "/hello_demo/{wildcard}" in paths:
            fail("unexpected wildcard underscore path still present: /hello_demo/{wildcard}")
        private_helper_paths = [
            "/users/_shared",
            "/blog/_shared",
            "/php/_shared",
            "/rust/_shared",
        ]
        leaked_helpers = [path for path in private_helper_paths if path in paths]
        if leaked_helpers:
            fail(f"private helper routes leaked into OpenAPI: {leaked_helpers}")
        hello_demo = (paths.get("/hello-demo/{name}") or {}).get("get") or {}
        hello_demo_name = get_param(hello_demo.get("parameters"), "name")
        if not isinstance(hello_demo_name, dict) or hello_demo_name.get("in") != "path":
            fail("missing required path parameter 'name' on /hello-demo/{name}")
    for path, ops in paths.items():
        if ":" in path:
            fail(f"unexpected raw ':' token in OpenAPI path: {path}")
        if not isinstance(ops, dict):
            continue
        for op_name, op in ops.items():
            if not isinstance(op, dict):
                continue
            for param in op.get("parameters") or []:
                if isinstance(param, dict):
                    if "in_" in param:
                        fail(f"invalid parameter key in_ on {path} {op_name}")
                    if "in" not in param:
                        fail(f"missing parameter in on {path} {op_name}")
            summary = str(op.get("summary") or "")
            if "unknown/unknown" in summary:
                fail(f"unexpected unknown OpenAPI summary on {path} {op_name}: {summary}")
    assert_openapi_catalog_alignment(paths, catalog)
    if args.mode == "multi_root":
        for bad in ("/polyglot-demo/handlers/list", "/polyglot-demo/handlers/create", "/polyglot-demo/src/delete"):
            if bad in paths:
                fail(f"unexpected nested manifest path still present: {bad}")


def build_mapped_invoke_payload(catalog: dict[str, Any], variant: str) -> dict[str, Any]:
    mapped = catalog.get("mapped_routes") or {}
    chosen = None
    if variant == "generic":
        routes = sorted(mapped.keys(), key=lambda route: (1 if ":" in route else 0, route))
        for route in routes:
            if not route.startswith("/"):
                continue
            entries = mapped.get(route)
            if isinstance(entries, dict):
                entries = [entries]
            if not isinstance(entries, list):
                continue
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                runtime = entry.get("runtime")
                fn_name = entry.get("fn_name")
                methods = entry.get("methods") or ["GET"]
                if not runtime or not fn_name:
                    continue
                method = "GET"
                upper = [str(item).upper() for item in methods]
                if "GET" in upper:
                    method = "GET"
                elif upper:
                    method = upper[0]
                params: dict[str, str] = {}
                expected = route

                def repl(match: re.Match[str]) -> str:
                    name = match.group(1)
                    star = match.group(2) == "*"
                    value = "a/b" if star else "123"
                    params[name] = value
                    return value

                if ":" in route:
                    expected = re.sub(r":([A-Za-z0-9_]+)(\*?)", repl, route)
                chosen = {
                    "runtime": runtime,
                    "name": fn_name,
                    "version": entry.get("version"),
                    "method": method,
                    "query": {},
                    "body": "",
                    "route": route,
                    "params": params,
                    "__expected_route": expected,
                }
                break
            if chosen:
                break
    elif variant == "dynamic":
        def route_priority(route: str) -> tuple[int, str]:
            if route == "/users/:id":
                return (0, route)
            if route.endswith("/users/:id"):
                return (1, route)
            return (2, route)

        for route in sorted(mapped.keys(), key=route_priority):
            if ":" not in route or not route.startswith("/"):
                continue
            entries = mapped.get(route)
            if isinstance(entries, dict):
                entries = [entries]
            if not isinstance(entries, list):
                continue
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                runtime = entry.get("runtime")
                fn_name = entry.get("fn_name")
                methods = [str(item).upper() for item in (entry.get("methods") or ["GET"])]
                if not runtime or not fn_name or "GET" not in methods:
                    continue
                params: dict[str, str] = {}

                def repl(match: re.Match[str]) -> str:
                    name = match.group(1)
                    star = match.group(2) == "*"
                    value = "a/b" if star else "123"
                    params[name] = value
                    return value

                expected = re.sub(r":([A-Za-z0-9_]+)(\*?)", repl, route)
                if not params:
                    continue
                chosen = {
                    "runtime": runtime,
                    "name": fn_name,
                    "version": entry.get("version"),
                    "method": "GET",
                    "query": {},
                    "body": "",
                    "route": route,
                    "params": params,
                    "__expected_route": expected,
                }
                break
            if chosen:
                break
    else:
        fail(f"unknown invoke payload variant: {variant}")

    if not chosen:
        fail("no mapped route candidate")
    return chosen


def command_mapped_invoke_payload(args: argparse.Namespace) -> None:
    catalog = load_json(raw=args.catalog_json)
    print(json.dumps(build_mapped_invoke_payload(catalog, args.variant), separators=(",", ":")))


def command_assert_invoke_mapped_route(args: argparse.Namespace) -> None:
    response = load_json(raw=args.response_json)
    request = load_json(raw=args.request_json)
    if not isinstance(response.get("status"), int):
        fail(json.dumps(response, ensure_ascii=False))
    if response.get("route") != request.get("__expected_route"):
        fail(json.dumps({"response": response, "request": request}, ensure_ascii=False))


def command_assert_invoke_route_params(args: argparse.Namespace) -> None:
    response = load_json(raw=args.response_json)
    request = load_json(raw=args.request_json)
    if not isinstance(response.get("status"), int):
        fail(json.dumps({"response": response, "request": request}, ensure_ascii=False))
    if response.get("route_template") != request.get("route"):
        fail(json.dumps({"response": response, "request": request}, ensure_ascii=False))
    if response.get("route") != request.get("__expected_route"):
        fail(json.dumps({"response": response, "request": request}, ensure_ascii=False))
    body = json.loads(response.get("body") or "{}")
    params = body.get("params") or {}
    for key, value in (request.get("params") or {}).items():
        if params.get(key) != value:
            fail(json.dumps({"param": key, "response_params": params, "request": request}, ensure_ascii=False))


def command_job_id(args: argparse.Namespace) -> None:
    obj = load_json(raw=args.response_json)
    job_id = obj.get("id")
    if not job_id:
        fail("missing job id in enqueue response")
    print(job_id)


def command_job_status(args: argparse.Namespace) -> None:
    obj = load_json(raw=args.response_json)
    print(obj.get("status") or "")


def command_assert_job_result_params(args: argparse.Namespace) -> None:
    result = load_json(raw=args.result_json)
    request = load_json(raw=args.request_json)
    if result.get("status") != 200:
        fail(json.dumps(result, ensure_ascii=False))
    body = json.loads(result.get("body") or "{}")
    params = body.get("params") or {}
    for key, value in (request.get("params") or {}).items():
        if params.get(key) != value:
            fail(json.dumps({"param": key, "params": params, "request": request}, ensure_ascii=False))


def command_cloudflare_status_body(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file)
    if obj.get("success") is not True:
        fail("status payload missing success=true")
    data = obj.get("data") or {}
    if data.get("status") != "healthy":
        fail("status payload missing healthy state")
    if data.get("environment") != "compat-fixture":
        fail("status payload missing fixture ENVIRONMENT")
    if data.get("version") != "1.0.0":
        fail("status payload missing version")
    if not isinstance(data.get("timestamp"), str) or not data.get("timestamp"):
        fail("status payload missing timestamp")


def command_cloudflare_message_body(args: argparse.Namespace) -> None:
    obj = load_json(file_path=args.file)
    if obj.get("success") is not True:
        fail("message payload missing success=true")
    data = obj.get("data") or {}
    if data.get("message") != "hola":
        fail("message payload missing echoed message")
    if not isinstance(data.get("timestamp"), str) or not data.get("timestamp"):
        fail("message payload missing timestamp")
    if not isinstance(data.get("id"), str) or not data.get("id"):
        fail("message payload missing id")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    pick_port = sub.add_parser("pick-free-port")
    pick_port.set_defaults(func=command_pick_free_port)

    health_all = sub.add_parser("health-all-up")
    health_all.add_argument("--file")
    health_all.add_argument("--json")
    health_all.set_defaults(func=command_health_all_up)

    health_runtime = sub.add_parser("health-runtime-up")
    health_runtime.add_argument("--runtime", required=True)
    health_runtime.add_argument("--file")
    health_runtime.add_argument("--json")
    health_runtime.set_defaults(func=command_health_runtime_up)

    health_missing = sub.add_parser("health-missing-runtimes")
    health_missing.add_argument("--file")
    health_missing.add_argument("--json")
    health_missing.add_argument("runtimes", nargs="+")
    health_missing.set_defaults(func=command_health_missing_runtimes)

    health_daemons = sub.add_parser("health-daemon-stack-ready")
    health_daemons.add_argument("--file")
    health_daemons.add_argument("--json")
    health_daemons.add_argument("--runtimes", required=True)
    health_daemons.add_argument("--min-sockets", type=int, default=3)
    health_daemons.set_defaults(func=command_health_daemon_stack_ready)

    catalog_signature = sub.add_parser("catalog-signature")
    catalog_signature.add_argument("--file")
    catalog_signature.add_argument("--json")
    catalog_signature.set_defaults(func=command_catalog_signature)

    catalog_has_function = sub.add_parser("catalog-has-function")
    catalog_has_function.add_argument("--file")
    catalog_has_function.add_argument("--json")
    catalog_has_function.add_argument("--runtime", required=True)
    catalog_has_function.add_argument("--name", required=True)
    catalog_has_function.set_defaults(func=command_catalog_has_function)

    catalog_has_functions = sub.add_parser("catalog-has-functions")
    catalog_has_functions.add_argument("--file")
    catalog_has_functions.add_argument("--json")
    catalog_has_functions.add_argument("--runtime", required=True)
    catalog_has_functions.add_argument("names", nargs="+")
    catalog_has_functions.set_defaults(func=command_catalog_has_functions)

    catalog_route = sub.add_parser("catalog-route-no-conflicts")
    catalog_route.add_argument("--file")
    catalog_route.add_argument("--json")
    catalog_route.add_argument("--route", required=True)
    catalog_route.add_argument("--min-entries", type=int, default=2)
    catalog_route.set_defaults(func=command_catalog_route_no_conflicts)

    extract = sub.add_parser("extract-json-field")
    extract.add_argument("--json")
    extract.add_argument("--stdin", action="store_true")
    extract.add_argument("--field", required=True)
    extract.set_defaults(func=command_extract_json_field)

    hmac_cmd = sub.add_parser("hmac-sha256")
    hmac_cmd.add_argument("--secret", required=True)
    hmac_cmd.add_argument("--body", required=True)
    hmac_cmd.set_defaults(func=command_hmac_sha256)

    remove_key = sub.add_parser("remove-json-key")
    remove_key.add_argument("--file", required=True)
    remove_key.add_argument("--key", required=True)
    remove_key.set_defaults(func=command_remove_json_key)

    secs_ms = sub.add_parser("seconds-to-ms")
    secs_ms.add_argument("--value", required=True)
    secs_ms.set_defaults(func=command_seconds_to_ms)

    dep_err = sub.add_parser("dependency-resolution-error")
    dep_err.add_argument("--file")
    dep_err.add_argument("--json")
    dep_err.add_argument("--runtime", required=True)
    dep_err.add_argument("--expected", required=True)
    dep_err.set_defaults(func=command_dependency_resolution_error)

    socket_path = sub.add_parser("runtime-socket-path")
    socket_path.add_argument("--file")
    socket_path.add_argument("--json")
    socket_path.add_argument("--runtime", required=True)
    socket_path.add_argument("--index", type=int, required=True)
    socket_path.set_defaults(func=command_runtime_socket_path)

    degraded = sub.add_parser("runtime-degraded")
    degraded.add_argument("--file")
    degraded.add_argument("--json")
    degraded.add_argument("--runtime", required=True)
    degraded.add_argument("--min-healthy", type=int, default=2)
    degraded.set_defaults(func=command_runtime_degraded)

    recovered = sub.add_parser("runtime-recovered")
    recovered.add_argument("--file")
    recovered.add_argument("--json")
    recovered.add_argument("--runtime", required=True)
    recovered.set_defaults(func=command_runtime_recovered)

    schedule_ok = sub.add_parser("schedule-has-success")
    schedule_ok.add_argument("--file")
    schedule_ok.add_argument("--json")
    schedule_ok.add_argument("--runtime", required=True)
    schedule_ok.add_argument("--name", required=True)
    schedule_ok.set_defaults(func=command_schedule_has_success)

    sched_probe = sub.add_parser("scheduler-probe-valid")
    sched_probe.add_argument("--file")
    sched_probe.add_argument("--json")
    sched_probe.set_defaults(func=command_scheduler_probe_valid)

    keep_warm = sub.add_parser("keep-warm-visible")
    keep_warm.add_argument("--snapshot-json", required=True)
    keep_warm.add_argument("--health-json", required=True)
    keep_warm.add_argument("--catalog-json", required=True)
    keep_warm.set_defaults(func=command_keep_warm_visible)

    log_line = sub.add_parser("logs-runtime-line")
    log_line.add_argument("--file")
    log_line.add_argument("--json")
    log_line.add_argument("--runtime", required=True)
    log_line.add_argument("--fn", required=True)
    log_line.add_argument("--version", required=True)
    log_line.add_argument("--stream", required=True)
    log_line.add_argument("--contains", nargs="+", required=True)
    log_line.add_argument("--not-contains", nargs="*", default=[])
    log_line.set_defaults(func=command_logs_runtime_line)

    log_empty = sub.add_parser("logs-stream-empty")
    log_empty.add_argument("--file")
    log_empty.add_argument("--json")
    log_empty.add_argument("--stream", required=True)
    log_empty.set_defaults(func=command_logs_stream_empty)

    route_present = sub.add_parser("openapi-route-present")
    route_present.add_argument("--file")
    route_present.add_argument("--json")
    route_present.add_argument("--route", required=True)
    route_present.add_argument("--method")
    route_present.set_defaults(func=command_openapi_route_present)

    route_absent = sub.add_parser("openapi-route-absent")
    route_absent.add_argument("--file")
    route_absent.add_argument("--json")
    route_absent.add_argument("--route", required=True)
    route_absent.set_defaults(func=command_openapi_route_absent)

    route_param = sub.add_parser("openapi-route-param")
    route_param.add_argument("--file")
    route_param.add_argument("--json")
    route_param.add_argument("--route", required=True)
    route_param.add_argument("--method", required=True)
    route_param.add_argument("--name", required=True)
    route_param.add_argument("--location", default="path")
    route_param.set_defaults(func=command_openapi_route_param)

    server_url = sub.add_parser("openapi-server-url")
    server_url.add_argument("--file")
    server_url.add_argument("--json")
    server_url.add_argument("--expected", required=True)
    server_url.set_defaults(func=command_openapi_server_url)

    openapi_default = sub.add_parser("openapi-functions-default-admin")
    openapi_default.add_argument("--openapi-json", required=True)
    openapi_default.add_argument("--require-path", required=True)
    openapi_default.set_defaults(func=command_openapi_functions_default_admin)

    openapi_native_default = sub.add_parser("openapi-native-default-admin")
    openapi_native_default.add_argument("--openapi-json", required=True)
    openapi_native_default.add_argument("--catalog-json", required=True)
    openapi_native_default.set_defaults(func=command_openapi_native_default_admin)

    openapi_internal_present = sub.add_parser("openapi-internal-paths-present")
    openapi_internal_present.add_argument("--openapi-json", required=True)
    openapi_internal_present.set_defaults(func=command_openapi_internal_paths_present)

    openapi_internal = sub.add_parser("openapi-internal-contract")
    openapi_internal.add_argument("--openapi-json", required=True)
    openapi_internal.add_argument("--catalog-json", required=True)
    openapi_internal.set_defaults(func=command_openapi_internal_contract)

    openapi_paths = sub.add_parser("openapi-assert-paths")
    openapi_paths.add_argument("--mode", required=True)
    openapi_paths.add_argument("--openapi-json", required=True)
    openapi_paths.add_argument("--catalog-json", required=True)
    openapi_paths.set_defaults(func=command_openapi_assert_paths)

    mapped_payload = sub.add_parser("mapped-invoke-payload")
    mapped_payload.add_argument("--catalog-json", required=True)
    mapped_payload.add_argument("--variant", choices=["generic", "dynamic"], required=True)
    mapped_payload.set_defaults(func=command_mapped_invoke_payload)

    assert_mapped = sub.add_parser("assert-invoke-mapped-route")
    assert_mapped.add_argument("--response-json", required=True)
    assert_mapped.add_argument("--request-json", required=True)
    assert_mapped.set_defaults(func=command_assert_invoke_mapped_route)

    assert_params = sub.add_parser("assert-invoke-route-params")
    assert_params.add_argument("--response-json", required=True)
    assert_params.add_argument("--request-json", required=True)
    assert_params.set_defaults(func=command_assert_invoke_route_params)

    job_id = sub.add_parser("job-id")
    job_id.add_argument("--response-json", required=True)
    job_id.set_defaults(func=command_job_id)

    job_status = sub.add_parser("job-status")
    job_status.add_argument("--response-json", required=True)
    job_status.set_defaults(func=command_job_status)

    job_result = sub.add_parser("assert-job-result-params")
    job_result.add_argument("--result-json", required=True)
    job_result.add_argument("--request-json", required=True)
    job_result.set_defaults(func=command_assert_job_result_params)

    cf_status = sub.add_parser("cloudflare-status-body")
    cf_status.add_argument("--file", required=True)
    cf_status.set_defaults(func=command_cloudflare_status_body)

    cf_msg = sub.add_parser("cloudflare-message-body")
    cf_msg.add_argument("--file", required=True)
    cf_msg.set_defaults(func=command_cloudflare_message_body)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
