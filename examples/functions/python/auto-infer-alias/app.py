import json


def _inferred_alias_marker():
    # PIL -> Pillow alias should be inferred automatically.
    from PIL import Image  # noqa: F401
    return "Pillow"


def handler(event):
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "runtime": "python",
                "function": "auto-infer-alias",
                "alias_example": "PIL -> Pillow",
            },
            separators=(",", ":"),
        ),
    }
