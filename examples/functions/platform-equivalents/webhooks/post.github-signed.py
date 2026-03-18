# POST /webhooks/github-signed — Receive a GitHub webhook with signature verification
import hashlib
import hmac
import json

DEFAULT_SECRET = "fastfn-webhook-secret"


def handler(event):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    # Step 1: Require the signature header
    signature = headers.get("x-hub-signature-256", "")
    if not signature:
        return {"status": 401, "body": json.dumps({"error": "Missing x-hub-signature-256 header"})}

    # Step 2: Verify the HMAC-SHA256 signature against the raw body
    body_raw = event.get("body") or ""
    if not isinstance(body_raw, str):
        body_raw = json.dumps(body_raw, separators=(",", ":"))

    secret = ((event.get("env") or {}).get("WEBHOOK_SECRET") or DEFAULT_SECRET)
    expected = "sha256=" + hmac.new(secret.encode(), body_raw.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        return {"status": 401, "body": json.dumps({"error": "Signature mismatch"})}

    # Step 3: Process the verified webhook payload
    try:
        payload = json.loads(body_raw)
    except Exception:
        payload = {}

    return {
        "status": 202,
        "body": json.dumps({
            "ok": True,
            "event": headers.get("x-github-event", "unknown"),
            "action": payload.get("action"),
        }),
    }
