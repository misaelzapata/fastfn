// @summary Telegram webhook -> OpenAI -> Telegram reply (AI bot)
// @methods POST
// @body {"message":{"chat":{"id":123},"text":"Hello"}}
//
// Receives a Telegram webhook update, sends the user's message to OpenAI,
// and replies in the same Telegram chat. Logic lives in a private sibling
// module so the entrypoint stays focused on request parsing/orchestration
// without exposing extra routes.

const {
  extractIncomingMessage,
  resolveTelegramConfig,
  runTelegramAiReply,
  respond,
} = require("./core");

exports.handler = async (event = {}) => {
  const env = event.env || {};
  const { parseError, chatId, userText, replyToMessageId } = extractIncomingMessage(event);
  if (parseError) {
    return respond(400, { error: parseError });
  }
  if (!chatId || !userText) {
    return respond(200, { ok: true, skipped: true, reason: "no text message" });
  }

  const { botToken, openaiKey, model, systemPrompt } = resolveTelegramConfig(env);
  const missingEnv = [];
  if (!botToken) missingEnv.push("TELEGRAM_BOT_TOKEN");
  if (!openaiKey) missingEnv.push("OPENAI_API_KEY");

  if (missingEnv.length) {
    return respond(200, {
      ok: true,
      skipped: true,
      chat_id: chatId,
      missing_env: missingEnv,
      note: "Configure TELEGRAM_BOT_TOKEN and OPENAI_API_KEY to enable live replies.",
    });
  }

  try {
    const { aiReply, telegramResult } = await runTelegramAiReply({
      botToken,
      openaiKey,
      model,
      systemPrompt,
      chatId,
      userText,
      replyToMessageId,
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
