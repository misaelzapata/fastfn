import json


def handler(event):
    query = event.get("query") or {}
    value = query.get("v", "ok")
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"value": value}, separators=(",", ":")),
    }
