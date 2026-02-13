const https = require("https");
const { URL } = require("url");

function bool(v, defaultValue = false) {
  if (v === undefined || v === null || v === "") return defaultValue;
  const s = String(v).trim().toLowerCase();
  return ["1", "true", "yes", "on"].includes(s);
}

function jsonResponse(status, obj) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(obj),
  };
}

function postJson(urlStr, payload, timeoutMs) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr);
    const body = Buffer.from(JSON.stringify(payload));
    const req = https.request(
      {
        method: "POST",
        protocol: u.protocol,
        hostname: u.hostname,
        port: u.port || 443,
        path: u.pathname + (u.search || ""),
        headers: {
          "Content-Type": "application/json",
          "Content-Length": String(body.length),
          "User-Agent": "fastfn-slack-webhook",
        },
        timeout: Math.max(1000, Number(timeoutMs || 5000)),
      },
      (res) => {
        const chunks = [];
        res.on("data", (d) => chunks.push(d));
        res.on("end", () => {
          resolve({
            statusCode: res.statusCode || 0,
            headers: res.headers || {},
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      }
    );
    req.on("timeout", () => {
      req.destroy(new Error("request timeout"));
    });
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

exports.handler = async (event) => {
  const query = event.query || {};
  const env = event.env || {};

  const text = query.text || "Hello from fastfn";
  const dryRun = bool(query.dry_run, true);

  const webhookUrl = env.SLACK_WEBHOOK_URL || "";

  const payload = { text: String(text) };

  if (dryRun) {
    return jsonResponse(200, {
      function: "slack_webhook",
      dry_run: true,
      ok: true,
      missing_env: webhookUrl ? [] : ["SLACK_WEBHOOK_URL"],
      request: {
        url: webhookUrl ? "<hidden>" : "",
        method: "POST",
        body: payload,
      },
      note: "Set dry_run=false and provide SLACK_WEBHOOK_URL in fn.env.json to send.",
    });
  }

  if (!webhookUrl) {
    return jsonResponse(400, { ok: false, error: "missing env SLACK_WEBHOOK_URL" });
  }

  const timeoutMs = (event.context || {}).timeout_ms || 5000;
  const res = await postJson(webhookUrl, payload, timeoutMs);
  return jsonResponse(200, {
    ok: true,
    slack_status: res.statusCode,
    slack_body: res.body,
  });
};

