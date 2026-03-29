// @summary Toolbox bot — parses tool directives from text and executes them
// @methods GET,POST
// @query {"text":"Use [[http:https://api.ipify.org?format=json]] and [[fn:hello|GET]]"}

const { handler: handleToolboxBot } = require("./core");

function normalizeToolboxBotEvent(event = {}) {
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

exports.handler = async (event = {}) => handleToolboxBot(normalizeToolboxBotEvent(event));
