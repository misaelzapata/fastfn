#!/usr/bin/env python3
import argparse
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter


def worker(base_url, path, total, counter, lock, timeout):
    while True:
        with lock:
            if counter["sent"] >= total:
                return
            counter["sent"] += 1
        url = base_url + path
        req = urllib.request.Request(url, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                code = resp.getcode()
        except urllib.error.HTTPError as e:
            code = e.code
        except Exception:
            code = 0
        with lock:
            counter["status"][code] += 1


def main():
    p = argparse.ArgumentParser(description="Simple HTTP stress runner")
    p.add_argument("--base-url", default="http://127.0.0.1:8080")
    p.add_argument("--path", required=True)
    p.add_argument("--total", type=int, default=200)
    p.add_argument("--concurrency", type=int, default=20)
    p.add_argument("--timeout", type=float, default=2.5)
    p.add_argument("--expect", type=int, nargs="*", default=[200])
    args = p.parse_args()

    counter = {
        "sent": 0,
        "status": Counter(),
    }
    lock = threading.Lock()

    start = time.time()
    threads = []
    for _ in range(max(1, args.concurrency)):
        t = threading.Thread(
            target=worker,
            args=(args.base_url, args.path, args.total, counter, lock, args.timeout),
            daemon=True,
        )
        t.start()
        threads.append(t)

    for t in threads:
        t.join()

    elapsed = time.time() - start
    status = dict(sorted(counter["status"].items(), key=lambda kv: kv[0]))

    summary = {
        "base_url": args.base_url,
        "path": args.path,
        "total": args.total,
        "concurrency": args.concurrency,
        "elapsed_sec": round(elapsed, 3),
        "rps": round(args.total / elapsed, 2) if elapsed > 0 else 0,
        "status": status,
    }
    print(json.dumps(summary, ensure_ascii=True))

    allowed = set(args.expect)
    bad = {code: count for code, count in status.items() if code not in allowed}
    if bad:
        raise SystemExit(f"unexpected statuses: {bad}")


if __name__ == "__main__":
    main()
