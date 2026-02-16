import json
import os


HITS = 0


def handler(event):
    global HITS
    HITS += 1
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "ok": True,
                "runtime": "python",
                "function": "py-persistent",
                "pid": os.getpid(),
                "hits": HITS,
            },
            separators=(",", ":"),
        ),
    }
