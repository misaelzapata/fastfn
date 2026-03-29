function isUnsetConfigValue(value) {
  if (value === undefined || value === null) return true;
  const s = String(value).trim();
  if (!s) return true;
  const l = s.toLowerCase();
  return l === "<set-me>" || l === "set-me" || l === "changeme" || l === "<changeme>" || l === "replace-me";
}

function chooseConfigValue(localValue, fallbackValue) {
  if (!isUnsetConfigValue(localValue)) return String(localValue).trim();
  if (!isUnsetConfigValue(fallbackValue)) return String(fallbackValue).trim();
  return "";
}

async function fetchRecentMessages(token) {
  const res = await fetch(
    `https://api.telegram.org/bot${token}/getUpdates?limit=100&allowed_updates=["message"]`
  );
  if (!res.ok) {
    throw new Error(`Telegram getUpdates failed: ${res.status}`);
  }
  const data = await res.json();
  if (!data.ok) {
    throw new Error(`Telegram API error: ${JSON.stringify(data)}`);
  }

  return (data.result || [])
    .map((u) => u.message?.text)
    .filter(Boolean);
}

async function summarize(apiKey, messages) {
  const joined = messages.map((m, i) => `${i + 1}. ${m}`).join("\n");

  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [
        {
          role: "system",
          content:
            "Summarize the following chat messages into a short bullet-point digest. " +
            "Highlight key topics and action items. Be concise.",
        },
        { role: "user", content: joined },
      ],
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`OpenAI API error ${res.status}: ${body}`);
  }

  const data = await res.json();
  return data.choices?.[0]?.message?.content || "No summary generated.";
}

async function sendTelegram(token, chatId, text) {
  const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Telegram sendMessage error ${res.status}: ${body}`);
  }
}

function respond(status, body) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

exports.handler = async (event) => {
  const env = event.env || {};
  const botToken = chooseConfigValue(env.TELEGRAM_BOT_TOKEN, process.env.TELEGRAM_BOT_TOKEN);
  const chatId = chooseConfigValue(env.TELEGRAM_CHAT_ID, process.env.TELEGRAM_CHAT_ID);
  const apiKey = chooseConfigValue(env.OPENAI_API_KEY, process.env.OPENAI_API_KEY);

  const missingEnv = [];
  if (!botToken) missingEnv.push("TELEGRAM_BOT_TOKEN");
  if (!chatId) missingEnv.push("TELEGRAM_CHAT_ID");
  if (!apiKey) missingEnv.push("OPENAI_API_KEY");

  if (missingEnv.length) {
    return respond(200, {
      ok: true,
      skipped: true,
      missing_env: missingEnv,
      note: "Configure TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, and OPENAI_API_KEY to enable live digests.",
    });
  }

  try {
    const messages = await fetchRecentMessages(botToken);

    if (!messages.length) {
      return respond(200, { ok: true, skipped: true, reason: "No recent messages" });
    }

    const summary = await summarize(apiKey, messages);
    const header = `Daily Digest (${new Date().toISOString().slice(0, 16)} UTC)`;
    const digest = `${header}\n\n${summary}`;
    await sendTelegram(botToken, chatId, digest);

    return respond(200, { ok: true, message_count: messages.length, digest });
  } catch (err) {
    return respond(502, { error: err.message || String(err) });
  }
};
