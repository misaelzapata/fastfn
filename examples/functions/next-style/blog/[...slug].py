import json


def handler(event):
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "route": "/blog/:slug*",
            "params": event.get("params") or {},
            "runtime": "python",
        }),
    }
