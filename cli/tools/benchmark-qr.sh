#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-default}"          # default | no-throttle
TOTAL="${TOTAL:-160}"
CONCURRENCY_SET="${CONCURRENCY_SET:-1,2,4,6,8}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
AUTO_STACK="${AUTO_STACK:-1}" # 1 => docker compose up/down in this script

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ "$MODE" != "default" && "$MODE" != "no-throttle" ]]; then
  echo "usage: $0 [default|no-throttle]"
  exit 1
fi

cleanup() {
  if [[ "$AUTO_STACK" == "1" ]]; then
    docker compose -f "$ROOT_DIR/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "$AUTO_STACK" == "1" ]]; then
  docker compose -f "$ROOT_DIR/docker-compose.yml" up -d --build >/dev/null
fi

python3 - <<'PY' "$BASE_URL"
import json
import sys
import time
import urllib.request

base = sys.argv[1]
for _ in range(90):
    try:
        with urllib.request.urlopen(base + "/_fn/health", timeout=2.0) as r:
            obj = json.loads(r.read().decode("utf-8"))
        runtimes = obj.get("runtimes", {})
        py_up = (((runtimes.get("python") or {}).get("health") or {}).get("up") is True)
        node_up = (((runtimes.get("node") or {}).get("health") or {}).get("up") is True)
        if py_up and node_up:
            print("health ready")
            break
    except Exception:
        pass
    time.sleep(1)
else:
    raise SystemExit("health not ready for python/node")
PY

if [[ "$MODE" == "no-throttle" ]]; then
  curl -sS -X PUT "$BASE_URL/_fn/function-config?runtime=python&name=qr" \
    -H 'Content-Type: application/json' \
    --data '{"max_concurrency":512,"timeout_ms":60000,"invoke":{"methods":["GET"]}}' >/dev/null

  curl -sS -X PUT "$BASE_URL/_fn/function-config?runtime=node&name=qr&version=v2" \
    -H 'Content-Type: application/json' \
    --data '{"max_concurrency":512,"timeout_ms":60000,"invoke":{"methods":["GET"]}}' >/dev/null
fi

python3 - <<'PY' "$BASE_URL" "$MODE" "$TOTAL" "$CONCURRENCY_SET" "$ROOT_DIR"
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

base_url, mode, total_raw, conc_raw, root_dir = sys.argv[1:6]
total = int(total_raw)
concurrency_levels = [int(x) for x in conc_raw.split(",") if x.strip()]

domains = [
    "https://github.com/misaelzapata/fastfn",
    "https://openai.com",
    "https://example.org/path?x=1&y=2",
    "https://n8n.io/workflows",
]
endpoints = ["/qr", "/qr@v2"]

def run_case(path: str, concurrency: int, total_requests: int):
    lock = threading.Lock()
    sent = {"n": 0}
    status = Counter()
    samples = {}

    def worker():
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
                if code not in (200, 429) and code not in samples:
                    samples[code] = body[:180]

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

rows = []
for endpoint in endpoints:
    for domain in domains:
        encoded = urllib.parse.quote(domain, safe="")
        path = f"{endpoint}?text={encoded}"
        for concurrency in concurrency_levels:
            row = run_case(path, concurrency, total)
            rows.append({"endpoint": endpoint, "domain": domain, **row})

results_dir = Path(root_dir) / "tests" / "stress" / "results"
results_dir.mkdir(parents=True, exist_ok=True)
out_path = results_dir / f"{time.strftime('%Y-%m-%d')}-qr-{mode}.json"
out_path.write_text(json.dumps(rows, ensure_ascii=True, indent=2), encoding="utf-8")

print(f"saved: {out_path}")
print("endpoint,domain,best_clean_concurrency,best_clean_rps")
for endpoint in sorted({r["endpoint"] for r in rows}):
    for domain in sorted({r["domain"] for r in rows if r["endpoint"] == endpoint}):
        clean = [
            r for r in rows
            if r["endpoint"] == endpoint and r["domain"] == domain
            and list(r["status"].keys()) == [200]
            and r["status"].get(200) == r["total"]
        ]
        if not clean:
            print(f"{endpoint},{domain},n/a,n/a")
            continue
        best = max(clean, key=lambda x: x["rps"])
        print(f"{endpoint},{domain},{best['concurrency']},{best['rps']}")
PY
