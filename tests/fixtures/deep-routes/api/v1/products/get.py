def handler(event):
    return {
        "status": 200,
        "body": {"route": "GET /api/v1/products", "params": event.get("params", {})}
    }
