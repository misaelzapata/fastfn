// @summary Request inspector (debug endpoint for demos)
// @methods GET,POST,PUT,PATCH,DELETE
// @query {"key":"value"}
// @body hello
//
// This function intentionally echoes parts of the incoming request to help you
// understand what fastfn sends to handlers and what edge proxy rewrites do.

const { handler: handleRequestInspector } = require("./core");

function normalizeRequestInspectorEvent(event = {}) {
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

exports.handler = async (event = {}) => handleRequestInspector(normalizeRequestInspectorEvent(event));
