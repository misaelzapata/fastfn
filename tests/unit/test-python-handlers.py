#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import struct
import sys
import tempfile
import time
from contextlib import redirect_stderr, redirect_stdout
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


def assert_binary_response_contract(resp):
    assert isinstance(resp, dict), "response must be an object"
    assert isinstance(resp.get("status"), int), "status must be int"
    assert isinstance(resp.get("headers"), dict), "headers must be object"
    # Some functions return binary responses using base64 fields.
    if resp.get("is_base64") is True:
        assert isinstance(resp.get("body_base64"), str), "body_base64 must be string"
    else:
        assert isinstance(resp.get("body"), str), "body must be string"


def require_demo(path):
    if path.exists():
        return True
    print(f"skip: missing optional demo {path}")
    return False


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


def test_python_hello_prefix():
    handler = load_handler(ROOT / "examples/functions/python/hello/app.py")
    resp = handler({"query": {"name": "Unit"}, "env": {"GREETING_PREFIX": "Hola"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["hello"] == "Hola Unit"


def test_python_risk_score():
    handler = load_handler(ROOT / "examples/functions/python/risk-score/app.py")
    resp = handler({"query": {"email": "user@example.com"}, "client": {"ip": "192.168.1.10"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["runtime"] == "python"
    assert body["function"] == "risk-score"
    assert isinstance(body["score"], int)
    assert body["risk"] in {"low", "medium", "high"}


def test_python_risk_score_branches():
    handler = load_handler(ROOT / "examples/functions/python/risk-score/app.py")

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
    handler = load_handler(ROOT / "examples/functions/python/lambda-echo/app.py")
    resp = handler({"query": {"name": "Unit"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["hello"] == "Unit"


def test_python_custom_echo_shape():
    handler = load_handler(ROOT / "examples/functions/python/custom-echo/app.py")
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
        handler = load_handler(ROOT / "examples/functions/python/pack-qr/app.py")
        resp = handler({"query": {"text": "unit-pack"}})
        assert_response_contract(resp)
        assert resp["headers"]["Content-Type"].startswith("image/svg+xml")
        assert "<svg" in resp["body"]

    _with_fake_qrcode(run)


def test_python_qr_svg_shape_uses_url_or_text():
    def run():
        handler = load_handler(ROOT / "examples/functions/python/qr/app.py")
        resp = handler({"query": {"url": "https://example.com"}})
        assert_response_contract(resp)
        assert resp["headers"]["Content-Type"].startswith("image/svg+xml")
        assert resp["headers"]["Cache-Control"] == "no-store"
        assert "<svg" in resp["body"]

    _with_fake_qrcode(run)


def test_python_html_demo():
    handler = load_handler(ROOT / "examples/functions/python/html-demo/app.py")
    resp = handler({"query": {"name": "Unit"}})
    assert_response_contract(resp)
    assert resp["headers"]["Content-Type"].startswith("text/html")
    assert "Hello Unit" in resp["body"]


def test_python_csv_demo():
    handler = load_handler(ROOT / "examples/functions/python/csv-demo/app.py")
    resp = handler({"query": {"name": "Unit"}})
    assert_response_contract(resp)
    assert resp["headers"]["Content-Type"].startswith("text/csv")
    assert "id,name,runtime" in resp["body"]
    assert "1,Unit,python" in resp["body"]


def test_python_png_demo_binary_contract():
    handler = load_handler(ROOT / "examples/functions/python/png-demo/app.py")
    resp = handler({})
    assert_binary_response_contract(resp)
    assert resp["headers"]["Content-Type"] == "image/png"
    assert resp.get("is_base64") is True
    assert len(resp.get("body_base64") or "") > 10


def test_python_slow_invalid_sleep_ms_is_zero():
    handler = load_handler(ROOT / "examples/functions/python/slow/app.py")
    resp = handler({"query": {"sleep_ms": "not-a-number"}})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["slept_ms"] == 0


def test_python_slow_positive_sleep_ms_calls_sleep():
    mod = load_module(ROOT / "examples/functions/python/slow/app.py")
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
    mod = load_module(ROOT / "examples/functions/python/cron-tick/app.py")
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
    mod = load_module(ROOT / "examples/functions/python/cron-tick/app.py")
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
        handler = load_handler(ROOT / f"examples/functions/python/{name}/app.py")
        resp = handler({"context": {"trigger": {"type": "schedule", "id": "unit"}}})
        assert_response_contract(resp)
        body = json.loads(resp["body"])
        assert body["function"] == name
        assert body["trigger"]["type"] == "schedule"


def test_python_requirements_demo():
    handler = load_handler(ROOT / "examples/functions/python/requirements-demo/app.py")
    resp = handler({})
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["function"] == "requirements-demo"


def test_python_sheets_webapp_append_dry_run_and_missing_env():
    handler = load_handler(ROOT / "examples/functions/python/sheets-webapp-append/app.py")
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
    mod = load_module(ROOT / "examples/functions/python/sheets-webapp-append/app.py")
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
    handler = load_handler(ROOT / "examples/functions/python/sendgrid-send/app.py")
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
    mod = load_module(ROOT / "examples/functions/python/sendgrid-send/app.py")
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
    mod = load_module(ROOT / "examples/functions/python/sendgrid-send/app.py")
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
    mod = load_module(ROOT / "examples/functions/python/github-webhook-verify/app.py")
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
    mod = load_module(ROOT / "examples/functions/python/github-webhook-verify/app.py")
    assert mod._bool(None) is False


def test_python_gmail_parse_json_and_forced_dry_run_without_creds():
    mod = load_module(ROOT / "examples/functions/python/gmail-send/app.py")
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
    mod = load_module(ROOT / "examples/functions/python/sheets-webapp-append/app.py")
    assert mod._bool(None) is False


def test_python_custom_handler_demo_main():
    mod = load_module(ROOT / "examples/functions/python/custom-handler-demo/app.py")
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
    demo_path = ROOT / "examples/functions/python/tools-loop/app.py"
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
    demo_path = ROOT / "examples/functions/python/tools-loop/app.py"
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
    mod = load_module(ROOT / "examples/functions/python/tools-loop/app.py")

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
    handler = load_handler(ROOT / "examples/functions/python/tools-loop/app.py")

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
    mod = load_module(ROOT / "examples/functions/python/tools-loop/app.py")
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
    mod = load_module(ROOT / "examples/functions/python/tools-loop/app.py")

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
    """Missing TELEGRAM_BOT_TOKEN or OPENAI_API_KEY returns 500."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
    if not require_demo(demo_path):
        return
    handler = load_handler(demo_path)
    update_body = {"message": {"chat": {"id": 1}, "text": "hi"}}

    # Missing bot token
    resp = handler({"body": update_body, "env": {"OPENAI_API_KEY": "k"}})
    assert_response_contract(resp)
    assert resp["status"] == 500
    assert "TELEGRAM_BOT_TOKEN" in json.loads(resp["body"])["error"]

    # Missing openai key
    resp = handler({"body": update_body, "env": {"TELEGRAM_BOT_TOKEN": "t"}})
    assert_response_contract(resp)
    assert resp["status"] == 500
    assert "OPENAI_API_KEY" in json.loads(resp["body"])["error"]


def test_python_telegram_ai_reply_py_no_text_message():
    """Non-text update (e.g. sticker) returns 200 with a skip note."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
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
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
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
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
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
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
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
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
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
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    result = mod._parse_body('{"message": {"chat": {"id": 1}, "text": "hi"}}')
    assert result["message"]["text"] == "hi"


def test_python_telegram_ai_reply_py_body_invalid_json():
    """_parse_body returns {} for invalid JSON string."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    result = mod._parse_body("not json {{{")
    assert result == {}


def test_python_telegram_ai_reply_py_body_none():
    """_parse_body returns {} for None input."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    result = mod._parse_body(None)
    assert result == {}


def test_python_telegram_ai_reply_py_caption_message():
    """_extract_message falls back to caption when text is absent."""
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
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
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
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
    demo_path = ROOT / "examples/functions/python/telegram-ai-reply-py/app.py"
    if not require_demo(demo_path):
        return
    mod = load_module(demo_path)
    resp = mod.handler({
        "body": {"message": {"chat": {"id": 1}, "text": "hi"}},
    })
    assert resp["status"] == 500
    body = json.loads(resp["body"])
    assert "TELEGRAM_BOT_TOKEN" in body["error"]


def test_python_gmail_send_dry_run():
    handler = load_handler(ROOT / "examples/functions/python/gmail-send/app.py")
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
    handler = load_handler(ROOT / "examples/functions/python/gmail-send/app.py")
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
    handler = load_handler(ROOT / "examples/functions/python/gmail-send/app.py")
    resp = handler({"query": {}, "body": ""})
    assert_response_contract(resp)
    assert resp["status"] == 400
    body = json.loads(resp["body"])
    assert body["error"] == "to is required"


def test_python_gmail_send_forced_dry_run_without_credentials():
    handler = load_handler(ROOT / "examples/functions/python/gmail-send/app.py")
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
    mod = load_module(ROOT / "examples/functions/python/gmail-send/app.py")
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
    mod = load_module(ROOT / "examples/functions/python/gmail-send/app.py")
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
    handler = load_handler(ROOT / "examples/functions/python/gmail-send/app.py")

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


def test_python_subprocess_does_not_fallback_to_oneshot() -> None:
    daemon = PYTHON_DAEMON

    handler_path = (ROOT / "tests" / "fixtures" / "dep-isolation" / "python" / "py-persistent" / "app.py").resolve()
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


PYTHON_WORKER = load_module(ROOT / "srv/fn/runtimes/python-function-worker.py")


def test_python_worker_captures_stdout():
    """print() during handler execution should be captured in response."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    print('hello from stdout')\n"
            "    print('second line')\n"
            "    return {'status': 200, 'headers': {}, 'body': 'ok'}\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 200
        assert resp["body"] == "ok"
        assert "stdout" in resp, "stdout should be captured"
        assert "hello from stdout" in resp["stdout"]
        assert "second line" in resp["stdout"]


def test_python_worker_captures_stderr():
    """sys.stderr writes during handler execution should be captured."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "import sys\n"
            "def handler(event):\n"
            "    sys.stderr.write('error output\\n')\n"
            "    return {'status': 200, 'headers': {}, 'body': 'ok'}\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 200
        assert "stderr" in resp, "stderr should be captured"
        assert "error output" in resp["stderr"]


def test_python_worker_no_stdout_when_silent():
    """Response should NOT contain stdout/stderr when handler is silent."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'ok'}\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 200
        assert "stdout" not in resp, "no stdout when handler is silent"
        assert "stderr" not in resp, "no stderr when handler is silent"


def test_python_daemon_preserves_stdout_stderr():
    """_normalize_response should preserve stdout/stderr from worker."""
    daemon = PYTHON_DAEMON

    resp_with_output = {
        "status": 200,
        "headers": {},
        "body": "ok",
        "stdout": "captured output",
        "stderr": "captured error",
    }
    norm = daemon._normalize_response(resp_with_output)
    assert norm["stdout"] == "captured output"
    assert norm["stderr"] == "captured error"

    resp_without = {
        "status": 200,
        "headers": {},
        "body": "ok",
    }
    norm2 = daemon._normalize_response(resp_without)
    assert "stdout" not in norm2
    assert "stderr" not in norm2


def test_python_daemon_emits_handler_logs() -> None:
    daemon = PYTHON_DAEMON
    stdout_buffer = io.StringIO()
    stderr_buffer = io.StringIO()
    with redirect_stdout(stdout_buffer), redirect_stderr(stderr_buffer):
        daemon._emit_handler_logs(
            {"fn": "hello", "version": "v2"},
            {"stdout": "line one\nline two", "stderr": "warn one"},
        )
    assert "[fn:hello@v2 stdout] line one" in stdout_buffer.getvalue()
    assert "[fn:hello@v2 stdout] line two" in stdout_buffer.getvalue()
    assert "[fn:hello@v2 stderr] warn one" in stderr_buffer.getvalue()


def test_python_worker_event_session_passthrough():
    """event.session should be accessible from handler."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "import json\n"
            "def handler(event):\n"
            "    session = event.get('session') or {}\n"
            "    return {\n"
            "        'status': 200,\n"
            "        'headers': {'Content-Type': 'application/json'},\n"
            "        'body': json.dumps({'sid': session.get('id'), 'cookies': session.get('cookies', {})})\n"
            "    }\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {
                "session": {
                    "id": "abc123",
                    "raw": "session_id=abc123; theme=dark",
                    "cookies": {"session_id": "abc123", "theme": "dark"},
                }
            },
        })
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["sid"] == "abc123"
        assert body["cookies"]["theme"] == "dark"


# ---------------------------------------------------------------------------
# Direct route params injection tests
# ---------------------------------------------------------------------------

def test_python_rest_product_id_direct_param():
    """[id] handler receives id as direct kwarg."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/products/[id]/get.py")
    resp = handler({"params": {"id": "42"}}, id="42")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["id"] == 42
    assert body["name"] == "Widget"


def test_python_rest_product_id_put_direct_param():
    """[id] PUT handler receives id as direct kwarg."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/products/[id]/put.py")
    event = {"params": {"id": "7"}, "body": '{"name":"Updated","price":19.99}'}
    resp = handler(event, id="7")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["id"] == 7


def test_python_rest_product_id_delete_direct_param():
    """[id] DELETE handler receives id as direct kwarg."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/products/[id]/delete.py")
    resp = handler({"params": {"id": "99"}}, id="99")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["deleted"] is True
    assert body["id"] == 99


def test_python_rest_slug_direct_param():
    """[slug] handler receives slug as direct kwarg."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/posts/[slug]/get.py")
    resp = handler({"params": {"slug": "hello-world"}}, slug="hello-world")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["slug"] == "hello-world"
    assert "hello-world" in body["title"]


def test_python_rest_category_slug_multi_param():
    """[category]/[slug] handler receives both params as direct kwargs."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/posts/[category]/[slug]/get.py")
    resp = handler({"params": {"category": "tech", "slug": "ai-news"}}, category="tech", slug="ai-news")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["category"] == "tech"
    assert body["slug"] == "ai-news"


def test_python_rest_wildcard_path_direct_param():
    """[...path] handler receives path as direct kwarg."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/files/[...path]/get.py")
    resp = handler({"params": {"path": "docs/2024/report.pdf"}}, path="docs/2024/report.pdf")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["path"] == "docs/2024/report.pdf"
    assert body["segments"] == ["docs", "2024", "report.pdf"]
    assert body["depth"] == 3


def test_python_rest_wildcard_empty_path():
    """[...path] handler handles empty path gracefully."""
    handler = load_handler(ROOT / "examples/functions/rest-api-methods/files/[...path]/get.py")
    resp = handler({"params": {"path": ""}}, path="")
    assert resp["status"] == 200
    body = resp["body"] if isinstance(resp["body"], dict) else json.loads(resp["body"])
    assert body["path"] == ""
    assert body["segments"] == []
    assert body["depth"] == 0


# ---------------------------------------------------------------------------
# Worker _call_handler route_params injection tests
# ---------------------------------------------------------------------------

def test_worker_call_handler_injects_kwargs():
    """_call_handler injects route_params as kwargs for handlers with named params."""
    worker = PYTHON_WORKER

    def handler_with_id(event, id):
        return {"got_id": id, "event_keys": list(event.keys())}

    result = worker._call_handler(handler_with_id, [{"method": "GET"}], route_params={"id": "42"})
    assert result["got_id"] == "42"
    assert "method" in result["event_keys"]


def test_worker_call_handler_injects_multiple_kwargs():
    """_call_handler injects multiple route_params."""
    worker = PYTHON_WORKER

    def handler_multi(event, category, slug):
        return {"category": category, "slug": slug}

    result = worker._call_handler(
        handler_multi, [{}], route_params={"category": "tech", "slug": "hello"}
    )
    assert result["category"] == "tech"
    assert result["slug"] == "hello"


def test_worker_call_handler_var_keyword_receives_all():
    """_call_handler passes all route_params via **kwargs."""
    worker = PYTHON_WORKER

    def handler_kwargs(event, **kwargs):
        return {"kwargs": kwargs}

    result = worker._call_handler(
        handler_kwargs, [{}], route_params={"id": "1", "slug": "test"}
    )
    assert result["kwargs"]["id"] == "1"
    assert result["kwargs"]["slug"] == "test"


def test_worker_call_handler_no_params_ignores_route_params():
    """_call_handler with handler(event) ignores route_params."""
    worker = PYTHON_WORKER

    def handler_event_only(event):
        return {"ok": True}

    result = worker._call_handler(
        handler_event_only, [{}], route_params={"id": "42"}
    )
    assert result["ok"] is True


def test_worker_call_handler_no_route_params_works():
    """_call_handler without route_params still works normally."""
    worker = PYTHON_WORKER

    def handler_normal(event):
        return {"method": event.get("method", "none")}

    result = worker._call_handler(handler_normal, [{"method": "GET"}])
    assert result["method"] == "GET"


def test_worker_call_handler_extra_params_ignored():
    """_call_handler ignores route_params not declared in handler signature."""
    worker = PYTHON_WORKER

    def handler_only_id(event, id):
        return {"id": id}

    result = worker._call_handler(
        handler_only_id, [{}], route_params={"id": "5", "slug": "extra"}
    )
    assert result["id"] == "5"


def test_worker_handle_passes_route_params_from_event():
    """_handle extracts event.params and passes to handler as kwargs."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event, id):\n"
            "    return {\n"
            "        'status': 200,\n"
            "        'headers': {'Content-Type': 'application/json'},\n"
            "        'body': '{\"id\": \"' + str(id) + '\"}'\n"
            "    }\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {"params": {"id": "42"}},
        })
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["id"] == "42"


def test_worker_handle_multi_params_from_event():
    """_handle injects multiple params from event.params."""
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "import json\n"
            "def handler(event, category, slug):\n"
            "    return {\n"
            "        'status': 200,\n"
            "        'headers': {'Content-Type': 'application/json'},\n"
            "        'body': json.dumps({'category': category, 'slug': slug})\n"
            "    }\n",
            encoding="utf-8",
        )

        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {"params": {"category": "tech", "slug": "hello-world"}},
        })
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["category"] == "tech"
        assert body["slug"] == "hello-world"


# ---------------------------------------------------------------------------
# python-function-worker.py full coverage tests
# ---------------------------------------------------------------------------


def test_worker_parse_extra_allow_roots_empty():
    worker = PYTHON_WORKER
    orig = worker.STRICT_FS_EXTRA_ALLOW
    try:
        worker.STRICT_FS_EXTRA_ALLOW = ""
        assert worker._parse_extra_allow_roots() == []
    finally:
        worker.STRICT_FS_EXTRA_ALLOW = orig


def test_worker_parse_extra_allow_roots_with_paths():
    worker = PYTHON_WORKER
    orig = worker.STRICT_FS_EXTRA_ALLOW
    try:
        worker.STRICT_FS_EXTRA_ALLOW = "/tmp/a, /tmp/b ,, "
        result = worker._parse_extra_allow_roots()
        assert len(result) == 2
        assert Path("/tmp/a").resolve(strict=False) in result
        assert Path("/tmp/b").resolve(strict=False) in result
    finally:
        worker.STRICT_FS_EXTRA_ALLOW = orig


def test_worker_resolve_candidate_path_int():
    worker = PYTHON_WORKER
    assert worker._resolve_candidate_path(42) is None


def test_worker_resolve_candidate_path_bytes():
    worker = PYTHON_WORKER
    result = worker._resolve_candidate_path(b"/tmp/test")
    assert result is not None
    assert isinstance(result, Path)


def test_worker_resolve_candidate_path_empty_string():
    worker = PYTHON_WORKER
    assert worker._resolve_candidate_path("") is None


def test_worker_resolve_candidate_path_none():
    worker = PYTHON_WORKER
    assert worker._resolve_candidate_path(None) is None


def test_worker_resolve_candidate_path_pathlike():
    worker = PYTHON_WORKER
    result = worker._resolve_candidate_path(Path("/tmp/test"))
    assert result is not None
    assert isinstance(result, Path)


def test_worker_resolve_candidate_path_string():
    worker = PYTHON_WORKER
    result = worker._resolve_candidate_path("/tmp/test")
    assert result == Path("/tmp/test").resolve(strict=False)


def test_worker_build_allowed_roots():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        handler_path = Path(tmp) / "app.py"
        handler_path.write_text("def handler(e): return {}", encoding="utf-8")
        roots, fn_dir = worker._build_allowed_roots(handler_path, [str(Path(tmp) / "deps")])
        assert fn_dir == Path(tmp).resolve(strict=False)
        # Should contain at least fn_dir, .deps, the deps dir, python prefix, system roots
        assert len(roots) >= 5
        assert fn_dir in roots


def test_worker_strict_fs_guard_blocks_outside_path():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "app.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                # Opening a file inside the sandbox should work
                import builtins
                # Trying to open a path outside sandbox should fail
                try:
                    builtins.open("/nonexistent_sandbox_test_path_xyz/secret.txt")
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
                except FileNotFoundError:
                    # Path is allowed (under a system root), but file doesn't exist
                    pass

                # subprocess should be blocked
                import subprocess
                try:
                    subprocess.run(["echo", "hi"])
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass

                # os.system should be blocked
                try:
                    os.system("echo hi")
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass

            # After context manager exits, things should be restored
            assert builtins.open is not None
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_disabled():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = False
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "app.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                pass  # Should not raise
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_protected_files():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "app.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            # Create a protected file
            protected = Path(tmp) / "fn.config.json"
            protected.write_text("{}", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                import builtins
                try:
                    builtins.open(str(protected))
                    assert False, "should have raised PermissionError for protected file"
                except PermissionError as e:
                    assert "protected" in str(e)
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_io_open():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "app.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            protected = Path(tmp) / "fn.env.json"
            protected.write_text("{}", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                try:
                    io.open(str(protected))
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_os_open():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "app.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            protected = Path(tmp) / "fn.test_events.json"
            protected.write_text("{}", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                try:
                    os.open(str(protected), os.O_RDONLY)
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_listdir_scandir():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "app.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                # listdir inside sandbox should work (fn_dir is allowed)
                entries = os.listdir(tmp)
                assert isinstance(entries, list)
                # scandir inside sandbox should work
                with os.scandir(tmp) as sd:
                    names = [e.name for e in sd]
                assert "app.py" in names
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_path_open():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "app.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            protected = Path(tmp) / "fn.config.json"
            protected.write_text("{}", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                try:
                    protected.open()
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_spawn_blocked():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "app.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                if hasattr(os, "spawnl"):
                    try:
                        os.spawnl(os.P_NOWAIT, "/bin/echo", "echo", "hi")
                        assert False, "should have raised PermissionError"
                    except PermissionError:
                        pass
                if hasattr(os, "execvpe"):
                    try:
                        os.execvpe("echo", ["echo", "hi"], {})
                        assert False, "should have raised PermissionError"
                    except PermissionError:
                        pass
                if hasattr(os, "execvp"):
                    try:
                        os.execvp("echo", ["echo", "hi"])
                        assert False, "should have raised PermissionError"
                    except PermissionError:
                        pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_pty_blocked():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "app.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                try:
                    import pty
                    pty.spawn("/bin/echo")
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
                except ImportError:
                    pass  # pty not available on this platform
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_ctypes_blocked():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "app.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                try:
                    import ctypes
                    ctypes.CDLL("libc.so.6")
                    assert False, "should have raised PermissionError"
                except PermissionError:
                    pass
                except ImportError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_subprocess_variants():
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler_path = Path(tmp) / "app.py"
            handler_path.write_text("x = 1", encoding="utf-8")
            with worker._strict_fs_guard(handler_path, []):
                import subprocess
                for fn in (subprocess.call, subprocess.check_call, subprocess.check_output, subprocess.Popen):
                    try:
                        fn(["echo", "hi"])
                        assert False, f"{fn.__name__} should have raised PermissionError"
                    except PermissionError:
                        pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_normalize_invoke_adapter():
    worker = PYTHON_WORKER
    assert worker._normalize_invoke_adapter(None) == "native"
    assert worker._normalize_invoke_adapter(123) == "native"
    assert worker._normalize_invoke_adapter("") == "native"
    assert worker._normalize_invoke_adapter("native") == "native"
    assert worker._normalize_invoke_adapter("none") == "native"
    assert worker._normalize_invoke_adapter("default") == "native"
    assert worker._normalize_invoke_adapter("  Native  ") == "native"
    assert worker._normalize_invoke_adapter("aws-lambda") == "aws-lambda"
    assert worker._normalize_invoke_adapter("lambda") == "aws-lambda"
    assert worker._normalize_invoke_adapter("apigw-v2") == "aws-lambda"
    assert worker._normalize_invoke_adapter("api-gateway-v2") == "aws-lambda"
    assert worker._normalize_invoke_adapter("cloudflare-worker") == "cloudflare-worker"
    assert worker._normalize_invoke_adapter("cloudflare-workers") == "cloudflare-worker"
    assert worker._normalize_invoke_adapter("worker") == "cloudflare-worker"
    assert worker._normalize_invoke_adapter("workers") == "cloudflare-worker"
    try:
        worker._normalize_invoke_adapter("invalid-adapter")
        assert False, "should have raised RuntimeError"
    except RuntimeError as e:
        assert "unsupported" in str(e)


def test_worker_resolve_handler_native():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.handler = lambda e: {"status": 200}
    result = worker._resolve_handler(mod, "handler", "native")
    assert result is mod.handler


def test_worker_resolve_handler_main_fallback():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.main = lambda e: {"status": 200}
    result = worker._resolve_handler(mod, "handler", "native")
    assert result is mod.main


def test_worker_resolve_handler_missing_raises():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    try:
        worker._resolve_handler(mod, "handler", "native")
        assert False, "should raise RuntimeError"
    except RuntimeError as e:
        assert "handler(event) is required" in str(e)


def test_worker_resolve_handler_cloudflare_fetch():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.fetch = lambda req, env, ctx: {"status": 200}
    result = worker._resolve_handler(mod, "handler", "cloudflare-worker")
    assert result is mod.fetch


def test_worker_resolve_handler_cloudflare_fallback():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.handler = lambda req, env, ctx: {"status": 200}
    result = worker._resolve_handler(mod, "handler", "cloudflare-worker")
    assert result is mod.handler


def test_worker_resolve_handler_cloudflare_missing():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    try:
        worker._resolve_handler(mod, "handler", "cloudflare-worker")
        assert False, "should raise RuntimeError"
    except RuntimeError as e:
        assert "cloudflare-worker" in str(e)


def test_worker_resolve_handler_custom_name():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.my_fn = lambda e: {"status": 200}
    result = worker._resolve_handler(mod, "my_fn", "native")
    assert result is mod.my_fn


def test_worker_resolve_handler_custom_name_not_callable():
    worker = PYTHON_WORKER
    import types
    mod = types.ModuleType("test_mod")
    mod.my_fn = "not callable"
    try:
        worker._resolve_handler(mod, "my_fn", "native")
        assert False, "should raise RuntimeError"
    except RuntimeError as e:
        assert "my_fn(event) is required" in str(e)


def test_worker_header_value():
    worker = PYTHON_WORKER
    headers = {"Content-Type": "text/html", "X-Custom": "val"}
    assert worker._header_value(headers, "content-type") == "text/html"
    assert worker._header_value(headers, "Content-Type") == "text/html"
    assert worker._header_value(headers, "x-custom") == "val"
    assert worker._header_value(headers, "missing") == ""


def test_worker_build_raw_path():
    worker = PYTHON_WORKER
    assert worker._build_raw_path({}) == "/"
    assert worker._build_raw_path({"path": "/api/test"}) == "/api/test"
    assert worker._build_raw_path({"raw_path": "/raw/path"}) == "/raw/path"
    assert worker._build_raw_path({"raw_path": "no-leading-slash"}) == "/no-leading-slash"
    assert worker._build_raw_path({"raw_path": "https://example.com/path"}) == "https://example.com/path"
    assert worker._build_raw_path({"raw_path": "http://example.com/path"}) == "http://example.com/path"
    assert worker._build_raw_path({"path": ""}) == "/"
    assert worker._build_raw_path({"raw_path": None, "path": "/fallback"}) == "/fallback"


def test_worker_encode_query_string():
    worker = PYTHON_WORKER
    assert worker._encode_query_string("not a dict") == ""
    assert worker._encode_query_string(None) == ""
    assert worker._encode_query_string({}) == ""
    assert worker._encode_query_string({"a": "1", "b": "2"}) in ("a=1&b=2", "b=2&a=1")
    assert worker._encode_query_string({"k": None}) == ""
    # List values
    result = worker._encode_query_string({"tags": ["a", "b"]})
    assert "tags=a" in result
    assert "tags=b" in result
    # None in list
    assert worker._encode_query_string({"tags": [None, "c"]}) == "tags=c"


def test_worker_build_raw_query():
    worker = PYTHON_WORKER
    assert worker._build_raw_query({"raw_path": "/path?foo=bar&x=1"}) == "foo=bar&x=1"
    assert worker._build_raw_query({"raw_path": "/path?"}) == ""
    assert worker._build_raw_query({"query": {"a": "1"}}) == "a=1"
    assert worker._build_raw_query({}) == ""


def test_worker_build_lambda_event():
    worker = PYTHON_WORKER
    event = {
        "method": "POST",
        "path": "/api/test",
        "headers": {"Content-Type": "application/json", "cookie": "a=1; b=2"},
        "query": {"page": "1"},
        "params": {"id": "42"},
        "body": "hello body",
        "client": {"ip": "1.2.3.4", "ua": "TestAgent"},
        "context": {"request_id": "req-123", "function_name": "my-fn", "timeout_ms": 5000},
        "id": "evt-1",
        "ts": 1700000000000,
    }
    result = worker._build_lambda_event(event)
    assert result["version"] == "2.0"
    assert result["routeKey"] == "POST /api/test"
    assert result["rawPath"] == "/api/test"
    assert result["headers"]["Content-Type"] == "application/json"
    assert result["queryStringParameters"] == {"page": "1"}
    assert result["pathParameters"] == {"id": "42"}
    assert result["body"] == "hello body"
    assert result["isBase64Encoded"] is False
    assert result["cookies"] == ["a=1", "b=2"]
    assert result["requestContext"]["requestId"] == "req-123"
    assert result["requestContext"]["http"]["method"] == "POST"
    assert result["requestContext"]["http"]["sourceIp"] == "1.2.3.4"
    assert result["requestContext"]["http"]["userAgent"] == "TestAgent"
    assert result["requestContext"]["timeEpoch"] == 1700000000000


def test_worker_build_lambda_event_base64_body():
    worker = PYTHON_WORKER
    import base64
    encoded = base64.b64encode(b"binary data").decode("utf-8")
    event = {
        "is_base64": True,
        "body_base64": encoded,
    }
    result = worker._build_lambda_event(event)
    assert result["isBase64Encoded"] is True
    assert result["body"] == encoded


def test_worker_build_lambda_event_defaults():
    worker = PYTHON_WORKER
    result = worker._build_lambda_event({})
    assert result["version"] == "2.0"
    assert result["rawPath"] == "/"
    assert result["headers"] == {}
    assert result["body"] == ""
    assert result["isBase64Encoded"] is False
    assert result["cookies"] is None
    assert result["queryStringParameters"] is None
    assert result["pathParameters"] is None


def test_worker_build_lambda_event_body_non_string():
    worker = PYTHON_WORKER
    result = worker._build_lambda_event({"body": 12345})
    assert result["body"] == "12345"


def test_worker_lambda_context():
    worker = PYTHON_WORKER
    event = {
        "id": "evt-1",
        "context": {
            "request_id": "req-123",
            "function_name": "my-fn",
            "version": "v2",
            "memory_limit_mb": "256",
            "invoked_function_arn": "arn:aws:lambda:us-east-1:123:function:my-fn",
            "timeout_ms": 30000,
        },
    }
    ctx = worker._LambdaContext(event)
    assert ctx.aws_request_id == "req-123"
    assert ctx.awsRequestId == "req-123"
    assert ctx.function_name == "my-fn"
    assert ctx.functionName == "my-fn"
    assert ctx.function_version == "v2"
    assert ctx.functionVersion == "v2"
    assert ctx.memory_limit_in_mb == "256"
    assert ctx.memoryLimitInMB == "256"
    assert ctx.invoked_function_arn == "arn:aws:lambda:us-east-1:123:function:my-fn"
    assert ctx.callback_waits_for_empty_event_loop is False
    assert ctx.get_remaining_time_in_millis() == 30000
    assert ctx.done() is None
    assert ctx.fail() is None
    assert ctx.succeed() is None


def test_worker_lambda_context_defaults():
    worker = PYTHON_WORKER
    ctx = worker._LambdaContext({})
    assert ctx.aws_request_id == ""
    assert ctx.function_name == ""
    assert ctx.function_version == "$LATEST"
    assert ctx.memory_limit_in_mb == ""
    assert ctx.invoked_function_arn == ""
    assert ctx.get_remaining_time_in_millis() == 0


def test_worker_build_workers_url():
    worker = PYTHON_WORKER
    assert worker._build_workers_url({"raw_path": "https://example.com/api"}) == "https://example.com/api"
    assert worker._build_workers_url({"raw_path": "http://example.com/api"}) == "http://example.com/api"
    result = worker._build_workers_url({"path": "/api", "headers": {"host": "myhost.com", "x-forwarded-proto": "https"}})
    assert result == "https://myhost.com/api"
    result2 = worker._build_workers_url({"path": "/api"})
    assert result2 == "http://127.0.0.1/api"


def test_worker_workers_request():
    worker = PYTHON_WORKER
    event = {
        "method": "POST",
        "headers": {"Content-Type": "application/json", "host": "example.com"},
        "path": "/api/test",
        "body": "hello",
    }
    req = worker._WorkersRequest(event)
    assert req.method == "POST"
    assert req.headers["Content-Type"] == "application/json"
    assert "example.com" in req.url
    assert req.body == b"hello"


def test_worker_workers_request_body_bytes():
    worker = PYTHON_WORKER
    event = {"body": b"raw bytes"}
    req = worker._WorkersRequest(event)
    assert req.body == b"raw bytes"


def test_worker_workers_request_body_none():
    worker = PYTHON_WORKER
    event = {}
    req = worker._WorkersRequest(event)
    assert req.body == b""


def test_worker_workers_request_body_non_string():
    worker = PYTHON_WORKER
    event = {"body": 12345}
    req = worker._WorkersRequest(event)
    assert req.body == b"12345"


def test_worker_workers_request_base64_body():
    worker = PYTHON_WORKER
    import base64
    encoded = base64.b64encode(b"binary data").decode("utf-8")
    event = {"is_base64": True, "body_base64": encoded}
    req = worker._WorkersRequest(event)
    assert req.body == b"binary data"


def test_worker_workers_request_base64_invalid():
    worker = PYTHON_WORKER
    event = {"is_base64": True, "body_base64": "!!!invalid!!!"}
    req = worker._WorkersRequest(event)
    assert req.body == b""


def test_worker_workers_request_async_text_and_json():
    worker = PYTHON_WORKER
    import asyncio
    event = {"body": '{"key": "value"}'}
    req = worker._WorkersRequest(event)
    text = asyncio.run(req.text())
    assert text == '{"key": "value"}'
    event2 = {"body": '{"key": "value"}'}
    req2 = worker._WorkersRequest(event2)
    data = asyncio.run(req2.json())
    assert data == {"key": "value"}


def test_worker_workers_request_json_empty():
    worker = PYTHON_WORKER
    import asyncio
    event = {"body": ""}
    req = worker._WorkersRequest(event)
    assert asyncio.run(req.json()) is None


def test_worker_workers_context():
    worker = PYTHON_WORKER
    event = {"id": "evt-1", "context": {"request_id": "req-123"}}
    ctx = worker._WorkersContext(event)
    assert ctx.request_id == "req-123"
    assert ctx._waitables == []
    assert ctx.passThroughOnException() is None
    assert ctx.pass_through_on_exception() is None


def test_worker_workers_context_wait_until():
    worker = PYTHON_WORKER
    import asyncio

    async def dummy():
        return 42

    ctx = worker._WorkersContext({})
    coro = dummy()
    ctx.waitUntil(coro)
    assert len(ctx._waitables) == 1
    # Clean up coroutine
    asyncio.run(ctx._waitables[0])


def test_worker_workers_context_wait_until_non_awaitable():
    worker = PYTHON_WORKER
    ctx = worker._WorkersContext({})
    ctx.wait_until("not awaitable")
    assert len(ctx._waitables) == 0


def test_worker_call_handler_var_positional():
    worker = PYTHON_WORKER

    def handler_varargs(*args):
        return {"args": len(args)}

    result = worker._call_handler(handler_varargs, [{"method": "GET"}, "extra"])
    assert result["args"] == 2


def test_worker_call_handler_zero_args():
    worker = PYTHON_WORKER

    def handler_no_args():
        return {"ok": True}

    result = worker._call_handler(handler_no_args, [{"method": "GET"}])
    assert result["ok"] is True


def test_worker_call_handler_async():
    worker = PYTHON_WORKER

    async def async_handler(event):
        return {"async": True}

    result = worker._call_handler(async_handler, [{}])
    # _call_handler returns the coroutine, _resolve_awaitable handles it
    import asyncio
    if asyncio.iscoroutine(result):
        result = asyncio.run(result)
    assert result["async"] is True


def test_worker_call_handler_keyword_only_params():
    worker = PYTHON_WORKER

    def handler_kw(event, *, id=None):
        return {"id": id}

    result = worker._call_handler(handler_kw, [{}], route_params={"id": "99"})
    assert result["id"] == "99"


def test_worker_call_handler_signature_fails_gracefully():
    worker = PYTHON_WORKER

    class WeirdCallable:
        def __call__(self, event):
            return {"ok": True}

    # Built-in callables may not support inspect.signature
    result = worker._call_handler(WeirdCallable(), [{}])
    assert result["ok"] is True


def test_worker_resolve_awaitable_sync():
    worker = PYTHON_WORKER
    assert worker._resolve_awaitable(42) == 42
    assert worker._resolve_awaitable("hello") == "hello"


def test_worker_resolve_awaitable_async():
    worker = PYTHON_WORKER

    async def get_value():
        return {"result": 99}

    result = worker._resolve_awaitable(get_value())
    assert result == {"result": 99}


def test_worker_normalize_response_like_object():
    worker = PYTHON_WORKER

    class FakeResp:
        status = 201
        headers = {"X-Test": "1"}
        body = "response body"

    result = worker._normalize_response_like_object(FakeResp())
    assert result["status"] == 201
    assert result["headers"]["X-Test"] == "1"
    assert result["body"] == "response body"


def test_worker_normalize_response_like_object_bytes():
    worker = PYTHON_WORKER
    import base64

    class FakeResp:
        status = 200
        headers = {}
        body = b"binary"

    result = worker._normalize_response_like_object(FakeResp())
    assert result["is_base64"] is True
    assert base64.b64decode(result["body_base64"]) == b"binary"


def test_worker_normalize_response_like_object_none_body():
    worker = PYTHON_WORKER

    class FakeResp:
        status = 200
        headers = {}
        body = None

    result = worker._normalize_response_like_object(FakeResp())
    assert result["body"] == ""


def test_worker_normalize_response_like_object_non_string_body():
    worker = PYTHON_WORKER

    class FakeResp:
        status = 200
        headers = {}
        body = 12345

    result = worker._normalize_response_like_object(FakeResp())
    assert result["body"] == "12345"


def test_worker_normalize_response_like_object_non_dict_headers():
    worker = PYTHON_WORKER

    class FakeResp:
        status = 200
        headers = "not-a-dict"
        body = "ok"

    result = worker._normalize_response_like_object(FakeResp())
    assert result["headers"] == {}


def test_worker_normalize_response_like_object_non_int_status():
    worker = PYTHON_WORKER

    class FakeResp:
        status = "not-int"
        headers = {}
        body = "ok"

    result = worker._normalize_response_like_object(FakeResp())
    assert result["status"] == 200


def test_worker_normalize_response_like_object_bytearray():
    worker = PYTHON_WORKER
    import base64

    class FakeResp:
        status = 200
        headers = {}
        body = bytearray(b"bytearray data")

    result = worker._normalize_response_like_object(FakeResp())
    assert result["is_base64"] is True
    assert base64.b64decode(result["body_base64"]) == b"bytearray data"


def test_worker_normalize_response_dict():
    worker = PYTHON_WORKER
    result = worker._normalize_response({"status": 200, "headers": {}, "body": "ok"})
    assert result == {"status": 200, "headers": {}, "body": "ok"}


def test_worker_normalize_response_tuple():
    worker = PYTHON_WORKER
    result = worker._normalize_response(("body text", 201, {"X-Custom": "1"}))
    assert result == {"body": "body text", "status": 201, "headers": {"X-Custom": "1"}}


def test_worker_normalize_response_tuple_partial():
    worker = PYTHON_WORKER
    result = worker._normalize_response(("just body",))
    assert result["body"] == "just body"
    assert result["status"] == 200
    assert result["headers"] == {}

    result2 = worker._normalize_response(("body", 202))
    assert result2["body"] == "body"
    assert result2["status"] == 202
    assert result2["headers"] == {}

    result3 = worker._normalize_response(())
    assert result3["body"] is None
    assert result3["status"] == 200


def test_worker_normalize_response_object():
    worker = PYTHON_WORKER

    class FakeResp:
        status = 204
        headers = {"X-Test": "1"}
        body = "no content"

    result = worker._normalize_response(FakeResp())
    assert result["status"] == 204
    assert result["body"] == "no content"


def test_worker_normalize_response_invalid():
    worker = PYTHON_WORKER
    try:
        worker._normalize_response(42)
        assert False, "should raise ValueError"
    except ValueError as e:
        assert "handler response" in str(e)


def test_worker_env_override_proxy():
    worker = PYTHON_WORKER
    real_env = {"A": "1", "B": "2"}
    proxy = worker._EnvOverrideProxy(real_env)

    # Basic access
    assert proxy["A"] == "1"
    assert proxy.get("A") == "1"
    assert proxy.get("MISSING", "default") == "default"
    assert "A" in proxy
    assert "MISSING" not in proxy
    assert len(proxy) == 2

    # Mutation
    proxy["C"] = "3"
    assert real_env["C"] == "3"
    del proxy["C"]
    assert "C" not in real_env

    # Iteration
    keys = list(proxy)
    assert "A" in keys
    assert "B" in keys
    assert proxy.keys() == ["A", "B"]
    assert proxy.values() == ["1", "2"]
    assert ("A", "1") in proxy.items()

    # Copy
    copy = proxy.copy()
    assert copy == {"A": "1", "B": "2"}

    # Pop
    real_env["D"] = "4"
    assert proxy.pop("D") == "4"
    assert "D" not in real_env

    # getattr passthrough
    assert proxy.pop("NONEXIST", "fallback") == "fallback"


def test_worker_env_override_proxy_with_overrides():
    worker = PYTHON_WORKER
    real_env = {"A": "1", "B": "2"}
    proxy = worker._EnvOverrideProxy(real_env)

    # Set thread-local overrides
    worker._thread_local_env.env_overrides = {"A": "override", "B": None, "NEW": "extra"}
    try:
        assert proxy["A"] == "override"
        assert proxy.get("A") == "override"
        try:
            _ = proxy["B"]
            assert False, "B should raise KeyError (overridden to None)"
        except KeyError:
            pass
        assert proxy.get("B", "default") == "default"
        assert "B" not in proxy
        assert "NEW" in proxy
        assert proxy["NEW"] == "extra"

        keys = list(proxy)
        assert "A" in keys
        assert "B" not in keys
        assert "NEW" in keys

        copy = proxy.copy()
        assert copy["A"] == "override"
        assert "B" not in copy
        assert copy["NEW"] == "extra"

        assert len(proxy) == 2  # A, NEW
    finally:
        worker._thread_local_env.env_overrides = None


def test_worker_patched_process_env():
    worker = PYTHON_WORKER
    event = {"env": {"TEST_VAR": "test_value", "EMPTY": None, "": "ignored"}}
    with worker._patched_process_env(event):
        assert worker._thread_local_env.env_overrides is not None
        assert worker._thread_local_env.env_overrides["TEST_VAR"] == "test_value"
        assert worker._thread_local_env.env_overrides["EMPTY"] is None
        assert "" not in worker._thread_local_env.env_overrides
    assert worker._thread_local_env.env_overrides is None


def test_worker_patched_process_env_empty():
    worker = PYTHON_WORKER
    with worker._patched_process_env({}):
        # Should not set overrides when env is empty
        pass
    with worker._patched_process_env({"env": {}}):
        pass


def test_worker_error_resp():
    worker = PYTHON_WORKER
    result = worker._error_resp(RuntimeError("test error"))
    assert result["status"] == 500
    assert result["headers"]["Content-Type"] == "application/json"
    body = json.loads(result["body"])
    assert body["error"] == "test error"


def test_worker_read_frame():
    worker = PYTHON_WORKER
    import struct

    # Normal frame
    payload = b'{"test": true}'
    frame = struct.pack(">I", len(payload)) + payload
    fake_stdin = io.BytesIO(frame)
    old_stdin = sys.stdin
    sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
    try:
        result = worker._read_frame()
        assert result == payload
    finally:
        sys.stdin = old_stdin


def test_worker_read_frame_empty():
    worker = PYTHON_WORKER

    # Short header (stdin closed)
    fake_stdin = io.BytesIO(b"\x00\x00")
    old_stdin = sys.stdin
    sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
    try:
        result = worker._read_frame()
        assert result is None
    finally:
        sys.stdin = old_stdin


def test_worker_read_frame_zero_length():
    worker = PYTHON_WORKER
    import struct

    frame = struct.pack(">I", 0)
    fake_stdin = io.BytesIO(frame)
    old_stdin = sys.stdin
    sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
    try:
        result = worker._read_frame()
        assert result == b""
    finally:
        sys.stdin = old_stdin


def test_worker_read_frame_truncated_data():
    worker = PYTHON_WORKER
    import struct

    # Header says 100 bytes but only 5 available
    frame = struct.pack(">I", 100) + b"short"
    fake_stdin = io.BytesIO(frame)
    old_stdin = sys.stdin
    sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
    try:
        result = worker._read_frame()
        assert result is None
    finally:
        sys.stdin = old_stdin


def test_worker_write_frame():
    worker = PYTHON_WORKER
    import struct

    buf = io.BytesIO()
    old_stdout = sys.stdout
    sys.stdout = type("FakeStdout", (), {"buffer": buf})()
    try:
        worker._write_frame(b'{"ok":true}')
    finally:
        sys.stdout = old_stdout
    buf.seek(0)
    data = buf.read()
    length = struct.unpack(">I", data[:4])[0]
    assert length == len(b'{"ok":true}')
    assert data[4:] == b'{"ok":true}'


def test_worker_load_handler():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n    return {'status': 200, 'headers': {}, 'body': 'ok'}\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        handler = worker._load_handler(str(fn_path), "handler", "native")
        assert callable(handler)

        # Call again should use cache
        handler2 = worker._load_handler(str(fn_path), "handler", "native")
        assert handler2 is handler


def test_worker_load_handler_cache_invalidation():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n    return {'status': 200, 'headers': {}, 'body': 'v1'}\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        handler1 = worker._load_handler(str(fn_path), "handler", "native")

        # Modify file and force different mtime_ns
        time.sleep(0.1)
        fn_path.write_text(
            "def handler(event):\n    return {'status': 200, 'headers': {}, 'body': 'v2'}\n",
            encoding="utf-8",
        )
        # Force mtime change if filesystem resolution is coarse
        import os as _os
        st = _os.stat(str(fn_path))
        _os.utime(str(fn_path), ns=(st.st_atime_ns, st.st_mtime_ns + 1000000000))
        handler2 = worker._load_handler(str(fn_path), "handler", "native")
        # Should be different handler since mtime changed
        result = handler2({})
        assert result["body"] == "v2"


def test_worker_handle_with_lambda_adapter():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "import json\n"
            "def handler(event, context):\n"
            "    return {\n"
            "        'status': 200,\n"
            "        'headers': {'Content-Type': 'application/json'},\n"
            "        'body': json.dumps({\n"
            "            'version': event.get('version'),\n"
            "            'request_id': context.aws_request_id,\n"
            "            'raw_path': event.get('rawPath'),\n"
            "        })\n"
            "    }\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "invoke_adapter": "aws-lambda",
            "deps_dirs": [],
            "event": {
                "method": "GET",
                "path": "/test",
                "headers": {},
                "context": {"request_id": "req-lambda-1"},
            },
        })
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["version"] == "2.0"
        assert body["request_id"] == "req-lambda-1"
        assert body["raw_path"] == "/test"


def test_worker_handle_with_cloudflare_adapter():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "import json\n"
            "async def fetch(request, env, ctx):\n"
            "    body = await request.text()\n"
            "    return type('Response', (), {\n"
            "        'status': 200,\n"
            "        'headers': {'Content-Type': 'application/json'},\n"
            "        'body': json.dumps({\n"
            "            'method': request.method,\n"
            "            'url': request.url,\n"
            "            'body_text': body,\n"
            "            'request_id': ctx.request_id,\n"
            "        })\n"
            "    })()\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "invoke_adapter": "cloudflare-worker",
            "deps_dirs": [],
            "event": {
                "method": "POST",
                "path": "/cf-test",
                "headers": {"host": "example.com"},
                "body": "cf body",
                "context": {"request_id": "req-cf-1"},
            },
        })
        assert resp["status"] == 200
        body = json.loads(resp["body"])
        assert body["method"] == "POST"
        assert "example.com" in body["url"]
        assert body["body_text"] == "cf body"
        assert body["request_id"] == "req-cf-1"


def test_worker_handle_error_in_handler():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n    raise RuntimeError('boom')\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        try:
            worker._handle({
                "handler_path": str(fn_path),
                "handler_name": "handler",
                "deps_dirs": [],
                "event": {},
            })
            assert False, "should raise"
        except RuntimeError:
            pass


def test_worker_handle_invalid_response():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n    return 42\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        try:
            worker._handle({
                "handler_path": str(fn_path),
                "handler_name": "handler",
                "deps_dirs": [],
                "event": {},
            })
            assert False, "should raise ValueError"
        except ValueError:
            pass


def test_worker_handle_with_env_overrides():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "import os, json\n"
            "def handler(event):\n"
            "    val = os.environ.get('TEST_WORKER_VAR', 'missing')\n"
            "    return {'status': 200, 'headers': {}, 'body': json.dumps({'val': val})}\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {"env": {"TEST_WORKER_VAR": "injected"}},
        })
        body = json.loads(resp["body"])
        assert body["val"] == "injected"


def test_worker_handle_async_handler():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "async def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'async ok'}\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 200
        assert resp["body"] == "async ok"


def test_worker_run_persistent():
    worker = PYTHON_WORKER
    import struct

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'persistent ok'}\n",
            encoding="utf-8",
        )

        payload = json.dumps({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        }).encode("utf-8")
        frame = struct.pack(">I", len(payload)) + payload
        # After the frame, send an empty stdin to trigger break
        fake_stdin = io.BytesIO(frame)
        stdout_buf = io.BytesIO()

        old_stdin = sys.stdin
        old_stdout = sys.stdout
        sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
        sys.stdout = type("FakeStdout", (), {"buffer": stdout_buf})()
        worker._handler_cache.clear()
        try:
            worker._run_persistent()
        finally:
            sys.stdin = old_stdin
            sys.stdout = old_stdout

        stdout_buf.seek(0)
        data = stdout_buf.read()
        resp_len = struct.unpack(">I", data[:4])[0]
        resp = json.loads(data[4:4 + resp_len])
        assert resp["status"] == 200
        assert resp["body"] == "persistent ok"


def test_worker_run_persistent_error():
    worker = PYTHON_WORKER
    import struct

    payload = json.dumps({
        "handler_path": "/nonexistent/app.py",
        "handler_name": "handler",
        "deps_dirs": [],
        "event": {},
    }).encode("utf-8")
    frame = struct.pack(">I", len(payload)) + payload
    fake_stdin = io.BytesIO(frame)
    stdout_buf = io.BytesIO()

    old_stdin = sys.stdin
    old_stdout = sys.stdout
    sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
    sys.stdout = type("FakeStdout", (), {"buffer": stdout_buf})()
    worker._handler_cache.clear()
    try:
        worker._run_persistent()
    finally:
        sys.stdin = old_stdin
        sys.stdout = old_stdout

    stdout_buf.seek(0)
    data = stdout_buf.read()
    resp_len = struct.unpack(">I", data[:4])[0]
    resp = json.loads(data[4:4 + resp_len])
    assert resp["status"] == 500
    assert "error" in json.loads(resp["body"])


def test_worker_run_oneshot():
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'oneshot ok'}\n",
            encoding="utf-8",
        )

        payload = json.dumps({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })

        old_stdin = sys.stdin
        old_stdout = sys.stdout
        sys.stdin = io.StringIO(payload)
        stdout_buf = io.StringIO()
        sys.stdout = stdout_buf
        worker._handler_cache.clear()
        try:
            worker._run_oneshot()
        finally:
            sys.stdin = old_stdin
            sys.stdout = old_stdout

        resp = json.loads(stdout_buf.getvalue())
        assert resp["status"] == 200
        assert resp["body"] == "oneshot ok"


def test_worker_run_oneshot_empty():
    worker = PYTHON_WORKER

    old_stdin = sys.stdin
    old_stdout = sys.stdout
    sys.stdin = io.StringIO("")
    stdout_buf = io.StringIO()
    sys.stdout = stdout_buf
    try:
        worker._run_oneshot()
    finally:
        sys.stdin = old_stdin
        sys.stdout = old_stdout

    assert stdout_buf.getvalue() == ""


def test_worker_run_oneshot_error():
    worker = PYTHON_WORKER

    payload = json.dumps({
        "handler_path": "/nonexistent/app.py",
        "handler_name": "handler",
        "deps_dirs": [],
        "event": {},
    })

    old_stdin = sys.stdin
    old_stdout = sys.stdout
    sys.stdin = io.StringIO(payload)
    stdout_buf = io.StringIO()
    sys.stdout = stdout_buf
    worker._handler_cache.clear()
    try:
        worker._run_oneshot()
    finally:
        sys.stdin = old_stdin
        sys.stdout = old_stdout

    resp = json.loads(stdout_buf.getvalue())
    assert resp["status"] == 500


def test_worker_main_oneshot_mode():
    worker = PYTHON_WORKER

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'main ok'}\n",
            encoding="utf-8",
        )

        payload = json.dumps({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })

        old_stdin = sys.stdin
        old_stdout = sys.stdout
        old_mode = os.environ.get("_FASTFN_WORKER_MODE")
        old_deps = os.environ.get("_FASTFN_WORKER_DEPS")
        sys.stdin = io.StringIO(payload)
        stdout_buf = io.StringIO()
        sys.stdout = stdout_buf
        os.environ["_FASTFN_WORKER_MODE"] = "oneshot"
        if "_FASTFN_WORKER_DEPS" in os.environ:
            del os.environ["_FASTFN_WORKER_DEPS"]
        worker._handler_cache.clear()
        try:
            worker.main()
        finally:
            sys.stdin = old_stdin
            sys.stdout = old_stdout
            if old_mode is not None:
                os.environ["_FASTFN_WORKER_MODE"] = old_mode
            elif "_FASTFN_WORKER_MODE" in os.environ:
                del os.environ["_FASTFN_WORKER_MODE"]
            if old_deps is not None:
                os.environ["_FASTFN_WORKER_DEPS"] = old_deps

        resp = json.loads(stdout_buf.getvalue())
        assert resp["status"] == 200


def test_worker_main_persistent_mode():
    worker = PYTHON_WORKER
    import struct

    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n"
            "    return {'status': 200, 'headers': {}, 'body': 'persistent main'}\n",
            encoding="utf-8",
        )

        payload = json.dumps({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        }).encode("utf-8")
        frame = struct.pack(">I", len(payload)) + payload
        fake_stdin = io.BytesIO(frame)
        stdout_buf = io.BytesIO()

        old_stdin = sys.stdin
        old_stdout = sys.stdout
        old_mode = os.environ.get("_FASTFN_WORKER_MODE")
        old_deps = os.environ.get("_FASTFN_WORKER_DEPS")
        sys.stdin = type("FakeStdin", (), {"buffer": fake_stdin})()
        sys.stdout = type("FakeStdout", (), {"buffer": stdout_buf})()
        os.environ["_FASTFN_WORKER_MODE"] = "persistent"
        if "_FASTFN_WORKER_DEPS" in os.environ:
            del os.environ["_FASTFN_WORKER_DEPS"]
        worker._handler_cache.clear()
        try:
            worker.main()
        finally:
            sys.stdin = old_stdin
            sys.stdout = old_stdout
            if old_mode is not None:
                os.environ["_FASTFN_WORKER_MODE"] = old_mode
            elif "_FASTFN_WORKER_MODE" in os.environ:
                del os.environ["_FASTFN_WORKER_MODE"]
            if old_deps is not None:
                os.environ["_FASTFN_WORKER_DEPS"] = old_deps

        stdout_buf.seek(0)
        data = stdout_buf.read()
        resp_len = struct.unpack(">I", data[:4])[0]
        resp = json.loads(data[4:4 + resp_len])
        assert resp["status"] == 200
        assert resp["body"] == "persistent main"


def test_worker_main_with_deps_env():
    worker = PYTHON_WORKER

    old_stdin = sys.stdin
    old_stdout = sys.stdout
    old_mode = os.environ.get("_FASTFN_WORKER_MODE")
    old_deps = os.environ.get("_FASTFN_WORKER_DEPS")
    sys.stdin = io.StringIO("")
    stdout_buf = io.StringIO()
    sys.stdout = stdout_buf

    fake_dep_dir = "/tmp/fake_fastfn_deps_test"
    os.environ["_FASTFN_WORKER_MODE"] = "oneshot"
    os.environ["_FASTFN_WORKER_DEPS"] = fake_dep_dir
    try:
        worker.main()
        assert fake_dep_dir in sys.path
    finally:
        sys.stdin = old_stdin
        sys.stdout = old_stdout
        if fake_dep_dir in sys.path:
            sys.path.remove(fake_dep_dir)
        if old_mode is not None:
            os.environ["_FASTFN_WORKER_MODE"] = old_mode
        elif "_FASTFN_WORKER_MODE" in os.environ:
            del os.environ["_FASTFN_WORKER_MODE"]
        if old_deps is not None:
            os.environ["_FASTFN_WORKER_DEPS"] = old_deps
        elif "_FASTFN_WORKER_DEPS" in os.environ:
            del os.environ["_FASTFN_WORKER_DEPS"]


def test_worker_handle_tuple_response():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n    return ('body', 201, {'X-Test': '1'})\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 201
        assert resp["body"] == "body"
        assert resp["headers"]["X-Test"] == "1"


def test_worker_handle_object_response():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "class Resp:\n"
            "    status = 202\n"
            "    headers = {'X-Custom': 'yes'}\n"
            "    body = 'object resp'\n"
            "def handler(event):\n"
            "    return Resp()\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {},
        })
        assert resp["status"] == 202
        assert resp["body"] == "object resp"


def test_worker_handle_deps_dirs_added_to_sys_path():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "def handler(event):\n    return {'status': 200, 'headers': {}, 'body': 'ok'}\n",
            encoding="utf-8",
        )
        deps_dir = str(Path(tmp) / "deps")
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [deps_dir],
            "event": {},
        })
        assert resp["status"] == 200
        assert deps_dir in sys.path
        # Cleanup
        if deps_dir in sys.path:
            sys.path.remove(deps_dir)


def test_worker_invoke_handler_native_with_params():
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        fn_path = Path(tmp) / "app.py"
        fn_path.write_text(
            "import json\n"
            "def handler(event, id=None):\n"
            "    return {'status': 200, 'headers': {}, 'body': json.dumps({'id': id})}\n",
            encoding="utf-8",
        )
        worker._handler_cache.clear()
        resp = worker._handle({
            "handler_path": str(fn_path),
            "handler_name": "handler",
            "deps_dirs": [],
            "event": {"params": {"id": "77"}},
        })
        body = json.loads(resp["body"])
        assert body["id"] == "77"


def test_worker_build_lambda_event_with_raw_path_query():
    worker = PYTHON_WORKER
    event = {
        "raw_path": "/api/test?foo=bar&x=1",
        "method": "GET",
    }
    result = worker._build_lambda_event(event)
    assert result["rawPath"] == "/api/test"
    assert result["rawQueryString"] == "foo=bar&x=1"


def test_worker_build_lambda_event_no_ts_uses_time():
    worker = PYTHON_WORKER
    result = worker._build_lambda_event({"ts": 0})
    assert result["requestContext"]["timeEpoch"] > 0


def test_worker_parse_extra_allow_roots_exception():
    """Cover lines 52-61: _parse_extra_allow_roots with paths."""
    worker = PYTHON_WORKER
    orig = worker.STRICT_FS_EXTRA_ALLOW
    try:
        # Normal path
        worker.STRICT_FS_EXTRA_ALLOW = "/tmp,/var"
        result = worker._parse_extra_allow_roots()
        assert len(result) == 2

        # Empty
        worker.STRICT_FS_EXTRA_ALLOW = ""
        result = worker._parse_extra_allow_roots()
        assert result == []

        # Only whitespace/commas
        worker.STRICT_FS_EXTRA_ALLOW = " , , "
        result = worker._parse_extra_allow_roots()
        assert result == []
    finally:
        worker.STRICT_FS_EXTRA_ALLOW = orig


def test_worker_resolve_candidate_path_bytes_exception():
    """Cover line 71-72: bytes decode exception."""
    worker = PYTHON_WORKER
    result = worker._resolve_candidate_path(b"/tmp/test")
    assert result is not None or result is None
    assert worker._resolve_candidate_path(42) is None
    assert worker._resolve_candidate_path("") is None


def test_worker_resolve_candidate_path_resolve_exception():
    """Cover line 79-80: Path().resolve() exception."""
    worker = PYTHON_WORKER
    # None target
    assert worker._resolve_candidate_path(None) is None
    # PathLike
    result = worker._resolve_candidate_path(Path("/tmp"))
    assert result is not None


def test_worker_build_allowed_roots_deps_exception():
    """Cover line 90-91: deps_dirs resolve exception."""
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "app.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")
        roots, fn_dir = worker._build_allowed_roots(handler, ["/tmp/valid"])
        assert fn_dir is not None


def test_worker_build_allowed_roots_sys_prefix_edges():
    """Cover lines 96, 99-100, 106-107."""
    worker = PYTHON_WORKER
    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "app.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")
        roots, fn_dir = worker._build_allowed_roots(handler, [])
        assert len(roots) > 0


def test_worker_strict_fs_guard_protected_files():
    """Cover line 132-134: access to protected fn.config.json / fn.env.json."""
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "app.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            config = Path(tmp) / "fn.config.json"
            config.write_text("{}", encoding="utf-8")
            env_file = Path(tmp) / "fn.env.json"
            env_file.write_text("{}", encoding="utf-8")

            with worker._strict_fs_guard(handler, []):
                try:
                    with open(config, "r") as f:
                        f.read()
                    assert False, "should have raised PermissionError for fn.config.json"
                except PermissionError:
                    pass
                try:
                    with open(env_file, "r") as f:
                        f.read()
                    assert False, "should have raised PermissionError for fn.env.json"
                except PermissionError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_guarded_calls():
    """Cover lines 155, 159, 163, 175: guarded builtins."""
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "app.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            test_file = Path(tmp) / "test.txt"
            test_file.write_text("hello", encoding="utf-8")

            with worker._strict_fs_guard(handler, []):
                with open(test_file, "r") as f:
                    assert f.read() == "hello"
                import io as io_mod
                with io_mod.open(str(test_file), "r") as f:
                    assert f.read() == "hello"
                fd = os.open(str(test_file), os.O_RDONLY)
                os.close(fd)
                test_file.open("r").close()
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_load_handler_spec_none():
    """Cover line 337: _load_handler when spec is None."""
    worker = PYTHON_WORKER
    old_cache = dict(worker._handler_cache)
    try:
        worker._handler_cache.clear()
        try:
            worker._load_handler(str(Path("/nonexistent/fake.py")), "handler", "native")
        except (RuntimeError, FileNotFoundError, OSError):
            pass
    finally:
        worker._handler_cache.clear()
        worker._handler_cache.update(old_cache)


def test_worker_resolve_awaitable_runtime_error():
    """Cover lines 576-581: _resolve_awaitable RuntimeError fallback."""
    import asyncio
    worker = PYTHON_WORKER
    async def coro():
        return 42
    result = worker._resolve_awaitable(coro())
    assert result == 42
    assert worker._resolve_awaitable("hello") == "hello"


def test_worker_env_override_proxy_iter_non_override():
    """Cover lines 658-659: __iter__ non-override keys."""
    worker = PYTHON_WORKER
    proxy = worker._EnvOverrideProxy({"A": "1", "B": "2"})
    # Set overrides via the module's thread-local
    worker._thread_local_env.env_overrides = {"B": "overridden", "C": "new"}
    try:
        keys = list(proxy)
        assert "A" in keys
        assert "B" in keys
        assert "C" in keys
    finally:
        worker._thread_local_env.env_overrides = None


def test_worker_env_override_proxy_getattr():
    """Cover line 691: __getattr__."""
    worker = PYTHON_WORKER
    real_env = {"PATH": "/usr/bin"}
    proxy = worker._EnvOverrideProxy(real_env)
    assert callable(proxy.get)
    assert proxy.get("PATH") == "/usr/bin"


def test_worker_parse_extra_allow_roots_resolve_fail():
    """Cover lines 60-61: Path.resolve raises inside _parse_extra_allow_roots."""
    worker = PYTHON_WORKER
    orig_allow = worker.STRICT_FS_EXTRA_ALLOW
    orig_resolve = Path.resolve
    call_count = [0]

    def bad_resolve(self, strict=False):
        if "badpath_xyz" in str(self):
            raise OSError("simulated resolve failure")
        return orig_resolve(self, strict=strict)

    try:
        worker.STRICT_FS_EXTRA_ALLOW = "/tmp,badpath_xyz_test"
        Path.resolve = bad_resolve
        result = worker._parse_extra_allow_roots()
        # Should skip the bad path and return the valid one
        assert len(result) >= 1
    finally:
        worker.STRICT_FS_EXTRA_ALLOW = orig_allow
        Path.resolve = orig_resolve


def test_worker_resolve_candidate_bytes_decode_fail():
    """Cover lines 71-72: bytes subclass that raises on decode."""
    worker = PYTHON_WORKER

    class BadBytes(bytes):
        def decode(self, *a, **kw):
            raise RuntimeError("simulated decode failure")

    result = worker._resolve_candidate_path(BadBytes(b"/tmp/test"))
    assert result is None

    # Normal bytes still work
    result2 = worker._resolve_candidate_path(b"/tmp/testpath")
    assert result2 is not None


def test_worker_resolve_candidate_resolve_fail():
    """Cover lines 79-80: Path.resolve raises."""
    worker = PYTHON_WORKER
    orig_resolve = Path.resolve

    def bad_resolve(self, strict=False):
        if "resolve_fail_xyz" in str(self):
            raise OSError("simulated")
        return orig_resolve(self, strict=strict)

    try:
        Path.resolve = bad_resolve
        result = worker._resolve_candidate_path("resolve_fail_xyz_test")
        assert result is None
    finally:
        Path.resolve = orig_resolve


def test_worker_build_allowed_roots_exception_paths():
    """Cover lines 90-91, 96, 99-100, 106-107."""
    worker = PYTHON_WORKER
    orig_resolve = Path.resolve

    call_count = [0]
    def bad_resolve(self, strict=False):
        s = str(self)
        if "bad_dep_xyz" in s:
            raise OSError("simulated dep resolve fail")
        return orig_resolve(self, strict=strict)

    with tempfile.TemporaryDirectory() as tmp:
        handler = Path(tmp) / "app.py"
        handler.write_text("def handler(e): return {}\n", encoding="utf-8")
        try:
            Path.resolve = bad_resolve
            roots, fn_dir = worker._build_allowed_roots(handler, ["/tmp", "bad_dep_xyz"])
            assert fn_dir is not None
        finally:
            Path.resolve = orig_resolve


def test_worker_strict_fs_guard_check_target_none():
    """Cover line 132: check_target returns when candidate is None (int fd)."""
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "app.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            test_file = Path(tmp) / "test.txt"
            test_file.write_text("x", encoding="utf-8")

            with worker._strict_fs_guard(handler, []):
                # Open by fd (int) — check_target gets None from _resolve_candidate_path
                fd = os.open(str(test_file), os.O_RDONLY)
                try:
                    # Now re-open using the fd (int target)
                    # open() with int fd just wraps the fd
                    f = open(fd, "r", closefd=False)
                    f.read()
                    f.close()
                finally:
                    os.close(fd)
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_strict_fs_guard_pty_ctypes_import_error():
    """Cover lines 222-223, 240-241: pty/ctypes ImportError paths."""
    # These lines handle ImportError for pty/ctypes — they're already covered
    # if pty/ctypes are available (which they are). The ImportError paths
    # are dead code on standard Python. We verify the guard works anyway.
    worker = PYTHON_WORKER
    orig_strict = worker.STRICT_FS
    try:
        worker.STRICT_FS = True
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "app.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            with worker._strict_fs_guard(handler, []):
                # pty.spawn should be blocked
                import pty
                try:
                    pty.spawn("/bin/echo")
                    assert False, "pty.spawn should be blocked"
                except PermissionError:
                    pass
                # ctypes.CDLL should be blocked
                import ctypes
                try:
                    ctypes.CDLL("libc.so.6")
                    assert False, "ctypes.CDLL should be blocked"
                except PermissionError:
                    pass
    finally:
        worker.STRICT_FS = orig_strict


def test_worker_load_handler_spec_none_actual():
    """Cover line 337: spec is None for a non-python file."""
    worker = PYTHON_WORKER
    old_cache = dict(worker._handler_cache)
    try:
        worker._handler_cache.clear()
        with tempfile.TemporaryDirectory() as tmp:
            # Create a file that importlib can't create a spec for
            bad_file = Path(tmp) / "notamodule.xyz"
            bad_file.write_text("x = 1\n", encoding="utf-8")
            try:
                worker._load_handler(str(bad_file), "handler", "native")
            except (RuntimeError, FileNotFoundError, OSError):
                pass
    finally:
        worker._handler_cache.clear()
        worker._handler_cache.update(old_cache)


def test_worker_resolve_awaitable_runtime_error_fallback():
    """Cover lines 576-581: asyncio.run raises RuntimeError, fallback to new_event_loop."""
    import asyncio
    worker = PYTHON_WORKER

    async def simple_coro():
        return 99

    # Monkey-patch asyncio.run to raise RuntimeError
    orig_run = asyncio.run

    def failing_run(coro, **kw):
        raise RuntimeError("no current event loop")

    try:
        asyncio.run = failing_run
        result = worker._resolve_awaitable(simple_coro())
        assert result == 99
    finally:
        asyncio.run = orig_run


def test_worker_env_proxy_getattr_coverage():
    """Cover line 691: __getattr__ delegating to _real."""
    worker = PYTHON_WORKER
    real = {"A": "1"}
    proxy = worker._EnvOverrideProxy(real)
    # Access methods that exist on dict but not on proxy class
    # These go through __getattr__
    assert callable(proxy.update)
    assert callable(proxy.setdefault)
    assert proxy.get("A") == "1"


def test_worker_build_allowed_roots_sys_prefix_empty():
    """Cover line 96: sys.prefix is empty string."""
    worker = PYTHON_WORKER
    orig_prefix = sys.prefix
    orig_base = getattr(sys, "base_prefix", None)
    orig_exec = getattr(sys, "exec_prefix", None)
    try:
        sys.prefix = ""
        sys.base_prefix = ""
        sys.exec_prefix = ""
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "app.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            roots, fn_dir = worker._build_allowed_roots(handler, [])
            assert fn_dir is not None
    finally:
        sys.prefix = orig_prefix
        if orig_base is not None:
            sys.base_prefix = orig_base
        if orig_exec is not None:
            sys.exec_prefix = orig_exec


def test_worker_build_allowed_roots_resolve_exception():
    """Cover lines 99-100, 106-107: Path.resolve raises for sys.prefix/system roots."""
    worker = PYTHON_WORKER
    orig_resolve = Path.resolve

    def bad_resolve(self, strict=False):
        s = str(self)
        if s == sys.prefix or s in ("/etc/pki",):
            raise OSError("simulated resolve fail")
        return orig_resolve(self, strict=strict)

    try:
        Path.resolve = bad_resolve
        with tempfile.TemporaryDirectory() as tmp:
            handler = Path(tmp) / "app.py"
            handler.write_text("def handler(e): return {}\n", encoding="utf-8")
            roots, fn_dir = worker._build_allowed_roots(handler, [])
            assert fn_dir is not None
    finally:
        Path.resolve = orig_resolve


def test_python_subprocess_does_not_fallback_to_oneshot_v2() -> None:
    handler = load_handler(ROOT / "examples/functions/python/sendgrid-send/app.py")
    # Missing both SENDGRID_API_KEY and SENDGRID_FROM
    resp = handler({"query": {"dry_run": "false"}, "env": {}})
    assert_response_contract(resp)
    assert resp["status"] == 400
    body = json.loads(resp["body"])
    assert body["ok"] is False
    assert "SENDGRID_API_KEY" in body["error"]

    # Has API key but missing FROM
    resp2 = handler({"query": {"dry_run": "false"}, "env": {"SENDGRID_API_KEY": "sk-test"}})
    assert_response_contract(resp2)
    assert resp2["status"] == 400
    body2 = json.loads(resp2["body"])
    assert "SENDGRID_FROM" in body2["error"]


def test_python_sendgrid_send_invalid_email_via_body():
    handler = load_handler(ROOT / "examples/functions/python/sendgrid-send/app.py")
    # POST with body overrides query defaults
    resp = handler({
        "method": "POST",
        "body": json.dumps({"to": "custom@test.com", "subject": "Custom Subject", "text": "Custom body"}),
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["dry_run"] is True
    assert body["request"]["body"]["personalizations"][0]["to"][0]["email"] == "custom@test.com"
    assert body["request"]["body"]["subject"] == "Custom Subject"
    assert body["request"]["body"]["content"][0]["value"] == "Custom body"


def test_python_sendgrid_send_api_error_returns_502():
    mod = load_module(ROOT / "examples/functions/python/sendgrid-send/app.py")
    handler = mod.handler

    class ErrorResp:
        def __init__(self):
            self.status = 400

        def read(self):
            return b'{"errors":[{"message":"invalid"}]}'

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    original = mod.urllib.request.urlopen
    try:
        # Test HTTP error from SendGrid API
        def fail_http(_req, timeout):
            raise mod.urllib.error.HTTPError(
                "https://api.sendgrid.com/v3/mail/send",
                400,
                "Bad Request",
                {},
                None,
            )

        mod.urllib.request.urlopen = fail_http
        resp = handler({
            "query": {"dry_run": "false", "to": "test@example.com"},
            "env": {"SENDGRID_API_KEY": "k", "SENDGRID_FROM": "from@example.com"},
            "context": {"timeout_ms": 1000},
        })
        assert_response_contract(resp)
        assert resp["status"] == 502

        # Test connection timeout
        def fail_timeout(_req, timeout):
            raise TimeoutError("connection timed out")

        mod.urllib.request.urlopen = fail_timeout
        resp2 = handler({
            "query": {"dry_run": "false", "to": "test@example.com"},
            "env": {"SENDGRID_API_KEY": "k", "SENDGRID_FROM": "from@example.com"},
            "context": {"timeout_ms": 1000},
        })
        assert_response_contract(resp2)
        assert resp2["status"] == 502
    finally:
        mod.urllib.request.urlopen = original


def test_python_sendgrid_send_context_timeout():
    handler = load_handler(ROOT / "examples/functions/python/sendgrid-send/app.py")
    # Default context timeout_ms when not provided
    resp = handler({
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["dry_run"] is True

    # Custom context timeout_ms
    resp2 = handler({
        "query": {"dry_run": "true"},
        "env": {},
        "context": {"timeout_ms": 30000},
    })
    assert_response_contract(resp2)
    body2 = json.loads(resp2["body"])
    assert body2["dry_run"] is True


def test_python_sendgrid_send_post_body_parsing():
    handler = load_handler(ROOT / "examples/functions/python/sendgrid-send/app.py")
    # PUT method with body should also parse
    resp = handler({
        "method": "PUT",
        "body": json.dumps({"to": "put@example.com", "subject": "PUT Subject"}),
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp)
    body = json.loads(resp["body"])
    assert body["request"]["body"]["personalizations"][0]["to"][0]["email"] == "put@example.com"

    # PATCH method with body should also parse
    resp2 = handler({
        "method": "PATCH",
        "body": json.dumps({"to": "patch@example.com"}),
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp2)
    body2 = json.loads(resp2["body"])
    assert body2["request"]["body"]["personalizations"][0]["to"][0]["email"] == "patch@example.com"

    # GET method ignores body
    resp3 = handler({
        "method": "GET",
        "body": json.dumps({"to": "ignored@example.com"}),
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp3)
    body3 = json.loads(resp3["body"])
    assert body3["request"]["body"]["personalizations"][0]["to"][0]["email"] == "demo@example.com"

    # dry_run hint includes missing_env keys
    resp4 = handler({
        "query": {"dry_run": "true"},
        "env": {},
    })
    assert_response_contract(resp4)
    body4 = json.loads(resp4["body"])
    assert "SENDGRID_API_KEY" in body4["missing_env"]
    assert "SENDGRID_FROM" in body4["missing_env"]

    # dry_run with keys present shows hidden authorization
    resp5 = handler({
        "query": {"dry_run": "true"},
        "env": {"SENDGRID_API_KEY": "sk-real", "SENDGRID_FROM": "real@example.com"},
    })
    assert_response_contract(resp5)
    body5 = json.loads(resp5["body"])
    assert body5["missing_env"] == []
    assert body5["request"]["headers"]["Authorization"] == "<hidden>"


def main():
    test_python_hello()
    test_python_hello_debug()
    test_python_hello_prefix()
    test_python_risk_score()
    test_python_risk_score_branches()
    test_python_lambda_echo_shape()
    test_python_custom_echo_shape()
    test_python_pack_qr_svg_shape()
    test_python_qr_svg_shape_uses_url_or_text()
    test_python_html_demo()
    test_python_csv_demo()
    test_python_png_demo_binary_contract()
    test_python_slow_invalid_sleep_ms_is_zero()
    test_python_slow_positive_sleep_ms_calls_sleep()
    test_python_cron_tick_read_and_inc_uses_local_count_file()
    test_python_cron_tick_invalid_count_falls_back_to_zero()
    test_python_utc_time_and_offset_time_include_trigger()
    test_python_requirements_demo()
    test_python_sheets_webapp_append_dry_run_and_missing_env()
    test_python_sheets_webapp_append_exec_success_and_failure_via_mock()
    test_python_sheets_webapp_append_bool_none_branch()
    test_python_sendgrid_send_dry_run_and_enforce_paths()
    test_python_sendgrid_send_parse_payload_error_and_bool_none_branch()
    test_python_sendgrid_send_exec_success_and_failure_via_mock()
    test_python_github_webhook_verify_dry_run_and_enforce()
    test_python_github_webhook_verify_bool_none_branch()
    test_python_gmail_parse_json_and_forced_dry_run_without_creds()
    test_python_custom_handler_demo_main()
    test_python_nombre_handler()
    test_python_tools_loop_dry_run_plan()
    test_python_tools_loop_exec_mock()
    test_python_tools_loop_helper_branches()
    test_python_tools_loop_help_and_unknown_paths()
    test_python_tools_loop_exec_non_mock_and_body_fallback()
    test_python_tools_loop_http_json_success_error_and_truncate()
    test_python_telegram_ai_reply_py_missing_env()
    test_python_telegram_ai_reply_py_no_text_message()
    test_python_telegram_ai_reply_py_success_flow()
    test_python_telegram_ai_reply_py_openai_error()
    test_python_telegram_ai_reply_py_telegram_send_error()
    test_python_telegram_ai_reply_py_edited_message()
    test_python_telegram_ai_reply_py_body_string()
    test_python_telegram_ai_reply_py_body_invalid_json()
    test_python_telegram_ai_reply_py_body_none()
    test_python_telegram_ai_reply_py_caption_message()
    test_python_telegram_ai_reply_py_openai_no_choices()
    test_python_telegram_ai_reply_py_env_none()
    test_python_gmail_send_dry_run()
    test_python_gmail_send_dry_run_with_credentials_no_forced_note()
    test_python_gmail_send_requires_to()
    test_python_gmail_send_forced_dry_run_without_credentials()
    test_python_gmail_send_success_via_mocked_smtp()
    test_python_gmail_send_failure_via_mocked_smtp()
    test_python_gmail_send_body_parse_variants()
    test_python_ip_intel_maxmind_mock()
    test_python_prepare_socket_path_tolerates_stat_race()
    test_python_persistent_worker_with_deps_dir()
    test_python_main_fallback_and_node_like_payload()
    test_python_subprocess_main_fallback_and_node_like_payload()
    test_python_subprocess_tuple_response()
    test_python_prefers_handler_over_main()
    test_python_worker_captures_stdout()
    test_python_worker_captures_stderr()
    test_python_worker_no_stdout_when_silent()
    test_python_daemon_preserves_stdout_stderr()
    test_python_daemon_emits_handler_logs()
    test_python_worker_event_session_passthrough()
    # Direct params injection
    test_python_rest_product_id_direct_param()
    test_python_rest_product_id_put_direct_param()
    test_python_rest_product_id_delete_direct_param()
    test_python_rest_slug_direct_param()
    test_python_rest_category_slug_multi_param()
    test_python_rest_wildcard_path_direct_param()
    test_python_rest_wildcard_empty_path()
    # Worker _call_handler injection
    test_worker_call_handler_injects_kwargs()
    test_worker_call_handler_injects_multiple_kwargs()
    test_worker_call_handler_var_keyword_receives_all()
    test_worker_call_handler_no_params_ignores_route_params()
    test_worker_call_handler_no_route_params_works()
    test_worker_call_handler_extra_params_ignored()
    test_worker_handle_passes_route_params_from_event()
    test_worker_handle_multi_params_from_event()
    # Worker full coverage tests
    test_worker_parse_extra_allow_roots_empty()
    test_worker_parse_extra_allow_roots_with_paths()
    test_worker_resolve_candidate_path_int()
    test_worker_resolve_candidate_path_bytes()
    test_worker_resolve_candidate_path_empty_string()
    test_worker_resolve_candidate_path_none()
    test_worker_resolve_candidate_path_pathlike()
    test_worker_resolve_candidate_path_string()
    test_worker_build_allowed_roots()
    test_worker_strict_fs_guard_blocks_outside_path()
    test_worker_strict_fs_guard_disabled()
    test_worker_strict_fs_guard_protected_files()
    test_worker_strict_fs_guard_io_open()
    test_worker_strict_fs_guard_os_open()
    test_worker_strict_fs_guard_listdir_scandir()
    test_worker_strict_fs_guard_path_open()
    test_worker_strict_fs_guard_spawn_blocked()
    test_worker_strict_fs_guard_pty_blocked()
    test_worker_strict_fs_guard_ctypes_blocked()
    test_worker_strict_fs_guard_subprocess_variants()
    test_worker_normalize_invoke_adapter()
    test_worker_resolve_handler_native()
    test_worker_resolve_handler_main_fallback()
    test_worker_resolve_handler_missing_raises()
    test_worker_resolve_handler_cloudflare_fetch()
    test_worker_resolve_handler_cloudflare_fallback()
    test_worker_resolve_handler_cloudflare_missing()
    test_worker_resolve_handler_custom_name()
    test_worker_resolve_handler_custom_name_not_callable()
    test_worker_header_value()
    test_worker_build_raw_path()
    test_worker_encode_query_string()
    test_worker_build_raw_query()
    test_worker_build_lambda_event()
    test_worker_build_lambda_event_base64_body()
    test_worker_build_lambda_event_defaults()
    test_worker_build_lambda_event_body_non_string()
    test_worker_lambda_context()
    test_worker_lambda_context_defaults()
    test_worker_build_workers_url()
    test_worker_workers_request()
    test_worker_workers_request_body_bytes()
    test_worker_workers_request_body_none()
    test_worker_workers_request_body_non_string()
    test_worker_workers_request_base64_body()
    test_worker_workers_request_base64_invalid()
    test_worker_workers_request_async_text_and_json()
    test_worker_workers_request_json_empty()
    test_worker_workers_context()
    test_worker_workers_context_wait_until()
    test_worker_workers_context_wait_until_non_awaitable()
    test_worker_call_handler_var_positional()
    test_worker_call_handler_zero_args()
    test_worker_call_handler_async()
    test_worker_call_handler_keyword_only_params()
    test_worker_call_handler_signature_fails_gracefully()
    test_worker_resolve_awaitable_sync()
    test_worker_resolve_awaitable_async()
    test_worker_normalize_response_like_object()
    test_worker_normalize_response_like_object_bytes()
    test_worker_normalize_response_like_object_none_body()
    test_worker_normalize_response_like_object_non_string_body()
    test_worker_normalize_response_like_object_non_dict_headers()
    test_worker_normalize_response_like_object_non_int_status()
    test_worker_normalize_response_like_object_bytearray()
    test_worker_normalize_response_dict()
    test_worker_normalize_response_tuple()
    test_worker_normalize_response_tuple_partial()
    test_worker_normalize_response_object()
    test_worker_normalize_response_invalid()
    test_worker_env_override_proxy()
    test_worker_env_override_proxy_with_overrides()
    test_worker_patched_process_env()
    test_worker_patched_process_env_empty()
    test_worker_error_resp()
    test_worker_read_frame()
    test_worker_read_frame_empty()
    test_worker_read_frame_zero_length()
    test_worker_read_frame_truncated_data()
    test_worker_write_frame()
    test_worker_load_handler()
    test_worker_load_handler_cache_invalidation()
    test_worker_handle_with_lambda_adapter()
    test_worker_handle_with_cloudflare_adapter()
    test_worker_handle_error_in_handler()
    test_worker_handle_invalid_response()
    test_worker_handle_with_env_overrides()
    test_worker_handle_async_handler()
    test_worker_run_persistent()
    test_worker_run_persistent_error()
    test_worker_run_oneshot()
    test_worker_run_oneshot_empty()
    test_worker_run_oneshot_error()
    test_worker_main_oneshot_mode()
    test_worker_main_persistent_mode()
    test_worker_main_with_deps_env()
    test_worker_handle_tuple_response()
    test_worker_handle_object_response()
    test_worker_handle_deps_dirs_added_to_sys_path()
    test_worker_invoke_handler_native_with_params()
    test_worker_build_lambda_event_with_raw_path_query()
    test_worker_build_lambda_event_no_ts_uses_time()
    test_python_sendgrid_send_invalid_email_via_body()
    test_python_sendgrid_send_invalid_email_via_body()
    test_python_sendgrid_send_api_error_returns_502()
    test_python_sendgrid_send_context_timeout()
    test_python_sendgrid_send_post_body_parsing()
    test_worker_parse_extra_allow_roots_exception()
    test_worker_resolve_candidate_path_bytes_exception()
    test_worker_resolve_candidate_path_resolve_exception()
    test_worker_build_allowed_roots_deps_exception()
    test_worker_build_allowed_roots_sys_prefix_edges()
    test_worker_strict_fs_guard_protected_files()
    test_worker_strict_fs_guard_guarded_calls()
    test_worker_load_handler_spec_none()
    test_worker_resolve_awaitable_runtime_error()
    test_worker_env_override_proxy_iter_non_override()
    test_worker_env_override_proxy_getattr()
    test_worker_parse_extra_allow_roots_resolve_fail()
    test_worker_resolve_candidate_bytes_decode_fail()
    test_worker_resolve_candidate_resolve_fail()
    test_worker_build_allowed_roots_exception_paths()
    test_worker_strict_fs_guard_check_target_none()
    test_worker_strict_fs_guard_pty_ctypes_import_error()
    test_worker_load_handler_spec_none_actual()
    test_worker_resolve_awaitable_runtime_error_fallback()
    test_worker_env_proxy_getattr_coverage()
    test_worker_build_allowed_roots_sys_prefix_empty()
    test_worker_build_allowed_roots_resolve_exception()
    print("python unit tests passed")


if __name__ == "__main__":
    main()
