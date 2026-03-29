import json


def _inferred_imports_marker():
    # FastFN should infer and persist these packages into requirements.txt.
    import requests  # noqa: F401
    return "requests"


def handler(event):
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "runtime": "python",
                "function": "auto-infer-no-requirements",
                "inference": "enabled",
            },
            separators=(",", ":"),
        ),
    }
