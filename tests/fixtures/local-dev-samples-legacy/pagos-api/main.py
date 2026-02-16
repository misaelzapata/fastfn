from typing import Any, Dict

def handler(event: Any, context: Dict[str, Any]) -> Dict[str, Any]:
    """
    Handle the request.
    """
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": {
            "message": "Hello from FastFn Python!",
            "input": event
        }
    }
