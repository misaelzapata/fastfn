const https = require("https");

function bool(v, defaultValue = false) {
  if (v === undefined || v === null || v === "") return defaultValue;
  const s = String(v).trim().toLowerCase();
  return ["1", "true", "yes", "on"].includes(s);
}

function jsonResponse(status, obj) {
  return { status, headers: { "Content-Type": "application/json" }, body: JSON.stringify(obj) };
}

function requestJson(opts, payload, timeoutMs) {
  return new Promise((resolve, reject) => {
    const body = Buffer.from(JSON.stringify(payload));
    const req = https.request(
      {
        method: opts.method || "POST",
        hostname: opts.hostname,
        path: opts.path,
        headers: {
          ...opts.headers,
          "Content-Type": "application/json",
          "Content-Length": String(body.length),
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
    req.on("timeout", () => req.destroy(new Error("request timeout")));
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

exports.handler = async (event) => {
  const q = event.query || {};
  const env = event.env || {};
  const ctx = event.context || {};

  const title = q.title || "Hello from fastfn";
  const content = q.content || "This page was created by fastfn.";
  const dryRun = bool(q.dry_run, true);

  const parentPageId = q.parent_page_id || "";
  const notionToken = env.NOTION_TOKEN || "";
  const notionVersion = env.NOTION_VERSION || "2022-06-28";

  const payload = {
    parent: parentPageId ? { page_id: String(parentPageId) } : null,
    properties: {
      title: {
        title: [{ text: { content: String(title) } }],
      },
    },
    children: [
      {
        object: "block",
        type: "paragraph",
        paragraph: { rich_text: [{ type: "text", text: { content: String(content) } }] },
      },
    ],
  };

  if (dryRun) {
    return jsonResponse(200, {
      function: "notion-create-page",
      dry_run: true,
      ok: true,
      missing: {
        query: parentPageId ? [] : ["parent_page_id"],
        env: notionToken ? [] : ["NOTION_TOKEN"],
      },
      request: {
        method: "POST",
        url: "https://api.notion.com/v1/pages",
        headers: {
          Authorization: notionToken ? "<hidden>" : "",
          "Notion-Version": notionVersion,
        },
        body: payload,
      },
      note: "Set dry_run=false and provide NOTION_TOKEN + parent_page_id to send.",
    });
  }

  if (!notionToken) {
    return jsonResponse(400, { ok: false, error: "missing env NOTION_TOKEN" });
  }
  if (!parentPageId) {
    return jsonResponse(400, { ok: false, error: "missing query parent_page_id" });
  }

  const timeoutMs = ctx.timeout_ms || 5000;
  const res = await requestJson(
    {
      hostname: "api.notion.com",
      path: "/v1/pages",
      method: "POST",
      headers: {
        Authorization: `Bearer ${String(notionToken)}`,
        "Notion-Version": String(notionVersion),
        "User-Agent": "fastfn-notion",
      },
    },
    payload,
    timeoutMs
  );

  let parsed = null;
  try {
    parsed = JSON.parse(res.body || "null");
  } catch (_) {}

  return jsonResponse(200, {
    ok: res.statusCode >= 200 && res.statusCode < 300,
    notion_status: res.statusCode,
    notion_body: parsed || res.body,
  });
};

