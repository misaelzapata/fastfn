// @summary WhatsApp real session manager (QR + connect + send + receive + AI reply)
// @methods GET POST DELETE
// @query {"action":"status"}
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
    "request_inspector,telegram_ai_digest,cron_tick"
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
      if (hostAllowed(u.hostname, cfg.allowedHosts)) {
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
    addFn("telegram_ai_digest", "?dry_run=true&include_ai=false");
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
    return { ok: res.ok, type: "fn", name: tool.name, status: res.status, body: body.slice(0, 4000) };
  }
  if (tool.type === "http") {
    let parsed;
    try {
      parsed = new URL(tool.url);
    } catch (_) {
      return { ok: false, type: "http", url: tool.url, error: "invalid url" };
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
      browser: lib.Browsers.macOS("FastFn"),
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

exports.handler = async (event) => {
  const method = String(event.method || "GET").toUpperCase();
  const query = (event && event.query) || {};
  let body;
  try {
    body = parseBody(event);
  } catch (err) {
    return json(400, { error: String(err.message || err) });
  }
  const env = (event && event.env) || {};

  const actionRaw = (query.action || body.action || "intro");
  const action = String(actionRaw).toLowerCase().replace(/_/g, "-");

  if (action === "intro") {
    if (method !== "GET") {
      return json(405, { error: "intro requires GET" });
    }
    return json(200, {
      runtime: "node",
      function: "whatsapp",
      mode: "demo-start",
      message: "WhatsApp demo ready. Start with qr, scan, then send.",
      quickstart: [
        "GET /fn/whatsapp?action=qr",
        "GET /fn/whatsapp?action=status",
        "POST /fn/whatsapp?action=send",
        "GET /fn/whatsapp?action=inbox",
      ],
      examples: {
        qr_autostart: "curl 'http://127.0.0.1:8080/fn/whatsapp?action=qr&format=raw'",
        qr_png: "curl 'http://127.0.0.1:8080/fn/whatsapp?action=qr' --output /tmp/wa-qr.png",
        connect_optional: "curl -X POST 'http://127.0.0.1:8080/fn/whatsapp?action=connect' -H 'Content-Type: application/json' --data '{}'",
        send: "curl -X POST 'http://127.0.0.1:8080/fn/whatsapp?action=send' -H 'Content-Type: application/json' --data '{\"to\":\"15551234567\",\"text\":\"hola\"}'",
      },
      actions: ["intro", "status", "connect", "disconnect", "reset-session", "qr", "inbox", "outbox", "send", "chat"],
    });
  }

  if (action === "status") {
    if (method !== "GET") {
      return json(405, { error: "status requires GET" });
    }
    return json(200, statusPayload());
  }

  if (action === "connect") {
    if (method !== "POST") {
      return json(405, { error: "connect requires POST" });
    }
    try {
      await startConnection();
      return json(200, {
        ok: true,
        action: "connect",
        ...statusPayload(),
      });
    } catch (err) {
      return json(500, { error: String(err.message || err), ...statusPayload() });
    }
  }

  if (action === "disconnect") {
    if (method !== "POST" && method !== "DELETE") {
      return json(405, { error: "disconnect requires POST or DELETE" });
    }
    await closeConnection(false);
    return json(200, { ok: true, action: "disconnect", ...statusPayload() });
  }

  if (action === "reset-session") {
    if (method !== "DELETE") {
      return json(405, { error: "reset-session requires DELETE" });
    }
    await closeConnection(true);
    try {
      fs.rmSync(SESSION_DIR, { recursive: true, force: true });
    } catch (_) {
      // Best effort.
    }
    runtimeState.lastQr = null;
    runtimeState.lastQrAt = null;
    runtimeState.lastError = null;
    runtimeState.inbox = [];
    runtimeState.outbox = [];
    return json(200, { ok: true, action: "reset-session", ...statusPayload() });
  }

  if (action === "qr") {
    if (method !== "GET") {
      return json(405, { error: "qr requires GET" });
    }
    if (!runtimeState.lastQr) {
      if (!runtimeState.connected && !runtimeState.connecting) {
        try {
          await startConnection();
        } catch (err) {
          return json(500, { error: String(err.message || err), ...statusPayload() });
        }
      }

      const ready = await waitUntilQr(QR_WAIT_MS);
      if (!ready) {
        if (runtimeState.connected) {
          return json(409, {
            error: "already connected; qr not required",
            ...statusPayload(),
          });
        }
        return json(202, {
          error: "qr not ready yet; retry in a few seconds",
          ...statusPayload(),
        });
      }
    }

    const format = String(query.format || "png").toLowerCase();
    const sizeRaw = Number(query.size || 360);
    const size = Number.isFinite(sizeRaw) ? Math.max(128, Math.min(1024, Math.floor(sizeRaw))) : 360;

    if (format === "svg") {
      const QRCode = loadQrCode();
      const svg = await QRCode.toString(runtimeState.lastQr, { type: "svg", width: size, margin: 2 });
      return {
        status: 200,
        headers: { "Content-Type": "image/svg+xml", "Cache-Control": "no-store" },
        body: svg,
      };
    }

    if (format === "raw") {
      return json(200, {
        qr: runtimeState.lastQr,
        last_qr_at: runtimeState.lastQrAt,
      });
    }

    const QRCode = loadQrCode();
    const png = await QRCode.toBuffer(runtimeState.lastQr, { type: "png", width: size, margin: 2 });
    return {
      status: 200,
      headers: { "Content-Type": "image/png", "Cache-Control": "no-store" },
      is_base64: true,
      body_base64: png.toString("base64"),
    };
  }

  if (action === "inbox") {
    if (method !== "GET") {
      return json(405, { error: "inbox requires GET" });
    }
    const limitRaw = Number(query.limit || 50);
    const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(200, Math.floor(limitRaw))) : 50;
    return json(200, { messages: runtimeState.inbox.slice(0, limit), total: runtimeState.inbox.length });
  }

  if (action === "outbox") {
    if (method !== "GET") {
      return json(405, { error: "outbox requires GET" });
    }
    const limitRaw = Number(query.limit || 50);
    const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(200, Math.floor(limitRaw))) : 50;
    return json(200, { messages: runtimeState.outbox.slice(0, limit), total: runtimeState.outbox.length });
  }

  if (action === "send") {
    if (method !== "POST") {
      return json(405, { error: "send requires POST" });
    }
    const to = body.to || query.to;
    const text = body.text || query.text;
    if (typeof text !== "string" || text.trim() === "") {
      return json(400, { error: "text is required" });
    }

    const connected = await ensureConnected();
    if (!connected || !runtimeState.socket) {
      return json(409, { error: "whatsapp not connected yet", ...statusPayload() });
    }

    try {
      const jid = normalizeJid(to);
      const sent = await runtimeState.socket.sendMessage(jid, { text: String(text) });
      pushLog(runtimeState.outbox, {
        id: sent && sent.key ? sent.key.id || null : null,
        from: jid,
        from_me: true,
        text: String(text),
        timestamp: Math.floor(Date.now() / 1000),
      });
      return json(200, {
        ok: true,
        message_id: sent && sent.key ? sent.key.id || null : null,
        to: jid,
      });
    } catch (err) {
      return json(500, { error: String(err.message || err) });
    }
  }

  if (action === "chat") {
    if (method !== "POST") {
      return json(405, { error: "chat requires POST" });
    }
    const userText = body.text || query.text || "";
    if (typeof userText !== "string" || userText.trim() === "") {
      return json(400, { error: "text is required for AI chat" });
    }
    const aiOpts = (body.ai && typeof body.ai === "object") ? body.ai : {};

    let aiText;
    try {
      const toolContext = await resolveToolContext(userText, query, aiOpts, env);
      aiText = await generateAiText(userText, aiOpts, env, toolContext);
    } catch (err) {
      return json(500, { error: String(err.message || err) });
    }

    const toCandidate = body.to || query.to || (runtimeState.inbox[0] && runtimeState.inbox[0].from);
    if (!toCandidate) {
      return json(200, {
        ok: true,
        ai_reply: aiText,
        sent: false,
        note: "AI response generated; no recipient set",
      });
    }

    const connected = await ensureConnected();
    if (!connected || !runtimeState.socket) {
      return json(409, {
        error: "whatsapp not connected yet",
        ai_reply: aiText,
        ...statusPayload(),
      });
    }

    try {
      const jid = normalizeJid(toCandidate);
      const sent = await runtimeState.socket.sendMessage(jid, { text: aiText });
      pushLog(runtimeState.outbox, {
        id: sent && sent.key ? sent.key.id || null : null,
        from: jid,
        from_me: true,
        text: aiText,
        timestamp: Math.floor(Date.now() / 1000),
      });
      return json(200, {
        ok: true,
        sent: true,
        to: jid,
        ai_reply: aiText,
      });
    } catch (err) {
      return json(500, { error: String(err.message || err), ai_reply: aiText });
    }
  }

  return json(400, {
    error: "unknown action",
    allowed_actions: ["intro", "status", "connect", "disconnect", "reset-session", "qr", "inbox", "outbox", "send", "chat"],
  });
};
