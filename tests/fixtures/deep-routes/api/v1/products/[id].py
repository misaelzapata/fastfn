def handler(event):
    return {
        "status": 200,
        "body": {"route": "GET /api/v1/products/:id", "params": event.get("params", {})}
    }
