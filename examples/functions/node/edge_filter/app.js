// @summary Edge filter (auth + rewrite + passthrough)
// @methods GET,POST,PUT,PATCH,DELETE
// @query {"user_id":"123"}
// @body hello
//
// This demonstrates a "Workers-like" filter:
// - validate/auth the incoming request
// - rewrite method/path/headers/body
// - return { proxy: ... } so fastfn performs the outbound fetch

function header(event, name) {
  const h = (event && event.headers) || {};
  return h[name] || h[name.toLowerCase()] || h[name.toUpperCase()] || null;
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

  // 1) Filter: require an API key (demo only; replace with JWT validation etc).
  const expected = String(env.EDGE_FILTER_API_KEY || "");
  const provided = String(header(event, "x-api-key") || "");
  if (!expected || provided !== expected) {
    return json(401, { error: "unauthorized" });
  }

  // 2) Filter: validate/normalize query.
  const q = event.query || {};
  const userId = String(q.user_id || q.userId || "");
  if (!/^[0-9]+$/.test(userId)) {
    return json(400, { error: "user_id must be numeric" });
  }

  // 3) Rewrite the outbound request.
  // In a real system this might be something like:
  //   path: `/v1/users/${userId}`
  // For an out-of-the-box demo, we proxy to the built-in OpenAPI document.
  return {
    proxy: {
      path: `/openapi.json?edge_user_id=${encodeURIComponent(userId)}`,
      method: "GET", // force GET upstream even if the incoming request is POST
      headers: {
        "x-fastfn-edge": "1",
        "x-fastfn-request-id": String(ctx.request_id || ""),
        "x-fastfn-user-id": userId,
        // Example: propagate an upstream token (do not log it).
        ...(env.UPSTREAM_TOKEN ? { authorization: `Bearer ${String(env.UPSTREAM_TOKEN)}` } : {}),
      },
      body: "", // ignore inbound body for this demo
      timeout_ms: ctx.timeout_ms || 2000,
    },
  };
};

