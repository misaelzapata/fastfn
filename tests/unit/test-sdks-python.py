#!/usr/bin/env python3
from __future__ import annotations

from sdk.python.fastfn.extras import json_response, validate
from sdk.python.fastfn.response import Response
from sdk.python.fastfn.types import Request, Response as ResponseDict


def main() -> None:
    event: Request = {
        "id": "req-sdk-1",
        "ts": 1700000000000,
        "method": "GET",
        "path": "/users",
        "raw_path": "/users?active=1",
        "query": {"active": "1"},
        "headers": {"accept": "application/json"},
        "body": "",
        "client": {"ip": "127.0.0.1", "ua": "pytest"},
        "context": {"request_id": "req-sdk-1", "function_name": "users"},
        "env": {"FOO": "bar"},
    }

    resp: ResponseDict = Response.json({"ok": True})
    txt: ResponseDict = Response.text("hello", status=201)
    pxy: ResponseDict = Response.proxy("/request-inspector", "post", {"X-Trace": "abc"})

    assert event["id"] == "req-sdk-1"
    assert resp["status"] == 200
    assert resp["headers"]["Content-Type"] == "application/json"
    assert txt["status"] == 201
    assert txt["headers"]["Content-Type"].startswith("text/plain")
    assert txt["body"] == "hello"
    assert pxy["proxy"]["path"] == "/request-inspector"
    assert pxy["proxy"]["method"] == "POST"
    assert pxy["proxy"]["headers"]["X-Trace"] == "abc"

    jr = json_response({"ok": True}, status=201, headers={"X-Test": "1"})
    assert jr["status"] == 201
    assert jr["headers"]["Content-Type"] == "application/json"

    try:
        from pydantic import BaseModel
    except Exception:
        try:
            validate(None, {})  # type: ignore[arg-type]
        except ImportError:
            pass
    else:
        class Demo(BaseModel):
            x: int

        demo = validate(Demo, {"x": 1})
        assert demo.x == 1

    print("Python SDK: OK")


if __name__ == "__main__":
    main()
