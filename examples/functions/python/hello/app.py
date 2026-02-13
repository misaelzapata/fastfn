import json


def handler(event):
    query = event.get("query") or {}
    name = query.get("name", "world")
    env = event.get("env") or {}
    ctx = event.get("context") or {}
    debug_enabled = ((ctx.get("debug") or {}).get("enabled")) is True

    message = name
    prefix = env.get("GREETING_PREFIX")
    if prefix:
        message = f"{prefix} {name}"

    payload = {"hello": message}
    if debug_enabled:
        payload["debug"] = {
            "request_id": event.get("id"),
            "runtime": "python",
            "function": "hello",
            "trace_id": (ctx.get("user") or {}).get("trace_id"),
        }

    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload, separators=(",", ":")),
    }
