def handler(event, slug):
    """GET /posts/:slug — slug arrives directly from [slug] filename"""
    return {
        "status": 200,
        "body": {"slug": slug, "title": f"Post: {slug}", "content": "Lorem ipsum..."},
    }
