def handler(event):
    name = (event.get("query") or {}).get("name", "world")
    return {
        "status": 200,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": f"<html><body><h1>Hello {name}</h1><p>html_demo</p></body></html>",
    }
