from _shared import build_blog_payload


def handler(event):
    return build_blog_payload("GET /blog/:slug*", event.get("params") or {})
