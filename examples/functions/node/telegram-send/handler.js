// Private helpers live in `core.js`; this entrypoint stays tiny and keeps the
// route contract on `/telegram-send` without publishing sibling modules as routes.

const { handler: handleTelegramSend } = require("./core");

function normalizeTelegramSendEvent(event = {}) {
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

exports.handler = async (event = {}) => handleTelegramSend(normalizeTelegramSendEvent(event));
