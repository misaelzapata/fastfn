// @summary Edge auth gateway — validate a Bearer token, then proxy upstream
// @methods GET,POST
// @query {"target":"openapi"}
// @body hello

// Private helpers live in `core.js`; this entrypoint stays tiny and keeps the
// route contract on `/edge-auth-gateway` without publishing sibling modules as routes.

const { handler: handleEdgeAuthGateway } = require("./core");

function normalizeEdgeAuthGatewayEvent(event = {}) {
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

exports.handler = async (event = {}) => handleEdgeAuthGateway(normalizeEdgeAuthGatewayEvent(event));
