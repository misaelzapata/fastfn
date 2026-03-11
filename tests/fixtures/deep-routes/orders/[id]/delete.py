def handler(event):
    return {
        "status": 200,
        "body": {"route": "DELETE /orders/:id", "params": event.get("params", {})}
    }
