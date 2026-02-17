#!/usr/bin/env python3
"""
FastFN fast-path benchmark runner.

This is intentionally "boring" and dependency-free so it can run anywhere:
- simple GET requests
- threads for concurrency
- counts HTTP status codes
- writes a JSON report to tests/stress/results/

It is designed to complement the heavier QR workload benchmark.
"""

from __future__ import annotations

import argparse
import json
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Target:
    runtime: str
    endpoint: str


DEFAULT_TARGETS = [
    # Keep these aligned with the polyglot tutorial demo so they're easy to reproduce.
    #
    # Recommended stack for this benchmark:
    #   FN_RUNTIMES=python,node,php,rust,lua bin/fastfn dev examples/functions/polyglot-tutorial
    Target(runtime="node", endpoint="/step-1"),
    Target(runtime="python", endpoint="/step-2"),
    Target(runtime="php", endpoint="/step-3"),
    Target(runtime="rust", endpoint="/step-4"),
]


def parse_csv_ints(s: str) -> list[int]:
    out: list[int] = []
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        out.append(int(part))
    return out


def run_case(base_url: str, path: str, concurrency: int, total_requests: int, timeout: float) -> dict:
    lock = threading.Lock()
    sent = {"n": 0}
    status: Counter[int] = Counter()
    samples: dict[int, str] = {}

    def worker() -> None:
        while True:
            with lock:
                if sent["n"] >= total_requests:
                    return
                sent["n"] += 1

            req = urllib.request.Request(base_url + path, method="GET")
            code = 0
            body = ""
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    code = resp.getcode()
            except urllib.error.HTTPError as exc:
                code = exc.code
                try:
                    body = exc.read().decode("utf-8", errors="ignore")
                except Exception:
                    body = ""
            except Exception as exc:
                code = 0
                body = str(exc)

            with lock:
                status[code] += 1
                if code not in (200, 429) and code not in samples and body:
                    samples[code] = body[:200]

    t0 = time.time()
    threads = []
    for _ in range(max(1, concurrency)):
        t = threading.Thread(target=worker, daemon=True)
        t.start()
        threads.append(t)

    for t in threads:
        t.join()

    elapsed = time.time() - t0
    return {
        "total": total_requests,
        "concurrency": concurrency,
        "elapsed_sec": round(elapsed, 3),
        "rps": round(total_requests / elapsed, 2) if elapsed > 0 else 0,
        "status": dict(sorted(status.items())),
        "samples": samples,
    }


def best_clean(rows: list[dict]) -> dict | None:
    clean = [
        r
        for r in rows
        if list(r.get("status", {}).keys()) == [200] and r["status"].get(200) == r.get("total")
    ]
    if not clean:
        return None
    return max(clean, key=lambda x: float(x.get("rps") or 0))


def main() -> None:
    p = argparse.ArgumentParser(description="FastFN fast-path benchmark runner")
    p.add_argument("--base-url", default="http://127.0.0.1:8080")
    p.add_argument("--profile", default="default")
    p.add_argument("--total", type=int, default=4000)
    p.add_argument("--timeout", type=float, default=3.0)
    p.add_argument("--concurrency-set", default="1,2,4,8,16,20,24,32")
    p.add_argument(
        "--out",
        default="",
        help="Output JSON path. Default: tests/stress/results/<YYYY-MM-DD>-fastpath-<profile>.json",
    )
    args = p.parse_args()

    concurrency_levels = parse_csv_ints(args.concurrency_set)
    if not concurrency_levels:
        raise SystemExit("--concurrency-set must not be empty")

    base_url = args.base_url.rstrip("/")
    profile = str(args.profile).strip() or "default"

    rows: list[dict] = []
    for t in DEFAULT_TARGETS:
        for c in concurrency_levels:
            row = run_case(base_url, t.endpoint, c, args.total, args.timeout)
            rows.append({"profile": profile, "runtime": t.runtime, "endpoint": t.endpoint, **row})

    if args.out:
        out_path = Path(args.out)
    else:
        out_path = (
            Path("tests")
            / "stress"
            / "results"
            / f"{time.strftime('%Y-%m-%d')}-fastpath-{profile}.json"
        )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(rows, ensure_ascii=True, indent=2), encoding="utf-8")

    print(f"saved: {out_path}")
    print("runtime,endpoint,best_clean_concurrency,best_clean_rps")
    for t in DEFAULT_TARGETS:
        subset = [r for r in rows if r["runtime"] == t.runtime and r["endpoint"] == t.endpoint]
        best = best_clean(subset)
        if best is None:
            print(f"{t.runtime},{t.endpoint},n/a,n/a")
        else:
            print(f"{t.runtime},{t.endpoint},{best['concurrency']},{best['rps']}")


if __name__ == "__main__":
    main()
