// @summary GitHub webhook guard (signature verify) + optional forward
// @methods POST
// @body {"zen":"Keep it logically awesome.","hook_id":123}
//
// Pattern:
// - verify webhook signature (security gate)
// - then forward (proxy) to a downstream URL (optional)

const crypto = require("node:crypto");

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

function timingSafeEq(a, b) {
  const ab = Buffer.from(String(a || ""), "utf8");
  const bb = Buffer.from(String(b || ""), "utf8");
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

function computeSig(secret, body) {
  return (
    "sha256=" +
    crypto
      .createHmac("sha256", Buffer.from(secret, "utf8"))
      .update(Buffer.from(body || "", "utf8"))
      .digest("hex")
  );
}

exports.handler = async (event) => {
  const env = event.env || {};
  const ctx = event.context || {};

  const secret = String(env.GITHUB_WEBHOOK_SECRET || "");
  if (!secret) {
    return json(500, { error: "GITHUB_WEBHOOK_SECRET not configured" });
  }

  const body = typeof event.body === "string" ? event.body : "";
  const provided = String(header(event, "x-hub-signature-256") || "");
  if (!provided) {
    return json(400, { error: "missing x-hub-signature-256" });
  }

  const expected = computeSig(secret, body);
  if (!timingSafeEq(provided, expected)) {
    return json(401, { error: "invalid signature" });
  }

  const delivery = String(header(event, "x-github-delivery") || "");
  const ghEvent = String(header(event, "x-github-event") || "");

  // Default behavior: return an ACK payload.
  // If you add ?forward=1, we forward to /fn/request_inspector (demo).
  const q = event.query || {};
  const forward = String(q.forward || "").trim() === "1";
  if (!forward) {
    return json(200, {
      ok: true,
      verified: true,
      delivery,
      event: ghEvent,
    });
  }

  return {
    proxy: {
      path: "/fn/request_inspector",
      method: "POST",
      headers: {
        "x-fastfn-edge": "1",
        "x-fastfn-request-id": String(ctx.request_id || ""),
        "x-webhook-verified": "1",
        "x-github-delivery": delivery,
        "x-github-event": ghEvent,
      },
      body,
      timeout_ms: ctx.timeout_ms || 2000,
    },
  };
};

