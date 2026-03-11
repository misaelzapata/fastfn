def handler(event, id):
    """DELETE /products/:id — id arrives directly from [id] filename"""
    return {
        "status": 200,
        "body": {"id": int(id), "deleted": True},
    }
