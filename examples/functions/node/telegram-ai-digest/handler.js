// Telegram AI Digest — runs on a schedule (cron)
// Fetches recent messages from a Telegram group, summarizes them with OpenAI,
// and sends the digest back to the chat. The heavy lifting lives in `core.js`.

const { handler: handleTelegramAiDigest } = require("./core");

function normalizeTelegramAiDigestEvent(event = {}) {
  return {
    ...event,
    method: event.method == null ? event.method : String(event.method).toUpperCase(),
    query: event.query || {},
    headers: event.headers || {},
    env: event.env || {},
    context: event.context || {},
    params: event.params || {},
  };
}

exports.handler = async (event = {}) => handleTelegramAiDigest(normalizeTelegramAiDigestEvent(event));
