// @summary Edge gateway auth (Bearer) + passthrough
// @methods GET,POST,PUT,PATCH,DELETE
// @query {"target":"openapi"}
// @body hello
//
// Pattern:
// - validate Authorization header (API gateway style)
// - proxy a request to an upstream (edge passthrough)

function header(event, name) {
  const h = (event && event.headers) || {};
  return h[name] || h[name.toLowerCase()] || h[name.toUpperCase()] || null;
}

function json(status, payload, extraHeaders) {
  return {
    status,
    headers: { "Content-Type": "application/json", ...(extraHeaders || {}) },
    body: JSON.stringify(payload),
  };
}

function normalizeTarget(raw) {
  const t = String(raw || "openapi").trim().toLowerCase();
  if (t === "health") return "/request-inspector?target=health";
  if (t === "openapi") return "/request-inspector?target=openapi";
  return null;
}

exports.handler = async (event) => {
  const env = event.env || {};
  const ctx = event.context || {};

  const expected = String(env.EDGE_AUTH_TOKEN || "");
  const auth = String(header(event, "authorization") || "");
  const ok = expected && auth === `Bearer ${expected}`;
  if (!ok) {
    return json(401, { error: "unauthorized" }, { "WWW-Authenticate": "Bearer" });
  }

  const q = event.query || {};
  const targetPath = normalizeTarget(q.target);
  if (!targetPath) {
    return json(400, { error: "invalid target (use ?target=openapi or ?target=health)" });
  }

  return {
    proxy: {
      path: targetPath,
      method: event.method || "GET",
      headers: {
        "x-fastfn-edge": "1",
        "x-fastfn-request-id": String(ctx.request_id || ""),
      },
      body: event.body || "",
      timeout_ms: ctx.timeout_ms || 2000,
    },
  };
};
