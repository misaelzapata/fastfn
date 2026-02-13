#@requirements requests
import json


def handler(event):
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"runtime": "python", "function": "requirements_demo"}, separators=(",", ":")),
    }
