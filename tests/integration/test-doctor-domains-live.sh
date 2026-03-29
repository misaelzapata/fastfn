#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_LIVE="${RUN_LIVE_DOMAIN_TESTS:-${FASTFN_RUN_LIVE_DOMAIN_TESTS:-0}}"
DOMAINS_CSV="${FASTFN_LIVE_DOMAIN_LIST:-example.com}"

if [[ "$RUN_LIVE" != "1" ]]; then
  echo "SKIP live domain smoke (set RUN_LIVE_DOMAIN_TESTS=1)"
  exit 0
fi

ensure_cli_built() {
  if [[ ! -x "$ROOT_DIR/bin/fastfn" ]]; then
    "$ROOT_DIR/cli/build.sh"
    return
  fi
  if find "$ROOT_DIR/cli" -type f -newer "$ROOT_DIR/bin/fastfn" -print -quit 2>/dev/null | grep -q .; then
    "$ROOT_DIR/cli/build.sh"
    return
  fi
}

run_one() {
  local domain="$1"
  local out err status
  out="$(mktemp -t fastfn-live-domain.XXXXXX.json)"
  err="$(mktemp -t fastfn-live-domain.XXXXXX.err)"

  set +e
  "$ROOT_DIR/bin/fastfn" doctor domains --domain "$domain" --json >"$out" 2>"$err"
  status="$?"
  set -e

  if [[ "$status" != "0" && "$status" != "1" ]]; then
    echo "FAIL live domain smoke unexpected exit for $domain: $status"
    sed -n '1,200p' "$out" || true
    sed -n '1,120p' "$err" || true
    rm -f "$out" "$err"
    exit 1
  fi

  python3 - "$out" "$domain" <<'PY'
import json
import sys

path = sys.argv[1]
domain = sys.argv[2]

with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

if data.get("scope") != "domains":
    raise SystemExit(f"unexpected scope: {data.get('scope')!r}")

checks = data.get("checks")
if not isinstance(checks, list) or not checks:
    raise SystemExit("expected non-empty checks list")

summary = data.get("summary")
if not isinstance(summary, dict):
    raise SystemExit("expected summary object")

allowed_status = {"OK", "WARN", "FAIL"}
status_total = 0
per_id = {}
for check in checks:
    status = check.get("status")
    if status not in allowed_status:
        raise SystemExit(f"unexpected status: {status!r}")
    status_total += 1
    if check.get("domain") == domain:
        per_id[check.get("id")] = check

required_ids = [
    "domain.format",
    "dns.resolve",
    "tls.handshake",
    "https.reachability",
    "http.redirect",
    "acme.challenge",
]
missing = [item for item in required_ids if item not in per_id]
if missing:
    raise SystemExit(f"missing live checks for {domain}: {missing}")

if per_id["domain.format"].get("status") != "OK":
    raise SystemExit("domain.format must be OK for live smoke")

if summary.get("ok", 0) + summary.get("warn", 0) + summary.get("fail", 0) != status_total:
    raise SystemExit("summary totals do not match checks length")
PY

  echo "PASS live domain smoke: $domain (exit=$status)"
  rm -f "$out" "$err"
}

ensure_cli_built

IFS=',' read -r -a domain_items <<< "$DOMAINS_CSV"
for raw in "${domain_items[@]}"; do
  domain="$(printf '%s' "$raw" | xargs)"
  if [[ -z "$domain" ]]; then
    continue
  fi
  run_one "$domain"
done
