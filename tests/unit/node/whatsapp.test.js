const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const { ROOT, requireFresh, jestRequireFresh, resetWhatsappRuntimeState } = require("./helpers");

// Shared mock state for the baileys socket.
const fakeBaileysListeners = {};
const fakeBaileysSocket = {
  user: { id: "bot@s.whatsapp.net" },
  ev: {
    on: (name, cb) => {
      fakeBaileysListeners[name] = cb;
      if (name === "connection.update" && fakeBaileysSocket._autoOpen) {
        if (fakeBaileysSocket._emitQr) cb({ qr: "unit-qr-token" });
        cb({ connection: "open" });
      }
    },
  },
  sendMessage: async (jid, payload) => ({ key: { id: `sent-${jid}-${(payload.text || "").length}` } }),
  logout: async () => {},
  end: () => {},
  _autoOpen: false,
  _emitQr: false,
  _lastOptions: null,
};

const mockBaileysModule = {
  _latestVersion: null,
  _latestVersionError: new Error("version fetch failed"),
  useMultiFileAuthState: async () => ({ state: {}, saveCreds: () => {} }),
  fetchLatestBaileysVersion: async () => {
    if (mockBaileysModule._latestVersionError) {
      throw mockBaileysModule._latestVersionError;
    }
    return mockBaileysModule._latestVersion;
  },
  makeWASocket: (opts) => {
    fakeBaileysSocket._lastOptions = opts;
    return fakeBaileysSocket;
  },
  Browsers: { macOS: () => "FastFNTest" },
};

// Mock optional deps that the handler lazy-loads via require().
jest.mock("@whiskeysockets/baileys", () => mockBaileysModule, { virtual: true });

jest.mock("qrcode", () => ({
  toString: async (value) => `<svg>${value}</svg>`,
  toBuffer: async () => Buffer.from([0, 1, 2, 3]),
}), { virtual: true });

const whatsappModule = require(path.join(ROOT, "examples/functions/node/whatsapp/handler.js"));
const whatsappHandler = whatsappModule.handler;

describe("whatsapp", () => {
  beforeEach(() => {
    resetWhatsappRuntimeState();
    fakeBaileysSocket._lastOptions = null;
    mockBaileysModule._latestVersion = null;
    mockBaileysModule._latestVersionError = new Error("version fetch failed");
  });

  test("intro", async () => {
    const resp = await whatsappHandler({ method: "GET", query: { action: "intro" }, body: "", env: {} });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.ok(Array.isArray(body.actions));
    assert.ok(body.message.includes("WhatsApp"));
  });

  test("status", async () => {
    const resp = await whatsappHandler({ method: "GET", query: { action: "status" }, body: "", env: {} });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.connected, false);
    assert.equal(body.inbox_count, 0);
  });

  test("unknown action", async () => {
    const resp = await whatsappHandler({ method: "GET", query: { action: "nonexistent" }, body: "", env: {} });
    assert.equal(resp.status, 400);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error || "").includes("unknown action"));
  });

  test("send missing text", async () => {
    const state = global.__fastfn_wa;
    state.connected = true;
    state.socket = { sendMessage: async () => ({}) };
    const resp = await whatsappHandler({
      method: "POST",
      query: { action: "send" },
      body: JSON.stringify({ to: "15551234567" }),
      env: {},
    });
    assert.equal(resp.status, 400);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error || "").includes("text is required"));
  });

  test("send success", async () => {
    const state = global.__fastfn_wa;
    state.connected = true;
    state.socket = {
      sendMessage: async (jid, payload) => ({ key: { id: `sent-${payload.text.length}` } }),
    };
    const resp = await whatsappHandler({
      method: "POST",
      query: { action: "send" },
      body: JSON.stringify({ to: "15551234567", text: "hi" }),
      env: {},
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.ok(body.to.endsWith("@s.whatsapp.net"));
  });

  test("send invalid number", async () => {
    const state = global.__fastfn_wa;
    state.connected = true;
    state.socket = { sendMessage: async () => ({}) };
    const resp = await whatsappHandler({
      method: "POST",
      query: { action: "send" },
      body: JSON.stringify({ to: "12", text: "hi" }),
      env: {},
    });
    assert.equal(resp.status, 500);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error || "").includes("invalid"));
  });

  test("send null to", async () => {
    const state = global.__fastfn_wa;
    state.connected = true;
    state.socket = { sendMessage: async () => ({}) };
    const resp = await whatsappHandler({
      method: "POST",
      query: { action: "send" },
      body: JSON.stringify({ text: "hello" }),
      env: {},
    });
    assert.equal(resp.status, 500);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error).includes("to is required"));
  });

  test("send already formatted jid", async () => {
    const state = global.__fastfn_wa;
    state.connected = true;
    let capturedJid = null;
    state.socket = {
      sendMessage: async (jid) => { capturedJid = jid; return { key: { id: "m1" } }; },
    };

    const resp1 = await whatsappHandler({
      method: "POST",
      query: { action: "send" },
      body: JSON.stringify({ to: "15551234567@s.whatsapp.net", text: "hi" }),
      env: {},
    });
    assert.equal(resp1.status, 200);
    assert.equal(capturedJid, "15551234567@s.whatsapp.net");

    capturedJid = null;
    const resp2 = await whatsappHandler({
      method: "POST",
      query: { action: "send" },
      body: JSON.stringify({ to: "120363012345@g.us", text: "hi group" }),
      env: {},
    });
    assert.equal(resp2.status, 200);
    assert.equal(capturedJid, "120363012345@g.us");
  });

  test("inbox", async () => {
    const state = global.__fastfn_wa;
    state.inbox = [{ id: "m1", text: "hello" }];
    const resp = await whatsappHandler({ method: "GET", query: { action: "inbox" }, body: "", env: {} });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.total, 1);
    assert.equal(body.messages.length, 1);
  });

  test("chat missing text", async () => {
    const resp = await whatsappHandler({
      method: "POST",
      query: { action: "chat" },
      body: JSON.stringify({}),
      env: {},
    });
    assert.equal(resp.status, 400);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error || "").includes("text is required"));
  });

  test("chat missing api key", async () => {
    const resp = await whatsappHandler({
      method: "POST",
      query: { action: "chat" },
      body: JSON.stringify({ text: "hola" }),
      env: {},
    });
    assert.equal(resp.status, 500);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error).includes("missing OPENAI_API_KEY"));
  });

  test("chat no recipient", async () => {
    const prevFetch = global.fetch;
    global.fetch = async (url) => {
      if (String(url).includes("/chat/completions")) {
        return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: "ai response" } }] }) };
      }
      return { ok: false, status: 404, json: async () => ({}) };
    };
    try {
      const resp = await whatsappHandler({
        method: "POST",
        query: { action: "chat" },
        body: JSON.stringify({ text: "hola" }),
        env: { OPENAI_API_KEY: "test-key" },
      });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.ok, true);
      assert.equal(body.sent, false);
      assert.ok(body.ai_reply);
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("chat success", async () => {
    const state = global.__fastfn_wa;
    state.connected = true;
    state.socket = {
      sendMessage: async (jid, payload) => ({ key: { id: "chat-ok" } }),
    };

    const prevFetch = global.fetch;
    global.fetch = async (url) => {
      if (String(url).includes("/chat/completions")) {
        return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: "ai reply" } }] }) };
      }
      return { ok: false, status: 404, json: async () => ({}) };
    };
    try {
      const resp = await whatsappHandler({
        method: "POST",
        query: { action: "chat" },
        body: JSON.stringify({ text: "hola", to: "15551234567" }),
        env: { OPENAI_API_KEY: "test-key" },
      });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.ok, true);
      assert.equal(body.sent, true);
      assert.equal(body.ai_reply, "ai reply");
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("chat OpenAI error", async () => {
    const prevFetch = global.fetch;
    global.fetch = async (url) => {
      if (String(url).includes("/chat/completions")) {
        return { ok: false, status: 500, text: async () => "openai down" };
      }
      return { ok: false, status: 404, text: async () => "not found" };
    };
    try {
      const resp = await whatsappHandler({
        method: "POST",
        query: { action: "chat" },
        body: JSON.stringify({ text: "hola" }),
        env: { OPENAI_API_KEY: "test-key" },
      });
      assert.equal(resp.status, 500);
      const body = JSON.parse(resp.body);
      assert.ok(String(body.error || "").includes("OpenAI error"));
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("chat send error", async () => {
    const state = global.__fastfn_wa;
    state.connected = true;
    state.socket = {
      sendMessage: async () => { throw new Error("wa send err"); },
    };

    const prevFetch = global.fetch;
    global.fetch = async (url) => {
      if (String(url).includes("/chat/completions")) {
        return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: "reply text" } }] }) };
      }
      return { ok: false, status: 404, json: async () => ({}) };
    };
    try {
      const resp = await whatsappHandler({
        method: "POST",
        query: { action: "chat" },
        body: JSON.stringify({ text: "test", to: "15551234567" }),
        env: { OPENAI_API_KEY: "k" },
      });
      assert.equal(resp.status, 500);
      const body = JSON.parse(resp.body);
      assert.ok(String(body.error).includes("wa send err"));
      assert.equal(body.ai_reply, "reply text");
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("bad json body", async () => {
    const resp = await whatsappHandler({ method: "POST", query: { action: "send" }, body: "{invalid-json", env: {} });
    assert.equal(resp.status, 400);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error || "").includes("invalid JSON"));
  });

  test("disconnect and reset", async () => {
    const state = global.__fastfn_wa;

    // Disconnect with a socket that throws on end()
    state.reconnectTimer = setTimeout(() => {}, 10000);
    state.connected = true;
    state.socket = { end: () => { throw new Error("end failed"); } };
    const disconnectOk = await whatsappHandler({
      method: "POST",
      query: { action: "disconnect" },
      body: "{}",
      env: {},
    });
    assert.equal(disconnectOk.status, 200);

    // Reset session
    const originalRmSync = fs.rmSync;
    fs.rmSync = () => { throw new Error("rm failed"); };
    try {
      state.connected = true;
      state.socket = {
        logout: async () => { throw new Error("logout failed"); },
      };
      const resetOk = await whatsappHandler({
        method: "DELETE",
        query: { action: "reset-session" },
        body: "{}",
        env: {},
      });
      assert.equal(resetOk.status, 200);
    } finally {
      fs.rmSync = originalRmSync;
    }
  });

  test("connect QR lifecycle with mocks", async () => {
    const state = global.__fastfn_wa;
    fakeBaileysSocket._autoOpen = true;
    fakeBaileysSocket._emitQr = true;
    for (const k of Object.keys(fakeBaileysListeners)) delete fakeBaileysListeners[k];
    try {
      const connect = await whatsappHandler({ method: "POST", query: { action: "connect" }, body: "{}", env: {} });
      assert.equal(connect.status, 200);
      const connectBody = JSON.parse(connect.body);
      assert.equal(connectBody.ok, true);
      assert.equal(connectBody.connected, true);

      const qrRaw = await whatsappHandler({ method: "GET", query: { action: "qr", format: "raw" }, body: "", env: {} });
      assert.equal(qrRaw.status, 200);
      assert.equal(JSON.parse(qrRaw.body).qr, "unit-qr-token");

      const qrSvg = await whatsappHandler({ method: "GET", query: { action: "qr", format: "svg" }, body: "", env: {} });
      assert.equal(qrSvg.status, 200);
      assert.equal(qrSvg.headers["Content-Type"], "image/svg+xml");

      const qrPng = await whatsappHandler({ method: "GET", query: { action: "qr", format: "png", size: "32" }, body: "", env: {} });
      assert.equal(qrPng.status, 200);
      assert.equal(qrPng.is_base64, true);

      // Test messages.upsert listener
      const upsert = fakeBaileysListeners["messages.upsert"];
      assert.equal(typeof upsert, "function");
      upsert({
        messages: [
          { key: { id: "m1", fromMe: false, remoteJid: "111@s.whatsapp.net" }, message: { conversation: "hola 1" }, messageTimestamp: 1, pushName: "Unit A" },
          { key: { id: "m2", fromMe: true, remoteJid: "222@s.whatsapp.net" }, message: { extendedTextMessage: { text: "reply" } }, messageTimestamp: 2 },
        ],
      });

      const inbox = await whatsappHandler({ method: "GET", query: { action: "inbox", limit: "5" }, body: "", env: {} });
      assert.equal(inbox.status, 200);
      assert.equal(JSON.parse(inbox.body).total >= 1, true);

      // Test connection close scenarios
      const closeUpdate = fakeBaileysListeners["connection.update"];
      closeUpdate({ connection: "close", lastDisconnect: { error: { output: { statusCode: 401 } } } });
      assert.equal(state.lastError, "logged_out");
      closeUpdate({ connection: "close", lastDisconnect: {} });
      assert.equal(state.lastError, "connection_closed");

      if (state.reconnectTimer) { clearTimeout(state.reconnectTimer); state.reconnectTimer = null; }

      const disconnect = await whatsappHandler({ method: "POST", query: { action: "disconnect" }, body: "", env: {} });
      assert.equal(disconnect.status, 200);

      const resetOk = await whatsappHandler({ method: "DELETE", query: { action: "reset-session" }, body: "", env: {} });
      assert.equal(resetOk.status, 200);
      assert.equal(JSON.parse(resetOk.body).ok, true);
    } finally {
      fakeBaileysSocket._autoOpen = false;
      fakeBaileysSocket._emitQr = false;
    }
  });

  test("connect uses fetched baileys version when available", async () => {
    fakeBaileysSocket._autoOpen = true;
    mockBaileysModule._latestVersionError = null;
    mockBaileysModule._latestVersion = { version: [9, 9, 9] };
    for (const k of Object.keys(fakeBaileysListeners)) delete fakeBaileysListeners[k];
    try {
      const resp = await whatsappHandler({ method: "POST", query: { action: "connect" }, body: "{}", env: {} });
      assert.equal(resp.status, 200);
      assert.deepEqual(fakeBaileysSocket._lastOptions.version, [9, 9, 9]);
    } finally {
      fakeBaileysSocket._autoOpen = false;
      mockBaileysModule._latestVersionError = new Error("version fetch failed");
      mockBaileysModule._latestVersion = null;
    }
  });

  test("connect error paths with mocks", async () => {
    const originalMkdirSync = fs.mkdirSync;
    fs.mkdirSync = () => { throw new Error("auth state failed"); };
    try {
      const connect = await whatsappHandler({ method: "POST", query: { action: "connect" }, body: "{}", env: {} });
      assert.equal(connect.status, 500);
      assert.ok(String(JSON.parse(connect.body).error || "").includes("auth state failed"));
    } finally {
      fs.mkdirSync = originalMkdirSync;
    }
  });

  test("QR timeout and ensureConnected with fake timers", async () => {
    jest.useFakeTimers();
    const whatsappPath = path.join(ROOT, "examples/functions/node/whatsapp/handler.js");
    const freshModule = jestRequireFresh(whatsappPath);
    const freshHandler = freshModule.handler;
    const state = global.__fastfn_wa;
    try {
      resetWhatsappRuntimeState();
      state.connected = true;
      state.connecting = false;
      state.lastQr = null;
      state.socket = { end: () => {} };
      const qrConnectedPromise = freshHandler({ method: "GET", query: { action: "qr" }, body: "", env: {} });
      await jest.advanceTimersByTimeAsync(16000);
      const resp409 = await qrConnectedPromise;
      assert.equal(resp409.status, 409);
      assert.ok(String(JSON.parse(resp409.body).error).includes("already connected"));

      resetWhatsappRuntimeState();
      state.connected = false;
      state.connecting = true;
      state.lastQr = null;
      state.socket = null;
      const qrPendingPromise = freshHandler({ method: "GET", query: { action: "qr" }, body: "", env: {} });
      await jest.advanceTimersByTimeAsync(16000);
      const resp202 = await qrPendingPromise;
      assert.equal(resp202.status, 202);
      assert.ok(String(JSON.parse(resp202.body).error).includes("not ready yet"));

      resetWhatsappRuntimeState();
      state.connected = false;
      state.connecting = true;
      state.socket = null;
      const sendPromise = freshHandler({
        method: "POST",
        query: { action: "send" },
        body: JSON.stringify({ text: "hello", to: "15551234567" }),
        env: {},
      });
      await jest.advanceTimersByTimeAsync(46000);
      const sendResp = await sendPromise;
      assert.equal(sendResp.status, 409);
      assert.ok(String(JSON.parse(sendResp.body).error).includes("not connected"));
    } finally {
      if (state.reconnectTimer) { clearTimeout(state.reconnectTimer); state.reconnectTimer = null; }
      jest.useRealTimers();
    }
  });

  test("module init and inbox log trimming", async () => {
    const whatsappPath = path.join(ROOT, "examples/functions/node/whatsapp/handler.js");
    const previousState = global.__fastfn_wa;
    delete global.__fastfn_wa;
    fakeBaileysSocket._autoOpen = true;
    fakeBaileysSocket._emitQr = false;
    for (const k of Object.keys(fakeBaileysListeners)) delete fakeBaileysListeners[k];
    try {
      const freshModule = jestRequireFresh(whatsappPath);
      const freshHandler = freshModule.handler;
      const freshState = global.__fastfn_wa;
      assert.equal(typeof freshState, "object");
      assert.deepEqual(freshState.inbox, []);
      assert.deepEqual(freshState.outbox, []);

      const connect = await freshHandler({ method: "POST", query: { action: "connect" }, body: "{}", env: {} });
      assert.equal(connect.status, 200);

      const upsert = fakeBaileysListeners["messages.upsert"];
      assert.equal(typeof upsert, "function");
      upsert({
        messages: Array.from({ length: 205 }, (_, idx) => ({
          key: { id: `m${idx}`, remoteJid: `1${idx}@s.whatsapp.net`, fromMe: false },
          message: { conversation: `msg-${idx}` },
          messageTimestamp: idx + 1,
        })),
      });

      assert.equal(freshState.inbox.length, 200);
      assert.equal(freshState.inbox[0].id, "m204");
      assert.equal(freshState.inbox.at(-1).id, "m5");
    } finally {
      fakeBaileysSocket._autoOpen = false;
      fakeBaileysSocket._emitQr = false;
      if (global.__fastfn_wa?.reconnectTimer) {
        clearTimeout(global.__fastfn_wa.reconnectTimer);
        global.__fastfn_wa.reconnectTimer = null;
      }
      global.__fastfn_wa = previousState;
      resetWhatsappRuntimeState();
    }
  });

  test("QR rendering paths on fresh module", async () => {
    const whatsappPath = path.join(ROOT, "examples/functions/node/whatsapp/handler.js");
    const freshModule = jestRequireFresh(whatsappPath);
    const freshHandler = freshModule.handler;
    const freshState = global.__fastfn_wa;
    freshState.lastQr = "render-qr";
    freshState.lastQrAt = 1234567890;

    const svgResp = await freshHandler({ method: "GET", query: { action: "qr", format: "svg", size: "360" }, body: "", env: {} });
    assert.equal(svgResp.status, 200);
    assert.equal(svgResp.headers["Content-Type"], "image/svg+xml");
    assert.ok(String(svgResp.body).includes("render-qr"));

    const pngResp = await freshHandler({ method: "GET", query: { action: "qr", format: "png", size: "400" }, body: "", env: {} });
    assert.equal(pngResp.status, 200);
    assert.equal(pngResp.headers["Content-Type"], "image/png");
    assert.equal(pngResp.is_base64, true);
  });

  test("extractText imageMessage and videoMessage caption", async () => {
    const state = global.__fastfn_wa;
    fakeBaileysSocket._autoOpen = true;
    fakeBaileysSocket._emitQr = false;
    for (const k of Object.keys(fakeBaileysListeners)) delete fakeBaileysListeners[k];
    try {
      const whatsappPath = path.join(ROOT, "examples/functions/node/whatsapp/handler.js");
      const freshModule = requireFresh(whatsappPath);
      await freshModule.handler({ method: "POST", query: { action: "connect" }, body: "{}", env: {} });
      const upsert = fakeBaileysListeners["messages.upsert"];
      assert.equal(typeof upsert, "function");

      state.inbox = [];
      upsert({ messages: [{ key: { id: "img1", remoteJid: "1234@s.whatsapp.net", fromMe: false }, pushName: "Alice", messageTimestamp: 1000, message: { imageMessage: { caption: "photo caption" } } }] });
      assert.equal(state.inbox.length, 1);
      assert.equal(state.inbox[0].text, "photo caption");

      state.inbox = [];
      upsert({ messages: [{ key: { id: "vid1", remoteJid: "5678@s.whatsapp.net", fromMe: false }, pushName: "Bob", messageTimestamp: 2000, message: { videoMessage: { caption: "video caption" } } }] });
      assert.equal(state.inbox.length, 1);
      assert.equal(state.inbox[0].text, "video caption");
    } finally {
      fakeBaileysSocket._autoOpen = false;
      if (state.reconnectTimer) { clearTimeout(state.reconnectTimer); state.reconnectTimer = null; }
    }
  });

  test("status payload fs error", async () => {
    const origExistsSync = fs.existsSync;
    fs.existsSync = (p) => {
      if (String(p).includes(".session")) throw new Error("simulated fs error");
      return origExistsSync(p);
    };
    try {
      const resp = await whatsappHandler({ method: "GET", query: { action: "status" }, body: "", env: {} });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.has_session, false);
    } finally {
      fs.existsSync = origExistsSync;
    }
  });

  test("status payload detects existing session files", async () => {
    const origExistsSync = fs.existsSync;
    const origReaddirSync = fs.readdirSync;
    fs.existsSync = (p) => String(p).includes(".session") ? true : origExistsSync(p);
    fs.readdirSync = (p) => String(p).includes(".session") ? ["creds.json"] : origReaddirSync(p);
    try {
      const resp = await whatsappHandler({ method: "GET", query: { action: "status" }, body: "", env: {} });
      assert.equal(resp.status, 200);
      assert.equal(JSON.parse(resp.body).has_session, true);
    } finally {
      fs.existsSync = origExistsSync;
      fs.readdirSync = origReaddirSync;
    }
  });

  test("QR size clamping", async () => {
    const state = global.__fastfn_wa;
    state.lastQr = "test-qr-for-size";
    state.lastQrAt = Date.now();
    const resp1 = await whatsappHandler({ method: "GET", query: { action: "qr", size: "0" }, body: "", env: {} });
    assert.equal(resp1.status, 200);
    const resp2 = await whatsappHandler({ method: "GET", query: { action: "qr", size: "9999" }, body: "", env: {} });
    assert.equal(resp2.status, 200);
  });

  test("default QR format", async () => {
    const state = global.__fastfn_wa;
    state.lastQr = "test-qr";
    state.lastQrAt = Date.now();
    const resp = await whatsappHandler({ method: "GET", query: { action: "qr" }, body: "", env: {} });
    assert.equal(resp.status, 200);
  });

  test("send message error", async () => {
    const state = global.__fastfn_wa;
    state.connected = true;
    state.socket = { sendMessage: async () => { throw new Error("socket write failed"); } };
    const resp = await whatsappHandler({
      method: "POST",
      query: { action: "send" },
      body: JSON.stringify({ to: "15551234567", text: "hello" }),
      env: {},
    });
    assert.equal(resp.status, 500);
    assert.ok(String(JSON.parse(resp.body).error).includes("socket write failed"));
  });

  test("disconnect without active socket still succeeds", async () => {
    const state = global.__fastfn_wa;
    state.reconnectTimer = setTimeout(() => {}, 10000);
    state.connected = true;
    state.socket = null;

    const resp = await whatsappHandler({ method: "DELETE", query: { action: "disconnect" }, body: "", env: {} });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.equal(state.reconnectTimer, null);
    assert.equal(state.connected, false);
  });

  test("reset session accepts action from object body with underscore alias", async () => {
    const state = global.__fastfn_wa;
    state.lastQr = "stale-qr";
    state.lastQrAt = Date.now();
    state.lastError = "stale";
    state.inbox = [{ id: "m1" }];
    state.outbox = [{ id: "m2" }];

    const resp = await whatsappHandler({ method: "DELETE", query: null, body: { action: "reset_session" }, env: null });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.equal(state.lastQr, null);
    assert.deepEqual(state.inbox, []);
    assert.deepEqual(state.outbox, []);
  });

  test("qr returns startup error when connection bootstrap fails", async () => {
    const originalMkdirSync = fs.mkdirSync;
    fs.mkdirSync = () => { throw new Error("qr bootstrap failed"); };
    try {
      const resp = await whatsappHandler({ method: "GET", query: { action: "qr" }, body: "", env: {} });
      assert.equal(resp.status, 500);
      assert.ok(String(JSON.parse(resp.body).error).includes("qr bootstrap failed"));
    } finally {
      fs.mkdirSync = originalMkdirSync;
    }
  });

  test("chat uses inbox sender as fallback recipient", async () => {
    const state = global.__fastfn_wa;
    state.connected = true;
    state.inbox = [{ from: "15551234567@s.whatsapp.net" }];
    let sentTo = null;
    state.socket = {
      sendMessage: async (jid) => {
        sentTo = jid;
        return { key: { id: "chat-inbox" } };
      },
    };

    const prevFetch = global.fetch;
    global.fetch = async (url) => {
      if (String(url).includes("/chat/completions")) {
        return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: "  inbox reply  " } }] }) };
      }
      return { ok: false, status: 404, json: async () => ({}) };
    };
    try {
      const resp = await whatsappHandler({
        method: "POST",
        query: { action: "chat" },
        body: JSON.stringify({ text: "hola" }),
        env: { OPENAI_API_KEY: "test-key" },
      });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.ok, true);
      assert.equal(body.sent, true);
      assert.equal(body.ai_reply, "inbox reply");
      assert.equal(sentTo, "15551234567@s.whatsapp.net");
    } finally {
      global.fetch = prevFetch;
    }
  });
});
