const { parseJsonBody, updateState } = require('./_state');

function json(status, payload) {
  return {
    status,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  };
}

function makeUpsertHandler(method) {
  return async (event) => {
    try {
      const payload = parseJsonBody(event.body);
      const data = updateState(payload);
      return json(200, {
        route: `${method} /showcase/form`,
        data,
        runtime: 'node',
      });
    } catch (err) {
      return json(400, {
        error: 'invalid_json_body',
        message: err && err.message ? err.message : 'Invalid body',
      });
    }
  };
}

module.exports = { makeUpsertHandler };
