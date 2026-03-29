#!/usr/bin/env python3
"""Tests for example function handlers (Python runtime)."""
import io
import json
import os
import struct
import sys
import tempfile
import time
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from conftest import ROOT, load_handler, load_module, assert_response_contract, assert_binary_response_contract, require_demo

PYTHON_DAEMON = load_module(ROOT / "srv/fn/runtimes/python-daemon.py")


def test_python_hello():
    handler = load_handler(ROOT / "examples/functions/python/hello/handler.py")
    resp = handler({"query": {"name": "Unit"}, "id": "req-1", "context": {"user": {"trace_id": "trace-1"}}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["hello"] == "Unit"
    assert "debug" not in body


def test_python_hello_debug():
    handler = load_handler(ROOT / "examples/functions/python/hello/handler.py")
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


def test_python_hello_prefix():
    handler = load_handler(ROOT / "examples/functions/python/hello/handler.py")
    resp = handler({"query": {"name": "Unit"}, "env": {"GREETING_PREFIX": "Hola"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["hello"] == "Hola Unit"


def test_python_risk_score():
    handler = load_handler(ROOT / "examples/functions/python/risk-score/handler.py")
    resp = handler({"query": {"email": "user@example.com"}, "client": {"ip": "192.168.1.10"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["runtime"] == "python"
    assert body["function"] == "risk-score"
    assert isinstance(body["score"], int)
    assert body["risk"] in {"low", "medium", "high"}


def test_python_risk_score_branches():
    handler = load_handler(ROOT / "examples/functions/python/risk-score/handler.py")

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
    handler = load_handler(ROOT / "examples/functions/python/lambda-echo/handler.py")
    resp = handler({"query": {"name": "Unit"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["hello"] == "Unit"


def test_python_custom_echo_shape():
    handler = load_handler(ROOT / "examples/functions/python/custom-echo/handler.py")
    resp = handler({"query": {"v": "abc"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["value"] == "abc"


def _with_fake_qrcode(run):
    import sys as _sys
    import types

    # Provide a minimal qrcode API so unit tests don't require external deps.
    class _FakeSvgImage:
        def __init__(self, text):
            self._text = text

        def save(self, buf):
            buf.write(f"<svg><text>{self._text}</text></svg>".encode("utf-8"))

    class _FakeQRCode:
        def __init__(self, **_kwargs):
            self._data = ""

        def add_data(self, text):
            self._data = str(text)

        def make(self, fit=True):  # noqa: ARG002
            return None

        def make_image(self, image_factory=None):  # noqa: ARG002
            return _FakeSvgImage(self._data)

    qrcode_mod = types.ModuleType("qrcode")
    qrcode_image_mod = types.ModuleType("qrcode.image")
    qrcode_image_svg_mod = types.ModuleType("qrcode.image.svg")
    qrcode_constants_mod = types.ModuleType("qrcode.constants")

    qrcode_image_svg_mod.SvgImage = object()
    qrcode_image_mod.svg = qrcode_image_svg_mod
    qrcode_mod.image = qrcode_image_mod

    qrcode_constants_mod.ERROR_CORRECT_M = "M"
    qrcode_mod.constants = qrcode_constants_mod

    def _make(text, image_factory=None):  # noqa: ARG001
        return _FakeSvgImage(str(text))

    qrcode_mod.make = _make
    qrcode_mod.QRCode = _FakeQRCode

    saved = {}
    for key in ("qrcode", "qrcode.image", "qrcode.image.svg", "qrcode.constants"):
        saved[key] = _sys.modules.get(key)

    _sys.modules["qrcode"] = qrcode_mod
    _sys.modules["qrcode.image"] = qrcode_image_mod
    _sys.modules["qrcode.image.svg"] = qrcode_image_svg_mod
    _sys.modules["qrcode.constants"] = qrcode_constants_mod

    try:
        run()
    finally:
        for key, old in saved.items():
            if old is None:
                _sys.modules.pop(key, None)
            else:
                _sys.modules[key] = old


def test_python_pack_qr_svg_shape():
    def run():
        handler = load_handler(ROOT / "examples/functions/python/pack-qr/handler.py")
        resp = handler({"query": {"text": "unit-pack"}})
        assert_response_contract(resp)
        assert resp["headers"]["Content-Type"].startswith("image/svg+xml")
        assert "<svg" in resp["body"]

    _with_fake_qrcode(run)


def test_python_qr_svg_shape_uses_url_or_text():
    def run():
        handler = load_handler(ROOT / "examples/functions/python/qr/handler.py")
        resp = handler({"query": {"url": "https://example.com"}})
        assert_response_contract(resp)
        assert resp["headers"]["Content-Type"].startswith("image/svg+xml")
        assert resp["headers"]["Cache-Control"] == "no-store"
        assert "<svg" in resp["body"]

    _with_fake_qrcode(run)


def test_python_html_demo():
    handler = load_handler(ROOT / "examples/functions/python/html-demo/handler.py")
    resp = handler({"query": {"name": "Unit"}})
    assert_response_contract(resp)
    assert resp["headers"]["Content-Type"].startswith("text/html")
    assert "Hello Unit" in resp["body"]


def test_python_csv_demo():
    handler = load_handler(ROOT / "examples/functions/python/csv-demo/handler.py")
    resp = handler({"query": {"name": "Unit"}})
    assert_response_contract(resp)
    assert resp["headers"]["Content-Type"].startswith("text/csv")
    assert "id,name,runtime" in resp["body"]
    assert "1,Unit,python" in resp["body"]


def test_python_png_demo_binary_contract():
    handler = load_handler(ROOT / "examples/functions/python/png-demo/handler.py")
    resp = handler({})
    assert_binary_response_contract(resp)
    assert resp["headers"]["Content-Type"] == "image/png"
    assert resp.get("is_base64") is True
    assert len(resp.get("body_base64") or "") > 10


def test_python_slow_invalid_sleep_ms_is_zero():
    handler = load_handler(ROOT / "examples/functions/python/slow/handler.py")
    resp = handler({"query": {"sleep_ms": "not-a-number"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["slept_ms"] == 0


def test_python_slow_positive_sleep_ms_calls_sleep():
    mod = load_module(ROOT / "examples/functions/python/slow/handler.py")
    handler = mod.handler
    seen = {"secs": None}
    original_sleep = mod.time.sleep
    try:
        mod.time.sleep = lambda secs: seen.__setitem__("secs", float(secs))
        resp = handler({"query": {"sleep_ms": "250"}})
        assert_response_contract(resp)
        body = json.loads(resp["body"])
        assert body["slept_ms"] == 250
        assert seen["secs"] == 0.25
    finally:
        mod.time.sleep = original_sleep


def test_python_cron_tick_read_and_inc_uses_local_count_file():
    mod = load_module(ROOT / "examples/functions/python/cron-tick/handler.py")
    handler = mod.handler

    with tempfile.TemporaryDirectory() as tmp:
        count_path = Path(tmp) / "count.txt"
        count_path.write_text("0\n", encoding="utf-8")
        original = mod.COUNT_PATH
        mod.COUNT_PATH = count_path
        try:
            resp0 = handler({"query": {"action": "read"}})
            assert_response_contract(resp0)
            body0 = json.loads(resp0["body"])
            assert body0["count"] == 0

            resp1 = handler({"query": {"action": "inc"}})
            assert_response_contract(resp1)
            body1 = json.loads(resp1["body"])
            assert body1["count"] == 1
        finally:
            mod.COUNT_PATH = original


def test_python_cron_tick_invalid_count_falls_back_to_zero():
    mod = load_module(ROOT / "examples/functions/python/cron-tick/handler.py")
    handler = mod.handler
    with tempfile.TemporaryDirectory() as tmp:
        count_path = Path(tmp) / "count.txt"
        count_path.write_text("not-an-int\n", encoding="utf-8")
        original = mod.COUNT_PATH
        mod.COUNT_PATH = count_path
        try:
            resp = handler({"query": {"action": "read"}})
            assert_response_contract(resp)
            body = json.loads(resp["body"])
            assert body["count"] == 0
        finally:
            mod.COUNT_PATH = original


def test_python_utc_time_and_offset_time_include_trigger():
    for name in ("utc-time", "offset-time"):
        handler = load_handler(ROOT / f"examples/functions/python/{name}/handler.py")
        resp = handler({"context": {"trigger": {"type": "schedule", "id": "unit"}}})
        assert_response_contract(resp)
        body = json.loads(resp["body"])
        assert body["function"] == name
        assert body["trigger"]["type"] == "schedule"


def test_python_requirements_demo():
    handler = load_handler(ROOT / "examples/functions/python/requirements-demo/handler.py")
    resp = handler({})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["function"] == "requirements-demo"


def test_python_sheets_webapp_append_dry_run_and_missing_env():
    handler = load_handler(ROOT / "examples/functions/python/sheets-webapp-append/handler.py")
    resp = handler({"query": {"sheet": "Unit", "values": "a,b", "dry_run": "true"}, "env": {}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["dry_run"] is True
    assert body["ok"] is True
    assert "SHEETS_WEBAPP_URL" in body.get("missing_env", [])

    resp2 = handler({"query": {"dry_run": "false"}, "env": {}})
    assert_response_contract(resp2)
    assert resp2["status"] == 400


def test_python_sheets_webapp_append_exec_success_and_failure_via_mock():
    mod = load_module(ROOT / "examples/functions/python/sheets-webapp-append/handler.py")
    handler = mod.handler

    class FakeResp:
        def __init__(self, status=200, body="ok"):
            self.status = status
            self._body = body

        def read(self):
            return self._body.encode("utf-8")

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    original = mod.urllib.request.urlopen
    try:
        mod.urllib.request.urlopen = lambda _req, timeout: FakeResp(status=201, body="created")  # noqa: ARG005
        ok = handler(
            {
                "query": {"dry_run": "false", "sheet": "Unit", "values": "a,b"},
                "env": {"SHEETS_WEBAPP_URL": "https://example.invalid/webapp"},
                "context": {"timeout_ms": 1000},
            }
        )
        assert_response_contract(ok)
        body = json.loads(ok["body"])
        assert body["ok"] is True
        assert body["status"] == 201

        def boom(_req, timeout):  # noqa: ARG001
            raise RuntimeError("unit urlopen failure")

        mod.urllib.request.urlopen = boom
        bad = handler(
            {
                "query": {"dry_run": "false", "sheet": "Unit", "values": "a,b"},
                "env": {"SHEETS_WEBAPP_URL": "https://example.invalid/webapp"},
                "context": {"timeout_ms": 1000},
            }
        )
        assert_response_contract(bad)
        assert bad["status"] == 502
    finally:
        mod.urllib.request.urlopen = original


def test_python_sendgrid_send_dry_run_and_enforce_paths():
    handler = load_handler(ROOT / "examples/functions/python/sendgrid-send/handler.py")
    resp = handler({"query": {"dry_run": "true", "to": "demo@example.com"}, "env": {}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["dry_run"] is True
    assert body["ok"] is True

    missing_key = handler({"query": {"dry_run": "false"}, "env": {"SENDGRID_FROM": "from@example.com"}})
    assert_response_contract(missing_key)
    assert missing_key["status"] == 400

    missing_from = handler({"query": {"dry_run": "false"}, "env": {"SENDGRID_API_KEY": "k"}})
    assert_response_contract(missing_from)
    assert missing_from["status"] == 400


def test_python_sendgrid_send_parse_payload_error_and_bool_none_branch():
    mod = load_module(ROOT / "examples/functions/python/sendgrid-send/handler.py")
    handler = mod.handler
    assert mod._bool(None) is False

    resp = handler(
        {
            "method": "POST",
            "body": "{bad-json",
            "query": {"dry_run": "true"},
            "env": {},
        }
    )
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["dry_run"] is True
    assert body["request"]["body"]["subject"] == "Hello"


def test_python_sendgrid_send_exec_success_and_failure_via_mock():
    mod = load_module(ROOT / "examples/functions/python/sendgrid-send/handler.py")
    handler = mod.handler

    class FakeResp:
        def __init__(self, status=202, body=""):
            self.status = status
            self._body = body

        def read(self):
            return self._body.encode("utf-8")

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    original = mod.urllib.request.urlopen
    try:
        mod.urllib.request.urlopen = lambda _req, timeout: FakeResp(status=202, body="accepted")  # noqa: ARG005
        ok = handler(
            {
                "query": {"dry_run": "false", "to": "ok@example.com"},
                "env": {"SENDGRID_API_KEY": "k", "SENDGRID_FROM": "from@example.com"},
                "context": {"timeout_ms": 1000},
            }
        )
        assert_response_contract(ok)
        body = json.loads(ok["body"])
        assert body["ok"] is True
        assert body["sendgrid_status"] == 202

        def boom(_req, timeout):  # noqa: ARG001
            raise RuntimeError("unit sendgrid failure")

        mod.urllib.request.urlopen = boom
        bad = handler(
            {
                "query": {"dry_run": "false", "to": "ok@example.com"},
                "env": {"SENDGRID_API_KEY": "k", "SENDGRID_FROM": "from@example.com"},
                "context": {"timeout_ms": 1000},
            }
        )
        assert_response_contract(bad)
        assert bad["status"] == 502
    finally:
        mod.urllib.request.urlopen = original


def test_python_github_webhook_verify_dry_run_and_enforce():
    mod = load_module(ROOT / "examples/functions/python/github-webhook-verify/handler.py")
    handler = mod.handler

    dry = handler({"query": {"dry_run": "true"}, "env": {}, "headers": {}, "body": "{}"})
    assert_response_contract(dry)
    dry_body = json.loads(dry["body"])
    assert dry_body["dry_run"] is True
    assert dry_body["ok"] in {True, False}

    secret = "unit-secret"
    raw = '{"x":1}'
    digest = mod.hmac.new(secret.encode("utf-8"), raw.encode("utf-8"), mod.hashlib.sha256).hexdigest()
    sig = "sha256=" + digest

    ok = handler(
        {
            "query": {"dry_run": "false"},
            "env": {"GITHUB_WEBHOOK_SECRET": secret},
            "headers": {"X-Hub-Signature-256": sig},
            "body": raw,
        }
    )
    assert_response_contract(ok)
    assert ok["status"] == 200

    bad = handler(
        {
            "query": {"dry_run": "false"},
            "env": {"GITHUB_WEBHOOK_SECRET": secret},
            "headers": {"X-Hub-Signature-256": "sha256=bad"},
            "body": raw,
        }
    )
    assert_response_contract(bad)
    assert bad["status"] == 400


def test_python_github_webhook_verify_bool_none_branch():
    mod = load_module(ROOT / "examples/functions/python/github-webhook-verify/handler.py")
    assert mod._bool(None) is False


def test_python_gmail_parse_json_and_forced_dry_run_without_creds():
    mod = load_module(ROOT / "examples/functions/python/gmail-send/handler.py")
    handler = mod.handler

    assert mod._parse_json('{"to":"x@example.com"}') == {"to": "x@example.com"}

    resp = handler(
        {
            "method": "POST",
            "body": json.dumps({"to": "u@example.com", "dry_run": False}),
            "query": {},
            "env": {},
        }
    )
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["dry_run"] is False
    assert "forced dry_run" in body.get("note", "")


def test_python_sheets_webapp_append_bool_none_branch():
    mod = load_module(ROOT / "examples/functions/python/sheets-webapp-append/handler.py")
    assert mod._bool(None) is False


def test_python_custom_handler_demo_main():
    mod = load_module(ROOT / "examples/functions/python/custom-handler-demo/handler.py")
    resp = mod.main({"query": {"name": "Unit"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["handler"] == "main"
    assert body["hello"] == "Unit"


def test_python_nombre_handler():
    handler = load_handler(ROOT / "examples/functions/python/nombre/handler.py")
    resp = handler({"query": {"name": "Unit"}, "id": "req-1"})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["runtime"] == "python"
    assert body["hello"] == "Unit"


def test_python_tools_loop_dry_run_plan():
    demo_path = ROOT / "examples/functions/python/tools-loop/handler.py"
    if not require_demo(demo_path):
        return
    handler = load_handler(demo_path)
    resp = handler({"query": {"text": "quiero mi ip y clima", "city": "Buenos Aires", "dry_run": "true"}})
    assert_response_contract(resp)
    assert resp["status"] == 200
    body = json.loads(resp["body"])
    assert body["ok"] is True
    assert body["dry_run"] is True
    assert isinstance(body.get("plan"), list)
    tools = [step.get("tool") for step in body["plan"] if isinstance(step, dict)]
    assert "ip_lookup" in tools
    assert "weather" in tools


def test_python_tools_loop_exec_mock():
    demo_path = ROOT / "examples/functions/python/tools-loop/handler.py"
    if not require_demo(demo_path):
        return
    handler = load_handler(demo_path)
    resp = handler({"query": {"tool": "ip_lookup,weather", "city": "Buenos Aires", "dry_run": "false", "mock": "true"}})
    assert_response_contract(resp)
    assert resp["status"] == 200
    body = json.loads(resp["body"])
    assert body["ok"] is True
    assert body["dry_run"] is False
    assert body["mock"] is True
    results = body.get("results") or []
    tools = [r.get("tool") for r in results if isinstance(r, dict)]
    assert "ip_lookup" in tools
    assert "weather" in tools
    assert all(bool(r.get("mock")) for r in results if isinstance(r, dict) and r.get("tool") in {"ip_lookup", "weather"})


def test_python_tools_loop_helper_branches():
    mod = load_module(ROOT / "examples/functions/python/tools-loop/handler.py")

    assert mod._as_bool(None, True) is True
    assert mod._as_bool(True, False) is True
    assert mod._as_bool("yes", False) is True
    assert mod._as_bool("off", True) is False
    assert mod._as_bool("unknown", True) is True

    assert mod._as_int("7", 5, 0, 10) == 7
    assert mod._as_int("bad", 5, 0, 10) == 5
    assert mod._as_int("-9", 5, 0, 10) == 0
    assert mod._as_int("999", 5, 0, 10) == 10

    assert mod._parse_csv(" ip_lookup, weather ,,") == ["ip_lookup", "weather"]
    assert mod._parse_csv("") == []
    assert mod._parse_body_object({"body": {"text": "hola"}}) == {"text": "hola"}
    assert mod._parse_body_object({"body": "  "}) == {}
    assert mod._parse_body_object({"body": '{"text":"hola"}'}) == {"text": "hola"}
    assert mod._parse_body_object({"body": "[1,2,3]"}) == {}
    assert mod._parse_body_object({"body": "{bad json"}) == {}

    assert mod._plan_from_text("", "Madrid") == [{"tool": "help"}]
    assert mod._tool_to_url({"tool": "ip_lookup"}) == "https://api.ipify.org?format=json"
    assert mod._tool_to_url({"tool": "weather", "city": "Buenos Aires"}) == "https://wttr.in/Buenos%20Aires?format=j1"
    assert mod._tool_to_url({"tool": "weather", "city": ""}) == "https://wttr.in/?format=j1"
    assert mod._tool_to_url({"tool": "unknown"}) == ""

    unknown = mod._mock_tool_result("unknown", "", "")
    assert unknown["ok"] is False
    assert unknown["error"] == "unknown_tool"


def test_python_tools_loop_help_and_unknown_paths():
    handler = load_handler(ROOT / "examples/functions/python/tools-loop/handler.py")

    help_resp = handler({"query": {"text": "hola", "dry_run": "true"}})
    assert_response_contract(help_resp)
    help_body = json.loads(help_resp["body"])
    assert [step.get("tool") for step in help_body["plan"]] == ["help"]
    assert help_body["results"][0]["tool"] == "help"
    assert help_body["results"][0]["ok"] is True
    assert len(help_body["results"][0]["data"]["examples"]) == 3

    unknown_resp = handler({"query": {"tool": "ip_lookup,badtool", "dry_run": "false", "mock": "true"}})
    assert_response_contract(unknown_resp)
    unknown_body = json.loads(unknown_resp["body"])
    assert unknown_body["summary"]["executed"] == 1
    assert unknown_body["summary"]["ok"] is False
    assert unknown_body["results"][0]["tool"] == "ip_lookup"
    assert unknown_body["results"][1]["tool"] == "unknown"
    assert unknown_body["results"][1]["error"] == "unknown_tool"


def test_python_tools_loop_exec_non_mock_and_body_fallback():
    mod = load_module(ROOT / "examples/functions/python/tools-loop/handler.py")
    handler = mod.handler

    seen_timeouts = []
    original_http_json = mod._http_json
    try:
        def fake_http_json(url, timeout_ms):
            seen_timeouts.append(int(timeout_ms))
            return {
                "ok": True,
                "status": 200,
                "elapsed_ms": 1,
                "url": url,
                "truncated": False,
                "data": {"url": url},
            }

        mod._http_json = fake_http_json

        # body text/query fallback + min timeout clamp
        resp = handler(
            {
                "query": {"tool_timeout_ms": "10"},
                "body": json.dumps({"tool": "ip_lookup,weather", "city": "Lisbon", "dry_run": "false", "mock": "false"}),
            }
        )
        assert_response_contract(resp)
        body = json.loads(resp["body"])
        assert body["dry_run"] is False
        assert body["mock"] is False
        assert body["summary"]["executed"] == 2
        assert len(body["results"]) == 2
        assert seen_timeouts[:2] == [250, 250]

        # max timeout clamp
        resp2 = handler({"query": {"tool": "ip_lookup", "dry_run": "false", "mock": "false", "tool_timeout_ms": "999999"}})
        assert_response_contract(resp2)
        assert seen_timeouts[-1] == 30000

        # invalid JSON body falls back to {} and then help plan
        resp3 = handler({"query": {}, "body": "{invalid json"})
        assert_response_contract(resp3)
        body3 = json.loads(resp3["body"])
        assert body3["plan"][0]["tool"] == "help"
    finally:
        mod._http_json = original_http_json


def test_python_tools_loop_http_json_success_error_and_truncate():
    mod = load_module(ROOT / "examples/functions/python/tools-loop/handler.py")

    class FakeResp:
        def __init__(self, status, raw):
            self.status = status
            self._raw = raw

        def read(self, _n):
            return self._raw

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    original_urlopen = mod.urllib.request.urlopen
    original_time = mod.time.time
    original_max = mod.MAX_RESPONSE_BYTES
    calls = {"count": 0}
    ticks = iter([1.0, 1.01, 2.0, 2.02, 3.0, 3.03, 4.0, 4.04])

    try:
        mod.MAX_RESPONSE_BYTES = 5

        def fake_time():
            return next(ticks)

        def fake_urlopen(req, timeout):  # noqa: ARG001
            calls["count"] += 1
            if calls["count"] == 1:
                assert req.full_url == "https://example.com/json"
                return FakeResp(201, b'{"ok":true}')
            if calls["count"] == 2:
                return FakeResp(200, b"plain-text-response")
            if calls["count"] == 3:
                raise RuntimeError("boom")
            return FakeResp(200, b"{}")

        mod.time.time = fake_time
        mod.urllib.request.urlopen = fake_urlopen

        out1 = mod._http_json("https://example.com/json", timeout_ms=1000)
        assert out1["ok"] is True
        assert out1["status"] == 201
        assert out1["truncated"] is True
        assert isinstance(out1["data"]["raw"], str)
        assert out1["data"]["raw"].startswith("{")

        out2 = mod._http_json("https://example.com/raw", timeout_ms=10)
        assert out2["ok"] is True
        assert out2["status"] == 200
        assert out2["truncated"] is True
        assert out2["data"]["raw"] == "plain"

        out3 = mod._http_json("https://example.com/fail", timeout_ms=10)
        assert out3["ok"] is False
        assert out3["status"] == 0
        assert "boom" in out3["error"]

        mod.MAX_RESPONSE_BYTES = 50
        out4 = mod._http_json("https://example.com/short", timeout_ms=10)
        assert out4["ok"] is True
        assert out4["truncated"] is False
    finally:
        mod.urllib.request.urlopen = original_urlopen
        mod.time.time = original_time
        mod.MAX_RESPONSE_BYTES = original_max


def test_python_telegram_ai_reply_py_missing_env():
    """Missing or placeholder credentials skip instead of failing demo endpoints."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    handler = load_handler(demo_path)
    update_body = {"message": {"chat": {"id": 1}, "text": "hi"}}

    # Missing bot token
    resp = handler({"body": update_body, "env": {"OPENAI_API_KEY": "k"}})
    assert_response_contract(resp)
    assert resp["status"] == 200
    body = json.loads(resp["body"])
    assert body["skipped"] is True
    assert "TELEGRAM_BOT_TOKEN" in body["missing_env"]

    # Missing openai key
    resp = handler({"body": update_body, "env": {"TELEGRAM_BOT_TOKEN": "t"}})
    assert_response_contract(resp)
    assert resp["status"] == 200
    body = json.loads(resp["body"])
    assert body["skipped"] is True
    assert "OPENAI_API_KEY" in body["missing_env"]

    placeholder = handler(
        {
            "body": update_body,
            "env": {"TELEGRAM_BOT_TOKEN": "<set-me>", "OPENAI_API_KEY": "changeme"},
        }
    )
    assert_response_contract(placeholder)
    assert placeholder["status"] == 200
    placeholder_body = json.loads(placeholder["body"])
    assert placeholder_body["skipped"] is True
    assert placeholder_body["missing_env"] == ["TELEGRAM_BOT_TOKEN", "OPENAI_API_KEY"]

    whitespace = handler(
        {
            "body": update_body,
            "env": {"TELEGRAM_BOT_TOKEN": "   ", "OPENAI_API_KEY": "\t"},
        }
    )
    assert_response_contract(whitespace)
    assert whitespace["status"] == 200
    whitespace_body = json.loads(whitespace["body"])
    assert whitespace_body["skipped"] is True
    assert whitespace_body["missing_env"] == ["TELEGRAM_BOT_TOKEN", "OPENAI_API_KEY"]


def test_python_telegram_ai_reply_py_process_env_fallback():
    """Placeholder fn.env values can fall back to process env for local demos."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    handler = mod.handler

    import urllib.request as _ur

    orig_urlopen = _ur.urlopen
    prev_bot = os.environ.get("TELEGRAM_BOT_TOKEN")
    prev_openai = os.environ.get("OPENAI_API_KEY")

    class _FakeResp:
        def __init__(self, data):
            self._data = json.dumps(data).encode()

        def read(self):
            return self._data

        def __enter__(self):
            return self

        def __exit__(self, *_a):
            pass

    def fake_urlopen(req, timeout=None):  # noqa: ARG001
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "openai.com" in url:
            return _FakeResp({"choices": [{"message": {"content": "from process env"}}]})
        if "api.telegram.org" in url:
            return _FakeResp({"ok": True, "result": {"message_id": 51}})
        raise RuntimeError(f"unexpected url: {url}")

    _ur.urlopen = fake_urlopen
    os.environ["TELEGRAM_BOT_TOKEN"] = "process-bot"
    os.environ["OPENAI_API_KEY"] = "process-openai"
    try:
        resp = handler(
            {
                "body": {"message": {"chat": {"id": 2}, "text": "hola"}},
                "env": {"TELEGRAM_BOT_TOKEN": "<set-me>", "OPENAI_API_KEY": "<set-me>"},
            }
        )
        assert_response_contract(resp)
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["ok"] is True
        assert body["reply"] == "from process env"
    finally:
        _ur.urlopen = orig_urlopen
        if prev_bot is None:
            os.environ.pop("TELEGRAM_BOT_TOKEN", None)
        else:
            os.environ["TELEGRAM_BOT_TOKEN"] = prev_bot
        if prev_openai is None:
            os.environ.pop("OPENAI_API_KEY", None)
        else:
            os.environ["OPENAI_API_KEY"] = prev_openai


def test_python_telegram_ai_reply_py_no_text_message():
    """Non-text update (e.g. sticker) returns 200 with a skip note."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    handler = load_handler(demo_path)
    resp = handler({"body": {"message": {"chat": {"id": 1}}}, "env": {}})
    assert_response_contract(resp)
    assert resp["status"] == 200
    body = json.loads(resp["body"])
    assert body.get("note") is not None


def test_python_telegram_ai_reply_py_success_flow():
    """Full webhook flow with mocked urllib calls."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    handler = mod.handler

    import urllib.request as _ur

    calls = {"openai": 0, "telegram": 0}
    orig_urlopen = _ur.urlopen

    class _FakeResp:
        def __init__(self, data):
            self._data = json.dumps(data).encode()

        def read(self):
            return self._data

        def __enter__(self):
            return self

        def __exit__(self, *_a):
            pass

    def fake_urlopen(req, timeout=None):  # noqa: ARG001
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "openai.com" in url:
            calls["openai"] += 1
            return _FakeResp({"choices": [{"message": {"content": "AI says hello"}}]})
        if "api.telegram.org" in url:
            calls["telegram"] += 1
            return _FakeResp({"ok": True, "result": {"message_id": 42}})
        raise RuntimeError(f"unexpected url: {url}")

    _ur.urlopen = fake_urlopen
    try:
        resp = handler(
            {
                "body": {"message": {"chat": {"id": 99}, "text": "hola"}},
                "env": {
                    "TELEGRAM_BOT_TOKEN": "tok",
                    "OPENAI_API_KEY": "key",
                },
            }
        )
        assert_response_contract(resp)
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["ok"] is True
        assert body["chat_id"] == 99
        assert body["reply"] == "AI says hello"
        assert calls["openai"] == 1
        assert calls["telegram"] == 1
    finally:
        _ur.urlopen = orig_urlopen


def test_python_telegram_ai_reply_py_openai_error():
    """OpenAI failure returns 502."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    handler = mod.handler

    import urllib.request as _ur

    orig_urlopen = _ur.urlopen

    def fail_urlopen(req, timeout=None):  # noqa: ARG001
        raise urllib.error.URLError("connection refused")

    import urllib.error

    _ur.urlopen = fail_urlopen
    try:
        resp = handler(
            {
                "body": {"message": {"chat": {"id": 1}, "text": "hi"}},
                "env": {"TELEGRAM_BOT_TOKEN": "t", "OPENAI_API_KEY": "k"},
            }
        )
        assert_response_contract(resp)
        assert resp["status"] == 502
        assert "OpenAI" in json.loads(resp["body"])["error"]
    finally:
        _ur.urlopen = orig_urlopen


def test_python_telegram_ai_reply_py_telegram_send_error():
    """Telegram send failure returns 502."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    handler = mod.handler

    import urllib.request as _ur

    orig_urlopen = _ur.urlopen

    class _FakeResp:
        def __init__(self, data):
            self._data = json.dumps(data).encode()

        def read(self):
            return self._data

        def __enter__(self):
            return self

        def __exit__(self, *_a):
            pass

    call_count = {"n": 0}

    def fake_urlopen(req, timeout=None):  # noqa: ARG001
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "openai.com" in url:
            return _FakeResp({"choices": [{"message": {"content": "reply"}}]})
        if "api.telegram.org" in url:
            call_count["n"] += 1
            return _FakeResp({"ok": False, "description": "Forbidden"})
        raise RuntimeError(f"unexpected url: {url}")

    _ur.urlopen = fake_urlopen
    try:
        resp = handler(
            {
                "body": {"message": {"chat": {"id": 1}, "text": "hi"}},
                "env": {"TELEGRAM_BOT_TOKEN": "t", "OPENAI_API_KEY": "k"},
            }
        )
        assert_response_contract(resp)
        assert resp["status"] == 502
        assert "Telegram" in json.loads(resp["body"])["error"]
        assert call_count["n"] == 1
    finally:
        _ur.urlopen = orig_urlopen


def test_python_telegram_ai_reply_py_edited_message():
    """Handler also processes edited_message updates."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    handler = mod.handler

    import urllib.request as _ur

    orig_urlopen = _ur.urlopen

    class _FakeResp:
        def __init__(self, data):
            self._data = json.dumps(data).encode()

        def read(self):
            return self._data

        def __enter__(self):
            return self

        def __exit__(self, *_a):
            pass

    def fake_urlopen(req, timeout=None):  # noqa: ARG001
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "openai.com" in url:
            return _FakeResp({"choices": [{"message": {"content": "edited reply"}}]})
        if "api.telegram.org" in url:
            return _FakeResp({"ok": True, "result": {"message_id": 50}})
        raise RuntimeError(f"unexpected url: {url}")

    _ur.urlopen = fake_urlopen
    try:
        resp = handler(
            {
                "body": {"edited_message": {"chat": {"id": 77}, "text": "corrected"}},
                "env": {
                    "TELEGRAM_BOT_TOKEN": "tok",
                    "OPENAI_API_KEY": "key",
                },
            }
        )
        assert_response_contract(resp)
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["ok"] is True
        assert body["chat_id"] == 77
        assert body["reply"] == "edited reply"
    finally:
        _ur.urlopen = orig_urlopen


def test_python_telegram_ai_reply_py_body_string():
    """_parse_body handles a valid JSON string."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    result = mod._parse_body('{"message": {"chat": {"id": 1}, "text": "hi"}}')
    assert result["message"]["text"] == "hi"


def test_python_telegram_ai_reply_py_body_invalid_json():
    """_parse_body returns {} for invalid JSON string."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    result = mod._parse_body("not json {{{")
    assert result == {}


def test_python_telegram_ai_reply_py_body_none():
    """_parse_body returns {} for None input."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    result = mod._parse_body(None)
    assert result == {}


def test_python_telegram_ai_reply_py_caption_message():
    """_extract_message falls back to caption when text is absent."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    import urllib.request as _ur

    orig_urlopen = _ur.urlopen

    class _FakeResp:
        def __init__(self, data):
            self._data = json.dumps(data).encode()
        def read(self):
            return self._data
        def __enter__(self):
            return self
        def __exit__(self, *_a):
            pass

    def fake_urlopen(req, timeout=None):  # noqa: ARG001
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "openai.com" in url:
            return _FakeResp({"choices": [{"message": {"content": "caption reply"}}]})
        if "api.telegram.org" in url:
            return _FakeResp({"ok": True, "result": {"message_id": 60}})
        raise RuntimeError(f"unexpected url: {url}")

    _ur.urlopen = fake_urlopen
    try:
        resp = mod.handler({
            "body": {"message": {"chat": {"id": 88}, "caption": "photo caption"}},
            "env": {"TELEGRAM_BOT_TOKEN": "tok", "OPENAI_API_KEY": "key"},
        })
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["reply"] == "caption reply"
    finally:
        _ur.urlopen = orig_urlopen


def test_python_telegram_ai_reply_py_openai_no_choices():
    """OpenAI returning empty choices raises RuntimeError."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    import urllib.request as _ur

    orig_urlopen = _ur.urlopen

    class _FakeResp:
        def __init__(self, data):
            self._data = json.dumps(data).encode()
        def read(self):
            return self._data
        def __enter__(self):
            return self
        def __exit__(self, *_a):
            pass

    def fake_urlopen(req, timeout=None):  # noqa: ARG001
        return _FakeResp({"choices": []})

    _ur.urlopen = fake_urlopen
    try:
        resp = mod.handler({
            "body": {"message": {"chat": {"id": 99}, "text": "hi"}},
            "env": {"TELEGRAM_BOT_TOKEN": "tok", "OPENAI_API_KEY": "key"},
        })
        assert resp["status"] == 502
        body = json.loads(resp["body"])
        assert "no choices" in body["error"].lower() or "OpenAI" in body["error"]
    finally:
        _ur.urlopen = orig_urlopen


def test_python_telegram_ai_reply_py_env_none():
    """Handler works when event has no 'env' key at all."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/handler.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    resp = mod.handler({
        "body": {"message": {"chat": {"id": 1}, "text": "hi"}},
    })
    assert resp["status"] == 200
    body = json.loads(resp["body"])
    assert body["skipped"] is True
    assert "TELEGRAM_BOT_TOKEN" in body["missing_env"]


def test_python_gmail_send_dry_run():
    handler = load_handler(ROOT / "examples/functions/python/gmail-send/handler.py")
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


def test_python_gmail_send_dry_run_with_credentials_no_forced_note():
    handler = load_handler(ROOT / "examples/functions/python/gmail-send/handler.py")
    resp = handler(
        {
            "query": {
                "to": "demo@example.com",
                "dry_run": "true",
            },
            "env": {
                "GMAIL_USER": "u@example.com",
                "GMAIL_APP_PASSWORD": "app-pass",
            },
        }
    )
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["dry_run"] is True
    assert "note" not in body


def test_python_gmail_send_requires_to():
    handler = load_handler(ROOT / "examples/functions/python/gmail-send/handler.py")
    resp = handler({"query": {}, "body": ""})
    assert_response_contract(resp)
    assert resp["status"] == 400
    body = json.loads(resp["body"])
    assert body["error"] == "to is required"


def test_python_gmail_send_forced_dry_run_without_credentials():
    handler = load_handler(ROOT / "examples/functions/python/gmail-send/handler.py")
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
    mod = load_module(ROOT / "examples/functions/python/gmail-send/handler.py")
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
    mod = load_module(ROOT / "examples/functions/python/gmail-send/handler.py")
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
    handler = load_handler(ROOT / "examples/functions/python/gmail-send/handler.py")

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
    demo_path = ROOT / "examples/functions/ip-intel/get.maxmind.py"
    if not require_demo(demo_path):
        return
    handler = load_handler(demo_path)

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


def test_python_prepare_socket_path_tolerates_stat_race():
    daemon = PYTHON_DAEMON
    old_stat = daemon.os.stat
    try:
        daemon.os.stat = lambda _p: (_ for _ in ()).throw(FileNotFoundError("gone"))
        daemon._prepare_socket_path("/tmp/fastfn/fn-python.sock")
    finally:
        daemon.os.stat = old_stat


def test_python_persistent_worker_with_deps_dir():
    daemon = PYTHON_DAEMON

    handler_path = (ROOT / "tests/fixtures/dep-isolation/python/py-persistent/handler.py").resolve()
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
        fn_path = Path(tmp) / "handler.py"
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
        fn_path = Path(tmp) / "handler.py"
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
        fn_path = Path(tmp) / "handler.py"
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


def test_python_subprocess_does_not_fallback_to_oneshot() -> None:
    daemon = PYTHON_DAEMON

    handler_path = (ROOT / "tests" / "fixtures" / "dep-isolation" / "python" / "py-persistent" / "handler.py").resolve()
    called = {"oneshot": False, "persistent": 0}
    old_get = daemon._get_or_create_worker
    old_oneshot = daemon._run_in_subprocess_oneshot
    old_pool = daemon._SUBPROCESS_POOL
    try:
        daemon._SUBPROCESS_POOL = {}

        def fake_get(*_args, **_kwargs):
            called["persistent"] += 1
            raise RuntimeError("worker crashed")

        def fake_oneshot(*_args, **_kwargs):
            called["oneshot"] = True
            return {"status": 200, "headers": {}, "body": "unexpected"}

        daemon._get_or_create_worker = fake_get
        daemon._run_in_subprocess_oneshot = fake_oneshot
        resp = daemon._run_in_subprocess(handler_path, "handler", [], {"query": {"name": "x"}}, 1.0)
        assert resp["status"] == 503, resp
        assert called["persistent"] == 2, called
        assert called["oneshot"] is False, called
    finally:
        daemon._get_or_create_worker = old_get
        daemon._run_in_subprocess_oneshot = old_oneshot
        daemon._SUBPROCESS_POOL = old_pool


def test_python_prefers_handler_over_main():
    daemon = PYTHON_DAEMON

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "handler.py"
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
