def handler(event, category, slug):
    """GET /posts/:category/:slug — both params arrive directly"""
    return {
        "status": 200,
        "body": {
            "category": category,
            "slug": slug,
            "title": f"{category}/{slug}",
            "url": f"/posts/{category}/{slug}",
        },
    }
