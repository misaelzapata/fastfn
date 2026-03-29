function pickHeaders(headers) {
  const input = headers && typeof headers === "object" ? headers : {};
  const out = {};
  for (const key of Object.keys(input)) {
    const lowerKey = String(key).toLowerCase();
    if (
      lowerKey.startsWith("x-") ||
      lowerKey === "content-type" ||
      lowerKey === "user-agent" ||
      lowerKey === "authorization"
    ) {
      out[lowerKey] = input[key];
    }
  }
  return out;
}

exports.handler = async (event) => {
  const query = event.query || {};
  const body = typeof event.body === "string" ? event.body : "";
  const truncated = body.length > 2048 ? body.slice(0, 2048) + "...(truncated)" : body;
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ok: true,
      method: event.method || null,
      path: event.path || null,
      query,
      headers: pickHeaders(event.headers || {}),
      body: truncated,
      context: {
        request_id: event.context && event.context.request_id,
        user: event.context && event.context.user,
      },
    }),
  };
};
