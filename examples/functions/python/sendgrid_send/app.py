import json
import urllib.request


def _bool(v):
    if v is None:
        return False
    s = str(v).strip().lower()
    return s in ("1", "true", "yes", "on")


def _json(status, obj):
    return {
        "status": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(obj, separators=(",", ":")),
    }


def _read_payload(event):
    method = (event.get("method") or "GET").upper()
    query = event.get("query") or {}
    body_raw = event.get("body") or ""
    payload = {}
    if method in ("POST", "PUT", "PATCH") and body_raw:
        try:
            payload = json.loads(body_raw)
        except Exception:
            payload = {}
    return query, payload


def handler(event):
    env = event.get("env") or {}
    ctx = event.get("context") or {}

    query, payload = _read_payload(event)

    to_email = (payload.get("to") if isinstance(payload, dict) else None) or query.get("to") or "demo@example.com"
    subject = (payload.get("subject") if isinstance(payload, dict) else None) or query.get("subject") or "Hello"
    text = (payload.get("text") if isinstance(payload, dict) else None) or query.get("text") or "Hello from fastfn"
    dry_run = _bool(query.get("dry_run", "true"))

    api_key = env.get("SENDGRID_API_KEY") or ""
    from_email = env.get("SENDGRID_FROM") or ""

    req_body = {
        "personalizations": [{"to": [{"email": str(to_email)}]}],
        "from": {"email": str(from_email or "demo@example.com")},
        "subject": str(subject),
        "content": [{"type": "text/plain", "value": str(text)}],
    }

    if dry_run:
        return _json(
            200,
            {
                "function": "sendgrid_send",
                "dry_run": True,
                "ok": True,
                "missing_env": [k for k in ("SENDGRID_API_KEY", "SENDGRID_FROM") if not env.get(k)],
                "request": {
                    "method": "POST",
                    "url": "https://api.sendgrid.com/v3/mail/send",
                    "headers": {"Authorization": api_key and "<hidden>" or ""},
                    "body": req_body,
                },
                "note": "Set dry_run=false and provide SENDGRID_API_KEY + SENDGRID_FROM in fn.env.json to send.",
            },
        )

    if not api_key:
        return _json(400, {"ok": False, "error": "missing env SENDGRID_API_KEY"})
    if not from_email:
        return _json(400, {"ok": False, "error": "missing env SENDGRID_FROM"})

    timeout_ms = int(ctx.get("timeout_ms") or 5000)
    data = json.dumps(req_body, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        "https://api.sendgrid.com/v3/mail/send",
        method="POST",
        data=data,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "fastfn-sendgrid",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=max(1, timeout_ms / 1000)) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return _json(200, {"ok": True, "sendgrid_status": resp.status, "sendgrid_body": raw})
    except Exception as exc:
        return _json(502, {"ok": False, "error": str(exc)})

