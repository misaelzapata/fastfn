import hmac
import hashlib
import json
import time


def _bool(v):
    if v is None:
        return False
    s = str(v).strip().lower()
    return s in ("1", "true", "yes", "on")


def _parse_sig_header(raw: str) -> dict:
    out = {"t": None, "v1": []}
    if not raw:
        return out
    parts = [p.strip() for p in raw.split(",") if p.strip()]
    for p in parts:
        if "=" not in p:
            continue
        k, v = p.split("=", 1)
        if k == "t":
            out["t"] = v
        elif k == "v1":
            out["v1"].append(v)
    return out


def _timing_safe_any_match(expected: str, candidates: list[str]) -> bool:
    for c in candidates:
        try:
            if hmac.compare_digest(expected, c):
                return True
        except Exception:
            continue
    return False


def handler(event):
    env = event.get("env") or {}
    headers = event.get("headers") or {}
    raw_body = event.get("body") or ""

    secret = env.get("STRIPE_WEBHOOK_SECRET") or ""
    sig_header = headers.get("stripe-signature") or headers.get("Stripe-Signature") or ""

    query = event.get("query") or {}
    dry_run = _bool(query.get("dry_run", "true"))
    tolerance_s = int(query.get("tolerance_s", 300) or 300)

    parsed = _parse_sig_header(str(sig_header))
    ts = parsed.get("t")
    candidates = parsed.get("v1") or []

    base = f"{ts}.{raw_body}" if ts else ""
    expected = ""
    if secret and ts:
        expected = hmac.new(str(secret).encode("utf-8"), base.encode("utf-8"), hashlib.sha256).hexdigest()

    now = int(time.time())
    ts_int = None
    try:
        ts_int = int(ts) if ts else None
    except Exception:
        ts_int = None

    issues = []
    if not sig_header:
        issues.append("missing Stripe-Signature header")
    if not secret:
        issues.append("missing env STRIPE_WEBHOOK_SECRET")
    if ts_int is None:
        issues.append("missing or invalid signature timestamp (t=...)")
    if ts_int is not None and abs(now - ts_int) > tolerance_s:
        issues.append("signature timestamp outside tolerance")

    ok = False
    if expected and candidates and ts_int is not None and abs(now - ts_int) <= tolerance_s:
        ok = _timing_safe_any_match(expected, [str(x) for x in candidates])
        if not ok:
            issues.append("signature mismatch")

    if dry_run:
        return {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "function": "stripe_webhook_verify",
                    "dry_run": True,
                    "ok": ok,
                    "issues": issues,
                    "note": "Set query dry_run=false and provide STRIPE_WEBHOOK_SECRET + Stripe-Signature header to enforce.",
                },
                separators=(",", ":"),
            ),
        }

    if not ok:
        return {
            "status": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"ok": False, "issues": issues}, separators=(",", ":")),
        }

    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"ok": True}, separators=(",", ":")),
    }

