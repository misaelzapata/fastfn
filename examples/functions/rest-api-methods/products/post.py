import json

def handler(event):
    """POST /products — create a product"""
    body = event.get("body", "")
    try:
        data = json.loads(body) if isinstance(body, str) else (body or {})
    except Exception:
        return {"status": 400, "body": {"error": "Invalid JSON"}}

    name = data.get("name", "").strip()
    price = data.get("price", 0)

    if not name:
        return {"status": 400, "body": {"error": "name is required"}}

    return {
        "status": 201,
        "body": {"id": 42, "name": name, "price": price, "created": True},
    }
