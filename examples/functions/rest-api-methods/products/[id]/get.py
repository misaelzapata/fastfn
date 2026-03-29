def handler(event, id):
    """GET /products/:id — id arrives directly from [id] filename"""
    return {
        "status": 200,
        "body": {"id": int(id), "name": "Widget", "price": 9.99},
    }
