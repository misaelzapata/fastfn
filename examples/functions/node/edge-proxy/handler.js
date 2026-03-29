// @summary Edge passthrough (proxy)
// @methods GET,POST,PUT,PATCH,DELETE
// @query {"key":"demo"}
// @body hello
// Private helpers live in `core.js`; this entrypoint stays tiny and keeps the
// route contract on `/edge-proxy` without publishing sibling modules as routes.

const { handler: handleEdgeProxy } = require("./core");

function normalizeEdgeProxyEvent(event = {}) {
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

exports.handler = async (event = {}) => handleEdgeProxy(normalizeEdgeProxyEvent(event));
