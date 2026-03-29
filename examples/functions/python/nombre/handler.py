import json


def handler(event):
    query = event.get("query") or {}
    name = query.get("name", "world")

    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "runtime": "python",
                "function": "hello",
                "hello": name,
                "request_id": event.get("id"),
            },
            separators=(",", ":"),
        ),
    }
