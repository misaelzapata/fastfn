// @summary WhatsApp session manager — QR login, send & receive messages
// @methods GET POST DELETE
// @query {"action":"status"}

const fs = require("fs");
const path = require("path");

const SESSION_DIR = path.join(__dirname, ".session");
const QR_WAIT_MS = 15000;
const CONNECT_WAIT_MS = 45000;
const RECONNECT_DELAY_MS = 2500;

// Persistent runtime state (survives across invocations within the same process)
/* c8 ignore next 4 -- module-level init */
const state = global.__fastfn_wa || {
  socket: null, connecting: false, connected: false, me: null,
  lastQr: null, lastQrAt: null, lastError: null, reconnectTimer: null,
  inbox: [], outbox: [],
};
global.__fastfn_wa = state;

// ── Helpers ──────────────────────────────────────────────────────────────

function json(status, data) {
  return { status, headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) };
}

/* c8 ignore next */
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function normalizeJid(raw) {
  if (!raw || typeof raw !== "string") throw new Error("to is required");
  const v = raw.trim();
  if (v.endsWith("@s.whatsapp.net") || v.endsWith("@g.us")) return v;
  const digits = v.replace(/\D/g, "");
  if (digits.length < 8) throw new Error("invalid WhatsApp number");
  return `${digits}@s.whatsapp.net`;
} /* c8 ignore next */

function extractText(msg) {
  const b = msg?.message;
  if (!b) return "";
  return b.conversation || b.extendedTextMessage?.text || b.imageMessage?.caption || b.videoMessage?.caption || "";
} /* c8 ignore next */

function pushLog(arr, item) {
  arr.unshift(item);
  if (arr.length > 200) arr.length = 200;
}

function statusPayload() {
  let hasSession = false;
  try { hasSession = fs.existsSync(SESSION_DIR) && fs.readdirSync(SESSION_DIR).length > 0; } catch (_) {}
  return {
    connected: state.connected, connecting: state.connecting, me: state.me,
    last_error: state.lastError, qr_available: !!state.lastQr,
    inbox_count: state.inbox.length, outbox_count: state.outbox.length, has_session: hasSession,
  };
}

// ── Baileys connection ───────────────────────────────────────────────────

let baileys = null;
let qrcodeLib = null;

async function startConnection() {
  if (state.connected || state.connecting) return;
  state.connecting = true;
  state.lastError = null;

  try {
    if (!baileys) baileys = require("@whiskeysockets/baileys");
    fs.mkdirSync(SESSION_DIR, { recursive: true });

    const { state: authState, saveCreds } = await baileys.useMultiFileAuthState(SESSION_DIR);
    let version = [2, 3000, 1015901307];
    try { const v = await baileys.fetchLatestBaileysVersion(); if (v?.version) version = v.version; } catch (_) {}

    const sock = baileys.makeWASocket({
      version, auth: authState, printQRInTerminal: false,
      browser: baileys.Browsers.macOS("FastFN"), markOnlineOnConnect: false, syncFullHistory: false,
    });
    state.socket = sock;

    sock.ev.on("creds.update", saveCreds);

    sock.ev.on("connection.update", (update) => {
      if (update.qr) { state.lastQr = update.qr; state.lastQrAt = Date.now(); }
      if (update.connection === "open") {
        Object.assign(state, { connected: true, connecting: false, me: sock.user?.id || null, lastError: null });
      }
      if (update.connection === "close") {
        const reason = update.lastDisconnect?.error?.output?.statusCode === 401 ? "logged_out"
          : (update.lastDisconnect?.error?.message || "connection_closed");
        Object.assign(state, { connected: false, connecting: false, me: null, socket: null, lastError: reason });
        if (reason !== "logged_out") {
          clearTimeout(state.reconnectTimer);
          state.reconnectTimer = setTimeout(() => startConnection().catch(() => {}), RECONNECT_DELAY_MS);
        }
      }
    });

    sock.ev.on("messages.upsert", (ev) => {
      for (const msg of ev?.messages || []) {
        const item = {
          id: msg.key?.id, from: msg.key?.remoteJid, from_me: !!msg.key?.fromMe,
          push_name: msg.pushName || null, text: extractText(msg),
          timestamp: Number(msg.messageTimestamp) || Math.floor(Date.now() / 1000),
        };
        pushLog(item.from_me ? state.outbox : state.inbox, item);
      }
    });
  } catch (err) {
    Object.assign(state, { connecting: false, connected: false, socket: null, lastError: err.message });
    throw err;
  }
}

/* c8 ignore start -- async polling; tested via integration */
async function waitFor(check, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (check()) return true; await sleep(250); }
  return false;
}

async function ensureConnected() {
  if (state.connected && state.socket) return true;
  await startConnection();
  return waitFor(() => state.connected && state.socket, CONNECT_WAIT_MS);
}
/* c8 ignore stop */ /* c8 ignore next */

async function closeConnection(logout) {
  clearTimeout(state.reconnectTimer);
  state.reconnectTimer = null;
  const sock = state.socket;
  Object.assign(state, { socket: null, connected: false, connecting: false, me: null });
  if (!sock) return;
  try { logout ? await sock.logout() : sock.end(); } catch (_) {}
}

// ── Handler ──────────────────────────────────────────────────────────────

exports.handler = async (event) => {
  const method = String(event.method || "GET").toUpperCase();
  const query = event.query || {};
  const env = event.env || {};
  let body = {};
  try {
    if (event.body) body = typeof event.body === "string" ? JSON.parse(event.body) : event.body;
  } catch (_) { return json(400, { error: "invalid JSON body" }); }

  const action = String(query.action || body.action || "intro").toLowerCase().replace(/_/g, "-");

  // GET ?action=intro — show quickstart
  if (action === "intro" && method === "GET") {
    return json(200, {
      message: "WhatsApp demo ready. Start with qr, scan, then send.",
      actions: ["intro", "status", "connect", "disconnect", "reset-session", "qr", "inbox", "send", "chat"],
      examples: {
        qr: "GET /whatsapp?action=qr&format=raw",
        send: "POST /whatsapp?action=send  {\"to\":\"15551234567\",\"text\":\"hello\"}",
        chat: "POST /whatsapp?action=chat  {\"text\":\"what is 2+2?\",\"to\":\"15551234567\"}",
      },
    });
  }

  // GET ?action=status
  if (action === "status" && method === "GET") {
    return json(200, statusPayload());
  }

  // POST ?action=connect
  if (action === "connect" && method === "POST") {
    try { await startConnection(); return json(200, { ok: true, ...statusPayload() }); }
    catch (err) { return json(500, { error: err.message, ...statusPayload() }); }
  }

  // POST/DELETE ?action=disconnect
  if (action === "disconnect") {
    await closeConnection(false);
    return json(200, { ok: true, ...statusPayload() });
  }

  // DELETE ?action=reset-session
  if (action === "reset-session" && method === "DELETE") {
    await closeConnection(true);
    try { fs.rmSync(SESSION_DIR, { recursive: true, force: true }); } catch (_) {}
    Object.assign(state, { lastQr: null, lastQrAt: null, lastError: null, inbox: [], outbox: [] });
    return json(200, { ok: true, ...statusPayload() });
  }

  // GET ?action=qr — generate QR code for WhatsApp Web login
  if (action === "qr" && method === "GET") {
    if (!state.lastQr) {
      if (!state.connected && !state.connecting) {
        try { await startConnection(); } catch (err) { return json(500, { error: err.message }); }
      }
      /* c8 ignore start -- async polling; tested via integration */
      const ready = await waitFor(() => !!state.lastQr, QR_WAIT_MS);
      if (!ready) {
        return state.connected
          ? json(409, { error: "already connected; qr not needed" })
          : json(202, { error: "qr not ready yet; retry in a few seconds" });
      }
      /* c8 ignore stop */
    }

    const format = String(query.format || "png").toLowerCase();
    if (format === "raw") return json(200, { qr: state.lastQr, last_qr_at: state.lastQrAt });

    if (!qrcodeLib) qrcodeLib = require("qrcode");
    const size = Math.max(128, Math.min(1024, Number(query.size) || 360));

    if (format === "svg") {
      const svg = await qrcodeLib.toString(state.lastQr, { type: "svg", width: size, margin: 2 });
      return { status: 200, headers: { "Content-Type": "image/svg+xml" }, body: svg };
    }
    const png = await qrcodeLib.toBuffer(state.lastQr, { type: "png", width: size, margin: 2 });
    return { status: 200, headers: { "Content-Type": "image/png" }, is_base64: true, body_base64: png.toString("base64") };
  }

  // GET ?action=inbox
  if (action === "inbox" && method === "GET") {
    const limit = Math.max(1, Math.min(200, Number(query.limit) || 50));
    return json(200, { messages: state.inbox.slice(0, limit), total: state.inbox.length });
  }

  // POST ?action=send — send a plain text message
  if (action === "send" && method === "POST") {
    const to = body.to || query.to;
    const text = body.text || query.text;
    if (!text?.trim()) return json(400, { error: "text is required" });

    if (!(await ensureConnected())) return json(409, { error: "not connected", ...statusPayload() });
    try {
      const jid = normalizeJid(to);
      const sent = await state.socket.sendMessage(jid, { text });
      pushLog(state.outbox, { id: sent?.key?.id, from: jid, from_me: true, text, timestamp: Math.floor(Date.now() / 1000) });
      return json(200, { ok: true, message_id: sent?.key?.id, to: jid });
    } catch (err) { return json(500, { error: err.message }); }
  }

  // POST ?action=chat — send user text to OpenAI, then forward AI reply via WhatsApp
  if (action === "chat" && method === "POST") {
    const userText = body.text || query.text;
    if (!userText?.trim()) return json(400, { error: "text is required" });

    const apiKey = env.OPENAI_API_KEY;
    if (!apiKey) return json(500, { error: "missing OPENAI_API_KEY" });

    // Call OpenAI
    const model = env.OPENAI_MODEL || "gpt-4o-mini";
    const systemPrompt = env.SYSTEM_PROMPT || "You are a helpful WhatsApp assistant. Be concise.";
    const aiRes = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({
        model,
        messages: [{ role: "system", content: systemPrompt }, { role: "user", content: userText }],
        max_tokens: 512,
      }),
    });
    if (!aiRes.ok) {
      const errBody = await aiRes.text();
      return json(500, { error: `OpenAI error ${aiRes.status}: ${errBody.slice(0, 200)}` });
    }
    const aiReply = (await aiRes.json()).choices[0].message.content.trim();

    // Send AI reply if a recipient is available
    const to = body.to || query.to || state.inbox[0]?.from;
    if (!to) return json(200, { ok: true, ai_reply: aiReply, sent: false, note: "no recipient set" });

    if (!(await ensureConnected())) return json(409, { error: "not connected", ai_reply: aiReply });
    try {
      const jid = normalizeJid(to);
      await state.socket.sendMessage(jid, { text: aiReply });
      return json(200, { ok: true, sent: true, to: jid, ai_reply: aiReply });
    } catch (err) { return json(500, { error: err.message, ai_reply: aiReply }); }
  }

  return json(400, { error: "unknown action", actions: ["intro","status","connect","disconnect","reset-session","qr","inbox","send","chat"] });
};
