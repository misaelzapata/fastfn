"""
Telegram AI Reply — FastFN example function.

Receives a Telegram webhook update, sends the user's message to OpenAI,
and replies in Telegram with the AI-generated response.

No external dependencies — uses only Python stdlib (urllib.request).
"""

import json
import urllib.request
import urllib.error


def handler(event):
    """FastFN entry point. Expects a Telegram webhook POST with a JSON body."""
    env = event.get("env") or {}
    body = event.get("body")

    # Parse the Telegram update from the webhook body
    update = _parse_body(body)
    chat_id, text = _extract_message(update)

    if chat_id is None or not text:
        return _response(200, {"ok": True, "note": "no chat message to process"})

    # Read secrets and config from environment
    bot_token = env.get("TELEGRAM_BOT_TOKEN", "")
    openai_key = env.get("OPENAI_API_KEY", "")
    model = env.get("OPENAI_MODEL", "gpt-4o-mini")
    system_prompt = env.get(
        "SYSTEM_PROMPT",
        "You are a concise Telegram assistant. Reply in the same language as the user.",
    )

    if not bot_token:
        return _response(500, {"error": "TELEGRAM_BOT_TOKEN not configured"})
    if not openai_key:
        return _response(500, {"error": "OPENAI_API_KEY not configured"})

    # Ask OpenAI for a reply
    try:
        reply = _openai_chat(openai_key, model, system_prompt, text)
    except Exception as err:
        return _response(502, {"error": f"OpenAI request failed: {err}"})

    # Send the reply back to Telegram
    try:
        _telegram_send(bot_token, chat_id, reply)
    except Exception as err:
        return _response(502, {"error": f"Telegram send failed: {err}"})

    return _response(200, {"ok": True, "chat_id": chat_id, "reply": reply})


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _parse_body(body):
    """Parse the webhook body into a dict."""
    if isinstance(body, dict):
        return body
    if isinstance(body, str):
        try:
            return json.loads(body)
        except (json.JSONDecodeError, ValueError):
            return {}
    return {}


def _extract_message(update):
    """Pull chat_id and text from a Telegram update dict."""
    msg = update.get("message") or update.get("edited_message") or {}
    chat = msg.get("chat") or {}
    chat_id = chat.get("id")
    text = (msg.get("text") or msg.get("caption") or "").strip()
    return chat_id, text


def _openai_chat(api_key, model, system_prompt, user_text):
    """Send a single-turn chat completion request to OpenAI and return the reply text."""
    url = "https://api.openai.com/v1/chat/completions"
    payload = json.dumps({
        "model": model,
        "temperature": 0.3,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_text},
        ],
    }).encode()

    req = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )

    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode())

    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError("OpenAI returned no choices")

    return choices[0]["message"]["content"].strip()


def _telegram_send(bot_token, chat_id, text):
    """Send a text message via the Telegram Bot API."""
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    payload = json.dumps({
        "chat_id": chat_id,
        "text": text[:4096],  # Telegram message limit
    }).encode()

    req = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/json"},
    )

    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())

    if not data.get("ok"):
        raise RuntimeError(f"Telegram API error: {data.get('description', 'unknown')}")

    return data


def _response(status, body):
    """Build a FastFN-compatible response dict."""
    return {
        "status": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
