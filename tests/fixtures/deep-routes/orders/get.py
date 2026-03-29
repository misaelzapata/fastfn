def handler(event):
    return {
        "status": 200,
        "body": {"route": "GET /orders", "params": event.get("params", {})}
    }
