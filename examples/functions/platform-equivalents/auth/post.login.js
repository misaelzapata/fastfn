// POST /auth/login — Issue an HMAC-signed bearer token
const crypto = require("node:crypto");

exports.handler = async (event = {}) => {
  const body =
    typeof event.body === "string" ? JSON.parse(event.body) : event.body || {};

  const username = (body.username || "").trim();
  if (!username) {
    return { status: 400, body: JSON.stringify({ error: "username is required" }) };
  }

  const role = body.role || "viewer";
  const secret = (event.env || {}).AUTH_SECRET || "fastfn-auth-secret";
  const now = Math.floor(Date.now() / 1000);

  // Build a simple token: base64url(payload).hmac-signature
  const payload = { sub: username, role, iat: now, exp: now + 3600 };
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const sig = crypto.createHmac("sha256", secret).update(encoded).digest("hex");
  const token = `${encoded}.${sig}`;

  return {
    status: 200,
    body: JSON.stringify({ token, expires_in: 3600, username, role }),
  };
};
