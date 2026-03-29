import json
from datetime import datetime, timezone


def handler(event):
    ctx = event.get("context") or {}
    trigger = ctx.get("trigger") or {}
    now_utc = datetime.now(timezone.utc).isoformat()
    now_local = datetime.now().astimezone().isoformat()

    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "function": "utc-time",
                "now_utc": now_utc,
                "now_local": now_local,
                "trigger": trigger,
            },
            separators=(",", ":"),
        ),
    }

