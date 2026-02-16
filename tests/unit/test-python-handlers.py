#!/usr/bin/env python3
import importlib.util
import json
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


def load_handler(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[attr-defined]
    return mod.handler


def load_module(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[attr-defined]
    return mod


PYTHON_DAEMON = load_module(ROOT / "srv/fn/runtimes/python-daemon.py")


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


def test_python_risk_score_branches():
    handler = load_handler(ROOT / "examples/functions/python/risk_score/app.py")

    low_resp = handler({"query": {"email": "user@public.test"}, "client": {"ip": "8.8.8.8"}})
    assert_response_contract(low_resp)
    low_body = json.loads(low_resp["body"])
    assert low_body["score"] == 10
    assert low_body["risk"] == "low"

    medium_resp = handler({"query": {}, "headers": {}, "client": {}})
    assert_response_contract(medium_resp)
    medium_body = json.loads(medium_resp["body"])
    assert medium_body["score"] == 35
    assert medium_body["risk"] == "medium"


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


def test_python_openclaw_single_dry_run_plan():
    handler = load_handler(ROOT / "examples/functions/python/openclaw-single/app.py")
    resp = handler({"query": {"text": "quiero saber mi ip", "dry_run": "true"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["agent"] == "openclaw-single-py"
    assert body["dry_run"] is True
    assert isinstance(body.get("planned_tools"), list) and len(body["planned_tools"]) >= 1
    assert body["planned_tools"][0]["tool"] == "ip_lookup"
    assert body["tool_results"] == []


def test_python_openclaw_single_exec_with_mocked_http():
    mod = load_module(ROOT / "examples/functions/python/openclaw-single/app.py")
    handler = mod.handler
    seen = []

    def fake_http(url, timeout_ms):
        seen.append((url, timeout_ms))
        if "api.ipify.org" in url:
            return {"ok": True, "status": 200, "elapsed_ms": 7, "data": {"ip": "1.2.3.4"}}
        if "api.agify.io" in url:
            return {"ok": True, "status": 200, "elapsed_ms": 9, "data": {"name": "ana", "age": 31}}
        return {"ok": False, "status": 404, "elapsed_ms": 4, "error": "not found", "data": {}}

    original = mod._http_get_json
    mod._http_get_json = fake_http
    try:
        resp = handler(
            {
                "query": {
                    "text": "proba tools",
                    "tool": "ip_lookup,age_predict",
                    "name": "ana",
                    "dry_run": "false",
                }
            }
        )
        assert_response_contract(resp)
        body = json.loads(resp["body"])
        assert body["dry_run"] is False
        assert len(body["tool_results"]) == 2
        assert body["tool_results"][0]["ok"] is True
        assert body["tool_results"][0]["data"]["ip"] == "1.2.3.4"
        assert body["tool_results"][1]["ok"] is True
        assert body["tool_results"][1]["data"]["name"] == "ana"
        assert len(seen) == 2
    finally:
        mod._http_get_json = original


def test_python_telegram_ai_reply_py_dry_run():
    handler = load_handler(ROOT / "examples/functions/python/telegram-ai-reply-py/app.py")
    resp = handler(
        {
            "query": {
                "mode": "reply",
                "chat_id": "123",
                "text": "hola python",
                "dry_run": "true",
                "tools": "true",
                "auto_tools": "true",
            }
        }
    )
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["ok"] is True
    assert body["dry_run"] is True
    assert body["chat_id"] == 123
    assert body["tools"]["enabled"] is True


def test_python_telegram_ai_reply_py_exec_with_mocks():
    mod = load_module(ROOT / "examples/functions/python/telegram-ai-reply-py/app.py")
    handler = mod.handler

    calls = {"openai": 0, "send": 0}
    orig_openai = mod._openai_generate_reply
    orig_send = mod._telegram_send
    orig_tools = mod._resolve_tools
    try:
        mod._openai_generate_reply = lambda env, user_text, history, tool_summary, timeout_ms: (
            calls.__setitem__("openai", calls["openai"] + 1) or "respuesta desde python"
        )
        mod._telegram_send = lambda env, chat_id, text, reply_to_message_id=None: (
            calls.__setitem__("send", calls["send"] + 1) or {"ok": True, "result": {"message_id": 77}}
        )
        mod._resolve_tools = lambda text, env, query: {
            "enabled": True,
            "plan": [{"kind": "http", "target": "https://api.ipify.org?format=json"}],
            "results": [{"ok": True, "status": 200}],
            "summary_text": "tool ok",
        }
        resp = handler(
            {
                "query": {
                    "mode": "reply",
                    "chat_id": "321",
                    "text": "hola con tools",
                    "dry_run": "false",
                    "memory": "false",
                },
                "env": {"TELEGRAM_BOT_TOKEN": "mock", "OPENAI_API_KEY": "mock"},
            }
        )
        assert_response_contract(resp)
        body = json.loads(resp["body"])
        assert body["ok"] is True
        assert body["dry_run"] is False
        assert body["chat_id"] == 321
        assert body["reply_preview"] == "respuesta desde python"
        assert body["telegram"]["message_id"] == 77
        assert body["tools"]["enabled"] is True
        assert body["tools"]["executed"] == 1
        assert calls["openai"] == 1
        assert calls["send"] == 1
    finally:
        mod._openai_generate_reply = orig_openai
        mod._telegram_send = orig_send
        mod._resolve_tools = orig_tools


def test_python_telegram_ai_reply_py_scheduler_bypass_loop_token():
    handler = load_handler(ROOT / "examples/functions/python/telegram-ai-reply-py/app.py")
    denied = handler(
        {
            "query": {"mode": "loop", "dry_run": "true"},
            "env": {"TELEGRAM_LOOP_ENABLED": "true", "TELEGRAM_LOOP_TOKEN": "secret"},
        }
    )
    assert_response_contract(denied)
    assert denied["status"] == 403

    scheduled = handler(
        {
            "query": {"mode": "loop", "dry_run": "true"},
            "env": {"TELEGRAM_LOOP_ENABLED": "true", "TELEGRAM_LOOP_TOKEN": "secret"},
            "context": {"trigger": {"type": "schedule"}},
        }
    )
    assert_response_contract(scheduled)
    assert scheduled["status"] == 200
    body = json.loads(scheduled["body"])
    assert body["mode"] == "loop"
    assert body["dry_run"] is True


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


def test_python_gmail_send_requires_to():
    handler = load_handler(ROOT / "examples/functions/python/gmail_send/app.py")
    resp = handler({"query": {}, "body": ""})
    assert_response_contract(resp)
    assert resp["status"] == 400
    body = json.loads(resp["body"])
    assert body["error"] == "to is required"


def test_python_gmail_send_forced_dry_run_without_credentials():
    handler = load_handler(ROOT / "examples/functions/python/gmail_send/app.py")
    resp = handler(
        {
            "query": {"to": "forced@example.com", "dry_run": "false"},
            "env": {},
        }
    )
    assert_response_contract(resp)
    assert resp["status"] == 200
    body = json.loads(resp["body"])
    assert body["dry_run"] is False
    assert "forced dry_run" in (body.get("note") or "")


def test_python_gmail_send_success_via_mocked_smtp():
    mod = load_module(ROOT / "examples/functions/python/gmail_send/app.py")
    handler = mod.handler
    sent = {"login": None, "to": None, "subject": None}

    class FakeSMTP:
        def __init__(self, host, port, timeout):
            self.host = host
            self.port = port
            self.timeout = timeout

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def login(self, user, password):
            sent["login"] = (user, password)

        def send_message(self, msg):
            sent["to"] = str(msg.get("To"))
            sent["subject"] = str(msg.get("Subject"))

    original = mod.smtplib.SMTP_SSL
    mod.smtplib.SMTP_SSL = FakeSMTP
    try:
        resp = handler(
            {
                "body": {
                    "to": "ok@example.com",
                    "subject": "Unit Subject",
                    "text": "Unit Body",
                    "dry_run": False,
                },
                "env": {
                    "GMAIL_USER": "unit-user@example.com",
                    "GMAIL_APP_PASSWORD": "unit-app-pass",
                    "GMAIL_FROM": "from@example.com",
                },
            }
        )
        assert_response_contract(resp)
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["sent"] is True
        assert body["dry_run"] is False
        assert sent["login"] == ("unit-user@example.com", "unit-app-pass")
        assert sent["to"] == "ok@example.com"
        assert sent["subject"] == "Unit Subject"
    finally:
        mod.smtplib.SMTP_SSL = original


def test_python_gmail_send_failure_via_mocked_smtp():
    mod = load_module(ROOT / "examples/functions/python/gmail_send/app.py")
    handler = mod.handler

    class FakeSMTP:
        def __init__(self, host, port, timeout):
            self.host = host
            self.port = port
            self.timeout = timeout

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def login(self, user, password):
            pass

        def send_message(self, msg):
            raise RuntimeError("smtp send failed in unit test")

    original = mod.smtplib.SMTP_SSL
    mod.smtplib.SMTP_SSL = FakeSMTP
    try:
        resp = handler(
            {
                "body": {
                    "to": "fail@example.com",
                    "subject": "Fail",
                    "text": "Fail",
                    "dry_run": False,
                },
                "env": {
                    "GMAIL_USER": "unit-user@example.com",
                    "GMAIL_APP_PASSWORD": "unit-app-pass",
                },
            }
        )
        assert_response_contract(resp)
        assert resp["status"] == 502
        body = json.loads(resp["body"])
        assert "gmail send failed" in (body.get("error") or "")
    finally:
        mod.smtplib.SMTP_SSL = original


def test_python_gmail_send_body_parse_variants():
    handler = load_handler(ROOT / "examples/functions/python/gmail_send/app.py")

    invalid_json = handler(
        {
            "body": "{not-json",
            "query": {"to": "invalid-json@example.com", "dry_run": "true"},
            "env": {},
        }
    )
    assert_response_contract(invalid_json)
    assert invalid_json["status"] == 200
    invalid_body = json.loads(invalid_json["body"])
    assert invalid_body["to"] == "invalid-json@example.com"
    assert invalid_body["dry_run"] is True

    array_json = handler(
        {
            "body": '["not-an-object"]',
            "query": {"to": "array-json@example.com", "dry_run": "true"},
            "env": {},
        }
    )
    assert_response_contract(array_json)
    assert array_json["status"] == 200
    array_body = json.loads(array_json["body"])
    assert array_body["to"] == "array-json@example.com"

    non_string_body = handler(
        {
            "body": 12345,
            "query": {"to": "number-body@example.com", "dry_run": "false"},
            "env": {},
        }
    )
    assert_response_contract(non_string_body)
    assert non_string_body["status"] == 200
    number_body = json.loads(non_string_body["body"])
    assert number_body["to"] == "number-body@example.com"
    assert number_body["dry_run"] is False
    assert "forced dry_run" in (number_body.get("note") or "")


def test_python_ip_intel_maxmind_mock():
    handler = load_handler(ROOT / "examples/functions/ip-intel/get.maxmind.py")

    ok_resp = handler({"query": {"ip": "8.8.8.8", "mock": "1"}})
    assert_response_contract(ok_resp)
    ok_body = json.loads(ok_resp["body"])
    assert ok_body["ok"] is True
    assert ok_body["country_code"] == "US"
    assert ok_body["provider"] == "maxmind-mock"

    bad_resp = handler({"query": {"ip": "999.1.1.1"}})
    assert_response_contract(bad_resp)
    assert bad_resp["status"] == 400


def _clear_subprocess_pool(daemon):
    workers_to_close = []
    with daemon._SUBPROCESS_POOL_LOCK:
        workers_to_close.extend(daemon._SUBPROCESS_POOL.values())
        daemon._SUBPROCESS_POOL.clear()
    for worker in workers_to_close:
        try:
            worker.shutdown()
        except Exception:
            pass


def test_python_persistent_worker_with_deps_dir():
    daemon = PYTHON_DAEMON

    handler_path = (ROOT / "tests/fixtures/dep-isolation/python/py-persistent/app.py").resolve()
    deps_dirs = [str((handler_path.parent / ".deps").resolve())]

    # Keep this test self-contained and avoid leaking child workers across test runs.
    _clear_subprocess_pool(daemon)

    try:
        t1 = time.time()
        resp1 = daemon._run_in_subprocess(handler_path, "handler", deps_dirs, {"unit": 1}, 8.0)
        d1 = time.time() - t1

        t2 = time.time()
        resp2 = daemon._run_in_subprocess(handler_path, "handler", deps_dirs, {"unit": 2}, 8.0)
        d2 = time.time() - t2

        body1 = json.loads(resp1["body"])
        body2 = json.loads(resp2["body"])

        assert body1["runtime"] == "python"
        assert body2["runtime"] == "python"
        assert body1["pid"] == body2["pid"], "expected same persistent worker process"
        assert body2["hits"] == body1["hits"] + 1, "expected process-local state increment"
        assert d1 < 2.0, f"first persistent call too slow ({d1:.3f}s)"
        assert d2 < 2.0, f"second persistent call too slow ({d2:.3f}s)"
    finally:
        _clear_subprocess_pool(daemon)


def test_python_main_fallback_and_node_like_payload():
    daemon = PYTHON_DAEMON

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def main(req):\n"
            "    return {\"message\": \"Hello, world!\", \"ok\": True}\n",
            encoding="utf-8",
        )

        daemon._HANDLER_CACHE.clear()
        handler = daemon._load_handler(fn_path, "handler")
        raw = handler({"query": {"name": "Unit"}})
        norm = daemon._normalize_response(raw)
        assert_response_contract(norm)
        assert norm["headers"].get("Content-Type") == "application/json"
        body = json.loads(norm["body"])
        assert body["message"] == "Hello, world!"
        assert body["ok"] is True


def test_python_subprocess_main_fallback_and_node_like_payload():
    daemon = PYTHON_DAEMON

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def main(req):\n"
            "    return {\"message\": \"Hello from subprocess\", \"ok\": True}\n",
            encoding="utf-8",
        )

        _clear_subprocess_pool(daemon)
        try:
            raw = daemon._run_in_subprocess(fn_path, "handler", [], {"query": {"name": "Unit"}}, 8.0)
            norm = daemon._normalize_response(raw)
            assert_response_contract(norm)
            assert norm["headers"].get("Content-Type") == "application/json"
            body = json.loads(norm["body"])
            assert body["message"] == "Hello from subprocess"
            assert body["ok"] is True
        finally:
            _clear_subprocess_pool(daemon)


def test_python_subprocess_tuple_response():
    daemon = PYTHON_DAEMON

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def main(req):\n"
            "    return ({\"message\": \"tuple\"}, 201, {\"X-Test\": \"1\"})\n",
            encoding="utf-8",
        )

        _clear_subprocess_pool(daemon)
        try:
            raw = daemon._run_in_subprocess(fn_path, "handler", [], {}, 8.0)
            norm = daemon._normalize_response(raw)
            assert_response_contract(norm)
            assert norm["status"] == 201
            assert norm["headers"].get("X-Test") == "1"
            body = json.loads(norm["body"])
            assert body["message"] == "tuple"
        finally:
            _clear_subprocess_pool(daemon)


def test_python_prefers_handler_over_main():
    daemon = PYTHON_DAEMON

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    return {\"status\": 200, \"headers\": {\"Content-Type\": \"application/json\"}, \"body\": \"{\\\"from\\\":\\\"handler\\\"}\"}\n"
            "\n"
            "def main(req):\n"
            "    return {\"from\": \"main\"}\n",
            encoding="utf-8",
        )

        daemon._HANDLER_CACHE.clear()
        handler = daemon._load_handler(fn_path, "handler")
        norm = daemon._normalize_response(handler({}))
        assert_response_contract(norm)
        body = json.loads(norm["body"])
        assert body["from"] == "handler"


def main():
    test_python_hello()
    test_python_hello_debug()
    test_python_risk_score()
    test_python_risk_score_branches()
    test_python_lambda_echo_shape()
    test_python_custom_echo_shape()
    test_python_openclaw_single_dry_run_plan()
    test_python_openclaw_single_exec_with_mocked_http()
    test_python_telegram_ai_reply_py_dry_run()
    test_python_telegram_ai_reply_py_exec_with_mocks()
    test_python_telegram_ai_reply_py_scheduler_bypass_loop_token()
    test_python_gmail_send_dry_run()
    test_python_gmail_send_requires_to()
    test_python_gmail_send_forced_dry_run_without_credentials()
    test_python_gmail_send_success_via_mocked_smtp()
    test_python_gmail_send_failure_via_mocked_smtp()
    test_python_gmail_send_body_parse_variants()
    test_python_ip_intel_maxmind_mock()
    test_python_persistent_worker_with_deps_dir()
    test_python_main_fallback_and_node_like_payload()
    test_python_subprocess_main_fallback_and_node_like_payload()
    test_python_subprocess_tuple_response()
    test_python_prefers_handler_over_main()
    print("python unit tests passed")


if __name__ == "__main__":
    main()
