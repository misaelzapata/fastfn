// @summary Toolbox bot (safe tool runner for demos)
// @methods GET,POST
// @query {"text":"Use [[http:https://api.ipify.org?format=json]] and [[fn:request-inspector?key=demo|GET]]","dry_run":"true"}
// @body {"text":"my ip and weather in Buenos Aires","dry_run":true,"auto_tools":true}
//
// This function is intentionally safe by default:
// - dry_run defaults to true (no outbound calls)
// - when dry_run=false, it still enforces strict allowlists for:
//   - fn tools: only configured function names
//   - http tools: only configured hostnames

function asBool(value, fallback) {
  if (value === undefined || value === null) return fallback;
  if (typeof value === "boolean") return value;
  const normalized = String(value).trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  return fallback;
}

function json(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
}

function parseJson(raw) {
  if (!raw) return null;
  if (typeof raw === "object" && !Array.isArray(raw)) return raw;
  if (typeof raw !== "string") return null;
  try {
    return JSON.parse(raw);
  } catch (_) {
    return null;
  }
}

function hostAllowed(hostname, allowlist) {
  const host = String(hostname || "").toLowerCase();
  if (!host) return false;
  for (const allowed of allowlist || []) {
    if (host === allowed) return true;
    if (host.endsWith("." + allowed)) return true;
  }
  return false;
}

function isLocalHostname(hostname) {
  const h = String(hostname || "").toLowerCase();
  if (!h) return false;
  if (h === "localhost") return true;
  if (h === "127.0.0.1") return true;
  if (h === "::1") return true;
  if (h.endsWith(".local")) return true;
  return false;
}

function canonicalSegment(name) {
  return String(name || "")
    .trim()
    .toLowerCase()
    .replace(/_+/g, "-");
}

async function fetchWithTimeout(url, opts, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1, Number(timeoutMs) || 5000));
  try {
    return await fetch(url, { ...(opts || {}), signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function toolConfig(env, query, bodyObj) {
  const enabled = asBool(query.tools ?? bodyObj.tools ?? env.TOOLBOX_TOOLS_ENABLED ?? process.env.TOOLBOX_TOOLS_ENABLED, true);
  const autoTools = asBool(
    query.auto_tools ?? bodyObj.auto_tools ?? env.TOOLBOX_AUTO_TOOLS ?? process.env.TOOLBOX_AUTO_TOOLS,
    false
  );

  const timeoutMsRaw = Number(
    query.tool_timeout_ms ??
    bodyObj.tool_timeout_ms ??
    env.TOOLBOX_TOOL_TIMEOUT_MS ??
    process.env.TOOLBOX_TOOL_TIMEOUT_MS ??
    5000
  );
  const timeoutMs = Number.isFinite(timeoutMsRaw) ? Math.max(250, Math.min(60000, Math.floor(timeoutMsRaw))) : 5000;

  const baseUrl = String(
    query.tool_base_url ??
    bodyObj.tool_base_url ??
    env.TOOLBOX_TOOL_INTERNAL_BASE_URL ??
    process.env.TOOLBOX_TOOL_INTERNAL_BASE_URL ??
    "http://127.0.0.1:8080"
  ).replace(/\/+$/, "");

  const allowedFns = String(
    query.tool_allow_fn ??
    bodyObj.tool_allow_fn ??
    env.TOOLBOX_TOOL_ALLOW_FN ??
    process.env.TOOLBOX_TOOL_ALLOW_FN ??
    "request-inspector,telegram-ai-digest,tools-loop,cron-tick,hello,risk-score"
  )
    .split(",")
    .map((v) => String(v).trim())
    .filter((v) => /^[A-Za-z0-9_-]+$/.test(v));

  const allowedHosts = String(
    query.tool_allow_hosts ??
    bodyObj.tool_allow_hosts ??
    env.TOOLBOX_TOOL_ALLOW_HTTP_HOSTS ??
    process.env.TOOLBOX_TOOL_ALLOW_HTTP_HOSTS ??
    "api.ipify.org,ipapi.co,wttr.in"
  )
    .split(",")
    .map((v) => String(v).trim().toLowerCase())
    .filter((v) => v.length > 0);

  return { enabled, autoTools, timeoutMs, baseUrl, allowedFns, allowedHosts };
}

function parseToolDirectives(text) {
  const out = [];
  const src = String(text || "");
  const fnRe = /\[\[fn:([A-Za-z0-9_-]+)(\?[^|\]]*)?(?:\|([A-Z]+))?\]\]/g;
  const httpRe = /\[\[http:(https?:\/\/[^\]\s]+)\]\]/g;
  let m;
  while ((m = fnRe.exec(src)) !== null) {
    out.push({
      type: "fn",
      name: m[1],
      query: m[2] || "",
      method: (m[3] || "GET").toUpperCase(),
    });
  }
  while ((m = httpRe.exec(src)) !== null) {
    out.push({
      type: "http",
      url: m[1],
    });
  }
  return out.slice(0, 6);
}

function extractWeatherLocation(text) {
  const src = String(text || "");
  if (!src) return "";
  const patterns = [
    /(?:clima|weather|temperatura|forecast)\s+(?:en|in)\s+([^\n\r\?\!\.,;:]+)/i,
    /(?:en|in)\s+([^\n\r\?\!\.,;:]+)\s+(?:clima|weather|temperatura|forecast)/i,
  ];
  for (const re of patterns) {
    const m = src.match(re);
    if (!m || !m[1]) continue;
    const loc = String(m[1]).trim().replace(/\s+/g, " ");
    if (!loc) continue;
    if (loc.length > 64) continue;
    return loc;
  }
  return "";
}

function inferAutoTools(text, cfg) {
  const rawText = String(text || "");
  const src = rawText.toLowerCase();
  const picks = [];

  const has = (s) => src.includes(s);
  const addFn = (name, query) => {
    if (cfg.allowedFns.includes(name)) {
      picks.push({ type: "fn", name, query: query || "", method: "GET" });
    }
  };
  const addHttp = (url) => {
    try {
      const u = new URL(url);
      if (hostAllowed(u.hostname, cfg.allowedHosts)) {
        picks.push({ type: "http", url: u.toString() });
      }
    } catch (_) {
      // ignore invalid predefined URL
    }
  };

  // IP helper
  if (has("ip") || has("mi ip") || has("my ip") || has("ubicacion")) {
    addHttp("https://api.ipify.org?format=json");
  }

  // Weather helper
  if (has("clima") || has("weather") || has("temperatura") || has("forecast")) {
    const loc = extractWeatherLocation(rawText);
    if (loc) addHttp(`https://wttr.in/${encodeURIComponent(loc)}?format=3`);
    else addHttp("https://wttr.in/?format=3");
  }

  // Request debug helper
  if (has("debug") || has("headers") || has("request")) {
    addFn("request-inspector", "?key=auto");
  }

  // De-duplicate
  const seen = new Set();
  const unique = [];
  for (const item of picks) {
    const key = JSON.stringify(item);
    if (seen.has(key)) continue;
    seen.add(key);
    unique.push(item);
  }
  return unique.slice(0, 6);
}

async function executeTool(tool, cfg) {
  const started = Date.now();

  if (tool.type === "fn") {
    if (!cfg.allowedFns.includes(tool.name)) {
      return { ok: false, type: "fn", name: tool.name, error: "function not allowed", elapsed_ms: Date.now() - started };
    }
    if (!["GET", "POST", "PUT", "PATCH", "DELETE"].includes(tool.method)) {
      return { ok: false, type: "fn", name: tool.name, error: "method not allowed", elapsed_ms: Date.now() - started };
    }
    const url = `${cfg.baseUrl}/${canonicalSegment(tool.name)}${tool.query || ""}`;
    const res = await fetchWithTimeout(url, { method: tool.method }, cfg.timeoutMs);
    const body = await res.text();
    const raw = body.slice(0, 4000);
    const contentType = (res.headers && res.headers.get && res.headers.get("content-type")) || "";
    let data = null;
    if (String(contentType).toLowerCase().includes("application/json")) {
      data = parseJson(raw);
    }
    return {
      ok: res.ok,
      type: "fn",
      name: tool.name,
      status: res.status,
      content_type: contentType,
      body: raw,
      json: data,
      elapsed_ms: Date.now() - started,
    };
  }

  if (tool.type === "http") {
    let parsed;
    try {
      parsed = new URL(tool.url);
    } catch (_) {
      return { ok: false, type: "http", url: tool.url, error: "invalid url", elapsed_ms: Date.now() - started };
    }
    if (isLocalHostname(parsed.hostname)) {
      return { ok: false, type: "http", url: tool.url, error: "local host not allowed", elapsed_ms: Date.now() - started };
    }
    if (!hostAllowed(parsed.hostname, cfg.allowedHosts)) {
      return { ok: false, type: "http", url: tool.url, error: "host not allowed", elapsed_ms: Date.now() - started };
    }
    const res = await fetchWithTimeout(parsed.toString(), { method: "GET", redirect: "manual" }, cfg.timeoutMs);
    const body = await res.text();
    const raw = body.slice(0, 4000);
    const contentType = (res.headers && res.headers.get && res.headers.get("content-type")) || "";
    let data = null;
    if (String(contentType).toLowerCase().includes("application/json")) {
      data = parseJson(raw);
    }
    return {
      ok: res.ok,
      type: "http",
      url: parsed.toString(),
      status: res.status,
      content_type: contentType,
      body: raw,
      json: data,
      elapsed_ms: Date.now() - started,
    };
  }

  return { ok: false, error: "unknown tool type", elapsed_ms: Date.now() - started };
}

exports.handler = async (event) => {
  const env = event.env || {};
  const query = event.query || {};
  const bodyObj = parseJson(event.body) || {};

  const text = String(query.text ?? bodyObj.text ?? "").trim();
  const dryRun = asBool(query.dry_run ?? bodyObj.dry_run, true);
  const cfg = toolConfig(env, query, bodyObj);

  if (!cfg.enabled) {
    return json(200, { ok: true, tools: { enabled: false }, note: "tools disabled (set TOOLBOX_TOOLS_ENABLED=true)" });
  }

  if (!text) {
    return json(200, {
      ok: true,
      dry_run: dryRun,
      note: "Provide text=... with [[http:...]] and/or [[fn:...]] directives (or set auto_tools=true).",
      examples: [
        "/toolbox-bot?text=Use%20[[http:https://api.ipify.org?format=json]]%20and%20[[fn:request-inspector?key=demo|GET]]&dry_run=true",
        "/toolbox-bot?text=what%20is%20my%20ip%20and%20weather%20in%20Buenos%20Aires%3F&auto_tools=true&dry_run=true",
      ],
      allow: { fn: cfg.allowedFns, http_hosts: cfg.allowedHosts },
    });
  }

  let plan = parseToolDirectives(text);
  if (plan.length === 0 && cfg.autoTools) {
    plan = inferAutoTools(text, cfg);
  }

  if (plan.length === 0) {
    return json(200, {
      ok: true,
      dry_run: dryRun,
      text,
      plan: [],
      note: "No tool directives found. Add [[http:...]] / [[fn:...]] or set auto_tools=true.",
    });
  }

  if (dryRun) {
    return json(200, {
      ok: true,
      dry_run: true,
      text,
      plan,
      note: "Set dry_run=false to execute tools.",
      allow: { fn: cfg.allowedFns, http_hosts: cfg.allowedHosts },
    });
  }

  const results = [];
  for (const tool of plan) {
    try {
      results.push(await executeTool(tool, cfg));
    } catch (err) {
      results.push({
        ok: false,
        type: tool && tool.type ? tool.type : "unknown",
        target: tool && (tool.name || tool.url) ? (tool.name || tool.url) : null,
        error: String(err && err.message ? err.message : err),
      });
    }
  }

  return json(200, {
    ok: true,
    dry_run: false,
    text,
    plan,
    results,
    summary: {
      ok: results.every((r) => r && r.ok === true),
      total: results.length,
      failed: results.filter((r) => !(r && r.ok === true)).length,
    },
  });
};
