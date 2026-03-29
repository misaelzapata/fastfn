from typing import Any, Dict, Optional, Union, TypedDict, Literal

class DebugContext(TypedDict, total=False):
    enabled: bool

class UserContext(TypedDict, total=False):
    id: str
    sub: str

class ClientContext(TypedDict):
    ip: str
    ua: Optional[str]

class Context(TypedDict, total=False):
    request_id: str
    function_name: str
    runtime: str
    version: str
    debug: DebugContext
    user: UserContext

class Request(TypedDict):
    id: str
    ts: int
    method: Literal["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"]
    path: str
    raw_path: str
    query: Dict[str, str]
    headers: Dict[str, str]
    body: Union[str, Dict[str, Any], Any]
    client: ClientContext
    context: Context
    env: Dict[str, str]

class ProxyDirective(TypedDict, total=False):
    path: str
    method: str
    headers: Dict[str, str]

class Response(TypedDict, total=False):
    status: int
    headers: Dict[str, str]
    body: Union[str, Dict[str, Any]]
    proxy: ProxyDirective
    is_base64: bool

# Type alias for the handler function signature
# def handler(event: Request) -> Response: ...
