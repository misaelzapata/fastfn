#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any


def wait_health(base_url: str) -> None:
    for _ in range(90):
        try:
            with urllib.request.urlopen(base_url + "/_fn/health", timeout=2.0) as resp:
                obj = json.loads(resp.read().decode("utf-8"))
            runtimes = obj.get("runtimes", {})
            py_up = (((runtimes.get("python") or {}).get("health") or {}).get("up") is True)
            node_up = (((runtimes.get("node") or {}).get("health") or {}).get("up") is True)
            if py_up and node_up:
                print("health ready")
                return
        except Exception:
            pass
        time.sleep(1)
    raise SystemExit("health not ready for python/node")


def run_case(base_url: str, path: str, concurrency: int, total_requests: int) -> dict[str, Any]:
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
                with urllib.request.urlopen(req, timeout=8.0) as resp:
                    code = int(resp.getcode() or 0)
            except urllib.error.HTTPError as exc:
                code = int(exc.code or 0)
                try:
                    body = exc.read().decode("utf-8", errors="ignore")
                except Exception:
                    body = ""
            except Exception as exc:
                code = 0
                body = str(exc)

            with lock:
                status[code] += 1
                if code not in (200, 429) and code not in samples:
                    samples[code] = body[:180]

    started = time.time()
    threads = []
    for _ in range(max(1, concurrency)):
        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        threads.append(thread)
    for thread in threads:
        thread.join()
    elapsed = time.time() - started
    return {
        "total": total_requests,
        "concurrency": concurrency,
        "elapsed_sec": round(elapsed, 3),
        "rps": round(total_requests / elapsed, 2) if elapsed > 0 else 0,
        "status": dict(sorted(status.items())),
        "samples": samples,
    }


def benchmark(base_url: str, mode: str, total: int, concurrency_set: str, root_dir: str, endpoints: str, report_suffix: str) -> None:
    concurrency_levels = [int(value) for value in concurrency_set.split(",") if value.strip()]
    domains = [
        "https://github.com/misaelzapata/fastfn",
        "https://openai.com",
        "https://example.org/path?x=1&y=2",
        "https://n8n.io/workflows",
    ]
    endpoint_list = [value.strip() for value in endpoints.split(",") if value.strip()]
    rows: list[dict[str, Any]] = []
    for endpoint in endpoint_list:
        for domain in domains:
            encoded = urllib.parse.quote(domain, safe="")
            path = f"{endpoint}?text={encoded}"
            for concurrency in concurrency_levels:
                row = run_case(base_url, path, concurrency, total)
                rows.append({"endpoint": endpoint, "domain": domain, **row})
    results_dir = Path(root_dir) / "tests" / "stress" / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    out_path = results_dir / f"{time.strftime('%Y-%m-%d')}-qr-{report_suffix or mode}.json"
    out_path.write_text(json.dumps(rows, ensure_ascii=True, indent=2), encoding="utf-8")
    print(f"saved: {out_path}")
    print("endpoint,domain,best_clean_concurrency,best_clean_rps")
    for endpoint in sorted({row["endpoint"] for row in rows}):
        for domain in sorted({row["domain"] for row in rows if row["endpoint"] == endpoint}):
            clean = [
                row
                for row in rows
                if row["endpoint"] == endpoint
                and row["domain"] == domain
                and list(row["status"].keys()) == [200]
                and row["status"].get(200) == row["total"]
            ]
            if not clean:
                print(f"{endpoint},{domain},n/a,n/a")
                continue
            best = max(clean, key=lambda row: row["rps"])
            print(f"{endpoint},{domain},{best['concurrency']},{best['rps']}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    health = sub.add_parser("wait-health")
    health.add_argument("--base-url", required=True)
    health.set_defaults(func=lambda args: wait_health(args.base_url))

    run = sub.add_parser("run")
    run.add_argument("--base-url", required=True)
    run.add_argument("--mode", required=True)
    run.add_argument("--total", type=int, required=True)
    run.add_argument("--concurrency-set", required=True)
    run.add_argument("--root-dir", required=True)
    run.add_argument("--endpoints", required=True)
    run.add_argument("--report-suffix", default="")
    run.set_defaults(
        func=lambda args: benchmark(
            args.base_url,
            args.mode,
            args.total,
            args.concurrency_set,
            args.root_dir,
            args.endpoints,
            args.report_suffix,
        )
    )
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
