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

function isUnsetSecret(value) {
  if (value === undefined || value === null) return true;
  const s = String(value).trim();
  if (!s) return true;
  const l = s.toLowerCase();
  return l === "<set-me>" || l === "set-me" || l === "changeme" || l === "<changeme>" || l === "replace-me";
}

function chooseSecret(localValue, fallbackValue) {
  if (!isUnsetSecret(localValue)) return String(localValue).trim();
  if (!isUnsetSecret(fallbackValue)) return String(fallbackValue).trim();
  return "";
}

async function fetchWithTimeout(url, opts, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1, Number(timeoutMs) || 8000));
  try {
    return await fetch(url, { ...(opts || {}), signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function clampInt(raw, fallback, min, max) {
  const n = Number(raw);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.floor(n)));
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

function toolConfig(env, query, bodyObj) {
  const fnBaseUrl = String(
    query.fn_base_url ??
    bodyObj.fn_base_url ??
    env.AGENT_TOOL_FN_BASE_URL ??
    process.env.AGENT_TOOL_FN_BASE_URL ??
    "http://127.0.0.1:8080"
  ).replace(/\/+$/, "");

  const timeoutMs = clampInt(
    query.tool_timeout_ms ??
      bodyObj.tool_timeout_ms ??
      env.AGENT_TOOL_TIMEOUT_MS ??
      process.env.AGENT_TOOL_TIMEOUT_MS ??
      8000,
    8000,
    250,
    60000
  );

  const allowedFns = String(
    query.tool_allow_fn ??
      bodyObj.tool_allow_fn ??
      env.AGENT_TOOL_ALLOW_FN ??
      process.env.AGENT_TOOL_ALLOW_FN ??
      "request-inspector,telegram-ai-digest,cron-tick"
  )
    .split(",")
    .map((v) => String(v).trim())
    .filter((v) => /^[A-Za-z0-9_-]+$/.test(v));

  const allowedHosts = String(
    query.tool_allow_hosts ??
      bodyObj.tool_allow_hosts ??
      env.AGENT_TOOL_ALLOW_HTTP_HOSTS ??
      process.env.AGENT_TOOL_ALLOW_HTTP_HOSTS ??
      "api.ipify.org,wttr.in,ipapi.co"
  )
    .split(",")
    .map((v) => String(v).trim().toLowerCase())
    .filter((v) => v.length > 0);

  const maxSteps = clampInt(
    query.max_steps ?? bodyObj.max_steps ?? env.AGENT_MAX_STEPS ?? process.env.AGENT_MAX_STEPS ?? 6,
    6,
    1,
    12
  );

  return { fnBaseUrl, timeoutMs, allowedFns, allowedHosts, maxSteps };
}

function memoryConfig(env, query, bodyObj) {
  const enabled = asBool(query.memory ?? bodyObj.memory ?? env.AGENT_MEMORY_ENABLED ?? process.env.AGENT_MEMORY_ENABLED, true);
  const maxTurns = clampInt(query.memory_max_turns ?? bodyObj.memory_max_turns ?? 8, 8, 0, 40);
  const ttlSecs = clampInt(query.memory_ttl_secs ?? bodyObj.memory_ttl_secs ?? 86400, 86400, 0, 86400 * 30);
  const agentId = String(query.agent_id ?? bodyObj.agent_id ?? env.AGENT_ID ?? process.env.AGENT_ID ?? "default").trim() || "default";

  const path = require("path");
  const memPath = process.env.FASTFN_AGENT_MEMORY_PATH || path.join(__dirname, ".memory.json");
  return { enabled, maxTurns, ttlSecs, agentId, memPath };
}

function loadMemory(cfg) {
  if (!cfg.enabled) return [];
  const fs = require("fs");
  let raw = "";
  try {
    raw = fs.readFileSync(cfg.memPath, "utf8");
  } catch (_) {
    return [];
  }
  const data = parseJson(raw);
  if (!data || typeof data !== "object") return [];
  const list = Array.isArray(data[cfg.agentId]) ? data[cfg.agentId] : [];
  const now = Date.now();
  const ttlMs = cfg.ttlSecs * 1000;
  const filtered = list.filter((item) => {
    if (!item || typeof item !== "object") return false;
    if (typeof item.ts !== "number" || typeof item.role !== "string" || typeof item.text !== "string") return false;
    if (ttlMs > 0 && now - item.ts > ttlMs) return false;
    return item.role === "user" || item.role === "assistant";
  });
  return filtered.slice(-cfg.maxTurns * 2);
}

function saveMemory(cfg, messages) {
  if (!cfg.enabled) return;
  const fs = require("fs");
  let data = {};
  try {
    data = parseJson(fs.readFileSync(cfg.memPath, "utf8")) || {};
  } catch (_) {
    data = {};
  }
  if (!data || typeof data !== "object") data = {};
  data[cfg.agentId] = messages.slice(-cfg.maxTurns * 2);
  try {
    fs.writeFileSync(cfg.memPath, JSON.stringify(data, null, 2));
  } catch (_) {
    // Best effort: do not fail the invocation if memory cannot be written.
  }
}

function toolSchemas(cfg) {
  return [
    {
      type: "function",
      function: {
        name: "http_get",
        description:
          "Fetch a URL via HTTP GET. Only allowlisted hostnames are allowed. Use this to retrieve simple JSON/text (IP, weather).",
        parameters: {
          type: "object",
          properties: {
            url: { type: "string", description: "Full URL (https://...)" },
          },
          required: ["url"],
          additionalProperties: false,
        },
      },
    },
    {
      type: "function",
      function: {
        name: "fn_get",
        description:
          "Invoke another FastFN function by name (GET). Only allowlisted function names are allowed. Use this for internal helpers like request-inspector or telegram-ai-digest.",
        parameters: {
          type: "object",
          properties: {
            name: { type: "string", description: "Function name (example: request-inspector)" },
            query: {
              type: "object",
              description: "Query parameters as key/value strings",
              additionalProperties: { type: "string" },
            },
          },
          required: ["name"],
          additionalProperties: false,
        },
      },
    },
  ];
}

async function executeToolCall(name, args, cfg) {
  const started = Date.now();

  if (name === "http_get") {
    const url = args && typeof args.url === "string" ? args.url : "";
    let parsed;
    try {
      parsed = new URL(url);
    } catch (_) {
      return { ok: false, tool: "http_get", error: "invalid url", elapsed_ms: Date.now() - started };
    }
    if (!["https:", "http:"].includes(parsed.protocol)) {
      return { ok: false, tool: "http_get", url, error: "protocol not allowed", elapsed_ms: Date.now() - started };
    }
    if (isLocalHostname(parsed.hostname)) {
      return { ok: false, tool: "http_get", url, error: "local host not allowed", elapsed_ms: Date.now() - started };
    }
    if (!hostAllowed(parsed.hostname, cfg.allowedHosts)) {
      return { ok: false, tool: "http_get", url, error: "host not allowed", elapsed_ms: Date.now() - started };
    }
    const res = await fetchWithTimeout(parsed.toString(), { method: "GET", redirect: "manual" }, cfg.timeoutMs);
    const body = await res.text();
    const contentType = (res.headers && res.headers.get && res.headers.get("content-type")) || "";
    const raw = String(body || "").slice(0, 4000);
    const parsedJson = String(contentType).toLowerCase().includes("application/json") ? parseJson(raw) : null;
    return {
      ok: res.ok,
      tool: "http_get",
      url: parsed.toString(),
      status: res.status,
      content_type: contentType,
      body: raw,
      json: parsedJson,
      elapsed_ms: Date.now() - started,
    };
  }

  if (name === "fn_get") {
    const fnName = args && typeof args.name === "string" ? args.name.trim() : "";
    if (!/^[A-Za-z0-9_-]+$/.test(fnName)) {
      return { ok: false, tool: "fn_get", name: fnName, error: "invalid function name", elapsed_ms: Date.now() - started };
    }
    if (!cfg.allowedFns.includes(fnName)) {
      return { ok: false, tool: "fn_get", name: fnName, error: "function not allowed", elapsed_ms: Date.now() - started };
    }
    const q = args && args.query && typeof args.query === "object" ? args.query : {};
    const url = new URL(`${cfg.fnBaseUrl}/${canonicalSegment(fnName)}`);
    for (const key of Object.keys(q || {})) {
      const k = String(key || "").trim();
      if (!k) continue;
      const v = q[key];
      url.searchParams.set(k, String(v));
    }
    const res = await fetchWithTimeout(url.toString(), { method: "GET" }, cfg.timeoutMs);
    const body = await res.text();
    const contentType = (res.headers && res.headers.get && res.headers.get("content-type")) || "";
    const raw = String(body || "").slice(0, 4000);
    const parsedJson = String(contentType).toLowerCase().includes("application/json") ? parseJson(raw) : null;
    return {
      ok: res.ok,
      tool: "fn_get",
      name: fnName,
      status: res.status,
      content_type: contentType,
      body: raw,
      json: parsedJson,
      elapsed_ms: Date.now() - started,
    };
  }

  return { ok: false, tool: name, error: "unknown tool", elapsed_ms: Date.now() - started };
}

async function openaiChat(env, messages, tools, timeoutMs) {
  const apiKey = chooseSecret(env.OPENAI_API_KEY, process.env.OPENAI_API_KEY);
  if (!apiKey) throw new Error("OPENAI_API_KEY not configured");
  const baseUrl = String(env.OPENAI_BASE_URL || process.env.OPENAI_BASE_URL || "https://api.openai.com/v1").replace(/\/+$/, "");
  const model = String(env.OPENAI_MODEL || process.env.OPENAI_MODEL || "gpt-4o-mini");

  const payload = {
    model,
    messages,
    tools,
    tool_choice: "auto",
    temperature: 0.2,
  };

  const res = await fetchWithTimeout(
    `${baseUrl}/chat/completions`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(payload),
    },
    timeoutMs
  );
  const raw = await res.text();
  if (!res.ok) throw new Error(`openai error status=${res.status} body=${raw}`);
  const parsed = parseJson(raw);
  const msg = parsed && parsed.choices && parsed.choices[0] && parsed.choices[0].message;
  if (!msg) throw new Error("openai returned no message");
  return msg;
}

function summarizeAssistantMessage(msg) {
  if (!msg || typeof msg !== "object") return { role: "assistant" };
  const out = {
    role: "assistant",
    content: typeof msg.content === "string" ? msg.content.slice(0, 500) : null,
    tool_calls: Array.isArray(msg.tool_calls)
      ? msg.tool_calls.map((c) => ({
          id: c && c.id,
          name: c && c.function && c.function.name,
        }))
      : [],
  };
  return out;
}

module.exports = {
  asBool,
  json,
  parseJson,
  isUnsetSecret,
  chooseSecret,
  fetchWithTimeout,
  clampInt,
  hostAllowed,
  isLocalHostname,
  canonicalSegment,
  toolConfig,
  memoryConfig,
  loadMemory,
  saveMemory,
  toolSchemas,
  executeToolCall,
  openaiChat,
  summarizeAssistantMessage
};
