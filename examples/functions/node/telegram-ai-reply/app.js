// @summary Telegram webhook -> OpenAI -> Telegram reply (AI bot)
// @methods POST
// @body {"message":{"chat":{"id":123},"text":"Hello"}}
//
// Receives a Telegram webhook update, sends the user's message to OpenAI,
// and replies in the same Telegram chat. Simple, self-contained example.

exports.handler = async (event) => {
  const env = event.env || {};

  // -- Read secrets and config from environment --
  const botToken = env.TELEGRAM_BOT_TOKEN;
  const openaiKey = env.OPENAI_API_KEY;
  const model = env.OPENAI_MODEL || "gpt-4o-mini";
  const systemPrompt =
    env.SYSTEM_PROMPT ||
    "You are a concise Telegram assistant. Reply in the same language as the user.";

  // -- Parse the incoming Telegram update --
  const update = typeof event.body === "string" ? JSON.parse(event.body) : event.body;
  const message = update?.message || update?.edited_message;
  const chatId = message?.chat?.id;
  const userText = message?.text;

  // Ignore updates without text (e.g. stickers, photos, join events)
  if (!chatId || !userText) {
    return respond(200, { ok: true, skipped: true, reason: "no text message" });
  }

  // Validate required secrets
  if (!botToken || !openaiKey) {
    return respond(400, {
      error: "Missing TELEGRAM_BOT_TOKEN or OPENAI_API_KEY in fn.env.json",
    });
  }

  try {
    // -- Step 1: Ask OpenAI for a reply --
    const aiReply = await askOpenAI({ openaiKey, model, systemPrompt, userText });

    // -- Step 2: Send the reply back to Telegram --
    const telegramResult = await sendTelegram({
      botToken,
      chatId,
      text: aiReply,
      replyToMessageId: message.message_id,
    });

    return respond(200, {
      ok: true,
      chat_id: chatId,
      reply: aiReply,
      message_id: telegramResult?.result?.message_id,
    });
  } catch (err) {
    console.error("telegram-ai-reply error:", err);
    return respond(502, { error: err.message });
  }
};

// ---------------------------------------------------------------------------
// OpenAI: send user text and get a completion
// ---------------------------------------------------------------------------
async function askOpenAI({ openaiKey, model, systemPrompt, userText }) {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${openaiKey}`,
    },
    body: JSON.stringify({
      model,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userText },
      ],
    }),
  });

  const data = await res.json();
  if (!res.ok) {
    throw new Error(`OpenAI error ${res.status}: ${JSON.stringify(data)}`);
  }

  const text = data.choices?.[0]?.message?.content;
  if (!text) throw new Error("OpenAI returned no text");
  return text.trim();
}

// ---------------------------------------------------------------------------
// Telegram: send a text message to a chat
// ---------------------------------------------------------------------------
async function sendTelegram({ botToken, chatId, text, replyToMessageId }) {
  const url = `https://api.telegram.org/bot${botToken}/sendMessage`;

  const body = { chat_id: chatId, text };
  if (replyToMessageId) body.reply_to_message_id = replyToMessageId;

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  const data = await res.json();
  if (!res.ok) {
    throw new Error(`Telegram error ${res.status}: ${JSON.stringify(data)}`);
  }
  return data;
}

// ---------------------------------------------------------------------------
// Helper: build a JSON response for FastFN
// ---------------------------------------------------------------------------
function respond(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
}
