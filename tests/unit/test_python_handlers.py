#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_handler(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[attr-defined]
    return mod.handler


def assert_response_contract(resp):
    assert isinstance(resp, dict), "response must be an object"
    assert isinstance(resp.get("status"), int), "status must be int"
    assert isinstance(resp.get("headers"), dict), "headers must be object"
    assert isinstance(resp.get("body"), str), "body must be string"


def test_python_hello():
    handler = load_handler(ROOT / "examples/functions/python/hello/app.py")
    resp = handler({"query": {"name": "Unit"}, "id": "req-1", "context": {"user": {"trace_id": "trace-1"}}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["hello"] == "Unit"
    assert "debug" not in body


def test_python_hello_debug():
    handler = load_handler(ROOT / "examples/functions/python/hello/app.py")
    resp = handler(
        {
            "query": {"name": "Unit"},
            "id": "req-1",
            "context": {"debug": {"enabled": True}, "user": {"trace_id": "trace-1"}},
        }
    )
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["hello"] == "Unit"
    assert body["debug"]["request_id"] == "req-1"
    assert body["debug"]["trace_id"] == "trace-1"


def test_python_risk_score():
    handler = load_handler(ROOT / "examples/functions/python/risk_score/app.py")
    resp = handler({"query": {"email": "user@example.com"}, "client": {"ip": "192.168.1.10"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["runtime"] == "python"
    assert body["function"] == "risk_score"
    assert isinstance(body["score"], int)
    assert body["risk"] in {"low", "medium", "high"}


def test_python_lambda_echo_shape():
    handler = load_handler(ROOT / "examples/functions/python/lambda_echo/app.py")
    resp = handler({"query": {"name": "Unit"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["hello"] == "Unit"


def test_python_custom_echo_shape():
    handler = load_handler(ROOT / "examples/functions/python/custom_echo/app.py")
    resp = handler({"query": {"v": "abc"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["value"] == "abc"


def test_python_gmail_send_dry_run():
    handler = load_handler(ROOT / "examples/functions/python/gmail_send/app.py")
    resp = handler(
        {
            "query": {
                "to": "demo@example.com",
                "subject": "Hello",
                "text": "Body",
                "dry_run": "true",
            }
        }
    )
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["channel"] == "gmail"
    assert body["to"] == "demo@example.com"
    assert body["dry_run"] is True


def main():
    test_python_hello()
    test_python_hello_debug()
    test_python_risk_score()
    test_python_lambda_echo_shape()
    test_python_custom_echo_shape()
    test_python_gmail_send_dry_run()
    print("python unit tests passed")


if __name__ == "__main__":
    main()
