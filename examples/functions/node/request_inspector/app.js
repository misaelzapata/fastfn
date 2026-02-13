// @summary Request inspector (debug endpoint for demos)
// @methods GET,POST,PUT,PATCH,DELETE
// @query {"key":"value"}
// @body hello
//
// This function intentionally echoes parts of the incoming request to help you
// understand what fastfn sends to handlers and what edge proxy rewrites do.

function pickHeaders(headers) {
  const h = headers && typeof headers === "object" ? headers : {};
  const out = {};
  for (const k of Object.keys(h)) {
    const lk = String(k).toLowerCase();
    if (lk.startsWith("x-") || lk === "content-type" || lk === "user-agent" || lk === "authorization") {
      out[lk] = h[k];
    }
  }
  return out;
}

exports.handler = async (event) => {
  const q = event.query || {};
  const body = typeof event.body === "string" ? event.body : "";
  const truncated = body.length > 2048 ? body.slice(0, 2048) + "...(truncated)" : body;
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ok: true,
      method: event.method || null,
      path: event.path || null,
      query: q,
      headers: pickHeaders(event.headers || {}),
      body: truncated,
      context: {
        request_id: event.context && event.context.request_id,
        user: event.context && event.context.user,
      },
    }),
  };
};

