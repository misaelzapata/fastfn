from __future__ import annotations

import json
from typing import Any, Dict, Optional

from .types import ProxyDirective, Response as ResponseDict


class Response:
    """Helpers to build FastFN-compatible response payloads."""

    @staticmethod
    def json(
        body: Any,
        status: int = 200,
        headers: Optional[Dict[str, str]] = None,
    ) -> ResponseDict:
        merged_headers: Dict[str, str] = {"Content-Type": "application/json"}
        if headers:
            merged_headers.update(headers)
        return {
            "status": int(status),
            "headers": merged_headers,
            "body": json.dumps(body),
        }

    @staticmethod
    def text(
        body: str,
        status: int = 200,
        headers: Optional[Dict[str, str]] = None,
    ) -> ResponseDict:
        merged_headers: Dict[str, str] = {
            "Content-Type": "text/plain; charset=utf-8"
        }
        if headers:
            merged_headers.update(headers)
        return {
            "status": int(status),
            "headers": merged_headers,
            "body": str(body),
        }

    @staticmethod
    def proxy(
        path: str,
        method: str = "GET",
        headers: Optional[Dict[str, str]] = None,
    ) -> ResponseDict:
        directive: ProxyDirective = {
            "path": str(path),
            "method": str(method).upper(),
        }
        if headers:
            directive["headers"] = headers
        return {"proxy": directive}
