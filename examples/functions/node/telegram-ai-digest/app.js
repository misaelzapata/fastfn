// Telegram AI Digest — runs on a schedule (cron)
// Fetches recent messages from a Telegram group, summarizes them with OpenAI,
// and sends the digest back to the chat.

exports.handler = async (event) => {
  const env = event.env || {};
  const botToken = env.TELEGRAM_BOT_TOKEN;
  const chatId = env.TELEGRAM_CHAT_ID;
  const apiKey = env.OPENAI_API_KEY;

  if (!botToken || !chatId || !apiKey) {
    return respond(400, {
      error: "Missing required env: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, OPENAI_API_KEY",
    });
  }

  try {
    // 1. Fetch recent messages from the group
    const messages = await fetchRecentMessages(botToken);

    if (!messages.length) {
      return respond(200, { ok: true, skipped: true, reason: "No recent messages" });
    }

    // 2. Summarize with OpenAI
    const summary = await summarize(apiKey, messages);

    // 3. Send digest back to the chat
    const header = `Daily Digest (${new Date().toISOString().slice(0, 16)} UTC)`;
    const digest = `${header}\n\n${summary}`;
    await sendTelegram(botToken, chatId, digest);

    return respond(200, { ok: true, message_count: messages.length, digest });
  } catch (err) {
    return respond(502, { error: err.message || String(err) });
  }
};

// Fetch the latest messages using Telegram's getUpdates endpoint.
// Returns an array of text strings from the last 100 updates.
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

  // Extract text content, skip empty/media-only messages
  return (data.result || [])
    .map((u) => u.message?.text)
    .filter(Boolean);
}

// Ask OpenAI to produce a concise bullet-point summary of the messages.
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

// Send a text message to a Telegram chat.
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

// Build a JSON response.
function respond(status, body) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}
