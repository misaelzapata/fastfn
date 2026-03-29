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

function resolveTelegramConfig(localEnv = {}, processEnv = process.env) {
  return {
    botToken: chooseConfigValue(localEnv.TELEGRAM_BOT_TOKEN, processEnv.TELEGRAM_BOT_TOKEN),
    openaiKey: chooseConfigValue(localEnv.OPENAI_API_KEY, processEnv.OPENAI_API_KEY),
    model: localEnv.OPENAI_MODEL || processEnv.OPENAI_MODEL || "gpt-4o-mini",
    systemPrompt:
      localEnv.SYSTEM_PROMPT ||
      processEnv.SYSTEM_PROMPT ||
      "You are a concise Telegram assistant. Reply in the same language as the user.",
  };
}

function extractIncomingMessage(event = {}) {
  let update = event.body;
  if (typeof update === "string") {
    try {
      update = JSON.parse(update);
    } catch (_) {
      return { parseError: "invalid JSON body" };
    }
  }
  if (!update || typeof update !== "object") {
    update = {};
  }

  const message = update.message || update.edited_message || null;
  return {
    update,
    message,
    chatId: message?.chat?.id,
    userText: message?.text || message?.caption || "",
    replyToMessageId: message?.message_id || null,
  };
}

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

function respond(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
}

async function runTelegramAiReply({ botToken, openaiKey, model, systemPrompt, chatId, userText, replyToMessageId }) {
  const aiReply = await askOpenAI({ openaiKey, model, systemPrompt, userText });
  const telegramResult = await sendTelegram({
    botToken,
    chatId,
    text: aiReply,
    replyToMessageId,
  });
  return {
    aiReply,
    telegramResult,
  };
}

exports.respond = respond;
exports.resolveTelegramConfig = resolveTelegramConfig;
exports.extractIncomingMessage = extractIncomingMessage;
exports.runTelegramAiReply = runTelegramAiReply;
