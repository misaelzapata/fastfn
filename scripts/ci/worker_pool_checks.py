#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import time
import urllib.error
import urllib.request
from typing import Any


def request_one(url: str, method: str = "GET", data: bytes | None = None, timeout: float = 8.0) -> dict[str, Any]:
    req = urllib.request.Request(url=url, method=method, headers={"Accept": "application/json"}, data=data)
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code = int(resp.getcode() or 0)
            headers = dict(resp.headers.items())
            body = resp.read().decode("utf-8", "ignore")
            return {
                "ok": True,
                "status": code,
                "headers": headers,
                "body": body,
                "ms": int((time.time() - started) * 1000),
            }
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore") if hasattr(err, "read") else ""
        return {
            "ok": False,
            "status": int(err.code or 0),
            "headers": dict(err.headers.items()) if err.headers else {},
            "body": body,
            "ms": int((time.time() - started) * 1000),
        }
    except Exception as err:
        return {"ok": False, "status": 0, "error": str(err), "body": str(err), "headers": {}, "ms": int((time.time() - started) * 1000)}


def runtime_fn_version(base_url: str) -> None:
    url = base_url + "/slow"

    def one_call() -> dict[str, Any]:
        row = request_one(url, timeout=6.0)
        if "error" in row:
            return row
        row["queued"] = str({k.lower(): v for (k, v) in row.get("headers", {}).items()}.get("x-fastfn-queued", "")).lower() == "true"
        return row

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(lambda _: one_call(), range(3)))

    errors = [row for row in results if row.get("status") == 0]
    if errors:
        raise SystemExit("worker_pool request error: " + json.dumps(errors, ensure_ascii=False))

    status_counts: dict[int, int] = {}
    for row in results:
        status_counts[int(row["status"])] = status_counts.get(int(row["status"]), 0) + 1
    if status_counts.get(200, 0) != 2 or status_counts.get(429, 0) != 1:
        raise SystemExit(
            "unexpected status distribution: " + json.dumps({"counts": status_counts, "results": results}, ensure_ascii=False)
        )
    queued_success = [row for row in results if row["status"] == 200 and row.get("queued")]
    if len(queued_success) < 1:
        raise SystemExit("expected at least one queued successful request: " + json.dumps(results, ensure_ascii=False))
    max_ms = max(int(row["ms"]) for row in results)
    if max_ms > 2800:
        raise SystemExit(
            "worker_pool latency budget exceeded: " + json.dumps({"max_ms": max_ms, "results": results}, ensure_ascii=False)
        )
    print(json.dumps({"counts": status_counts, "max_ms": max_ms}, separators=(",", ":")))

    def call_state(path: str) -> tuple[int, dict[str, Any]]:
        row = request_one(base_url + path, timeout=6.0)
        if row["status"] != 200:
            raise SystemExit(f"unexpected status for {path}: {row['status']}")
        return int(row["status"]), json.loads(row["body"])

    s1, b1 = call_state("/state-a")
    s2, b2 = call_state("/state-a")
    s3, b3 = call_state("/state-b")
    if s1 != 200 or s2 != 200 or s3 != 200:
        raise SystemExit(f"unexpected statuses: {s1},{s2},{s3}")
    v1 = int(b1.get("value") or 0)
    v2 = int(b2.get("value") or 0)
    vb = int(b3.get("value") or 0)
    if v1 < 1 or v2 != (v1 + 1):
        raise SystemExit(f"state-a warm worker sequence invalid: v1={v1}, v2={v2}")
    if vb != 0:
        raise SystemExit(f"state-b should not see state-a global data: vb={vb}")
    print(json.dumps({"state_a_first": v1, "state_a_second": v2, "state_b": vb}, separators=(",", ":")))


def parallel_multiruntime(base_url: str) -> None:
    targets = [
        {"runtime": "node", "path": "/slow-node"},
        {"runtime": "python", "path": "/slow-python"},
        {"runtime": "php", "path": "/slow-php"},
        {"runtime": "rust", "path": "/slow-rust"},
    ]
    parallel_calls = 2
    max_total_ms = 1500
    report: list[dict[str, Any]] = []
    for target in targets:
        warm = request_one(base_url + target["path"], timeout=8.0)
        if warm.get("status") != 200:
            raise SystemExit("warmup failed for " + target["runtime"] + ": " + json.dumps(warm, ensure_ascii=False))
        started = time.time()
        with concurrent.futures.ThreadPoolExecutor(max_workers=parallel_calls) as pool:
            results = list(pool.map(lambda _: request_one(base_url + target["path"], timeout=8.0), range(parallel_calls)))
        total_ms = int((time.time() - started) * 1000)
        failures = [row for row in results if row.get("status") != 200]
        if failures:
            raise SystemExit("parallel status failure for " + target["runtime"] + ": " + json.dumps(failures, ensure_ascii=False))
        if total_ms > max_total_ms:
            raise SystemExit(
                "parallel budget exceeded for "
                + target["runtime"]
                + ": "
                + json.dumps({"total_ms": total_ms, "results": results, "max_total_ms": max_total_ms}, ensure_ascii=False)
            )
        report.append(
            {
                "runtime": target["runtime"],
                "path": target["path"],
                "parallel_calls": parallel_calls,
                "total_ms": total_ms,
                "max_single_ms": max(int(row["ms"]) for row in results),
            }
        )
    print(json.dumps(report, separators=(",", ":")))


def health_observability(base_url: str) -> None:
    row = request_one(base_url + "/_fn/health", timeout=8.0)
    health = json.loads(row["body"])
    functions = health.get("functions") or {}
    agg = functions.get("summary") or {}
    states = functions.get("states") or []
    target = next((item for item in states if item.get("key") == "node/slow@default"), None)
    if target is None:
        raise SystemExit("node/slow@default not found in /_fn/health")
    pool = target.get("worker_pool") or {}
    drops = pool.get("queue_drops") or {}
    overflow = int(drops.get("overflow") or 0)
    timeout_count = int(drops.get("timeout") or 0)
    total = int(drops.get("total") or 0)
    if pool.get("enabled") is not True:
        raise SystemExit("node/slow worker_pool.enabled expected true")
    if overflow < 1 or total < overflow:
        raise SystemExit("unexpected queue drop counters")
    if int(agg.get("pool_enabled") or 0) < 1:
        raise SystemExit("summary.pool_enabled expected >= 1")
    if int(agg.get("pool_queue_drops") or 0) < 1:
        raise SystemExit("summary.pool_queue_drops expected >= 1")
    if int(agg.get("pool_queue_overflow_drops") or 0) < 1:
        raise SystemExit("summary.pool_queue_overflow_drops expected >= 1")
    print(
        json.dumps(
            {
                "summary_pool_enabled": int(agg.get("pool_enabled") or 0),
                "summary_pool_queue_drops": int(agg.get("pool_queue_drops") or 0),
                "summary_pool_queue_overflow_drops": int(agg.get("pool_queue_overflow_drops") or 0),
                "summary_pool_queue_timeout_drops": int(agg.get("pool_queue_timeout_drops") or 0),
                "node_slow_overflow": overflow,
                "node_slow_timeout": timeout_count,
                "node_slow_total": total,
            },
            separators=(",", ":"),
        )
    )


def python_dep_worker_persistent(base_url: str) -> None:
    url = base_url + "/py-persistent"

    def call_once() -> dict[str, int]:
        row = request_one(url, timeout=90.0)
        code = int(row.get("status") or 0)
        body = json.loads(row["body"])
        if code != 200:
            raise SystemExit(f"py-persistent unexpected status: {code}")
        if body.get("runtime") != "python":
            raise SystemExit("py-persistent expected runtime=python")
        pid = int(body.get("pid") or 0)
        hits = int(body.get("hits") or 0)
        if pid <= 0 or hits <= 0:
            raise SystemExit("py-persistent missing pid/hits")
        return {"pid": pid, "hits": hits}

    first = call_once()
    second = call_once()
    if second["pid"] != first["pid"]:
        raise SystemExit(
            "python deps worker is not persistent (pid changed): "
            + json.dumps({"first": first, "second": second}, ensure_ascii=False)
        )
    if second["hits"] != first["hits"] + 1:
        raise SystemExit(
            "python deps worker counter did not increment: "
            + json.dumps({"first": first, "second": second}, ensure_ascii=False)
        )
    print(json.dumps({"first": first, "second": second}, separators=(",", ":")))


def python_with_deps_available(base_url: str) -> None:
    url = base_url + "/py-with-deps"
    deadline = time.time() + 180
    last_err: dict[str, Any] | None = None
    while time.time() < deadline:
        row = request_one(url, timeout=90.0)
        try:
            body = json.loads(row["body"])
        except Exception:
            body = row["body"]
        if row["status"] == 200 and isinstance(body, dict) and body.get("runtime") == "python" and body.get("has_requests") is True:
            print(json.dumps({"status": row["status"], "requests_version": body.get("requests_version")}, separators=(",", ":")))
            return
        last_err = {"status": row["status"], "body": body}
        time.sleep(2)
    raise SystemExit("py-with-deps unavailable after retries: " + json.dumps(last_err, ensure_ascii=False))


def parallel_mapped_routes_nonblocking(base_url: str, threshold_ms: int) -> None:
    warm_timeout_sec = float(os.environ.get("PARALLEL_WARM_TIMEOUT_SEC", "45"))
    warm_timeout_rust_sec = float(os.environ.get("PARALLEL_WARM_TIMEOUT_RUST_SEC", "180"))
    catalog = json.loads(request_one(base_url + "/_fn/catalog", timeout=8.0)["body"])
    mapped = catalog.get("mapped_routes") or {}
    specs: list[dict[str, Any]] = []
    for route, entries in mapped.items():
        if not isinstance(route, str) or not route.startswith("/") or route.startswith("/_fn/"):
            continue
        if isinstance(entries, dict):
            entries = [entries]
        if not isinstance(entries, list):
            continue
        picked = None
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            methods = entry.get("methods") or ["GET"]
            runtime = entry.get("runtime") if isinstance(entry.get("runtime"), str) else ""
            picked = {
                "route": route,
                "path": re.sub(r":([A-Za-z0-9_]+)\*", "a/b", re.sub(r":([A-Za-z0-9_]+)", "123", route)),
                "method": pick_method(methods),
                "runtime": runtime,
            }
            break
        if picked:
            specs.append(picked)
    uniq: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for spec in specs:
        key = (spec["method"], spec["path"])
        if key in seen:
            continue
        seen.add(key)
        uniq.append(spec)
    if not uniq:
        raise SystemExit("no mapped routes found for parallel check")
    for spec in uniq:
        timeout = warm_timeout_rust_sec if spec.get("runtime") == "rust" else warm_timeout_sec
        warm = request_one_with_spec(base_url, spec, timeout)
        if not warm["ok"]:
            raise SystemExit("warm-up failed: " + json.dumps(warm, ensure_ascii=False))
    max_ms = 0
    rounds = 3
    workers = min(16, max(4, len(uniq)))
    for _ in range(rounds):
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            results = list(pool.map(lambda spec: request_one_with_spec(base_url, spec, 8.0), uniq))
        bad = [item for item in results if not item["ok"]]
        if bad:
            raise SystemExit("parallel requests failed: " + json.dumps(bad[:3], ensure_ascii=False))
        max_ms = max(max_ms, max(int(item["ms"]) for item in results))
    if max_ms > threshold_ms:
        raise SystemExit(f"parallel max latency too high: {max_ms}ms > {threshold_ms}ms")
    print(json.dumps({"routes": len(uniq), "max_ms": max_ms}, separators=(",", ":")))


def pick_method(methods: Any) -> str:
    preferred = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    if not isinstance(methods, list) or not methods:
        return "GET"
    normalized = [str(item).upper() for item in methods]
    for method in preferred:
        if method in normalized:
            return method
    return normalized[0]


def request_one_with_spec(base_url: str, spec: dict[str, Any], timeout: float) -> dict[str, Any]:
    method = spec["method"]
    url = base_url + spec["path"]
    headers = {"Accept": "application/json"}
    data = None
    if method in ("POST", "PUT", "PATCH"):
        headers["Content-Type"] = "application/json"
        data = b"{}"
    req = urllib.request.Request(url=url, method=method, headers=headers, data=data)
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code = int(resp.getcode() or 0)
            body = resp.read().decode("utf-8", "ignore")
    except urllib.error.HTTPError as err:
        code = int(err.code or 0)
        body = err.read().decode("utf-8", "ignore") if hasattr(err, "read") else ""
    except Exception as err:
        return {"ok": False, "spec": spec, "status": 0, "error": str(err), "ms": int((time.time() - started) * 1000)}
    return {
        "ok": 200 <= code < 400,
        "spec": spec,
        "status": code,
        "body": body,
        "ms": int((time.time() - started) * 1000),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    runtime = sub.add_parser("runtime-fn-version")
    runtime.add_argument("--base-url", default=os.environ.get("FASTFN_TEST_BASE_URL", "http://127.0.0.1:8080"))
    runtime.set_defaults(func=lambda args: runtime_fn_version(args.base_url))

    multi = sub.add_parser("parallel-multiruntime")
    multi.add_argument("--base-url", default=os.environ.get("FASTFN_TEST_BASE_URL", "http://127.0.0.1:8080"))
    multi.set_defaults(func=lambda args: parallel_multiruntime(args.base_url))

    health = sub.add_parser("health-observability")
    health.add_argument("--base-url", default=os.environ.get("FASTFN_TEST_BASE_URL", "http://127.0.0.1:8080"))
    health.set_defaults(func=lambda args: health_observability(args.base_url))

    persistent = sub.add_parser("python-dep-worker-persistent")
    persistent.add_argument("--base-url", default=os.environ.get("FASTFN_TEST_BASE_URL", "http://127.0.0.1:8080"))
    persistent.set_defaults(func=lambda args: python_dep_worker_persistent(args.base_url))

    deps = sub.add_parser("python-with-deps-available")
    deps.add_argument("--base-url", default=os.environ.get("FASTFN_TEST_BASE_URL", "http://127.0.0.1:8080"))
    deps.set_defaults(func=lambda args: python_with_deps_available(args.base_url))

    routes = sub.add_parser("parallel-mapped-routes-nonblocking")
    routes.add_argument("--base-url", default=os.environ.get("FASTFN_TEST_BASE_URL", "http://127.0.0.1:8080"))
    routes.add_argument("--threshold-ms", type=int, required=True)
    routes.set_defaults(func=lambda args: parallel_mapped_routes_nonblocking(args.base_url, args.threshold_ms))

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
