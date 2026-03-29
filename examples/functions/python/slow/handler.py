import json
import time


def handler(event):
    query = event.get("query") or {}
    try:
        sleep_ms = int(query.get("sleep_ms") or 0)
    except Exception:
        sleep_ms = 0

    if sleep_ms > 0:
        time.sleep(sleep_ms / 1000.0)

    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "runtime": "python",
                "function": "slow",
                "slept_ms": sleep_ms,
            },
            separators=(",", ":"),
        ),
    }
