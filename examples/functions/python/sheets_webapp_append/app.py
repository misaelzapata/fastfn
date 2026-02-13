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


def handler(event):
    env = event.get("env") or {}
    ctx = event.get("context") or {}
    query = event.get("query") or {}

    url = env.get("SHEETS_WEBAPP_URL") or ""
    dry_run = _bool(query.get("dry_run", "true"))

    sheet = query.get("sheet") or "Sheet1"
    values_raw = query.get("values") or "hello,world"
    values = [x.strip() for x in str(values_raw).split(",") if x.strip()]

    payload = {"sheet": str(sheet), "values": values}

    if dry_run:
        return _json(
            200,
            {
                "function": "sheets_webapp_append",
                "dry_run": True,
                "ok": True,
                "missing_env": ["SHEETS_WEBAPP_URL"] if not url else [],
                "request": {
                    "method": "POST",
                    "url": url and "<hidden>" or "",
                    "body": payload,
                },
                "note": "This expects a Google Apps Script Web App URL that appends rows. Set dry_run=false and provide SHEETS_WEBAPP_URL.",
            },
        )

    if not url:
        return _json(400, {"ok": False, "error": "missing env SHEETS_WEBAPP_URL"})

    timeout_ms = int(ctx.get("timeout_ms") or 5000)
    data = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        str(url),
        method="POST",
        data=data,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "fastfn-sheets-webapp",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=max(1, timeout_ms / 1000)) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return _json(200, {"ok": True, "status": resp.status, "body": raw})
    except Exception as exc:
        return _json(502, {"ok": False, "error": str(exc)})

