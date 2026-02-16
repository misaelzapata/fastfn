import json


def handler(event):
    params = event.get("params") or {}
    query = event.get("query") or {}
    raw_name = params.get("name") or query.get("name") or "world"
    name = str(raw_name)
    lang = str(query.get("lang") or "en").lower()
    greeting = "Hola" if lang.startswith("es") else "Hello"

    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "route": "GET /hello-demo/:name",
                "runtime": "python",
                "message": f"{greeting} {name}",
                "name": name,
                "params": params,
                "query": query,
            },
            separators=(",", ":"),
        ),
    }
