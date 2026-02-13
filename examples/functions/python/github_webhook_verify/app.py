import hmac
import hashlib
import json


def _bool(v):
    if v is None:
        return False
    s = str(v).strip().lower()
    return s in ("1", "true", "yes", "on")


def handler(event):
    env = event.get("env") or {}
    headers = event.get("headers") or {}
    raw_body = event.get("body") or ""

    secret = env.get("GITHUB_WEBHOOK_SECRET") or ""
    sig = headers.get("x-hub-signature-256") or headers.get("X-Hub-Signature-256") or ""

    query = event.get("query") or {}
    dry_run = _bool(query.get("dry_run", "true"))

    issues = []
    if not secret:
        issues.append("missing env GITHUB_WEBHOOK_SECRET")
    if not sig:
        issues.append("missing X-Hub-Signature-256 header")

    expected = ""
    if secret and raw_body is not None:
        digest = hmac.new(str(secret).encode("utf-8"), str(raw_body).encode("utf-8"), hashlib.sha256).hexdigest()
        expected = "sha256=" + digest

    ok = bool(expected and sig and hmac.compare_digest(str(expected), str(sig)))
    if sig and expected and not ok:
        issues.append("signature mismatch")

    if dry_run:
        return {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "function": "github_webhook_verify",
                    "dry_run": True,
                    "ok": ok,
                    "issues": issues,
                    "note": "Set query dry_run=false and provide GITHUB_WEBHOOK_SECRET + X-Hub-Signature-256 header to enforce.",
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

