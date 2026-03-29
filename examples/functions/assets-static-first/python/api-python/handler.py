import json


def handler(_event):
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "runtime": "python",
                "title": "Python fallback route",
                "summary": "The gateway misses on public/ and then dispatches to Python.",
                "path": "/api-python",
            },
            separators=(",", ":"),
        ),
    }
