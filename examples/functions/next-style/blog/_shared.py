import json


def respond(payload):
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def build_blog_payload(route, params=None, intro=None):
    params = dict(params or {})
    payload = {
        "route": route,
        "params": params,
        "runtime": "python",
        "helper": "blog/_shared.py",
    }
    slug = params.get("slug")
    if isinstance(slug, str) and slug:
        payload["slug"] = slug
    if intro:
        payload["intro"] = intro
    return respond(payload)
