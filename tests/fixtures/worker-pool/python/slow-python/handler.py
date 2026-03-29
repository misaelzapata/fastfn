import json
import time


def handler(event):
    time.sleep(0.2)
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"ok": True, "runtime": "python"}),
    }

