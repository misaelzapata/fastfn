def main(event):
    q = (event or {}).get("query") or {}
    name = q.get("name", "world")
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": '{"runtime":"python","handler":"main","hello":"%s"}' % str(name),
    }
