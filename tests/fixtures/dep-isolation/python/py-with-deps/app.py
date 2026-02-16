import json
import os


HITS = 0


def handler(event):
    global HITS
    HITS += 1
    try:
        import requests  # noqa: F811 — installed via requirements.txt

        return {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "ok": True,
                    "runtime": "python",
                    "has_requests": True,
                    "requests_version": requests.__version__,
                    "pid": os.getpid(),
                    "hits": HITS,
                },
                separators=(",", ":"),
            ),
        }
    except ImportError as exc:
        return {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "ok": False,
                    "runtime": "python",
                    "has_requests": False,
                    "error": str(exc),
                },
                separators=(",", ":"),
            ),
        }
