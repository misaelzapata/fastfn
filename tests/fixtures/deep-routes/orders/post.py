def handler(event):
    return {
        "status": 200,
        "body": {"route": "POST /orders", "params": event.get("params", {})}
    }
