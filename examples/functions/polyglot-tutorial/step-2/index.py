import json


def handler(event):
    query = event.get("query") or {}
    name = query.get("name") or "friend"
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "step": 2,
                "message": f"Hello {name} from Python.",
                "runtime": "python",
                "name": name,
            }
        ),
    }
