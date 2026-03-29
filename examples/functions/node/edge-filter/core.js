function header(event, name) {
  const h = (event && event.headers) || {};
  const expected = String(name).toLowerCase();
  for (const key of Object.keys(h)) {
    if (String(key).toLowerCase() === expected) {
      return h[key];
    }
  }
  return null;
}

function json(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
}

exports.handler = async (event) => {
  const env = event.env || {};
  const ctx = event.context || {};

  const expected = String(env.EDGE_FILTER_API_KEY || "");
  const provided = String(header(event, "x-api-key") || "");
  if (!expected || provided !== expected) {
    return json(401, { error: "unauthorized" });
  }

  const q = event.query || {};
  const userId = String(q.user_id || q.userId || "");
  if (!/^[0-9]+$/.test(userId)) {
    return json(400, { error: "user_id must be numeric" });
  }

  return {
    proxy: {
      path: `/request-inspector?edge_user_id=${encodeURIComponent(userId)}`,
      method: "GET",
      headers: {
        "x-fastfn-edge": "1",
        "x-fastfn-request-id": String(ctx.request_id || ""),
        "x-fastfn-user-id": userId,
        ...(env.UPSTREAM_TOKEN ? { authorization: `Bearer ${String(env.UPSTREAM_TOKEN)}` } : {}),
      },
      body: "",
      timeout_ms: Math.max(Number(ctx.timeout_ms) || 0, 10000),
    },
  };
};
