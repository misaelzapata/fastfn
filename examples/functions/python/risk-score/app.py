import json


def _score_email(email):
    if not email:
        return 20
    if email.endswith("@example.com"):
        return 35
    return 5


def _score_ip(ip):
    if not ip:
        return 15
    if ip.startswith("10.") or ip.startswith("192.168."):
        return 25
    return 5


def handler(event):
    query = event.get("query") or {}
    headers = event.get("headers") or {}

    email = query.get("email") or headers.get("x-user-email")
    ip = (event.get("client") or {}).get("ip")

    score = _score_email(email) + _score_ip(ip)
    level = "high" if score >= 50 else "medium" if score >= 25 else "low"

    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "runtime": "python",
                "function": "risk-score",
                "score": score,
                "risk": level,
                "signals": {
                    "email": bool(email),
                    "ip": ip,
                },
            },
            separators=(",", ":"),
        ),
    }
