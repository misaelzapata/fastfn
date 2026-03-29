// @summary Edge header injection + passthrough
// @methods GET,POST,PUT,PATCH,DELETE
// @query {"tenant":"demo"}
// @body hello
//
// Pattern:
// - compute/inject gateway headers (tenant, request id, etc)
// - proxy to an upstream endpoint
//
// Demo upstream: /request-inspector (so you can see injected headers).

// Private helpers live in `core.js`; this entrypoint stays tiny and keeps the
// route contract on `/edge-header-inject` without publishing sibling modules as routes.

const { handler: handleEdgeHeaderInject } = require("./core");

function normalizeEdgeHeaderInjectEvent(event = {}) {
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

exports.handler = async (event = {}) => handleEdgeHeaderInject(normalizeEdgeHeaderInjectEvent(event));
