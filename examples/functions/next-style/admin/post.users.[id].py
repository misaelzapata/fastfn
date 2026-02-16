import json


def handler(event):
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "route": "POST /admin/users/:id",
            "params": event.get("params") or {},
            "runtime": "python",
        }),
    }
