// @summary AI tool-calling agent (OpenAI chooses tools + full trace)
// @methods GET,POST
// @query {"text":"what is my IP and weather in Buenos Aires?","dry_run":"true","agent_id":"demo"}
// @body {"text":"what is my IP and weather in Buenos Aires?","dry_run":true,"agent_id":"demo"}
//
// This example demonstrates real OpenAI tool-calling:
// - the model picks tools (`http_get`, `fn_get`) and provides JSON args
// - the function executes tools with strict allowlists
// - the function sends tool results back to the model
// - the function returns a trace of the whole run
//
// Safety:
// - dry_run defaults to true
// - strict allowlists for both tool types
// - capped steps / capped response sizes

// Private helpers live in `core.js`; this entrypoint stays tiny and keeps the
// route contract on `/ai-tool-agent` without publishing sibling modules as routes.

const { handler: handleAiToolAgent } = require("./core");

function normalizeAiToolAgentEvent(event = {}) {
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

exports.handler = async (event = {}) => handleAiToolAgent(normalizeAiToolAgentEvent(event));
