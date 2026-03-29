// @summary WhatsApp session manager — QR login, send & receive messages
// @methods GET POST DELETE
// @query {"action":"status"}

// Private helpers live in `core.js`; this entrypoint stays tiny and keeps the
// route contract on `/whatsapp` without publishing sibling modules as routes.

const { handler: handleWhatsApp } = require("./core");

function normalizeWhatsAppEvent(event = {}) {
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

exports.handler = async (event = {}) => handleWhatsApp(normalizeWhatsAppEvent(event));
