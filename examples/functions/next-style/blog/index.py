from _shared import build_blog_payload


def handler(event):
    return build_blog_payload(
        "GET /blog",
        event.get("params") or {},
        intro="Blog root endpoint using a private helper module.",
    )
