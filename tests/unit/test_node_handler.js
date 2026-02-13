#!/usr/bin/env node
const assert = require("node:assert/strict");
const path = require("node:path");

const root = path.resolve(__dirname, "..", "..");
const handler = require(path.join(root, "examples/functions/node/hello/v2/app.js")).handler;
const nodeEchoHandler = require(path.join(root, "examples/functions/node/node_echo/app.js")).handler;
const nodeSimpleEchoHandler = require(path.join(root, "examples/functions/node/echo/handler.js")).handler;
const telegramSendHandler = require(path.join(root, "examples/functions/node/telegram_send/app.js")).handler;
const edgeProxyHandler = require(path.join(root, "examples/functions/node/edge_proxy/app.js")).handler;
const edgeFilterHandler = require(path.join(root, "examples/functions/node/edge_filter/app.js")).handler;
const requestInspectorHandler = require(path.join(root, "examples/functions/node/request_inspector/app.js")).handler;
const edgeAuthGatewayHandler = require(path.join(root, "examples/functions/node/edge_auth_gateway/app.js")).handler;
const githubWebhookGuardHandler = require(path.join(root, "examples/functions/node/github_webhook_guard/app.js")).handler;
const edgeHeaderInjectHandler = require(path.join(root, "examples/functions/node/edge_header_inject/app.js")).handler;
const telegramAiReplyHandler = require(path.join(root, "examples/functions/node/telegram_ai_reply/app.js")).handler;
const telegramAiDigestHandler = require(path.join(root, "examples/functions/node/telegram_ai_digest/app.js")).handler;
const whatsappHandler = require(path.join(root, "examples/functions/node/whatsapp/app.js")).handler;

async function testNodeHello() {
  const resp = await handler({ query: { name: "Unit" }, id: "req-2" });
  assert.equal(typeof resp, "object");
  assert.equal(resp.status, 200);
  assert.equal(typeof resp.headers, "object");
  assert.equal(typeof resp.body, "string");

  const body = JSON.parse(resp.body);
  assert.equal(body.hello, "v2-Unit");
  assert.equal(body.debug, undefined);
}

async function testNodeHelloDebug() {
  const resp = await handler({
    query: { name: "Unit" },
    id: "req-3",
    context: { debug: { enabled: true }, user: { trace_id: "trace-9" } },
  });
  const body = JSON.parse(resp.body);
  assert.equal(body.hello, "v2-Unit");
  assert.equal(body.debug.request_id, "req-3");
  assert.equal(body.debug.trace_id, "trace-9");
}

async function main() {
  await testNodeHello();
  await testNodeHelloDebug();
  await testNodeEcho();
  await testNodeSimpleEcho();
  await testEdgeProxyDirectiveShape();
  await testEdgeFilterAuthAndRewrite();
  await testRequestInspector();
  await testEdgeAuthGateway();
  await testGithubWebhookGuard();
  await testEdgeHeaderInject();
  await testTelegramAiReplyDryRun();
  await testTelegramAiReplyQueryModeDryRun();
  await testTelegramAiReplyLoopDryRun();
  await testTelegramAiReplyLoopDryRunAllChats();
  await testTelegramAiReplyLoopTokenRequiredForManualCalls();
  await testTelegramAiReplyLoopTokenBypassedForSchedulerCalls();
  await testTelegramAiReplySchedulerLoopDoesNotSendPromptByDefault();
  await testTelegramAiReplyLoopConflictIsSkippedForScheduler();
  await testTelegramAiReplyLoopTimeoutIsSkippedForScheduler();
  await testTelegramAiReplyMemoryByChat();
  await testTelegramAiReplyLoopOffsetPersistence();
  await testTelegramAiReplyToolsContext();
  await testTelegramAiReplyAutoToolsContext();
  await testTelegramAiReplyAutoToolsWeatherLocation();
  await testTelegramAiReplyMemoryPromptGuard();
  await testWhatsappChatToolsContext();
  await testWhatsappChatAutoToolsContext();
  await testTelegramAiDigestPreviewMode();
  await testTelegramAiDigestSingleSendOnConcurrentCalls();
  await testTelegramSendDryRun();
  console.log("node unit tests passed");
}

async function testNodeEcho() {
  const resp = await nodeEchoHandler({ query: { name: "NodeOnly" } });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.runtime, "node");
  assert.equal(body.function, "node_echo");
  assert.equal(body.hello, "NodeOnly");
}

async function testNodeSimpleEcho() {
  const resp = await nodeSimpleEchoHandler({ query: { key: "test" }, context: { user: { trace_id: "z1" } } });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.key, "test");
  assert.equal(body.query.key, "test");
  assert.equal(body.context.user.trace_id, "z1");
}

async function testTelegramSendDryRun() {
  const resp = await telegramSendHandler({ query: { chat_id: "123", text: "hola", dry_run: "true" } });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.channel, "telegram");
  assert.equal(body.chat_id, "123");
  assert.equal(body.dry_run, true);
}

async function testEdgeProxyDirectiveShape() {
  const resp = await edgeProxyHandler({ method: "GET", body: "", context: { request_id: "req-x", timeout_ms: 1234 } });
  assert.equal(resp.status, 200);
  assert.equal(typeof resp.proxy, "object");
  assert.equal(resp.proxy.path, "/_fn/health");
  assert.equal(resp.proxy.timeout_ms, 1234);
}

async function testEdgeFilterAuthAndRewrite() {
  const denied = await edgeFilterHandler({ query: { user_id: "123" }, headers: {}, env: { EDGE_FILTER_API_KEY: "dev" } });
  assert.equal(denied.status, 401);

  const bad = await edgeFilterHandler({
    query: { user_id: "abc" },
    headers: { "x-api-key": "dev" },
    env: { EDGE_FILTER_API_KEY: "dev" },
  });
  assert.equal(bad.status, 400);

  const ok = await edgeFilterHandler({
    method: "POST",
    query: { user_id: "123" },
    headers: { "x-api-key": "dev" },
    env: { EDGE_FILTER_API_KEY: "dev", UPSTREAM_TOKEN: "" },
    context: { request_id: "req-ef", timeout_ms: 777 },
    body: "ignored",
  });
  assert.equal(typeof ok.proxy, "object");
  assert.equal(ok.proxy.method, "GET");
  assert.ok(String(ok.proxy.path).startsWith("/openapi.json?edge_user_id=123"));
  assert.equal(ok.proxy.timeout_ms, 777);
}

async function testRequestInspector() {
  const resp = await requestInspectorHandler({
    method: "POST",
    path: "/fn/request_inspector",
    query: { key: "v" },
    headers: { "x-test": "1", "Content-Type": "text/plain" },
    body: "hello",
    context: { request_id: "req-ri", user: { trace_id: "t1" } },
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.method, "POST");
  assert.equal(body.query.key, "v");
  assert.equal(body.headers["x-test"], "1");
  assert.equal(body.body, "hello");
  assert.equal(body.context.request_id, "req-ri");
}

async function testEdgeAuthGateway() {
  const denied = await edgeAuthGatewayHandler({
    method: "GET",
    query: { target: "openapi" },
    headers: {},
    env: { EDGE_AUTH_TOKEN: "dev-token" },
  });
  assert.equal(denied.status, 401);

  const ok = await edgeAuthGatewayHandler({
    method: "GET",
    query: { target: "health" },
    headers: { authorization: "Bearer dev-token" },
    env: { EDGE_AUTH_TOKEN: "dev-token" },
    context: { request_id: "req-auth", timeout_ms: 111 },
    body: "",
  });
  assert.equal(typeof ok.proxy, "object");
  assert.equal(ok.proxy.path, "/_fn/health");
  assert.equal(ok.proxy.timeout_ms, 111);
}

async function testGithubWebhookGuard() {
  const crypto = require("node:crypto");
  const secret = "dev";
  const payload = JSON.stringify({ zen: "Keep it logically awesome.", hook_id: 123 });
  const sig =
    "sha256=" + crypto.createHmac("sha256", Buffer.from(secret, "utf8")).update(Buffer.from(payload, "utf8")).digest("hex");

  const bad = await githubWebhookGuardHandler({
    method: "POST",
    headers: { "x-hub-signature-256": "sha256=bad" },
    env: { GITHUB_WEBHOOK_SECRET: secret },
    body: payload,
  });
  assert.equal(bad.status, 401);

  const ok = await githubWebhookGuardHandler({
    method: "POST",
    headers: { "x-hub-signature-256": sig, "x-github-event": "ping", "x-github-delivery": "d1" },
    env: { GITHUB_WEBHOOK_SECRET: secret },
    body: payload,
    query: {},
  });
  assert.equal(ok.status, 200);
  const body = JSON.parse(ok.body);
  assert.equal(body.verified, true);
}

async function testEdgeHeaderInject() {
  const resp = await edgeHeaderInjectHandler({
    method: "POST",
    query: { tenant: "acme" },
    body: "hello",
    context: { request_id: "req-h", timeout_ms: 222 },
  });
  assert.equal(typeof resp.proxy, "object");
  assert.equal(resp.proxy.path, "/fn/request_inspector");
  assert.equal(resp.proxy.headers["x-tenant"], "acme");
  assert.equal(resp.proxy.timeout_ms, 222);
}

async function testTelegramAiReplyDryRun() {
  const update = { message: { chat: { id: 123 }, text: "Hola" } };
  const resp = await telegramAiReplyHandler({
    method: "POST",
    query: { dry_run: "true" },
    body: JSON.stringify(update),
    env: {},
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.dry_run, true);
  assert.equal(body.chat_id, 123);
}

async function testTelegramAiReplyQueryModeDryRun() {
  const resp = await telegramAiReplyHandler({
    method: "POST",
    query: { dry_run: "true", mode: "reply", chat_id: "123", text: "Hola" },
    body: "",
    env: {},
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.dry_run, true);
  assert.equal(body.chat_id, 123);
  assert.equal(body.received_text, "Hola");
}

async function testTelegramAiReplyLoopDryRun() {
  const resp = await telegramAiReplyHandler({
    method: "POST",
    query: { dry_run: "true", mode: "loop", chat_id: "123", prompt: "Hola loop", wait_secs: "30" },
    body: "",
    env: { TELEGRAM_LOOP_ENABLED: "true" },
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.dry_run, true);
  assert.equal(body.mode, "loop");
  assert.equal(body.chat_id, 123);
  assert.equal(body.prompt, "Hola loop");
}

async function testTelegramAiReplyLoopDryRunAllChats() {
  const resp = await telegramAiReplyHandler({
    method: "POST",
    query: { dry_run: "true", mode: "loop", wait_secs: "30" },
    body: "",
    env: { TELEGRAM_LOOP_ENABLED: "true" },
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.dry_run, true);
  assert.equal(body.mode, "loop");
  assert.equal(body.all_chats_mode, true);
}

async function testTelegramAiReplyLoopTokenRequiredForManualCalls() {
  const denied = await telegramAiReplyHandler({
    method: "GET",
    query: { mode: "loop", dry_run: "false", wait_secs: "10" },
    body: "",
    env: {
      TELEGRAM_LOOP_ENABLED: "true",
      TELEGRAM_LOOP_TOKEN: "secret-loop-token",
      TELEGRAM_BOT_TOKEN: "test-token",
    },
  });
  assert.equal(denied.status, 403);
  const body = JSON.parse(denied.body);
  assert.equal(body.error, "invalid loop token");
}

async function testTelegramAiReplyLoopTokenBypassedForSchedulerCalls() {
  const prevFetch = global.fetch;
  const os = require("node:os");
  const fs = require("node:fs");
  const lockPath = path.join(os.tmpdir(), `fastfn-loop-lock-${Date.now()}-${Math.random()}.lock`);
  const prevLock = process.env.FASTFN_TELEGRAM_LOOP_LOCK;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/getUpdates")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: [] }),
      };
    }
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: {} }) };
  };

  try {
    process.env.FASTFN_TELEGRAM_LOOP_LOCK = lockPath;
    const resp = await telegramAiReplyHandler({
      method: "GET",
      query: { mode: "loop", dry_run: "false", wait_secs: "5", poll_ms: "1000" },
      body: "",
      context: { trigger: { type: "schedule" }, timeout_ms: 2000 },
      env: {
        TELEGRAM_LOOP_ENABLED: "true",
        TELEGRAM_LOOP_TOKEN: "secret-loop-token",
        TELEGRAM_BOT_TOKEN: "test-token",
      },
    });
    // Scheduler calls should not fail 403 on loop token checks.
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.skipped, true);
    assert.ok(body.error === "timeout waiting for reply" || body.reason === "in_progress");
  } finally {
    global.fetch = prevFetch;
    if (prevLock === undefined) delete process.env.FASTFN_TELEGRAM_LOOP_LOCK; else process.env.FASTFN_TELEGRAM_LOOP_LOCK = prevLock;
    try { fs.unlinkSync(lockPath); } catch (_) {}
  }
}

async function testTelegramAiReplySchedulerLoopDoesNotSendPromptByDefault() {
  const prevFetch = global.fetch;
  let sendMessageCalls = 0;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/sendMessage")) {
      sendMessageCalls += 1;
      return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: { message_id: 1 } }) };
    }
    if (u.includes("/getUpdates")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: [] }),
      };
    }
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: {} }) };
  };

  try {
    const resp = await telegramAiReplyHandler({
      method: "GET",
      query: { mode: "loop", dry_run: "false", wait_secs: "5", poll_ms: "1000", chat_id: "123" },
      body: "",
      context: { trigger: { type: "schedule" }, timeout_ms: 2000 },
      env: {
        TELEGRAM_LOOP_ENABLED: "true",
        TELEGRAM_BOT_TOKEN: "test-token",
      },
    });
    assert.equal(resp.status, 200);
    assert.equal(sendMessageCalls, 0);
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyLoopConflictIsSkippedForScheduler() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/getUpdates")) {
      return {
        ok: false,
        status: 409,
        text: async () => JSON.stringify({
          ok: false,
          error_code: 409,
          description: "Conflict: terminated by other getUpdates request",
        }),
      };
    }
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: {} }) };
  };

  try {
    const resp = await telegramAiReplyHandler({
      method: "GET",
      query: { mode: "loop", dry_run: "false", wait_secs: "10", force_clear_webhook: "false" },
      body: "",
      context: { trigger: { type: "schedule" }, timeout_ms: 2000 },
      env: { TELEGRAM_LOOP_ENABLED: "true", TELEGRAM_BOT_TOKEN: "test-token" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.skipped, true);
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyLoopTimeoutIsSkippedForScheduler() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/getUpdates")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: [] }),
      };
    }
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: {} }) };
  };

  try {
    const resp = await telegramAiReplyHandler({
      method: "GET",
      query: { mode: "loop", dry_run: "false", wait_secs: "5", poll_ms: "1000" },
      body: "",
      context: { trigger: { type: "schedule" }, timeout_ms: 2000 },
      env: { TELEGRAM_LOOP_ENABLED: "true", TELEGRAM_BOT_TOKEN: "test-token" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.skipped, true);
    assert.ok(body.error === "timeout waiting for reply" || body.reason === "in_progress");
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyMemoryByChat() {
  const os = require("node:os");
  const fs = require("node:fs");
  const memPath = path.join(os.tmpdir(), `fastfn-memory-${Date.now()}-${Math.random()}.json`);
  const prevFetch = global.fetch;
  const prevMem = process.env.FASTFN_MEMORY_PATH;
  const payloads = [];

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      const req = JSON.parse(String(opts.body || "{}"));
      payloads.push(req);
      const idx = payloads.length;
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({
          choices: [{ message: { content: `resp-${idx}` } }],
        }),
      };
    }
    if (u.includes("/sendMessage")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: { message_id: 10 } }),
      };
    }
    return { ok: false, status: 404, text: async () => "not found" };
  };

  process.env.FASTFN_MEMORY_PATH = memPath;
  try {
    const baseEnv = {
      TELEGRAM_BOT_TOKEN: "test-token",
      OPENAI_API_KEY: "test-key",
      OPENAI_BASE_URL: "https://api.openai.com/v1",
    };
    const req1 = await telegramAiReplyHandler({
      method: "GET",
      query: { mode: "reply", dry_run: "false", chat_id: "1001", text: "Hola 1", memory: "true" },
      body: "",
      env: baseEnv,
      context: { timeout_ms: 1500 },
    });
    assert.equal(req1.status, 200);

    const req2 = await telegramAiReplyHandler({
      method: "GET",
      query: { mode: "reply", dry_run: "false", chat_id: "1001", text: "Hola 2", memory: "true" },
      body: "",
      env: baseEnv,
      context: { timeout_ms: 1500 },
    });
    assert.equal(req2.status, 200);

    assert.equal(payloads.length, 2);
    const secondMessages = payloads[1].messages || [];
    const hasFirstUser = secondMessages.some((m) => m && m.role === "user" && m.content === "Hola 1");
    const hasFirstAssistant = secondMessages.some((m) => m && m.role === "assistant" && m.content === "resp-1");
    assert.equal(hasFirstUser, true);
    assert.equal(hasFirstAssistant, true);
  } finally {
    global.fetch = prevFetch;
    if (prevMem === undefined) delete process.env.FASTFN_MEMORY_PATH; else process.env.FASTFN_MEMORY_PATH = prevMem;
    try { fs.unlinkSync(memPath); } catch (_) {}
  }
}

async function testTelegramAiReplyLoopOffsetPersistence() {
  const os = require("node:os");
  const fs = require("node:fs");
  const statePath = path.join(os.tmpdir(), `fastfn-loop-state-${Date.now()}-${Math.random()}.json`);
  const memPath = path.join(os.tmpdir(), `fastfn-loop-memory-${Date.now()}-${Math.random()}.json`);
  const lockPath = path.join(os.tmpdir(), `fastfn-loop-lock-${Date.now()}-${Math.random()}.lock`);
  const prevFetch = global.fetch;
  const prevState = process.env.FASTFN_TELEGRAM_LOOP_STATE;
  const prevMem = process.env.FASTFN_MEMORY_PATH;
  const prevLock = process.env.FASTFN_TELEGRAM_LOOP_LOCK;
  const getUpdatesUrls = [];
  let run = 0;

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/getUpdates")) {
      getUpdatesUrls.push(u);
      run += 1;
      if (run === 1) {
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({
            ok: true,
            result: [
              { update_id: 10, message: { message_id: 1, chat: { id: 2001 }, text: "hola A" } },
            ],
          }),
        };
      }
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({
          ok: true,
          result: [
            { update_id: 11, message: { message_id: 2, chat: { id: 2001 }, text: "hola B" } },
          ],
        }),
      };
    }
    if (u.includes("/chat/completions")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ choices: [{ message: { content: "ok" } }] }),
      };
    }
    if (u.includes("/sendMessage")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: { message_id: 99 } }),
      };
    }
    if (u.includes("/deleteWebhook")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: true }),
      };
    }
    return { ok: false, status: 404, text: async () => "not found" };
  };

  process.env.FASTFN_TELEGRAM_LOOP_STATE = statePath;
  process.env.FASTFN_MEMORY_PATH = memPath;
  process.env.FASTFN_TELEGRAM_LOOP_LOCK = lockPath;
  try {
    const env = {
      TELEGRAM_LOOP_ENABLED: "true",
      TELEGRAM_BOT_TOKEN: "test-token",
      OPENAI_API_KEY: "test-key",
      OPENAI_BASE_URL: "https://api.openai.com/v1",
    };
    const q = { mode: "loop", dry_run: "false", max_replies: "1", wait_secs: "5", force_clear_webhook: "false" };
    const r1 = await telegramAiReplyHandler({ method: "GET", query: q, body: "", env, context: { timeout_ms: 2000 } });
    assert.equal(r1.status, 200);
    const r2 = await telegramAiReplyHandler({ method: "GET", query: q, body: "", env, context: { timeout_ms: 2000 } });
    assert.equal(r2.status, 200);

    const secondGetUpdates = getUpdatesUrls.find((u) => u.includes("offset=11"));
    assert.equal(!!secondGetUpdates, true);
  } finally {
    global.fetch = prevFetch;
    if (prevState === undefined) delete process.env.FASTFN_TELEGRAM_LOOP_STATE; else process.env.FASTFN_TELEGRAM_LOOP_STATE = prevState;
    if (prevMem === undefined) delete process.env.FASTFN_MEMORY_PATH; else process.env.FASTFN_MEMORY_PATH = prevMem;
    if (prevLock === undefined) delete process.env.FASTFN_TELEGRAM_LOOP_LOCK; else process.env.FASTFN_TELEGRAM_LOOP_LOCK = prevLock;
    try { fs.unlinkSync(statePath); } catch (_) {}
    try { fs.unlinkSync(memPath); } catch (_) {}
    try { fs.unlinkSync(lockPath); } catch (_) {}
  }
}

async function testTelegramAiReplyToolsContext() {
  const prevFetch = global.fetch;
  let openaiPayload = null;

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/fn/request_inspector")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, source: "internal-fn" }),
      };
    }
    if (u.includes("api.ipify.org")) {
      return {
        ok: true,
        status: 200,
        text: async () => "203.0.113.10",
      };
    }
    if (u.includes("/chat/completions")) {
      openaiPayload = JSON.parse(String(opts.body || "{}"));
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ choices: [{ message: { content: "ok-tools" } }] }),
      };
    }
    if (u.includes("/sendMessage")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: { message_id: 321 } }),
      };
    }
    return { ok: false, status: 404, text: async () => "not found" };
  };

  try {
    const resp = await telegramAiReplyHandler({
      method: "GET",
      query: {
        mode: "reply",
        dry_run: "false",
        chat_id: "123",
        text: "Use [[fn:request_inspector?key=unit|GET]] and [[http:https://api.ipify.org?format=json]]",
        tools: "true",
        tool_allow_fn: "request_inspector",
        tool_allow_hosts: "api.ipify.org",
      },
      body: "",
      env: {
        TELEGRAM_BOT_TOKEN: "test-token",
        OPENAI_API_KEY: "test-key",
        OPENAI_BASE_URL: "https://api.openai.com/v1",
      },
      context: { timeout_ms: 2000 },
    });
    assert.equal(resp.status, 200);
    assert.ok(openaiPayload && Array.isArray(openaiPayload.messages));
    const last = openaiPayload.messages[openaiPayload.messages.length - 1];
    assert.equal(last.role, "user");
    assert.ok(String(last.content).includes("[Tool results]"));
    assert.ok(String(last.content).includes("internal-fn"));
    assert.ok(String(last.content).includes("203.0.113.10"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyAutoToolsContext() {
  const prevFetch = global.fetch;
  let openaiPayload = null;

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("wttr.in")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ current_condition: [{ temp_C: "22" }] }),
      };
    }
    if (u.includes("/chat/completions")) {
      openaiPayload = JSON.parse(String(opts.body || "{}"));
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ choices: [{ message: { content: "ok-auto-tools" } }] }),
      };
    }
    if (u.includes("/sendMessage")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: { message_id: 555 } }),
      };
    }
    return { ok: false, status: 404, text: async () => "not found" };
  };

  try {
    const resp = await telegramAiReplyHandler({
      method: "GET",
      query: {
        mode: "reply",
        dry_run: "false",
        chat_id: "123",
        text: "Como está el clima hoy?",
        tools: "true",
        auto_tools: "true",
        tool_allow_hosts: "wttr.in",
      },
      body: "",
      env: {
        TELEGRAM_BOT_TOKEN: "test-token",
        OPENAI_API_KEY: "test-key",
        OPENAI_BASE_URL: "https://api.openai.com/v1",
      },
      context: { timeout_ms: 2000 },
    });
    assert.equal(resp.status, 200);
    assert.ok(openaiPayload && Array.isArray(openaiPayload.messages));
    const last = openaiPayload.messages[openaiPayload.messages.length - 1];
    assert.equal(last.role, "user");
    assert.ok(String(last.content).includes("[Tool results]"));
    assert.ok(String(last.content).includes("wttr.in"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyAutoToolsWeatherLocation() {
  const prevFetch = global.fetch;
  let openaiPayload = null;
  const seenUrls = [];

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    seenUrls.push(u);
    if (u.includes("wttr.in")) {
      return {
        ok: true,
        status: 200,
        text: async () => "Beijing: ☀️ +8°C",
      };
    }
    if (u.includes("/chat/completions")) {
      openaiPayload = JSON.parse(String(opts.body || "{}"));
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ choices: [{ message: { content: "ok-weather-location" } }] }),
      };
    }
    if (u.includes("/sendMessage")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: { message_id: 556 } }),
      };
    }
    return { ok: false, status: 404, text: async () => "not found" };
  };

  try {
    const resp = await telegramAiReplyHandler({
      method: "GET",
      query: {
        mode: "reply",
        dry_run: "false",
        chat_id: "123",
        text: "y el clima en china?",
        tools: "true",
        auto_tools: "true",
        tool_allow_hosts: "wttr.in",
      },
      body: "",
      env: {
        TELEGRAM_BOT_TOKEN: "test-token",
        OPENAI_API_KEY: "test-key",
        OPENAI_BASE_URL: "https://api.openai.com/v1",
      },
      context: { timeout_ms: 2000 },
    });
    assert.equal(resp.status, 200);
    assert.ok(seenUrls.some((u) => u.includes("wttr.in/") && (u.includes("china") || u.includes("China"))));
    assert.ok(openaiPayload && Array.isArray(openaiPayload.messages));
    const last = openaiPayload.messages[openaiPayload.messages.length - 1];
    assert.equal(last.role, "user");
    assert.ok(String(last.content).includes("[Tool results]"));
    assert.ok(String(last.content).includes("Beijing"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyMemoryPromptGuard() {
  const prevFetch = global.fetch;
  const payloads = [];
  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      const req = JSON.parse(String(opts.body || "{}"));
      payloads.push(req);
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ choices: [{ message: { content: `ok-${payloads.length}` } }] }),
      };
    }
    if (u.includes("/sendMessage")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: { message_id: 900 } }),
      };
    }
    return { ok: false, status: 404, text: async () => "not found" };
  };

  try {
    const env = {
      TELEGRAM_BOT_TOKEN: "test-token",
      OPENAI_API_KEY: "test-key",
      OPENAI_BASE_URL: "https://api.openai.com/v1",
    };
    await telegramAiReplyHandler({
      method: "GET",
      query: { mode: "reply", dry_run: "false", chat_id: "321", text: "Hola", memory: "true" },
      body: "",
      env,
      context: { timeout_ms: 1500 },
    });
    await telegramAiReplyHandler({
      method: "GET",
      query: { mode: "reply", dry_run: "false", chat_id: "321", text: "que te dije antes?", memory: "true" },
      body: "",
      env,
      context: { timeout_ms: 1500 },
    });
    assert.equal(payloads.length, 2);
    const system = (((payloads[1] || {}).messages || [])[0] || {}).content || "";
    assert.ok(
      String(system).toLowerCase().includes("do not claim")
        || String(system).toLowerCase().includes("never say"),
      "memory guard must explicitly forbid false no-memory disclaimers"
    );
  } finally {
    global.fetch = prevFetch;
  }
}

async function testWhatsappChatToolsContext() {
  const prevFetch = global.fetch;
  let responsesPayload = null;

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/fn/request_inspector")) {
      return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, source: "wa-fn" }) };
    }
    if (u.includes("api.ipify.org")) {
      return { ok: true, status: 200, text: async () => "203.0.113.42" };
    }
    if (u.includes("/responses")) {
      responsesPayload = JSON.parse(String(opts.body || "{}"));
      return { ok: true, status: 200, json: async () => ({ output_text: "wa-ok" }) };
    }
    return { ok: false, status: 404, text: async () => "not found", json: async () => ({}) };
  };

  try {
    const resp = await whatsappHandler({
      method: "POST",
      query: { action: "chat" },
      body: JSON.stringify({
        text: "Usa [[fn:request_inspector?key=wa|GET]] y [[http:https://api.ipify.org?format=json]]",
      }),
      env: {
        OPENAI_API_KEY: "test-key",
        OPENAI_BASE_URL: "https://api.openai.com/v1",
        WHATSAPP_TOOLS_ENABLED: "true",
        WHATSAPP_TOOL_ALLOW_FN: "request_inspector",
        WHATSAPP_TOOL_ALLOW_HTTP_HOSTS: "api.ipify.org",
      },
    });
    assert.equal(resp.status, 200);
    assert.ok(responsesPayload && Array.isArray(responsesPayload.input));
    const userItem = responsesPayload.input.find((x) => x && x.role === "user");
    assert.ok(userItem && String(userItem.content).includes("[Tool results]"));
    assert.ok(String(userItem.content).includes("203.0.113.42"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testWhatsappChatAutoToolsContext() {
  const prevFetch = global.fetch;
  let responsesPayload = null;
  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("wttr.in")) {
      return { ok: true, status: 200, text: async () => JSON.stringify({ current_condition: [{ temp_C: "24" }] }) };
    }
    if (u.includes("/responses")) {
      responsesPayload = JSON.parse(String(opts.body || "{}"));
      return { ok: true, status: 200, json: async () => ({ output_text: "wa-auto-ok" }) };
    }
    return { ok: false, status: 404, text: async () => "not found", json: async () => ({}) };
  };
  try {
    const resp = await whatsappHandler({
      method: "POST",
      query: { action: "chat" },
      body: JSON.stringify({ text: "como esta el clima hoy?" }),
      env: {
        OPENAI_API_KEY: "test-key",
        OPENAI_BASE_URL: "https://api.openai.com/v1",
        WHATSAPP_TOOLS_ENABLED: "true",
        WHATSAPP_AUTO_TOOLS: "true",
        WHATSAPP_TOOL_ALLOW_HTTP_HOSTS: "wttr.in",
      },
    });
    assert.equal(resp.status, 200);
    assert.ok(responsesPayload && Array.isArray(responsesPayload.input));
    const userItem = responsesPayload.input.find((x) => x && x.role === "user");
    assert.ok(userItem && String(userItem.content).includes("[Tool results]"));
    assert.ok(String(userItem.content).includes("wttr.in"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiDigestSingleSendOnConcurrentCalls() {
  const os = require("node:os");
  const fs = require("node:fs");
  const stateFile = path.join(os.tmpdir(), `fastfn-digest-state-${Date.now()}-${Math.random()}.json`);
  const lockFile = stateFile + ".lock";
  const prevFetch = global.fetch;
  const prevState = process.env.FASTFN_DIGEST_STATE;
  const prevToken = process.env.TELEGRAM_BOT_TOKEN;
  let sendCount = 0;

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/json/")) {
      return { ok: true, status: 200, text: async () => JSON.stringify({ country_code: "US", city: "Austin", country_name: "USA", latitude: 30.27, longitude: -97.74 }) };
    }
    if (u.includes("open-meteo.com")) {
      return { ok: true, status: 200, text: async () => JSON.stringify({ current: { temperature_2m: 23, weather_code: 1, wind_speed_10m: 5 } }) };
    }
    if (u.includes("news.google.com/rss")) {
      return { ok: true, status: 200, text: async () => "<rss><channel><item><title>A</title><link>https://example.com/a</link></item></channel></rss>" };
    }
    if (u.includes("/sendMessage") && String(opts.method || "GET").toUpperCase() === "POST") {
      sendCount += 1;
      await new Promise((resolve) => setTimeout(resolve, 25));
      return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: { message_id: 123 } }) };
    }
    return { ok: false, status: 404, text: async () => "not found" };
  };

  process.env.FASTFN_DIGEST_STATE = stateFile;
  process.env.TELEGRAM_BOT_TOKEN = "test-token";

  try {
    const event = {
      query: {
        chat_id: "123",
        dry_run: "false",
        min_interval_secs: "0",
        include_ai: "false",
      },
      headers: {},
      client: { ip: "8.8.8.8" },
      context: { timeout_ms: 2000 },
      env: {},
    };

    const [r1, r2] = await Promise.all([telegramAiDigestHandler(event), telegramAiDigestHandler(event)]);
    const b1 = JSON.parse(r1.body);
    const b2 = JSON.parse(r2.body);
    assert.equal(sendCount, 1);
    assert.equal((b1.skipped === true || b2.skipped === true), true);
    assert.equal((b1.ok === true && b2.ok === true), true);
  } finally {
    global.fetch = prevFetch;
    if (prevState === undefined) delete process.env.FASTFN_DIGEST_STATE; else process.env.FASTFN_DIGEST_STATE = prevState;
    if (prevToken === undefined) delete process.env.TELEGRAM_BOT_TOKEN; else process.env.TELEGRAM_BOT_TOKEN = prevToken;
    try { fs.unlinkSync(stateFile); } catch (_) {}
    try { fs.unlinkSync(lockFile); } catch (_) {}
  }
}

async function testTelegramAiDigestPreviewMode() {
  const prevFetch = global.fetch;
  const prevToken = process.env.TELEGRAM_BOT_TOKEN;
  let sendCount = 0;

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("news.google.com/rss")) {
      return {
        ok: true,
        status: 200,
        text: async () => "<rss><channel><item><title>N1</title><link>https://example.com/n1</link></item></channel></rss>",
      };
    }
    if (u.includes("/sendMessage")) {
      sendCount += 1;
      return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: { message_id: 1 } }) };
    }
    if (u.includes("/json/")) {
      return { ok: true, status: 200, text: async () => JSON.stringify({ country_code: "US" }) };
    }
    return { ok: false, status: 404, text: async () => "not found" };
  };

  process.env.TELEGRAM_BOT_TOKEN = "test-token";
  try {
    const resp = await telegramAiDigestHandler({
      query: { preview: "true", include_ai: "false", include_weather: "false", include_news: "true" },
      headers: {},
      context: { timeout_ms: 2000 },
      env: {},
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.preview, true);
    assert.ok(String(body.message || "").includes("Headlines") || String(body.message || "").includes("Titulares"));
    assert.equal(sendCount, 0);
  } finally {
    global.fetch = prevFetch;
    if (prevToken === undefined) delete process.env.TELEGRAM_BOT_TOKEN; else process.env.TELEGRAM_BOT_TOKEN = prevToken;
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
