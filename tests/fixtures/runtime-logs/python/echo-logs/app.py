def handler(event):
    print(event)
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": "{\"ok\":true}",
    }
