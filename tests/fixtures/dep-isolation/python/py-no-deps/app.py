import json


def handler(event):
    try:
        import requests  # should NOT be available — no requirements.txt here

        return {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "ok": True,
                    "runtime": "python",
                    "has_requests": True,
                    "requests_version": requests.__version__,
                    "isolation_broken": True,
                },
                separators=(",", ":"),
            ),
        }
    except ImportError:
        return {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "ok": True,
                    "runtime": "python",
                    "has_requests": False,
                    "isolation_ok": True,
                },
                separators=(",", ":"),
            ),
        }
