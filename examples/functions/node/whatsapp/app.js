// @summary WhatsApp real session manager (QR + connect + send + receive + AI reply)
// @methods GET POST DELETE
// @query {"action":"status"}

const {
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
} = require("./_internal");

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
        "GET /whatsapp?action=qr",
        "GET /whatsapp?action=status",
        "POST /whatsapp?action=send",
        "GET /whatsapp?action=inbox",
      ],
      examples: {
        qr_autostart: "curl 'http://127.0.0.1:8080/whatsapp?action=qr&format=raw'",
        qr_png: "curl 'http://127.0.0.1:8080/whatsapp?action=qr' --output /tmp/wa-qr.png",
        connect_optional: "curl -X POST 'http://127.0.0.1:8080/whatsapp?action=connect' -H 'Content-Type: application/json' --data '{}'",
        send: "curl -X POST 'http://127.0.0.1:8080/whatsapp?action=send' -H 'Content-Type: application/json' --data '{\"to\":\"15551234567\",\"text\":\"hola\"}'",
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
