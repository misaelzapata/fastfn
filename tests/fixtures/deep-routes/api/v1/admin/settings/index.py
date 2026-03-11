def handler(event):
    return {
        "status": 200,
        "body": {"route": "GET /api/v1/admin/settings", "params": event.get("params", {})}
    }
