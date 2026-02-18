// @summary Telegram webhook -> OpenAI -> Telegram reply (AI bot)
// @methods POST
// @body {"message":{"chat":{"id":123},"text":"Hola"}}
//
// This is an end-to-end demo:
// - Receive Telegram webhook updates (POST JSON)
// - Generate a reply with OpenAI (Responses API)
// - Send the reply back via Telegram Bot API
//
// Safety:
// - dry_run defaults to true (set ?dry_run=false to really send)

function asBool(value, fallback = true) {
  if (value === undefined || value === null) return fallback;
  if (typeof value === "boolean") return value;
  const normalized = String(value).trim().toLowerCase();
  return !["0", "false", "off", "no"].includes(normalized);
}

function json(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
}

function logInteraction(stage, data) {
  try {
    const line = JSON.stringify({
      t: new Date().toISOString(),
      fn: "telegram-ai-reply",
      stage,
      ...data,
    });
    console.log(line);
  } catch (_) {
    // ignore logging failures
  }
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

function isTransientNetworkError(err) {
  if (!err) return false;
  const msg = String(err && err.message ? err.message : err).toLowerCase();
  if (msg.includes("fetch failed")) return true;
  if (msg.includes("timed out")) return true;
  if (msg.includes("aborterror")) return true;
  if (msg.includes("econnreset")) return true;
  if (msg.includes("enotfound")) return true;
  if (msg.includes("eai_again")) return true;
  return false;
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

function extractTelegram(update) {
  const msg =
    (update && update.message) ||
    (update && update.edited_message) ||
    (update && update.channel_post) ||
    (update && update.edited_channel_post) ||
    null;
  if (msg) {
    return {
      chat_id: msg.chat && msg.chat.id,
      text: msg.text || msg.caption || "",
      message_id: msg.message_id || null,
    };
  }

  const cb = update && update.callback_query;
  if (cb && cb.message) {
    return {
      chat_id: cb.message.chat && cb.message.chat.id,
      text: cb.data || "",
      message_id: cb.message.message_id || null,
    };
  }

  return { chat_id: null, text: "", message_id: null };
}

function extractResponsesText(resp) {
  const output = resp && resp.output;
  if (!Array.isArray(output)) return null;
  let out = "";
  for (const item of output) {
    if (!item || item.type !== "message" || item.role !== "assistant" || !Array.isArray(item.content)) continue;
    for (const part of item.content) {
      if (part && part.type === "output_text" && typeof part.text === "string") out += part.text;
    }
  }
  return out ? out : null;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function withTransientRetry(fn, attempts, baseDelayMs) {
  const total = Math.max(1, Number(attempts) || 1);
  const base = Math.max(50, Number(baseDelayMs) || 200);
  let lastErr = null;
  for (let i = 0; i < total; i++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (!isTransientNetworkError(err) || i >= total - 1) {
        throw err;
      }
      await sleep(base * (i + 1));
    }
  }
  throw lastErr || new Error("retry failed");
}

async function fetchWithTimeout(url, opts, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1, Number(timeoutMs) || 15000));
  try {
    return await fetch(url, { ...(opts || {}), signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function telegramTimeoutMs(env) {
  const raw = env.TELEGRAM_HTTP_TIMEOUT_MS || process.env.TELEGRAM_HTTP_TIMEOUT_MS || "15000";
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 1000) return 15000;
  return Math.min(120000, Math.floor(n));
}

function thinkingConfig(env, query) {
  const enabled = asBool(
    query.show_thinking ?? env.TELEGRAM_SHOW_THINKING ?? process.env.TELEGRAM_SHOW_THINKING,
    false
  );
  const mode = String(
    query.thinking_mode ||
    env.TELEGRAM_THINKING_MODE ||
    process.env.TELEGRAM_THINKING_MODE ||
    "typing"
  ).toLowerCase();
  const text = String(
    query.thinking_text ||
    env.TELEGRAM_THINKING_TEXT ||
    process.env.TELEGRAM_THINKING_TEXT ||
    "Escribiendo..."
  );
  const fallbackText = asBool(
    query.thinking_fallback_text ?? env.TELEGRAM_THINKING_FALLBACK_TEXT ?? process.env.TELEGRAM_THINKING_FALLBACK_TEXT,
    false
  );
  const minMsRaw = Number(
    query.thinking_min_ms ??
    env.TELEGRAM_THINKING_MIN_MS ??
    process.env.TELEGRAM_THINKING_MIN_MS ??
    600
  );
  const minMs = Number.isFinite(minMsRaw) ? Math.max(0, Math.min(5000, Math.floor(minMsRaw))) : 600;
  return { enabled, mode, text, fallbackText, minMs };
}

function memoryConfig(query) {
  const enabled = query.memory === undefined ? true : asBool(query.memory, true);
  const maxTurns = Math.max(0, Math.min(40, Number(query.memory_max_turns || 8)));
  const ttlSecs = Math.max(0, Math.min(86400, Number(query.memory_ttl_secs || 3600)));
  return { enabled, maxTurns, ttlSecs };
}

function toolConfig(env, query) {
  const enabled = asBool(
    query.tools ?? env.TELEGRAM_TOOLS_ENABLED ?? process.env.TELEGRAM_TOOLS_ENABLED,
    false
  );
  const autoTools = asBool(
    query.auto_tools ?? env.TELEGRAM_AUTO_TOOLS ?? process.env.TELEGRAM_AUTO_TOOLS,
    false
  );
  const timeoutMsRaw = Number(
    query.tool_timeout_ms ??
    env.TELEGRAM_TOOL_TIMEOUT_MS ??
    process.env.TELEGRAM_TOOL_TIMEOUT_MS ??
    20000
  );
  const timeoutMs = Number.isFinite(timeoutMsRaw) ? Math.max(500, Math.min(60000, Math.floor(timeoutMsRaw))) : 20000;
  const baseUrl = String(
    env.TELEGRAM_TOOL_INTERNAL_BASE_URL ||
    process.env.TELEGRAM_TOOL_INTERNAL_BASE_URL ||
    "http://127.0.0.1:8080"
  ).replace(/\/+$/, "");
  const allowedFns = String(
    query.tool_allow_fn ||
    env.TELEGRAM_TOOL_ALLOW_FN ||
    process.env.TELEGRAM_TOOL_ALLOW_FN ||
    "telegram-ai-digest,request-inspector,cron-tick"
  )
    .split(",")
    .map((v) => String(v).trim())
    .filter((v) => /^[A-Za-z0-9_-]+$/.test(v));
  const allowedHosts = String(
    query.tool_allow_hosts ||
    env.TELEGRAM_TOOL_ALLOW_HTTP_HOSTS ||
    process.env.TELEGRAM_TOOL_ALLOW_HTTP_HOSTS ||
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
  return out.slice(0, 5);
}

function inferAutoTools(text, cfg) {
  const rawText = String(text || "");
  const src = rawText.toLowerCase();
  const picks = [];
  const has = (s) => src.includes(s);
  const isCapabilitiesQuestion =
    has("herramient") ||
    has("tools") ||
    has("capacidades") ||
    has("que puedes") ||
    has("qué puedes") ||
    has("what can you do") ||
    has("what tools");

  // Do not call tools for capability/help questions. Just answer descriptively.
  if (isCapabilitiesQuestion) {
    return [];
  }
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
  if (has("ip") || has("mi ip") || has("my ip") || has("where am i") || has("ubicacion")) {
    addHttp("https://api.ipify.org?format=json");
  }

  // Weather helper
  if (has("clima") || has("weather") || has("temperatura") || has("forecast")) {
    // Placeholder resolved later by AI planner (with regex fallback).
    addHttp("https://wttr.in/?format=3");
  }

  // News digest helper
  if (has("noticias") || has("news") || has("digest") || has("resumen diario")) {
    addFn("telegram-ai-digest", "?preview=true&include_ai=false&include_news=true&include_weather=false");
  }

  // Internal request inspection helper
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
  return unique.slice(0, 5);
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

async function executeTool(tool, cfg) {
  if (tool.type === "fn") {
    if (!cfg.allowedFns.includes(tool.name)) {
      return { ok: false, type: "fn", name: tool.name, error: "function not allowed" };
    }
    if (!["GET", "POST", "PUT", "PATCH", "DELETE"].includes(tool.method)) {
      return { ok: false, type: "fn", name: tool.name, error: "method not allowed" };
    }
    const url = `${cfg.baseUrl}/fn/${tool.name}${tool.query || ""}`;
    const res = await fetchWithTimeout(url, { method: tool.method }, cfg.timeoutMs);
    const body = await res.text();
    return {
      ok: res.ok,
      type: "fn",
      name: tool.name,
      status: res.status,
      body: body.slice(0, 4000),
    };
  }

  if (tool.type === "http") {
    let parsed;
    try {
      parsed = new URL(tool.url);
    } catch (_) {
      return { ok: false, type: "http", url: tool.url, error: "invalid url" };
    }
    if (isLocalHostname(parsed.hostname)) {
      return { ok: false, type: "http", url: tool.url, error: "local host not allowed" };
    }
    if (!hostAllowed(parsed.hostname, cfg.allowedHosts)) {
      return { ok: false, type: "http", url: tool.url, error: "host not allowed" };
    }
    const res = await fetchWithTimeout(parsed.toString(), { method: "GET" }, cfg.timeoutMs);
    const body = await res.text();
    return {
      ok: res.ok,
      type: "http",
      url: parsed.toString(),
      status: res.status,
      body: body.slice(0, 4000),
    };
  }

  return { ok: false, error: "unknown tool type" };
}

async function resolveToolContext(text, env, query, requestId) {
  const cfg = toolConfig(env, query);
  if (!cfg.enabled) return "";
  let directives = parseToolDirectives(text);
  if (directives.length === 0 && cfg.autoTools) {
    directives = inferAutoTools(text, cfg);
    directives = await resolveAutoToolDirectives(directives, text, env, cfg);
    if (directives.length > 0) {
      logInteraction("tool_plan_auto", {
        request_id: requestId,
        count: directives.length,
      });
    }
  }
  if (directives.length === 0) return "";
  const results = [];
  for (const tool of directives) {
    try {
      const result = await executeTool(tool, cfg);
      results.push(result);
      logInteraction("tool_result", {
        request_id: requestId,
        tool: tool.type,
        target: tool.name || tool.url || null,
        ok: result.ok === true,
        status: result.status || null,
      });
    } catch (err) {
      results.push({
        ok: false,
        type: tool.type,
        target: tool.name || tool.url || null,
        error: String(err && err.message ? err.message : err),
      });
      logInteraction("tool_error", {
        request_id: requestId,
        tool: tool.type,
        target: tool.name || tool.url || null,
        error: String(err && err.message ? err.message : err),
      });
    }
  }
  if (results.some((r) => r && r.ok === true)) {
    return `\n\n[Tool results]\n${JSON.stringify(results)}\n\n[Tool instruction]\nUse the successful tool results as the primary source of truth for this turn. Do not claim lack of real-time access when tool data is present.`;
  }
  return `\n\n[Tool results]\n${JSON.stringify(results)}\n\n[Tool instruction]\nTool execution failed for this turn. Explain the specific tool failure briefly and ask the user to retry.`;
}

function extractOpenAIMessageText(raw) {
  const parsed = parseJson(raw);
  return (
    parsed &&
    parsed.choices &&
    parsed.choices[0] &&
    parsed.choices[0].message &&
    typeof parsed.choices[0].message.content === "string"
  )
    ? parsed.choices[0].message.content
    : "";
}

function sanitizeLocation(input) {
  const value = String(input || "").trim().replace(/\s+/g, " ");
  if (!value) return "";
  if (value.length > 64) return "";
  if (!/^[\p{L}\p{N}\s,.'-]+$/u.test(value)) return "";
  return value;
}

async function planWeatherLocationWithAI(env, userText, timeoutMs) {
  const apiKey = chooseSecret(env.OPENAI_API_KEY, process.env.OPENAI_API_KEY);
  if (!apiKey) return "";
  const baseUrl = String(env.OPENAI_BASE_URL || process.env.OPENAI_BASE_URL || "https://api.openai.com/v1").replace(/\/+$/, "");
  const model = String(env.OPENAI_TOOL_MODEL || env.OPENAI_MODEL || process.env.OPENAI_MODEL || "gpt-4o-mini");
  const payload = {
    model,
    messages: [
      {
        role: "system",
        content:
          "Extract only the location requested for weather. Return strict JSON object: {\"location\":\"...\"}. If none, return {\"location\":\"\"}.",
      },
      { role: "user", content: String(userText || "") },
    ],
  };
  try {
    const res = await fetchWithTimeout(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(payload),
    }, Math.max(1200, Math.min(8000, Number(timeoutMs) || 3000)));
    if (!res.ok) return "";
    const raw = await res.text();
    const content = extractOpenAIMessageText(raw);
    const maybe = parseJson(content);
    if (!maybe || typeof maybe !== "object") return "";
    return sanitizeLocation(maybe.location);
  } catch (_) {
    return "";
  }
}

async function resolveAutoToolDirectives(directives, userText, env, cfg) {
  if (!Array.isArray(directives) || directives.length === 0) return directives || [];
  let aiWeatherLocation = null;
  const out = [];
  for (const tool of directives) {
    if (!tool || tool.type !== "http" || typeof tool.url !== "string") {
      out.push(tool);
      continue;
    }
    if (!tool.url.startsWith("https://wttr.in/?format=3")) {
      out.push(tool);
      continue;
    }
    if (aiWeatherLocation === null) {
      aiWeatherLocation = await planWeatherLocationWithAI(env, userText, cfg.timeoutMs);
      if (!aiWeatherLocation) {
        aiWeatherLocation = extractWeatherLocation(userText);
      }
    }
    if (aiWeatherLocation) {
      out.push({ ...tool, url: `https://wttr.in/${encodeURIComponent(aiWeatherLocation)}?format=3` });
    } else {
      out.push(tool);
    }
  }
  return out;
}

function memoryPath() {
  return process.env.FASTFN_MEMORY_PATH || require("path").join(__dirname, ".memory.json");
}

function loopStatePath() {
  return process.env.FASTFN_TELEGRAM_LOOP_STATE || require("path").join(__dirname, ".loop_state.json");
}

function loopLockPath() {
  return process.env.FASTFN_TELEGRAM_LOOP_LOCK || require("path").join(__dirname, ".loop.lock");
}

function tryAcquireLoopLock(maxAgeSecs) {
  const fs = require("fs");
  const path = loopLockPath();
  const now = Date.now();

  attempt:
  for (let i = 0; i < 2; i++) {
    try {
      const fd = fs.openSync(path, "wx");
      fs.writeFileSync(fd, JSON.stringify({ ts: now, pid: process.pid }));
      return { path, fd };
    } catch (err) {
      if (!err || err.code !== "EEXIST") {
        return null;
      }
      try {
        const raw = fs.readFileSync(path, "utf8");
        const parsed = parseJson(raw) || {};
        const ts = Number(parsed.ts || 0);
        if (ts > 0 && (now - ts) / 1000 > Math.max(10, Number(maxAgeSecs || 180))) {
          fs.unlinkSync(path);
          continue attempt;
        }
      } catch (_) {
        try {
          fs.unlinkSync(path);
          continue attempt;
        } catch (__e) {
          return null;
        }
      }
      return null;
    }
  }
  return null;
}

function releaseLoopLock(lock) {
  if (!lock) return;
  const fs = require("fs");
  try {
    if (typeof lock.fd === "number") fs.closeSync(lock.fd);
  } catch (_) {
    // ignore
  }
  try {
    if (lock.path) fs.unlinkSync(lock.path);
  } catch (_) {
    // ignore
  }
}

function loadLoopState() {
  const fs = require("fs");
  const path = loopStatePath();
  let raw = "";
  try {
    raw = fs.readFileSync(path, "utf8");
  } catch (_) {
    return { last_update_id: null };
  }
  const parsed = parseJson(raw);
  if (!parsed || typeof parsed !== "object") {
    return { last_update_id: null };
  }
  const id = Number(parsed.last_update_id);
  if (!Number.isFinite(id) || id < 0) {
    return { last_update_id: null };
  }
  return { last_update_id: Math.floor(id) };
}

function saveLoopState(lastUpdateId) {
  const fs = require("fs");
  const path = loopStatePath();
  const value = Number(lastUpdateId);
  if (!Number.isFinite(value) || value < 0) {
    return;
  }
  const payload = { last_update_id: Math.floor(value), ts: Date.now() };
  try {
    fs.writeFileSync(path, JSON.stringify(payload, null, 2));
  } catch (_) {
    // Best effort; do not fail the invocation if state file cannot be written.
  }
}

function loadMemory(chatId, cfg) {
  if (!cfg.enabled || !chatId) return [];
  const fs = require("fs");
  const path = memoryPath();
  let raw = "";
  try {
    raw = fs.readFileSync(path, "utf8");
  } catch (_) {
    return [];
  }
  const data = parseJson(raw);
  if (!data || typeof data !== "object") return [];
  const list = Array.isArray(data[chatId]) ? data[chatId] : [];
  const now = Date.now();
  const ttlMs = cfg.ttlSecs * 1000;
  const filtered = list.filter((item) => {
    if (!item || typeof item !== "object") return false;
    if (typeof item.ts !== "number" || typeof item.role !== "string" || typeof item.text !== "string") return false;
    if (ttlMs > 0 && now - item.ts > ttlMs) return false;
    return true;
  });
  return filtered.slice(-cfg.maxTurns * 2);
}

function saveMemory(chatId, cfg, messages) {
  if (!cfg.enabled || !chatId) return;
  const fs = require("fs");
  const path = memoryPath();
  let data = {};
  try {
    data = parseJson(fs.readFileSync(path, "utf8")) || {};
  } catch (_) {
    data = {};
  }
  if (!data || typeof data !== "object") data = {};
  data[chatId] = messages.slice(-cfg.maxTurns * 2);
  fs.writeFileSync(path, JSON.stringify(data, null, 2));
}

async function openaiGenerate(env, userText, timeoutMs, history, extraContext) {
  const apiKey = chooseSecret(env.OPENAI_API_KEY, process.env.OPENAI_API_KEY);
  if (!apiKey) throw new Error("OPENAI_API_KEY not configured");
  const baseUrl = String(env.OPENAI_BASE_URL || process.env.OPENAI_BASE_URL || "https://api.openai.com/v1").replace(/\/+$/, "");
  const model = String(env.OPENAI_MODEL || process.env.OPENAI_MODEL || "gpt-4o-mini");
  const systemBase = String(
    env.OPENAI_SYSTEM_PROMPT ||
    process.env.OPENAI_SYSTEM_PROMPT ||
    "You are a concise assistant. Reply in the same language as the user."
  );
  const nowUtc = new Date().toISOString();
  const system = [
    systemBase,
    "You can use tool data for IP, weather, and internal summaries when explicitly asked.",
    "For capability/help questions, answer directly without pretending you executed tools.",
    "Use the conversation history when the user asks follow-up questions.",
    "Do not claim you cannot remember previous messages when history is available.",
    "If prior messages are present, never claim you cannot remember previous messages.",
    "Do not say you lack memory of earlier messages in this chat unless history is truly empty.",
    "If the user message includes a [Tool results] JSON block, treat it as trusted real-time context for this turn.",
    "When [Tool results] is present, use it directly and do not say you cannot access real-time data.",
    "If tool results include an IP, weather, location, or digest payload, answer from that payload first.",
    "If you are not sure, say so briefly instead of inventing facts.",
    `Current UTC datetime: ${nowUtc}`,
  ].join("\n");

  const messages = [
    { role: "system", content: system },
  ];
  if (Array.isArray(history)) {
    for (const m of history) {
      if (!m || (m.role !== "user" && m.role !== "assistant") || typeof m.text !== "string") continue;
      messages.push({ role: m.role, content: m.text });
    }
  }
  const finalUserText = String(userText || "") + (extraContext ? String(extraContext) : "");
  messages.push({ role: "user", content: finalUserText });

  const payload = { model, messages };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1, timeoutMs || 8000));
  try {
    const res = await fetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    const raw = await res.text();
    if (!res.ok) throw new Error(`openai error status=${res.status} body=${raw}`);
    const parsed = parseJson(raw);
    const text = parsed && parsed.choices && parsed.choices[0] && parsed.choices[0].message && parsed.choices[0].message.content;
    if (!text) throw new Error("openai returned no text");
    return { text, raw: parsed };
  } finally {
    clearTimeout(timer);
  }
}

async function telegramGetUpdates(env, offset) {
  const token = chooseSecret(env.TELEGRAM_BOT_TOKEN, process.env.TELEGRAM_BOT_TOKEN);
  if (!token) throw new Error("TELEGRAM_BOT_TOKEN not configured");
  const apiBase = String(env.TELEGRAM_API_BASE || process.env.TELEGRAM_API_BASE || "https://api.telegram.org").replace(/\/+$/, "");

  const url = new URL(`${apiBase}/bot${token}/getUpdates`);
  if (offset !== null && offset !== undefined) {
    url.searchParams.set("offset", String(offset));
  }
  const res = await fetchWithTimeout(url.toString(), { method: "GET" }, telegramTimeoutMs(env));
  const raw = await res.text();
  const parsed = parseJson(raw) || { raw };
  if (!res.ok || parsed.ok !== true) {
    const code = parsed && parsed.error_code ? parsed.error_code : res.status;
    const desc = parsed && parsed.description ? parsed.description : raw;
    const err = new Error(`telegram getUpdates failed status=${code} body=${desc}`);
    err.code = code;
    throw err;
  }
  return parsed;
}

async function telegramDeleteWebhook(env) {
  const token = chooseSecret(env.TELEGRAM_BOT_TOKEN, process.env.TELEGRAM_BOT_TOKEN);
  if (!token) throw new Error("TELEGRAM_BOT_TOKEN not configured");
  const apiBase = String(env.TELEGRAM_API_BASE || process.env.TELEGRAM_API_BASE || "https://api.telegram.org").replace(/\/+$/, "");
  const url = `${apiBase}/bot${token}/deleteWebhook?drop_pending_updates=false`;
  const res = await fetchWithTimeout(url, { method: "POST" }, telegramTimeoutMs(env));
  const raw = await res.text();
  const parsed = parseJson(raw) || { raw };
  if (!res.ok || parsed.ok !== true) {
    throw new Error(`telegram deleteWebhook failed status=${res.status} body=${raw}`);
  }
  return parsed;
}

async function telegramSend(env, chatId, text, replyToMessageId) {
  const token = chooseSecret(env.TELEGRAM_BOT_TOKEN, process.env.TELEGRAM_BOT_TOKEN);
  if (!token) throw new Error("TELEGRAM_BOT_TOKEN not configured");
  const apiBase = String(env.TELEGRAM_API_BASE || process.env.TELEGRAM_API_BASE || "https://api.telegram.org").replace(/\/+$/, "");

  const body = {
    chat_id: String(chatId),
    text: String(text || ""),
  };
  if (replyToMessageId) body.reply_to_message_id = replyToMessageId;

  const res = await fetchWithTimeout(`${apiBase}/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }, telegramTimeoutMs(env));
  const raw = await res.text();
  const parsed = parseJson(raw) || { raw };
  if (!res.ok || parsed.ok !== true) {
    throw new Error(`telegram send failed status=${res.status} body=${raw}`);
  }
  return parsed;
}

async function telegramSendTypingAction(env, chatId) {
  const token = chooseSecret(env.TELEGRAM_BOT_TOKEN, process.env.TELEGRAM_BOT_TOKEN);
  if (!token) throw new Error("TELEGRAM_BOT_TOKEN not configured");
  const apiBase = String(env.TELEGRAM_API_BASE || process.env.TELEGRAM_API_BASE || "https://api.telegram.org").replace(/\/+$/, "");
  const body = {
    chat_id: String(chatId),
    action: "typing",
  };
  const res = await fetchWithTimeout(`${apiBase}/bot${token}/sendChatAction`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }, telegramTimeoutMs(env));
  const raw = await res.text();
  const parsed = parseJson(raw) || { raw };
  if (!res.ok || parsed.ok !== true) {
    throw new Error(`telegram sendChatAction failed status=${res.status} body=${raw}`);
  }
  return parsed;
}

exports.handler = async (event) => {
  const env = event.env || {};
  const ctx = event.context || {};
  const query = event.query || {};
  const isScheduledCall = !!(ctx && ctx.trigger && ctx.trigger.type === "schedule");
  const requestId = (ctx && ctx.request_id) || event.id || null;
  logInteraction("start", {
    request_id: requestId,
    scheduled: isScheduledCall,
    method: event.method || null,
  });

  const dryRun = asBool(query.dry_run, true);

  const update = parseJson(event.body);
  const hasWebhookUpdate = !!update;

  // Optional: full loop mode (self-contained)
  // POST /fn/telegram-ai-reply?mode=loop&chat_id=123&prompt=Hola
  // If no webhook update is provided and chat_id is present, we default to loop mode.
  const modeRaw = String(query.mode || query.action || "").trim().toLowerCase();
  const wantsSingle = modeRaw === "reply" || modeRaw === "single" || modeRaw === "once";
  const wantsLoop = modeRaw === "loop" || asBool(query.loop, false);
  const loopEnabled = asBool(env.TELEGRAM_LOOP_ENABLED ?? process.env.TELEGRAM_LOOP_ENABLED, false);
  const loopToken = chooseSecret(env.TELEGRAM_LOOP_TOKEN, process.env.TELEGRAM_LOOP_TOKEN);

  if (wantsLoop) {
    if (!loopEnabled) {
      return json(403, { error: "loop mode disabled" });
    }
    if (loopToken && !isScheduledCall) {
      const provided = String(query.loop_token || query.loopToken || "");
      if (provided !== loopToken) {
        logInteraction("denied", {
          request_id: requestId,
          reason: "invalid_loop_token",
        });
        return json(403, { error: "invalid loop token" });
      }
    }
    const chatId = query.chat_id || query.chatId || env.TELEGRAM_CHAT_ID || process.env.TELEGRAM_CHAT_ID;
    const allChatsMode = !chatId;
    const prompt = String(query.prompt || query.prompt_text || query.text || "fastfn: responde y te contesto con IA");
    const sendPrompt = asBool(
      query.send_prompt,
      isScheduledCall
        ? asBool(env.TELEGRAM_LOOP_SEND_PROMPT_ON_SCHEDULE ?? process.env.TELEGRAM_LOOP_SEND_PROMPT_ON_SCHEDULE, false)
        : true
    );
    const waitSecs = Math.max(5, Math.min(120, Number(query.wait_secs || query.wait_s || 60)));
    const pollMs = Math.max(300, Math.min(5000, Number(query.poll_ms || 2000)));
    const maxReplies = Math.max(1, Math.min(50, Number(query.max_replies || query.max_msgs || 5)));
    const memCfg = memoryConfig(query);
    const forceClearWebhook = asBool(query.force_clear_webhook, false);
    const thinkCfg = thinkingConfig(env, query);

      if (dryRun) {
        logInteraction("dry_run_loop", {
          request_id: requestId,
          chat_id: chatId ? Number(chatId) : null,
          all_chats_mode: allChatsMode,
          send_prompt: sendPrompt,
        });
        return json(200, {
          ok: true,
          dry_run: true,
          mode: "loop",
          chat_id: chatId ? Number(chatId) : null,
          all_chats_mode: allChatsMode,
          send_prompt: sendPrompt,
          prompt,
          wait_secs: waitSecs,
          max_replies: maxReplies,
          note: allChatsMode
            ? "Set ?dry_run=false to poll Telegram updates and auto-reply to new text messages."
            : "Set ?dry_run=false to send prompt, wait for replies, and answer with OpenAI.",
        });
      }

    try {
      const loopLock = tryAcquireLoopLock(waitSecs + 60);
      if (!loopLock) {
        logInteraction("loop_skipped", {
          request_id: requestId,
          reason: "in_progress",
        });
        return json(isScheduledCall ? 200 : 409, {
          ok: isScheduledCall,
          skipped: true,
          reason: "in_progress",
          mode: "loop",
        });
      }

      try {
      if (!allChatsMode && sendPrompt && prompt) {
        await telegramSend(env, chatId, prompt, null);
      }

      const start = Date.now();
      const loopState = loadLoopState();
      let lastId = Number.isFinite(loopState.last_update_id) ? loopState.last_update_id : -1;
      try {
        if (forceClearWebhook) {
          await telegramDeleteWebhook(env);
        }
        if (lastId < 0) {
          const seed = await telegramGetUpdates(env);
          const res = Array.isArray(seed.result) ? seed.result : [];
          if (res.length > 0 && res[res.length - 1].update_id !== undefined) {
            lastId = res[res.length - 1].update_id;
            saveLoopState(lastId);
          }
        }
      } catch (err) {
        if (err && err.code === 409) {
          return json(isScheduledCall ? 200 : 409, {
            error: "getUpdates conflict (another polling client or webhook is active)",
            skipped: isScheduledCall,
            hint: "Stop other getUpdates clients or call with ?force_clear_webhook=true to clear webhook.",
          });
        }
        // ignore initial seed errors; we'll retry below
      }

      let repliesSent = 0;
      const handled = new Set();
      let transientErrors = 0;
      while ((Date.now() - start) / 1000 < waitSecs) {
        let updates;
        try {
          updates = await telegramGetUpdates(env, lastId >= 0 ? lastId + 1 : undefined);
        } catch (err) {
          if (err && err.code === 409) {
            return json(isScheduledCall ? 200 : 409, {
              error: "getUpdates conflict (another polling client or webhook is active)",
              skipped: isScheduledCall,
              hint: "Stop other getUpdates clients or call with ?force_clear_webhook=true to clear webhook.",
            });
          }
          transientErrors += 1;
          logInteraction("poll_error", {
            request_id: requestId,
            error: String(err && err.message ? err.message : err),
            transient: isTransientNetworkError(err),
            transient_errors: transientErrors,
          });
          await sleep(Math.min(5000, pollMs * 2));
          continue;
        }
        if (!updates) {
          continue;
        }
        const res = Array.isArray(updates.result) ? updates.result : [];
        for (const item of res) {
          if (item && typeof item.update_id === "number") {
            lastId = item.update_id;
          }
          const msg = (item && (item.message || item.edited_message)) || null;
          const chat = msg && msg.chat;
          const text = msg && (msg.text || msg.caption || "");
          const msgId = msg && (msg.message_id || null);
          if (msg && msg.from && msg.from.is_bot === true) {
            continue;
          }
          if (chat && text && (allChatsMode || String(chat.id) === String(chatId))) {
            const dedupeKey = String(item.update_id || msgId || "");
            if (dedupeKey && handled.has(dedupeKey)) {
              continue;
            }
            if (dedupeKey) handled.add(dedupeKey);
            const activeChatId = String(chat.id);
            const history = loadMemory(activeChatId, memCfg);
            if (thinkCfg.enabled && thinkCfg.text) {
              try {
                if (thinkCfg.mode === "text") {
                  await telegramSend(env, activeChatId, thinkCfg.text, msgId || null);
                } else {
                  try {
                    await telegramSendTypingAction(env, activeChatId);
                  } catch (typingErr) {
                    if (isTransientNetworkError(typingErr)) {
                      await sleep(250);
                      await telegramSendTypingAction(env, activeChatId);
                    } else {
                      throw typingErr;
                    }
                  }
                  if (thinkCfg.minMs > 0) {
                    await sleep(thinkCfg.minMs);
                  }
                }
              } catch (err) {
                logInteraction("thinking_error", {
                  request_id: requestId,
                  chat_id: Number(activeChatId),
                  error: String(err && err.message ? err.message : err),
                });
                if (thinkCfg.mode !== "text" && thinkCfg.fallbackText) {
                  try {
                    await telegramSend(env, activeChatId, thinkCfg.text, msgId || null);
                  } catch (_) {
                    // Best effort only; do not fail main reply path.
                  }
                }
              }
            }
            const toolContext = await resolveToolContext(text, env, query, requestId);
            let reply = "";
            let sent = null;
            try {
              const gen = await withTransientRetry(
                () => openaiGenerate(
                  env,
                  text,
                  Math.min(15000, ctx.timeout_ms || 8000),
                  history,
                  toolContext
                ),
                3,
                300
              );
              reply = gen.text.trim().slice(0, 3000);
              sent = await withTransientRetry(
                () => telegramSend(env, activeChatId, reply, msgId || null),
                3,
                250
              );
            } catch (err) {
              transientErrors += 1;
              logInteraction("reply_error", {
                request_id: requestId,
                chat_id: Number(activeChatId),
                update_id: item.update_id || null,
                error: String(err && err.message ? err.message : err),
                transient: isTransientNetworkError(err),
                transient_errors: transientErrors,
              });
              continue;
            }
            // Persist right after a successful send so transient errors later in the
            // loop do not reprocess the same Telegram update on the next scheduler run.
            saveLoopState(lastId);
            if (memCfg.enabled) {
              const now = Date.now();
              history.push({ role: "user", text: String(text), ts: now });
              history.push({ role: "assistant", text: String(reply), ts: now });
              saveMemory(activeChatId, memCfg, history);
            }
            repliesSent += 1;
            logInteraction("loop_replied", {
              request_id: requestId,
              chat_id: Number(activeChatId),
              update_id: item.update_id || null,
              message_id: msgId || null,
              replies_sent: repliesSent,
            });
            if (repliesSent >= maxReplies) {
              saveLoopState(lastId);
              return json(200, {
                ok: true,
                dry_run: false,
                mode: "loop",
                chat_id: allChatsMode ? null : Number(chatId),
                all_chats_mode: allChatsMode,
                replies_sent: repliesSent,
                reply_preview: reply,
                telegram: { message_id: sent.result && sent.result.message_id },
              });
            }
          }
        }
        await sleep(pollMs);
      }

      saveLoopState(lastId);
      logInteraction("loop_timeout", {
        request_id: requestId,
        chat_id: allChatsMode ? null : Number(chatId),
        replies_sent: repliesSent,
      });
      return json(isScheduledCall ? 200 : 504, {
        ok: isScheduledCall,
        skipped: isScheduledCall,
        error: "timeout waiting for reply",
        mode: "loop",
        chat_id: allChatsMode ? null : Number(chatId),
        all_chats_mode: allChatsMode,
        replies_sent: repliesSent,
        transient_errors: transientErrors,
      });
      } finally {
        releaseLoopLock(loopLock);
      }
      
    } catch (err) {
      logInteraction("loop_error", {
        request_id: requestId,
        error: String(err && err.message ? err.message : err),
      });
      return json(502, { error: String(err && err.message ? err.message : err), mode: "loop" });
    }
  }

  // Accept a real Telegram update via body (webhook style),
  // or a simple query-mode for manual E2E without setting a webhook:
  //   POST /fn/telegram-ai-reply?chat_id=123&text=Hola
  let t = null;
  if (update) {
    t = extractTelegram(update);
  } else {
    const chatId = query.chat_id || query.chatId;
    const text = query.text;
    t = {
      chat_id: chatId != null ? Number(chatId) : null,
      text: text != null ? String(text) : "",
      message_id: null,
    };
  }
  if (!t.chat_id) {
    return json(200, { ok: true, note: "no chat_id provided; nothing to do" });
  }
  if (!t.text) {
    return json(200, { ok: true, chat_id: t.chat_id, note: "no text in update; nothing to do" });
  }

  if (dryRun) {
    logInteraction("dry_run_reply", {
      request_id: requestId,
      chat_id: Number(t.chat_id),
    });
    return json(200, {
      ok: true,
      dry_run: true,
      chat_id: t.chat_id,
      received_text: t.text,
      note: "Set ?dry_run=false and configure TELEGRAM_BOT_TOKEN + OPENAI_API_KEY to enable sending.",
    });
  }

  try {
    const memCfg = memoryConfig(query);
    const thinkCfg = thinkingConfig(env, query);
    const history = loadMemory(String(t.chat_id), memCfg);
    if (thinkCfg.enabled && thinkCfg.text) {
      try {
        if (thinkCfg.mode === "text") {
          await telegramSend(env, t.chat_id, thinkCfg.text, t.message_id);
        } else {
          try {
            await telegramSendTypingAction(env, t.chat_id);
          } catch (typingErr) {
            if (isTransientNetworkError(typingErr)) {
              await sleep(250);
              await telegramSendTypingAction(env, t.chat_id);
            } else {
              throw typingErr;
            }
          }
          if (thinkCfg.minMs > 0) {
            await sleep(thinkCfg.minMs);
          }
        }
      } catch (err) {
        logInteraction("thinking_error", {
          request_id: requestId,
          chat_id: Number(t.chat_id),
          error: String(err && err.message ? err.message : err),
        });
        if (thinkCfg.mode !== "text" && thinkCfg.fallbackText) {
          try {
            await telegramSend(env, t.chat_id, thinkCfg.text, t.message_id);
          } catch (_) {
            // Best effort only; do not fail main reply path.
          }
        }
      }
    }
    const toolContext = await resolveToolContext(t.text, env, query, requestId);
    const gen = await withTransientRetry(
      () => openaiGenerate(
        env,
        t.text,
        Math.min(15000, ctx.timeout_ms || 8000),
        history,
        toolContext
      ),
      3,
      300
    );
    const reply = gen.text.trim().slice(0, 3000);
    const sent = await withTransientRetry(
      () => telegramSend(env, t.chat_id, reply, t.message_id),
      3,
      250
    );
    if (memCfg.enabled) {
      const now = Date.now();
      history.push({ role: "user", text: String(t.text), ts: now });
      history.push({ role: "assistant", text: String(reply), ts: now });
      saveMemory(String(t.chat_id), memCfg, history);
    }
    logInteraction("reply_sent", {
      request_id: requestId,
      chat_id: Number(t.chat_id),
      message_id: sent.result && sent.result.message_id,
    });
    return json(200, {
      ok: true,
      dry_run: false,
      chat_id: t.chat_id,
      reply_preview: reply,
      telegram: { message_id: sent.result && sent.result.message_id },
    });
  } catch (err) {
    logInteraction("reply_error", {
      request_id: requestId,
      chat_id: Number(t.chat_id),
      error: String(err && err.message ? err.message : err),
    });
    return json(502, { error: String(err && err.message ? err.message : err) });
  }
};
