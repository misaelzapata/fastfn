// @summary Edge filter (auth + rewrite + passthrough)
// @methods GET,POST,PUT,PATCH,DELETE
// @query {"user_id":"123"}
// @body hello
//
// This demonstrates a "Workers-like" filter:
// - validate/auth the incoming request
// - rewrite method/path/headers/body
// - return { proxy: ... } so fastfn performs the outbound fetch

// Private helpers live in `core.js`; this entrypoint stays tiny and keeps the
// route contract on `/edge-filter` without publishing sibling modules as routes.

const { handler: handleEdgeFilter } = require("./core");

function normalizeEdgeFilterEvent(event = {}) {
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

exports.handler = async (event = {}) => handleEdgeFilter(normalizeEdgeFilterEvent(event));
