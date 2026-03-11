import json

def handler(event, id):
    """PUT /products/:id — id arrives directly from [id] filename"""
    body = event.get("body", "")
    try:
        data = json.loads(body) if isinstance(body, str) else (body or {})
    except Exception:
        return {"status": 400, "body": {"error": "Invalid JSON"}}

    return {
        "status": 200,
        "body": {"id": int(id), **data, "updated": True},
    }
