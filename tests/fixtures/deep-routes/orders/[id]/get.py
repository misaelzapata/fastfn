def handler(event):
    return {
        "status": 200,
        "body": {"route": "GET /orders/:id", "params": event.get("params", {})}
    }
