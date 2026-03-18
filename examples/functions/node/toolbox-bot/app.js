// @summary Toolbox bot — parses tool directives from text and executes them
// @methods GET,POST
// @query {"text":"Use [[http:https://api.ipify.org?format=json]] and [[fn:hello|GET]]"}

const ALLOWED_FNS = ["hello", "request-inspector"];
const ALLOWED_HOSTS = ["api.ipify.org", "wttr.in"];
const BASE_URL = "http://127.0.0.1:8080";
const TIMEOUT_MS = 5000;

exports.handler = async (event) => {
  const query = event.query || {};
  const body = typeof event.body === "string" ? tryJson(event.body) : event.body || {};
  const text = String(query.text ?? body.text ?? "").trim();

  if (!text) {
    return json(200, {
      ok: true,
      note: "Send text= with [[fn:name]] or [[http:url]] directives.",
      example: "/toolbox-bot?text=Use%20[[http:https://api.ipify.org?format=json]]",
      allowed: { fn: ALLOWED_FNS, hosts: ALLOWED_HOSTS },
    });
  }

  const tools = parseDirectives(text);

  if (tools.length === 0) {
    return json(200, { ok: true, text, tools: [], note: "No directives found." });
  }

  const results = [];
  for (const tool of tools) {
    results.push(await execute(tool));
  }

  return json(200, { ok: true, text, results });
};

// --- helpers ----------------------------------------------------------------

function parseDirectives(text) {
  const out = [];
  const fnRe = /\[\[fn:([A-Za-z0-9_-]+)(\?[^|\]]*)?(?:\|([A-Z]+))?\]\]/g;
  const httpRe = /\[\[http:(https?:\/\/[^\]\s]+)\]\]/g;
  let m;
  while ((m = fnRe.exec(text)) !== null) {
    out.push({ type: "fn", name: m[1], query: m[2] || "", method: m[3] || "GET" });
  }
  while ((m = httpRe.exec(text)) !== null) {
    out.push({ type: "http", url: m[1] });
  }
  return out.slice(0, 6);
}

async function execute(tool) {
  if (tool.type === "fn") {
    if (!ALLOWED_FNS.includes(tool.name)) {
      return { ok: false, type: "fn", name: tool.name, error: "not in allowlist" };
    }
    const url = `${BASE_URL}/${tool.name}${tool.query}`;
    return fetchTool("fn", tool.name, url, tool.method);
  }

  if (tool.type === "http") {
    let parsed;
    try { parsed = new URL(tool.url); } catch { return { ok: false, type: "http", url: tool.url, error: "invalid url" }; }
    if (!ALLOWED_HOSTS.some((h) => parsed.hostname === h || parsed.hostname.endsWith("." + h))) {
      return { ok: false, type: "http", url: tool.url, error: "host not in allowlist" };
    }
    return fetchTool("http", tool.url, parsed.toString(), "GET");
  }

  return { ok: false, error: "unknown directive type" };
}

async function fetchTool(type, label, url, method) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url, { method, signal: ctrl.signal });
    const text = (await res.text()).slice(0, 4000);
    const ct = res.headers.get("content-type") || "";
    return {
      ok: res.ok,
      type,
      target: label,
      status: res.status,
      body: ct.includes("application/json") ? tryJson(text) ?? text : text,
    };
  } catch (err) {
    return { ok: false, type, target: label, error: err.message };
  } finally {
    clearTimeout(timer);
  }
}

function json(status, data) {
  return { status, headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) };
}

function tryJson(s) {
  try { return JSON.parse(s); } catch { return null; }
}
