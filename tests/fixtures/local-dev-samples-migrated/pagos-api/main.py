from typing import Any, Dict, Optional

def handler(event: Any, context: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """
    Handle the request.
    """
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": {
            "message": "Hello from FastFn Python!",
            "input": event,
            "context": context,
        }
    }
