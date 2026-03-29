def handler(event):
    return {
        "status": 200,
        "body": {"route": "PUT /orders/:id", "params": event.get("params", {})}
    }
