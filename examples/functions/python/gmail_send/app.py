import json
import smtplib
from email.message import EmailMessage


def _parse_json(raw):
    if raw is None or raw == "":
        return {}
    if isinstance(raw, dict):
        return raw
    if not isinstance(raw, str):
        return {}
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            return parsed
    except Exception:
        return {}
    return {}


def _bool(v, default=True):
    if v is None:
        return default
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() not in {"0", "false", "off", "no"}


def handler(event):
    query = event.get("query") or {}
    body = _parse_json(event.get("body"))
    env = event.get("env") or {}

    to_addr = body.get("to") or query.get("to")
    subject = body.get("subject") or query.get("subject") or "fastfn message"
    text = body.get("text") or query.get("text") or "hello from fastfn"
    dry_run = _bool(body.get("dry_run") if "dry_run" in body else query.get("dry_run"), True)

    smtp_host = env.get("GMAIL_HOST") or "smtp.gmail.com"
    smtp_port = int(env.get("GMAIL_PORT") or 465)
    smtp_user = env.get("GMAIL_USER")
    smtp_password = env.get("GMAIL_APP_PASSWORD")
    from_addr = body.get("from") or query.get("from") or env.get("GMAIL_FROM") or smtp_user

    if not to_addr:
        return {
            "status": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "to is required"}, separators=(",", ":")),
        }

    response = {
        "channel": "gmail",
        "to": to_addr,
        "subject": subject,
        "dry_run": dry_run,
        "transport": {"host": smtp_host, "port": smtp_port},
    }

    if dry_run or not smtp_user or not smtp_password:
        if not smtp_user or not smtp_password:
            response["note"] = "GMAIL_USER/GMAIL_APP_PASSWORD not configured; forced dry_run"
        return {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(response, separators=(",", ":")),
        }

    msg = EmailMessage()
    msg["From"] = from_addr or smtp_user
    msg["To"] = to_addr
    msg["Subject"] = subject
    msg.set_content(text)

    try:
        with smtplib.SMTP_SSL(smtp_host, smtp_port, timeout=20) as smtp:
            smtp.login(smtp_user, smtp_password)
            smtp.send_message(msg)
    except Exception as exc:
        return {
            "status": 502,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": f"gmail send failed: {exc}"}, separators=(",", ":")),
        }

    response["sent"] = True
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(response, separators=(",", ":")),
    }
