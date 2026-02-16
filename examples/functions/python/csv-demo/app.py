def handler(event):
    q = event.get("query") or {}
    rows = [
        ["id", "name", "runtime"],
        ["1", q.get("name", "world"), "python"],
    ]
    csv_text = "\n".join([",".join(r) for r in rows]) + "\n"
    return {
        "status": 200,
        "headers": {"Content-Type": "text/csv; charset=utf-8"},
        "body": csv_text,
    }
