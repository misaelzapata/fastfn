function parseJsonBody(raw) {
  if (!raw) return {};
  if (typeof raw === "object" && !Array.isArray(raw)) return raw;
  if (typeof raw !== "string") return {};
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch (_) {
    return {};
  }
}

function asBool(value, fallback = true) {
  if (value === undefined || value === null) return fallback;
  if (typeof value === "boolean") return value;
  const normalized = String(value).trim().toLowerCase();
  return !["0", "false", "off", "no"].includes(normalized);
}

function json(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
}

function isUnsetSecret(value) {
  if (value === undefined || value === null) return true;
  const s = String(value).trim();
  if (!s) return true;
  const l = s.toLowerCase();
  return l === "<set-me>" || l === "set-me" || l === "changeme" || l === "<changeme>" || l === "replace-me";
}

function chooseSecret(localValue, fallbackValue) {
  if (!isUnsetSecret(localValue)) return String(localValue).trim();
  if (!isUnsetSecret(fallbackValue)) return String(fallbackValue).trim();
  return "";
}

exports.handler = async (event) => {
  const query = event.query || {};
  const body = parseJsonBody(event.body);
  const env = event.env || {};

  const chatId = body.chat_id || body.chatId || query.chat_id || query.chatId;
  const text = body.text || query.text || "hello from fastfn";
  const dryRun = asBool(
    Object.prototype.hasOwnProperty.call(body, "dry_run") ? body.dry_run : query.dry_run,
    true
  );

  if (!chatId) {
    return json(400, { error: "chat_id is required" });
  }

  const token = chooseSecret(env.TELEGRAM_BOT_TOKEN, process.env.TELEGRAM_BOT_TOKEN);
  const apiBase = env.TELEGRAM_API_BASE || process.env.TELEGRAM_API_BASE || "https://api.telegram.org";
  const payload = {
    channel: "telegram",
    chat_id: String(chatId),
    text: String(text),
    dry_run: dryRun,
  };

  if (dryRun || !token) {
    if (!token) {
      payload.note = "TELEGRAM_BOT_TOKEN not configured; forced dry_run";
    }
    return json(200, payload);
  }

  try {
    const response = await fetch(`${apiBase}/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: String(chatId), text: String(text) }),
    });
    const raw = await response.text();
    let parsed = {};
    try {
      parsed = JSON.parse(raw);
    } catch (_) {
      parsed = { raw };
    }

    if (!response.ok || parsed.ok !== true) {
      return json(502, { error: "telegram send failed", status: response.status, telegram: parsed });
    }

    payload.sent = true;
    payload.telegram = {
      message_id: parsed.result && parsed.result.message_id,
    };
    return json(200, payload);
  } catch (err) {
    return json(502, { error: `telegram send failed: ${String(err && err.message ? err.message : err)}` });
  }
};
