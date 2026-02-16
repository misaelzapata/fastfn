import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from threading import Lock


BASE_DIR = Path(__file__).resolve().parent
FILE_LOCK = Lock()

DEFAULT_TELEGRAM_TIMEOUT_MS = 15000
DEFAULT_OPENAI_TIMEOUT_MS = 20000
DEFAULT_TOOL_TIMEOUT_MS = 5000
MAX_LOOP_WAIT_SECS = 120
MAX_LOOP_REPLIES = 50

DIRECTIVE_RE = re.compile(r"\[\[(fn|http):([^\]|]+)(?:\|([A-Za-z]+))?\]\]")


def _json_response(status, payload):
    return {
        "status": int(status),
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload, separators=(",", ":")),
    }


def _parse_json_object(raw):
    if isinstance(raw, dict):
        return raw
    if not isinstance(raw, str) or not raw.strip():
        return {}
    try:
        parsed = json.loads(raw)
    except Exception:
        return {}
    return parsed if isinstance(parsed, dict) else {}


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


def _clean_text(value, default=""):
    text = str(value or "").strip()
    if not text:
        return default
    return re.sub(r"\s+", " ", text)


def _pick_secret(primary, fallback):
    if primary is not None and str(primary).strip() != "":
        return str(primary).strip()
    if fallback is not None and str(fallback).strip() != "":
        return str(fallback).strip()
    return ""


def _memory_path(env):
    return Path(
        env.get("FASTFN_TELEGRAM_PY_MEMORY")
        or os.environ.get("FASTFN_TELEGRAM_PY_MEMORY")
        or (BASE_DIR / ".memory.json")
    )


def _loop_state_path(env):
    return Path(
        env.get("FASTFN_TELEGRAM_PY_LOOP_STATE")
        or os.environ.get("FASTFN_TELEGRAM_PY_LOOP_STATE")
        or (BASE_DIR / ".loop_state.json")
    )


def _loop_lock_path(env):
    return Path(
        env.get("FASTFN_TELEGRAM_PY_LOOP_LOCK")
        or os.environ.get("FASTFN_TELEGRAM_PY_LOOP_LOCK")
        or (BASE_DIR / ".loop.lock")
    )


def _read_json_file(path, default):
    with FILE_LOCK:
        try:
            raw = path.read_text(encoding="utf-8")
        except Exception:
            return default
    try:
        parsed = json.loads(raw)
    except Exception:
        return default
    return parsed


def _write_json_file(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    blob = json.dumps(payload, separators=(",", ":"), ensure_ascii=True)
    with FILE_LOCK:
        path.write_text(blob, encoding="utf-8")


def _http_request_json(url, method="GET", headers=None, body=None, timeout_ms=8000):
    req_headers = dict(headers or {})
    data = None
    if body is not None:
        if isinstance(body, (dict, list)):
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            req_headers.setdefault("Content-Type", "application/json")
        elif isinstance(body, str):
            data = body.encode("utf-8")
        else:
            data = str(body).encode("utf-8")
    timeout_s = max(0.2, float(timeout_ms) / 1000.0)
    req = urllib.request.Request(url=url, method=method, data=data, headers=req_headers)
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            status = int(getattr(resp, "status", 200))
            try:
                parsed = json.loads(raw)
            except Exception:
                parsed = {"raw": raw[:4000]}
            return {
                "ok": 200 <= status < 300,
                "status": status,
                "elapsed_ms": int((time.time() - started) * 1000),
                "data": parsed,
                "raw": raw,
            }
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"raw": raw[:4000]}
        return {
            "ok": False,
            "status": int(getattr(err, "code", 500)),
            "elapsed_ms": int((time.time() - started) * 1000),
            "error": f"http_error:{getattr(err, 'code', 'unknown')}",
            "data": parsed,
            "raw": raw,
        }
    except Exception as err:
        return {
            "ok": False,
            "status": 0,
            "elapsed_ms": int((time.time() - started) * 1000),
            "error": str(err),
            "data": {},
            "raw": "",
        }


def _telegram_timeout_ms(env):
    return _as_int(
        env.get("TELEGRAM_HTTP_TIMEOUT_MS")
        or os.environ.get("TELEGRAM_HTTP_TIMEOUT_MS")
        or DEFAULT_TELEGRAM_TIMEOUT_MS,
        DEFAULT_TELEGRAM_TIMEOUT_MS,
        1000,
        60000,
    )


def _telegram_api_base(env):
    return _clean_text(
        env.get("TELEGRAM_API_BASE") or os.environ.get("TELEGRAM_API_BASE") or "https://api.telegram.org"
    ).rstrip("/")


def _telegram_token(env):
    return _pick_secret(env.get("TELEGRAM_BOT_TOKEN"), os.environ.get("TELEGRAM_BOT_TOKEN"))


def _telegram_send(env, chat_id, text, reply_to_message_id=None):
    token = _telegram_token(env)
    if not token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN not configured")
    payload = {"chat_id": str(chat_id), "text": str(text)[:3500]}
    if reply_to_message_id:
        payload["reply_to_message_id"] = int(reply_to_message_id)
    url = f"{_telegram_api_base(env)}/bot{token}/sendMessage"
    out = _http_request_json(
        url=url,
        method="POST",
        body=payload,
        timeout_ms=_telegram_timeout_ms(env),
    )
    if not out.get("ok") or not isinstance(out.get("data"), dict) or out["data"].get("ok") is not True:
        raise RuntimeError(f"telegram send failed status={out.get('status')} body={out.get('raw')}")
    return out["data"]


def _telegram_get_updates(env, offset=None):
    token = _telegram_token(env)
    if not token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN not configured")
    params = {"timeout": "3"}
    if offset is not None:
        params["offset"] = str(int(offset))
    url = f"{_telegram_api_base(env)}/bot{token}/getUpdates?{urllib.parse.urlencode(params)}"
    out = _http_request_json(url=url, method="GET", timeout_ms=_telegram_timeout_ms(env))
    if not out.get("ok"):
        err = RuntimeError(f"telegram getUpdates failed status={out.get('status')}")
        err.code = int(out.get("status") or 0)
        raise err
    data = out.get("data")
    if not isinstance(data, dict) or data.get("ok") is not True:
        raise RuntimeError(f"telegram getUpdates failed body={out.get('raw')}")
    return data


def _telegram_delete_webhook(env):
    token = _telegram_token(env)
    if not token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN not configured")
    url = f"{_telegram_api_base(env)}/bot{token}/deleteWebhook"
    out = _http_request_json(url=url, method="POST", timeout_ms=_telegram_timeout_ms(env))
    if not out.get("ok"):
        raise RuntimeError(f"telegram deleteWebhook failed status={out.get('status')}")
    return out.get("data") or {}


def _parse_csv(value):
    raw = str(value or "").strip()
    if not raw:
        return []
    return [part.strip() for part in raw.split(",") if part.strip()]


def _host_allowed(url, allow_hosts):
    try:
        host = (urllib.parse.urlparse(url).hostname or "").lower()
    except Exception:
        return False
    if not host:
        return False
    for item in allow_hosts:
        allowed = item.lower()
        if host == allowed or host.endswith("." + allowed):
            return True
    return False


def _extract_tool_directives(text):
    calls = []
    for kind, target, method in DIRECTIVE_RE.findall(str(text or "")):
        calls.append(
            {
                "kind": kind.lower(),
                "target": str(target or "").strip(),
                "method": str(method or "GET").upper(),
                "auto": False,
            }
        )
    return calls


def _auto_tool_calls(text, query):
    lower = str(text or "").lower()
    calls = []
    if any(token in lower for token in ("mi ip", "my ip", "public ip", "ip publica")):
        calls.append({"kind": "http", "target": "https://api.ipify.org?format=json", "method": "GET", "auto": True})
    if any(token in lower for token in ("weather", "clima", "temperatura")):
        city = _clean_text(query.get("city"), "")
        city_path = urllib.parse.quote(city) if city else ""
        calls.append(
            {
                "kind": "http",
                "target": f"https://wttr.in/{city_path}?format=j1" if city_path else "https://wttr.in/?format=j1",
                "method": "GET",
                "auto": True,
            }
        )
    return calls


def _call_internal_function(base_url, target, method, timeout_ms):
    route = str(target or "").strip()
    if not route:
        return {"ok": False, "status": 0, "error": "empty fn target", "data": {}}
    if route.startswith("http://") or route.startswith("https://"):
        url = route
    elif route.startswith("/"):
        url = base_url.rstrip("/") + route
    elif route.startswith("fn/"):
        url = base_url.rstrip("/") + "/" + route
    else:
        url = base_url.rstrip("/") + "/fn/" + route
    return _http_request_json(url=url, method=method, timeout_ms=timeout_ms)


def _resolve_tools(text, env, query):
    tools_enabled = _as_bool(
        query.get("tools"),
        _as_bool(env.get("TELEGRAM_TOOLS_ENABLED") or os.environ.get("TELEGRAM_TOOLS_ENABLED"), False),
    )
    auto_enabled = _as_bool(
        query.get("auto_tools"),
        _as_bool(env.get("TELEGRAM_AUTO_TOOLS") or os.environ.get("TELEGRAM_AUTO_TOOLS"), False),
    )
    if not tools_enabled:
        return {"enabled": False, "plan": [], "results": [], "summary_text": ""}

    allow_fn = set(
        _parse_csv(
            query.get("tool_allow_fn")
            or env.get("TELEGRAM_TOOL_ALLOW_FN")
            or os.environ.get("TELEGRAM_TOOL_ALLOW_FN")
            or "request_inspector"
        )
    )
    allow_hosts = _parse_csv(
        query.get("tool_allow_hosts")
        or env.get("TELEGRAM_TOOL_ALLOW_HTTP_HOSTS")
        or os.environ.get("TELEGRAM_TOOL_ALLOW_HTTP_HOSTS")
        or "api.ipify.org,wttr.in,ipapi.co"
    )
    timeout_ms = _as_int(
        query.get("tool_timeout_ms")
        or env.get("TELEGRAM_TOOL_TIMEOUT_MS")
        or os.environ.get("TELEGRAM_TOOL_TIMEOUT_MS")
        or DEFAULT_TOOL_TIMEOUT_MS,
        DEFAULT_TOOL_TIMEOUT_MS,
        250,
        30000,
    )
    base_url = _clean_text(
        query.get("tool_internal_base_url")
        or env.get("TELEGRAM_TOOL_INTERNAL_BASE_URL")
        or os.environ.get("TELEGRAM_TOOL_INTERNAL_BASE_URL")
        or "http://127.0.0.1:8080"
    )

    plan = _extract_tool_directives(text)
    if auto_enabled:
        plan.extend(_auto_tool_calls(text, query))

    results = []
    for item in plan[:6]:
        kind = item.get("kind")
        target = item.get("target")
        method = item.get("method", "GET")
        row = {
            "kind": kind,
            "target": target,
            "method": method,
            "auto": item.get("auto") is True,
            "ok": False,
            "status": 0,
            "error": None,
            "data": {},
        }
        if kind == "fn":
            fn_name = str(target).split("?", 1)[0].strip().lstrip("/")
            fn_name = fn_name[3:] if fn_name.startswith("fn/") else fn_name
            if fn_name not in allow_fn:
                row["error"] = "fn_not_allowed"
                results.append(row)
                continue
            out = _call_internal_function(base_url, target, method, timeout_ms)
        elif kind == "http":
            if not _host_allowed(str(target), allow_hosts):
                row["error"] = "http_host_not_allowed"
                results.append(row)
                continue
            out = _http_request_json(url=str(target), method=method, timeout_ms=timeout_ms)
        else:
            row["error"] = "invalid_tool_kind"
            results.append(row)
            continue

        row["ok"] = bool(out.get("ok"))
        row["status"] = int(out.get("status") or 0)
        row["error"] = out.get("error")
        data = out.get("data")
        row["data"] = data if isinstance(data, (dict, list)) else {"value": str(data)}
        results.append(row)

    snippets = []
    for item in results:
        prefix = f"{item['kind']}:{item['target']} status={item['status']} ok={str(item['ok']).lower()}"
        blob = json.dumps(item.get("data") or {}, separators=(",", ":"))[:600]
        snippets.append(f"{prefix} data={blob}")
    summary_text = "\n".join(snippets)[:4000]
    return {"enabled": True, "plan": plan, "results": results, "summary_text": summary_text}


def _memory_config(env, query):
    return {
        "enabled": _as_bool(query.get("memory"), True),
        "max_turns": _as_int(
            query.get("memory_max_turns")
            or env.get("TELEGRAM_MEMORY_MAX_TURNS")
            or os.environ.get("TELEGRAM_MEMORY_MAX_TURNS")
            or 24,
            24,
            2,
            120,
        ),
        "ttl_secs": _as_int(
            query.get("memory_ttl_secs")
            or env.get("TELEGRAM_MEMORY_TTL_SECS")
            or os.environ.get("TELEGRAM_MEMORY_TTL_SECS")
            or 86400,
            86400,
            60,
            1209600,
        ),
    }


def _load_memory(env, chat_id, cfg):
    if not cfg.get("enabled"):
        return []
    data = _read_json_file(_memory_path(env), {})
    rows = data.get(str(chat_id), [])
    if not isinstance(rows, list):
        return []
    now_ms = int(time.time() * 1000)
    ttl_ms = int(cfg["ttl_secs"]) * 1000
    filtered = []
    for item in rows:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role") or "")
        text = str(item.get("text") or "")
        ts = int(item.get("ts") or 0)
        if role not in {"user", "assistant"} or not text:
            continue
        if ts > 0 and (now_ms - ts) > ttl_ms:
            continue
        filtered.append({"role": role, "text": text, "ts": ts or now_ms})
    limit = int(cfg["max_turns"]) * 2
    return filtered[-limit:]


def _save_memory(env, chat_id, cfg, history):
    if not cfg.get("enabled"):
        return
    path = _memory_path(env)
    data = _read_json_file(path, {})
    if not isinstance(data, dict):
        data = {}
    limit = int(cfg["max_turns"]) * 2
    data[str(chat_id)] = list(history)[-limit:]
    _write_json_file(path, data)


def _extract_telegram_update(update):
    if not isinstance(update, dict):
        return {"chat_id": None, "text": "", "message_id": None}
    msg = update.get("message") or update.get("edited_message") or {}
    if not isinstance(msg, dict):
        return {"chat_id": None, "text": "", "message_id": None}
    chat = msg.get("chat") or {}
    chat_id = chat.get("id") if isinstance(chat, dict) else None
    text = msg.get("text") or msg.get("caption") or ""
    return {"chat_id": chat_id, "text": str(text or ""), "message_id": msg.get("message_id")}


def _load_loop_state(env):
    data = _read_json_file(_loop_state_path(env), {})
    if not isinstance(data, dict):
        return -1
    try:
        return int(data.get("last_update_id", -1))
    except Exception:
        return -1


def _save_loop_state(env, last_update_id):
    _write_json_file(_loop_state_path(env), {"last_update_id": int(last_update_id)})


def _try_acquire_loop_lock(env, ttl_secs):
    path = _loop_lock_path(env)
    now = time.time()
    with FILE_LOCK:
        try:
            if path.exists():
                age = max(0.0, now - path.stat().st_mtime)
                if age < ttl_secs:
                    return None
        except Exception:
            return None
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(str(now), encoding="utf-8")
        except Exception:
            return None
    return path


def _release_loop_lock(path):
    if path is None:
        return
    with FILE_LOCK:
        try:
            path.unlink()
        except Exception:
            return


def _openai_generate_reply(env, user_text, history, tool_summary, timeout_ms):
    api_key = _pick_secret(env.get("OPENAI_API_KEY"), os.environ.get("OPENAI_API_KEY"))
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY not configured")
    model = _clean_text(env.get("OPENAI_MODEL") or os.environ.get("OPENAI_MODEL") or "gpt-4o-mini")
    base = _clean_text(env.get("OPENAI_BASE_URL") or os.environ.get("OPENAI_BASE_URL") or "https://api.openai.com/v1").rstrip("/")
    system_prompt = _clean_text(
        env.get("OPENAI_SYSTEM_PROMPT")
        or os.environ.get("OPENAI_SYSTEM_PROMPT")
        or "You are a concise Telegram assistant. Reply in the same language as the user."
    )

    messages = [{"role": "system", "content": system_prompt}]
    for item in history[-24:]:
        role = str(item.get("role") or "")
        text = str(item.get("text") or "")
        if role in {"user", "assistant"} and text:
            messages.append({"role": role, "content": text})

    content = str(user_text or "")
    if tool_summary:
        content += "\n\nTool context:\n" + str(tool_summary)
    messages.append({"role": "user", "content": content})

    payload = {
        "model": model,
        "messages": messages,
        "temperature": 0.3,
    }
    out = _http_request_json(
        url=base + "/chat/completions",
        method="POST",
        headers={"Authorization": "Bearer " + api_key},
        body=payload,
        timeout_ms=timeout_ms,
    )
    if not out.get("ok"):
        raise RuntimeError(f"openai error status={out.get('status')} body={out.get('raw')}")

    data = out.get("data") or {}
    choices = data.get("choices") if isinstance(data, dict) else None
    if not isinstance(choices, list) or not choices:
        raise RuntimeError("openai empty choices")
    msg = choices[0].get("message") if isinstance(choices[0], dict) else {}
    content_obj = msg.get("content") if isinstance(msg, dict) else ""
    if isinstance(content_obj, str):
        reply = content_obj.strip()
    elif isinstance(content_obj, list):
        chunks = []
        for part in content_obj:
            if isinstance(part, dict) and part.get("type") == "text":
                chunks.append(str(part.get("text") or ""))
        reply = "\n".join(chunks).strip()
    else:
        reply = ""
    if not reply:
        raise RuntimeError("openai returned empty text")
    return reply[:3000]


def _generate_reply_and_send(env, query, chat_id, text, message_id):
    mem_cfg = _memory_config(env, query)
    history = _load_memory(env, chat_id, mem_cfg)
    tools = _resolve_tools(text, env, query)
    openai_timeout = _as_int(
        query.get("openai_timeout_ms")
        or env.get("OPENAI_TIMEOUT_MS")
        or os.environ.get("OPENAI_TIMEOUT_MS")
        or DEFAULT_OPENAI_TIMEOUT_MS,
        DEFAULT_OPENAI_TIMEOUT_MS,
        1000,
        90000,
    )
    reply = _openai_generate_reply(
        env=env,
        user_text=text,
        history=history,
        tool_summary=tools.get("summary_text", ""),
        timeout_ms=openai_timeout,
    )
    sent = _telegram_send(env, chat_id, reply, message_id)
    now_ms = int(time.time() * 1000)
    if mem_cfg.get("enabled"):
        history.append({"role": "user", "text": str(text), "ts": now_ms})
        history.append({"role": "assistant", "text": str(reply), "ts": now_ms})
        _save_memory(env, chat_id, mem_cfg, history)
    return reply, sent, tools


def _handle_loop(event, env, query, is_scheduled):
    loop_enabled = _as_bool(env.get("TELEGRAM_LOOP_ENABLED") or os.environ.get("TELEGRAM_LOOP_ENABLED"), False)
    if not loop_enabled:
        return _json_response(403, {"error": "loop mode disabled"})

    loop_token = _pick_secret(env.get("TELEGRAM_LOOP_TOKEN"), os.environ.get("TELEGRAM_LOOP_TOKEN"))
    if loop_token and not is_scheduled:
        provided = _clean_text(query.get("loop_token") or query.get("loopToken"), "")
        if provided != loop_token:
            return _json_response(403, {"error": "invalid loop token"})

    dry_run = _as_bool(query.get("dry_run"), True)
    chat_id = query.get("chat_id") or query.get("chatId") or env.get("TELEGRAM_CHAT_ID") or os.environ.get("TELEGRAM_CHAT_ID")
    all_chats_mode = chat_id is None or str(chat_id).strip() == ""
    prompt = _clean_text(query.get("prompt") or query.get("text"), "fastfn loop demo")
    send_prompt_default = _as_bool(
        env.get("TELEGRAM_LOOP_SEND_PROMPT_ON_SCHEDULE") or os.environ.get("TELEGRAM_LOOP_SEND_PROMPT_ON_SCHEDULE"),
        False,
    )
    send_prompt = _as_bool(query.get("send_prompt"), send_prompt_default if is_scheduled else True)
    wait_secs = _as_int(query.get("wait_secs") or query.get("wait_s") or 60, 60, 5, MAX_LOOP_WAIT_SECS)
    poll_ms = _as_int(query.get("poll_ms") or 2000, 2000, 300, 5000)
    max_replies = _as_int(query.get("max_replies") or 5, 5, 1, MAX_LOOP_REPLIES)
    force_clear_webhook = _as_bool(query.get("force_clear_webhook"), False)

    if dry_run:
        return _json_response(
            200,
            {
                "ok": True,
                "dry_run": True,
                "mode": "loop",
                "chat_id": None if all_chats_mode else int(chat_id),
                "all_chats_mode": all_chats_mode,
                "send_prompt": send_prompt,
                "prompt": prompt,
                "wait_secs": wait_secs,
                "max_replies": max_replies,
            },
        )

    lock = _try_acquire_loop_lock(env, ttl_secs=wait_secs + 45)
    if lock is None:
        return _json_response(
            200 if is_scheduled else 409,
            {"ok": is_scheduled, "skipped": True, "reason": "in_progress", "mode": "loop"},
        )

    try:
        if force_clear_webhook:
            _telegram_delete_webhook(env)

        if not all_chats_mode and send_prompt and prompt:
            _telegram_send(env, chat_id, prompt)

        last_id = _load_loop_state(env)
        if last_id < 0:
            seed = _telegram_get_updates(env)
            seed_items = seed.get("result") if isinstance(seed, dict) else []
            if isinstance(seed_items, list) and seed_items:
                tail = seed_items[-1]
                if isinstance(tail, dict) and isinstance(tail.get("update_id"), int):
                    last_id = int(tail["update_id"])
                    _save_loop_state(env, last_id)

        started = time.time()
        replies_sent = 0
        while (time.time() - started) < wait_secs:
            try:
                updates = _telegram_get_updates(env, offset=(last_id + 1) if last_id >= 0 else None)
            except Exception as err:
                code = int(getattr(err, "code", 0))
                if code == 409:
                    return _json_response(
                        200 if is_scheduled else 409,
                        {
                            "ok": is_scheduled,
                            "skipped": is_scheduled,
                            "error": "getUpdates conflict (another poller/webhook is active)",
                        },
                    )
                time.sleep(min(5.0, poll_ms / 1000.0))
                continue

            result_items = updates.get("result") if isinstance(updates, dict) else []
            if not isinstance(result_items, list):
                result_items = []
            for item in result_items:
                if not isinstance(item, dict):
                    continue
                upd_id = item.get("update_id")
                if isinstance(upd_id, int):
                    last_id = upd_id
                msg = item.get("message") or item.get("edited_message") or {}
                if isinstance(msg, dict):
                    from_user = msg.get("from") or {}
                    if isinstance(from_user, dict) and from_user.get("is_bot") is True:
                        continue
                t = _extract_telegram_update(item)
                incoming_chat = t.get("chat_id")
                incoming_text = _clean_text(t.get("text"), "")
                if incoming_chat is None or not incoming_text:
                    continue
                if (not all_chats_mode) and (str(incoming_chat) != str(chat_id)):
                    continue

                try:
                    _generate_reply_and_send(env, query, incoming_chat, incoming_text, t.get("message_id"))
                    replies_sent += 1
                except Exception:
                    continue
                _save_loop_state(env, last_id)
                if replies_sent >= max_replies:
                    return _json_response(
                        200,
                        {
                            "ok": True,
                            "mode": "loop",
                            "chat_id": None if all_chats_mode else int(chat_id),
                            "all_chats_mode": all_chats_mode,
                            "replies_sent": replies_sent,
                        },
                    )
            time.sleep(float(poll_ms) / 1000.0)

        _save_loop_state(env, last_id)
        return _json_response(
            200 if is_scheduled else 504,
            {
                "ok": is_scheduled,
                "skipped": is_scheduled,
                "mode": "loop",
                "error": "timeout waiting for messages",
                "chat_id": None if all_chats_mode else int(chat_id),
                "all_chats_mode": all_chats_mode,
                "replies_sent": replies_sent,
            },
        )
    finally:
        _release_loop_lock(lock)


def handler(event):
    env = event.get("env") or {}
    query = event.get("query") or {}
    context = event.get("context") or {}

    mode = _clean_text(query.get("mode") or query.get("action"), "").lower()
    wants_loop = mode == "loop" or _as_bool(query.get("loop"), False)
    is_scheduled = ((context.get("trigger") or {}).get("type") == "schedule")

    if wants_loop:
        return _handle_loop(event, env, query, is_scheduled)

    dry_run = _as_bool(query.get("dry_run"), True)
    update = _parse_json_object(event.get("body"))
    telegram_update = _extract_telegram_update(update)
    chat_id = query.get("chat_id") or query.get("chatId") or telegram_update.get("chat_id")
    text = _clean_text(query.get("text") or telegram_update.get("text"), "")
    message_id = telegram_update.get("message_id")

    if chat_id is None or str(chat_id).strip() == "":
        return _json_response(200, {"ok": True, "note": "no chat_id provided; nothing to do"})
    if not text:
        return _json_response(200, {"ok": True, "chat_id": int(chat_id), "note": "no text provided; nothing to do"})

    if dry_run:
        tools = _resolve_tools(text, env, query)
        return _json_response(
            200,
            {
                "ok": True,
                "dry_run": True,
                "mode": "reply",
                "chat_id": int(chat_id),
                "received_text": text,
                "tools": {
                    "enabled": tools.get("enabled"),
                    "plan_count": len(tools.get("plan") or []),
                },
                "note": "Set dry_run=false and configure TELEGRAM_BOT_TOKEN + OPENAI_API_KEY to send real replies.",
            },
        )

    try:
        reply, sent, tools = _generate_reply_and_send(env, query, chat_id, text, message_id)
    except Exception as err:
        return _json_response(502, {"error": str(err), "mode": "reply"})

    return _json_response(
        200,
        {
            "ok": True,
            "dry_run": False,
            "mode": "reply",
            "chat_id": int(chat_id),
            "reply_preview": reply,
            "telegram": {"message_id": ((sent or {}).get("result") or {}).get("message_id")},
            "tools": {
                "enabled": bool((tools or {}).get("enabled")),
                "executed": len((tools or {}).get("results") or []),
                "successful": sum(1 for row in ((tools or {}).get("results") or []) if row.get("ok")),
            },
        },
    )
