from typing import Any, Callable, Dict, Optional, Type, TypeVar, Union, cast

try:
    from pydantic import BaseModel, ValidationError
except ImportError:
    BaseModel = None  # type: ignore

Model = TypeVar("Model", bound="BaseModel")

class ValidationRequestError(Exception):
    def __init__(self, errors: Any):
        self.errors = errors
        super().__init__("Validation failed")

def validate(model: Type[Model], data: Any) -> Model:
    """
    Validates data against a Pydantic model.
    Raises ValidationRequestError if validation fails.
    """
    if BaseModel is None:
        raise ImportError("pydantic is required for validation. Run `pip install pydantic`.")
    
    try:
        return model.model_validate(data)
    except ValidationError as e:
        raise ValidationRequestError(e.errors())

def json_response(
    body: Any, 
    status: int = 200, 
    headers: Optional[Dict[str, str]] = None
) -> Dict[str, Any]:
    """Helper to return a standard JSON response."""
    import json
    
    if headers is None:
        headers = {}
    
    if "Content-Type" not in headers:
        headers["Content-Type"] = "application/json"

    # Handle pydantic models automatically
    if hasattr(body, "model_dump"):
        body = body.model_dump()
    elif hasattr(body, "dict"):  # Pydantic v1 compatibility
        body = body.dict()

    return {
        "status": status,
        "headers": headers,
        "body": json.dumps(body) if not isinstance(body, str) else body
    }
