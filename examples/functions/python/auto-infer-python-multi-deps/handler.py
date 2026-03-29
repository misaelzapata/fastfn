import json


def _inferred_imports_marker():
    import flask  # noqa: F401
    import httpx  # noqa: F401
    import requests  # noqa: F401
    return "multi-deps"


def handler(event):
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "runtime": "python",
                "function": "auto-infer-python-multi-deps",
                "inference": "multiple-imports",
            },
            separators=(",", ":"),
        ),
    }
