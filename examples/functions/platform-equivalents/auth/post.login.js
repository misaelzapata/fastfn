const crypto = require("node:crypto");

const DEFAULT_AUTH_SECRET = "fastfn-auth-secret";
const ALLOWED_ROLES = new Set(["viewer", "editor", "admin"]);

function parseJsonBody(body) {
  if (body == null || body === "") {
    return {};
  }
  if (typeof body === "object") {
    return body;
  }
  try {
    return JSON.parse(String(body));
  } catch {
    return null;
  }
}

function json(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(payload),
  };
}

exports.handler = async (event = {}) => {
  const data = parseJsonBody(event.body);
  if (!data) {
    return json(400, { error: "invalid_json", message: "Request body must be valid JSON." });
  }

  const username = String(data.username || "").trim();
  const role = String(data.role || "viewer").trim().toLowerCase();
  if (!username) {
    return json(400, { error: "validation_error", message: "username is required." });
  }
  if (!ALLOWED_ROLES.has(role)) {
    return json(400, { error: "validation_error", message: "role must be one of viewer/editor/admin." });
  }

  const env = event.env || {};
  const secret = String(env.AUTH_SECRET || DEFAULT_AUTH_SECRET);
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    sub: username,
    role,
    iat: now,
    exp: now + 3600,
    iss: "platform-equivalents",
  };
  const encodedPayload = Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
  const sig = crypto.createHmac("sha256", secret).update(encodedPayload).digest("hex");
  const token = `${encodedPayload}.${sig}`;

  return json(200, {
    token,
    token_type: "bearer",
    expires_in: 3600,
    profile_url: "/auth/profile",
    issued_for: username,
    role,
  });
};

