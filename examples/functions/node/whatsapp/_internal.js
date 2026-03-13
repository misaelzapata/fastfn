const fs = require("fs");
const path = require("path");

const SESSION_DIR = path.join(__dirname, ".session");
const MAX_LOG_ITEMS = 200;
const CONNECT_WAIT_MS = 45000;
const RECONNECT_DELAY_MS = 2500;
const QR_WAIT_MS = 15000;

const runtimeState = global.__fastfn_whatsapp_runtime || {
  socket: null,
  connecting: false,
  connected: false,
  me: null,
  lastQr: null,
  lastQrAt: null,
  lastError: null,
  reconnectTimer: null,
  inbox: [],
  outbox: [],
};
global.__fastfn_whatsapp_runtime = runtimeState;

let baileys = null;
let qrcodeLib = null;

function json(status, payload, extraHeaders) {
  return {
    status,
    headers: {
      "Content-Type": "application/json",
      ...(extraHeaders || {}),
    },
    body: JSON.stringify(payload),
  };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function asBool(value, fallback = false) {
  if (value === undefined || value === null) return fallback;
  if (typeof value === "boolean") return value;
  const normalized = String(value).trim().toLowerCase();
  return !["0", "false", "off", "no"].includes(normalized);
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

function whatsappToolsConfig(query, aiOpts, env) {
  const enabled = asBool(
    query.tools ?? aiOpts.tools ?? env.WHATSAPP_TOOLS_ENABLED ?? process.env.WHATSAPP_TOOLS_ENABLED,
    false
  );
  const autoTools = asBool(
    query.auto_tools ?? aiOpts.auto_tools ?? env.WHATSAPP_AUTO_TOOLS ?? process.env.WHATSAPP_AUTO_TOOLS,
    false
  );
  const timeoutMsRaw = Number(
    query.tool_timeout_ms ??
    aiOpts.tool_timeout_ms ??
    env.WHATSAPP_TOOL_TIMEOUT_MS ??
    process.env.WHATSAPP_TOOL_TIMEOUT_MS ??
    5000
  );
  const timeoutMs = Number.isFinite(timeoutMsRaw) ? Math.max(500, Math.min(30000, Math.floor(timeoutMsRaw))) : 5000;
  const baseUrl = String(
    env.WHATSAPP_TOOL_INTERNAL_BASE_URL ||
    process.env.WHATSAPP_TOOL_INTERNAL_BASE_URL ||
    "http://127.0.0.1:8080"
  ).replace(/\/+$/, "");
  const allowedFns = String(
    query.tool_allow_fn ||
    aiOpts.tool_allow_fn ||
    env.WHATSAPP_TOOL_ALLOW_FN ||
    process.env.WHATSAPP_TOOL_ALLOW_FN ||
    "request-inspector,telegram-ai-digest,cron-tick"
  )
    .split(",")
    .map((v) => String(v).trim())
    .filter((v) => /^[A-Za-z0-9_-]+$/.test(v));
  const allowedHosts = String(
    query.tool_allow_hosts ||
    aiOpts.tool_allow_hosts ||
    env.WHATSAPP_TOOL_ALLOW_HTTP_HOSTS ||
    process.env.WHATSAPP_TOOL_ALLOW_HTTP_HOSTS ||
    "api.ipify.org,ipapi.co,wttr.in"
  )
    .split(",")
    .map((v) => String(v).trim().toLowerCase())
    .filter((v) => v.length > 0);
  return { enabled, autoTools, timeoutMs, baseUrl, allowedFns, allowedHosts };
}

function inferAutoTools(text, cfg) {
  const src = String(text || "").toLowerCase();
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
      if (!isLocalHostname(u.hostname) && hostAllowed(u.hostname, cfg.allowedHosts)) {
        picks.push({ type: "http", url: u.toString() });
      }
    } catch (_) {
      // ignore
    }
  };

  if (has("ip") || has("mi ip") || has("my ip") || has("ubicacion")) {
    addHttp("https://api.ipify.org?format=json");
  }
  if (has("clima") || has("weather") || has("temperatura") || has("forecast")) {
    addHttp("https://wttr.in/?format=j1");
  }
  if (has("noticias") || has("news") || has("digest")) {
    addFn("telegram-ai-digest", "?dry_run=true&include_ai=false");
  }

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

async function fetchWithTimeout(url, opts, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1, Number(timeoutMs) || 5000));
  try {
    return await fetch(url, { ...(opts || {}), signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function canonicalSegment(name) {
  return String(name || "")
    .trim()
    .toLowerCase()
    .replace(/_+/g, "-");
}

async function executeTool(tool, cfg) {
  if (tool.type === "fn") {
    if (!cfg.allowedFns.includes(tool.name)) {
      return { ok: false, type: "fn", name: tool.name, error: "function not allowed" };
    }
    if (!["GET", "POST", "PUT", "PATCH", "DELETE"].includes(tool.method)) {
      return { ok: false, type: "fn", name: tool.name, error: "method not allowed" };
    }
    const url = `${cfg.baseUrl}/${canonicalSegment(tool.name)}${tool.query || ""}`;
    const res = await fetchWithTimeout(url, { method: tool.method }, cfg.timeoutMs);
    const body = await res.text();
    return { ok: res.ok, type: "fn", name: tool.name, status: res.status, body: body.slice(0, 4000) };
  }
  if (tool.type === "http") {
    let parsed;
    try {
      parsed = new URL(tool.url);
    } catch (_) {
      return { ok: false, type: "http", url: tool.url, error: "invalid url" };
    }
    if (isLocalHostname(parsed.hostname)) {
      return { ok: false, type: "http", url: parsed.toString(), error: "local host not allowed" };
    }
    if (!hostAllowed(parsed.hostname, cfg.allowedHosts)) {
      return { ok: false, type: "http", url: parsed.toString(), error: "host not allowed" };
    }
    const res = await fetchWithTimeout(parsed.toString(), { method: "GET" }, cfg.timeoutMs);
    const body = await res.text();
    return { ok: res.ok, type: "http", url: parsed.toString(), status: res.status, body: body.slice(0, 4000) };
  }
  return { ok: false, error: "unknown tool type" };
}

async function resolveToolContext(inputText, query, aiOpts, env) {
  const cfg = whatsappToolsConfig(query, aiOpts, env);
  if (!cfg.enabled) return "";
  let directives = parseToolDirectives(inputText);
  if (directives.length === 0 && cfg.autoTools) {
    directives = inferAutoTools(inputText, cfg);
  }
  if (directives.length === 0) return "";
  const results = [];
  for (const tool of directives) {
    try {
      const r = await executeTool(tool, cfg);
      results.push(r);
    } catch (err) {
      results.push({
        ok: false,
        type: tool.type,
        target: tool.name || tool.url || null,
        error: String(err && err.message ? err.message : err),
      });
    }
  }
  return `\n\n[Tool results]\n${JSON.stringify(results)}`;
}

function pushLog(arr, item) {
  arr.unshift(item);
  if (arr.length > MAX_LOG_ITEMS) {
    arr.length = MAX_LOG_ITEMS;
  }
}

function sessionInfo() {
  let hasSession = false;
  let files = 0;
  try {
    if (fs.existsSync(SESSION_DIR)) {
      files = fs.readdirSync(SESSION_DIR).length;
      hasSession = files > 0;
    }
  } catch (_) {
    // Keep best-effort behavior.
  }
  return { has_session: hasSession, session_files: files };
}

function parseBody(event) {
  if (!event || typeof event !== "object") {
    return {};
  }
  if (event.body == null || event.body === "") {
    return {};
  }
  if (typeof event.body === "object") {
    return event.body;
  }
  if (typeof event.body !== "string") {
    return {};
  }
  try {
    const parsed = JSON.parse(event.body);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (_) {
    throw new Error("invalid JSON body");
  }
}

function normalizeJid(raw) {
  if (typeof raw !== "string" || raw.trim() === "") {
    throw new Error("to is required");
  }
  const value = raw.trim();
  if (value.endsWith("@s.whatsapp.net") || value.endsWith("@g.us")) {
    return value;
  }
  const digits = value.replace(/[^\d]/g, "");
  if (digits.length < 8) {
    throw new Error("invalid WhatsApp number");
  }
  return `${digits}@s.whatsapp.net`;
}

function extractMessageText(msg) {
  const body = msg && msg.message;
  if (!body || typeof body !== "object") {
    return "";
  }
  if (typeof body.conversation === "string") {
    return body.conversation;
  }
  if (body.extendedTextMessage && typeof body.extendedTextMessage.text === "string") {
    return body.extendedTextMessage.text;
  }
  if (body.imageMessage && typeof body.imageMessage.caption === "string") {
    return body.imageMessage.caption;
  }
  if (body.videoMessage && typeof body.videoMessage.caption === "string") {
    return body.videoMessage.caption;
  }
  return "";
}

function disconnectReason(lastDisconnect) {
  const err = lastDisconnect && lastDisconnect.error;
  const statusCode = err && err.output && err.output.statusCode;
  if (statusCode === 401) {
    return "logged_out";
  }
  if (err && err.message) {
    return String(err.message);
  }
  return "connection_closed";
}

function loadBaileys() {
  if (baileys) {
    return baileys;
  }
  baileys = require("@whiskeysockets/baileys");
  return baileys;
}

function loadQrCode() {
  if (qrcodeLib) {
    return qrcodeLib;
  }
  qrcodeLib = require("qrcode");
  return qrcodeLib;
}

async function startConnection() {
  if (runtimeState.connected || runtimeState.connecting) {
    return;
  }

  runtimeState.connecting = true;
  runtimeState.lastError = null;

  try {
    const lib = loadBaileys();
    fs.mkdirSync(SESSION_DIR, { recursive: true });

    const { state, saveCreds } = await lib.useMultiFileAuthState(SESSION_DIR);
    const fallbackVersion = [2, 3000, 1015901307];
    let version = fallbackVersion;
    try {
      const latest = await lib.fetchLatestBaileysVersion();
      if (latest && Array.isArray(latest.version)) {
        version = latest.version;
      }
    } catch (_) {
      // Fallback version is fine.
    }

    const sock = lib.makeWASocket({
      version,
      auth: state,
      printQRInTerminal: false,
      browser: lib.Browsers.macOS("FastFN"),
      markOnlineOnConnect: false,
      syncFullHistory: false,
    });
    runtimeState.socket = sock;

    sock.ev.on("creds.update", saveCreds);

    sock.ev.on("connection.update", (update) => {
      if (update.qr) {
        runtimeState.lastQr = update.qr;
        runtimeState.lastQrAt = Date.now();
      }

      if (update.connection === "open") {
        runtimeState.connected = true;
        runtimeState.connecting = false;
        runtimeState.me = (sock.user && sock.user.id) || null;
        runtimeState.lastError = null;
      }

      if (update.connection === "close") {
        runtimeState.connected = false;
        runtimeState.connecting = false;
        runtimeState.me = null;
        runtimeState.socket = null;
        const reason = disconnectReason(update.lastDisconnect);
        runtimeState.lastError = reason;

        if (reason !== "logged_out") {
          if (runtimeState.reconnectTimer) {
            clearTimeout(runtimeState.reconnectTimer);
          }
          runtimeState.reconnectTimer = setTimeout(() => {
            runtimeState.reconnectTimer = null;
            startConnection().catch((err) => {
              runtimeState.lastError = String(err && err.message ? err.message : err);
            });
          }, RECONNECT_DELAY_MS);
        }
      }
    });

    sock.ev.on("messages.upsert", (ev) => {
      const messages = Array.isArray(ev && ev.messages) ? ev.messages : [];
      for (const msg of messages) {
        const id = msg && msg.key && msg.key.id;
        const fromMe = !!(msg && msg.key && msg.key.fromMe);
        const from = msg && msg.key && msg.key.remoteJid;
        const pushName = msg && msg.pushName;
        const text = extractMessageText(msg);
        const ts = Number(msg && msg.messageTimestamp ? msg.messageTimestamp : 0);
        const item = {
          id: id || null,
          from: from || null,
          from_me: fromMe,
          push_name: pushName || null,
          text,
          timestamp: ts || Math.floor(Date.now() / 1000),
        };
        if (fromMe) {
          pushLog(runtimeState.outbox, item);
        } else {
          pushLog(runtimeState.inbox, item);
        }
      }
    });
  } catch (err) {
    runtimeState.connecting = false;
    runtimeState.connected = false;
    runtimeState.socket = null;
    runtimeState.lastError = String(err && err.message ? err.message : err);
    throw err;
  }
}

async function waitUntilConnected(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (runtimeState.connected && runtimeState.socket) {
      return true;
    }
    await sleep(250);
  }
  return false;
}

async function waitUntilQr(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (runtimeState.lastQr) {
      return true;
    }
    await sleep(250);
  }
  return false;
}

async function ensureConnected() {
  if (runtimeState.connected && runtimeState.socket) {
    return true;
  }
  await startConnection();
  return waitUntilConnected(CONNECT_WAIT_MS);
}

async function closeConnection(logout) {
  if (runtimeState.reconnectTimer) {
    clearTimeout(runtimeState.reconnectTimer);
    runtimeState.reconnectTimer = null;
  }
  const sock = runtimeState.socket;
  runtimeState.socket = null;
  runtimeState.connected = false;
  runtimeState.connecting = false;
  runtimeState.me = null;

  if (!sock) {
    return;
  }

  try {
    if (logout && typeof sock.logout === "function") {
      await sock.logout();
    } else if (typeof sock.end === "function") {
      sock.end();
    }
  } catch (_) {
    // Ignore close errors.
  }
}

async function generateAiText(inputText, aiOpts, env, extraContext) {
  const apiKey = env.OPENAI_API_KEY || env.AI_API_KEY;
  if (!apiKey) {
    throw new Error("missing OPENAI_API_KEY");
  }
  const model = aiOpts.model || env.OPENAI_MODEL || "gpt-4o-mini";
  const systemPrompt = aiOpts.system_prompt || env.OPENAI_SYSTEM_PROMPT || "You are a helpful assistant for WhatsApp chat.";
  const baseUrl = (env.OPENAI_BASE_URL || "https://api.openai.com/v1").replace(/\/+$/, "");

  const payload = {
    model,
    input: [
      { role: "system", content: systemPrompt },
      { role: "user", content: String(inputText || "") + (extraContext ? String(extraContext) : "") },
    ],
  };
  if (aiOpts.max_output_tokens != null) {
    payload.max_output_tokens = Number(aiOpts.max_output_tokens);
  }
  if (aiOpts.temperature != null) {
    payload.temperature = Number(aiOpts.temperature);
  }

  const res = await fetch(`${baseUrl}/responses`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`ai request failed (${res.status}): ${body.slice(0, 240)}`);
  }

  const data = await res.json();
  if (typeof data.output_text === "string" && data.output_text.trim() !== "") {
    return data.output_text.trim();
  }

  if (Array.isArray(data.output)) {
    for (const item of data.output) {
      if (!item || !Array.isArray(item.content)) {
        continue;
      }
      for (const part of item.content) {
        if (part && typeof part.text === "string" && part.text.trim() !== "") {
          return part.text.trim();
        }
      }
    }
  }

  if (Array.isArray(data.choices) && data.choices[0] && data.choices[0].message) {
    const content = data.choices[0].message.content;
    if (typeof content === "string" && content.trim() !== "") {
      return content.trim();
    }
  }

  throw new Error("ai response did not include text");
}

function statusPayload() {
  const s = sessionInfo();
  return {
    runtime: "node",
    function: "whatsapp",
    connected: runtimeState.connected,
    connecting: runtimeState.connecting,
    me: runtimeState.me,
    last_error: runtimeState.lastError,
    qr_available: !!runtimeState.lastQr,
    last_qr_at: runtimeState.lastQrAt,
    inbox_count: runtimeState.inbox.length,
    outbox_count: runtimeState.outbox.length,
    has_session: s.has_session,
    session_files: s.session_files,
  };
}

module.exports = {
  fs,
  SESSION_DIR,
  QR_WAIT_MS,
  runtimeState,
  json,
  sleep,
  asBool,
  parseToolDirectives,
  hostAllowed,
  isLocalHostname,
  whatsappToolsConfig,
  inferAutoTools,
  fetchWithTimeout,
  canonicalSegment,
  executeTool,
  resolveToolContext,
  pushLog,
  sessionInfo,
  parseBody,
  normalizeJid,
  extractMessageText,
  disconnectReason,
  loadBaileys,
  loadQrCode,
  startConnection,
  waitUntilConnected,
  waitUntilQr,
  ensureConnected,
  closeConnection,
  generateAiText,
  statusPayload
};
