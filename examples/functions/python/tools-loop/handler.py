import json
import time
import urllib.parse
import urllib.request


DEFAULT_TIMEOUT_MS = 5000
MAX_RESPONSE_BYTES = 1024 * 1024


def _json_response(status, payload):
    return {
        "status": int(status),
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload, separators=(",", ":"), ensure_ascii=True),
    }


def _as_bool(value, default=False):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    if text in {"1", "true", "yes", "on"}:
        return True
    if text in {"0", "false", "no", "off"}:
        return False
    return default


def _as_int(value, default, minimum, maximum):
    try:
        out = int(value)
    except Exception:
        return default
    if out < minimum:
        return minimum
    if out > maximum:
        return maximum
    return out


def _parse_csv(value):
    raw = str(value or "").strip()
    if not raw:
        return []
    return [part.strip() for part in raw.split(",") if part.strip()]


def _parse_body_object(event):
    body = event.get("body")
    if isinstance(body, dict):
        return body
    if not isinstance(body, str) or not body.strip():
        return {}
    try:
        parsed = json.loads(body)
    except Exception:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _http_json(url, timeout_ms):
    started = time.time()
    req = urllib.request.Request(url=url, method="GET")
    timeout_s = max(0.2, float(timeout_ms) / 1000.0)
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            status = int(getattr(resp, "status", 200))
            raw_bytes = resp.read(MAX_RESPONSE_BYTES + 1)
            truncated = len(raw_bytes) > MAX_RESPONSE_BYTES
            if truncated:
                raw_bytes = raw_bytes[:MAX_RESPONSE_BYTES]
            raw = raw_bytes.decode("utf-8", errors="replace")
            try:
                data = json.loads(raw)
            except Exception:
                data = {"raw": raw[:4000]}
            return {
                "ok": 200 <= status < 300,
                "status": status,
                "elapsed_ms": int((time.time() - started) * 1000),
                "url": url,
                "truncated": truncated,
                "data": data,
            }
    except Exception as err:
        return {
            "ok": False,
            "status": 0,
            "elapsed_ms": int((time.time() - started) * 1000),
            "url": url,
            "error": str(err),
            "data": {},
        }


def _plan_from_text(text, city):
    lower = str(text or "").lower()
    plan = []
    if any(token in lower for token in ("my ip", "mi ip", "ip publica", "public ip", "ip")):
        plan.append({"tool": "ip_lookup"})
    if any(token in lower for token in ("weather", "clima", "temperatura")):
        plan.append({"tool": "weather", "city": city})
    if not plan:
        plan.append({"tool": "help"})
    return plan


def _tool_to_url(step):
    tool = step.get("tool")
    if tool == "ip_lookup":
        return "https://api.ipify.org?format=json"
    if tool == "weather":
        city = str(step.get("city") or "").strip()
        if city:
            return f"https://wttr.in/{urllib.parse.quote(city)}?format=j1"
        return "https://wttr.in/?format=j1"
    return ""

def _mock_tool_result(tool, url, city):
    if tool == "ip_lookup":
        return {
            "tool": tool,
            "ok": True,
            "status": 200,
            "elapsed_ms": 0,
            "url": url,
            "mock": True,
            "data": {"ip": "203.0.113.10"},
        }
    if tool == "weather":
        return {
            "tool": tool,
            "ok": True,
            "status": 200,
            "elapsed_ms": 0,
            "url": url,
            "mock": True,
            "data": {"city": city or "Mock City", "temp_c": 21, "description": "Clear"},
        }
    return {"tool": tool, "ok": False, "status": 0, "mock": True, "error": "unknown_tool", "data": {}}


def handler(event):
    query = event.get("query") or {}
    body_obj = _parse_body_object(event)

    text = query.get("text")
    if text is None:
        text = body_obj.get("text")
    city = str(query.get("city") or body_obj.get("city") or "").strip()

    dry_run = _as_bool(query.get("dry_run", body_obj.get("dry_run")), True)
    mock = _as_bool(query.get("mock", body_obj.get("mock")), False)
    timeout_ms = _as_int(query.get("tool_timeout_ms", body_obj.get("tool_timeout_ms")), DEFAULT_TIMEOUT_MS, 250, 30000)

    explicit_tools = _parse_csv(query.get("tool", body_obj.get("tool")))
    plan = []
    if explicit_tools:
        for name in explicit_tools[:8]:
            tool = name.strip().lower()
            if tool in {"ip_lookup", "weather"}:
                step = {"tool": tool}
                if tool == "weather":
                    step["city"] = city
                plan.append(step)
            else:
                plan.append({"tool": "unknown", "name": name})
    else:
        plan = _plan_from_text(text, city)

    results = []
    executed = 0
    for step in plan:
        tool = step.get("tool")
        if tool == "help":
            results.append(
                {
                    "tool": "help",
                    "ok": True,
                    "status": 200,
                    "data": {
                        "message": "Provide text=... or tool=ip_lookup,weather. Use dry_run=false to execute.",
                        "examples": [
                            "/tools-loop?text=quiero%20mi%20ip%20y%20clima&dry_run=true",
                            "/tools-loop?tool=ip_lookup,weather&city=Buenos%20Aires&dry_run=false",
                            "/tools-loop?tool=ip_lookup,weather&city=Buenos%20Aires&dry_run=false&mock=true",
                        ],
                    },
                }
            )
            continue

        url = _tool_to_url(step)
        if not url:
            results.append({"tool": tool, "ok": False, "status": 0, "error": "unknown_tool", "data": {}})
            continue

        if dry_run:
            results.append({"tool": tool, "ok": True, "status": 200, "dry_run": True, "url": url, "data": {}})
            continue

        executed += 1
        if mock:
            results.append(_mock_tool_result(tool, url, city))
        else:
            out = _http_json(url, timeout_ms=timeout_ms)
            results.append({"tool": tool, **out})

    summary = {
        "tools": [step.get("tool") for step in plan],
        "executed": executed,
        "ok": all(bool(r.get("ok")) for r in results) if results else True,
    }

    return _json_response(
        200,
        {
            "ok": True,
            "dry_run": dry_run,
            "mock": mock,
            "input": {"text": str(text or ""), "city": city, "tool": explicit_tools},
            "plan": plan,
            "results": results,
            "summary": summary,
        },
    )
