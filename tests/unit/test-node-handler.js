#!/usr/bin/env node
const assert = require("node:assert/strict");
const path = require("node:path");

const root = path.resolve(__dirname, "..", "..");
const handler = require(path.join(root, "examples/functions/node/hello/v2/app.js")).handler;
const nodeEchoHandler = require(path.join(root, "examples/functions/node/node-echo/app.js")).handler;
const nodeSimpleEchoHandler = require(path.join(root, "examples/functions/node/echo/handler.js")).handler;
const telegramSendHandler = require(path.join(root, "examples/functions/node/telegram-send/app.js")).handler;
const edgeProxyHandler = require(path.join(root, "examples/functions/node/edge-proxy/app.js")).handler;
const edgeFilterHandler = require(path.join(root, "examples/functions/node/edge-filter/app.js")).handler;
const requestInspectorHandler = require(path.join(root, "examples/functions/node/request-inspector/app.js")).handler;
const edgeAuthGatewayHandler = require(path.join(root, "examples/functions/node/edge-auth-gateway/app.js")).handler;
const githubWebhookGuardHandler = require(path.join(root, "examples/functions/node/github-webhook-guard/app.js")).handler;
const edgeHeaderInjectHandler = require(path.join(root, "examples/functions/node/edge-header-inject/app.js")).handler;
const telegramAiReplyHandler = require(path.join(root, "examples/functions/node/telegram-ai-reply/app.js")).handler;
const telegramAiDigestHandler = require(path.join(root, "examples/functions/node/telegram-ai-digest/app.js")).handler;
const whatsappHandler = require(path.join(root, "examples/functions/node/whatsapp/app.js")).handler;
const ipIntelRemoteHandler = require(path.join(root, "examples/functions/ip-intel/get.remote.js")).handler;

async function withPatchedModuleLoad(patches, run) {
  const Module = require("node:module");
  const originalLoad = Module._load;
  Module._load = function patchedLoad(request, parent, isMain) {
    if (Object.prototype.hasOwnProperty.call(patches, request)) {
      return patches[request];
    }
    return originalLoad.call(this, request, parent, isMain);
  };
  try {
    return await run();
  } finally {
    Module._load = originalLoad;
  }
}

function requireFresh(modulePath) {
  delete require.cache[require.resolve(modulePath)];
  return require(modulePath);
}

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
  await testIpIntelRemoteMockMode();
  await testIpIntelRemoteIpapiSuccess();
  await testIpIntelRemoteIpapiError();
  await testIpIntelRemoteValidationAndNonJsonFailures();
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
  await testTelegramAiReplyWebhookExtractionAndEmptyPayloadBranches();
  await testTelegramAiReplyToolsFailureAndCapabilityBranches();
  await testTelegramAiReplyThinkingModesAndFallbackText();
  await testTelegramAiReplyLoopPromptPollAndConflictBranches();
  await testTelegramAiReplySendFailureReturns502();
  await testTelegramAiReplyLoopDisabledBusyAndOuterErrorBranches();
  await testTelegramAiReplyLoopThinkingAndForceClearWebhookBranches();
  await testWhatsappActionGuardsAndStatus();
  await testWhatsappInboxOutboxAndQrRaw();
  await testWhatsappSendPathsAndBodyValidation();
  await testWhatsappChatErrorAndNoRecipientPaths();
  await testWhatsappChatToolsContext();
  await testWhatsappChatAutoToolsContext();
  await testWhatsappMethodGuardsParseVariantsAndClosePaths();
  await testWhatsappChatAiOutputFallbacksAndErrors();
  await testWhatsappToolDirectiveFailureAndAutoNewsBranches();
  await testWhatsappConnectQrLifecycleWithMocks();
  await testWhatsappConnectErrorPathsWithMocks();
  await testTelegramAiDigestPreviewMode();
  await testTelegramAiDigestSingleSendOnConcurrentCalls();
  await testTelegramAiDigestDryRunMinIntervalAndAiFallbacks();
  await testTelegramSendDryRun();
  await testTelegramSendErrorAndSendPaths();
  console.log("node unit tests passed");
}

async function testNodeEcho() {
  const resp = await nodeEchoHandler({ query: { name: "NodeOnly" } });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.runtime, "node");
  assert.equal(body.function, "node-echo");
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

async function testIpIntelRemoteMockMode() {
  const resp = await ipIntelRemoteHandler({ query: { ip: "8.8.8.8", mock: "1" } });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.provider, "ipapi-mock");
  assert.equal(body.country_code, "US");
}

async function testIpIntelRemoteIpapiSuccess() {
  const prevFetch = global.fetch;
  let requestedURL = "";
  global.fetch = async (url) => {
    requestedURL = String(url);
    return {
      ok: true,
      status: 200,
      text: async () =>
        JSON.stringify({
          ip: "8.8.8.8",
          country_code: "US",
          country_name: "United States",
          city: "Mountain View",
          region: "California",
        }),
    };
  };
  try {
    const resp = await ipIntelRemoteHandler({
      query: { ip: "8.8.8.8" },
      env: { IPAPI_BASE_URL: "https://mock.ipapi.local" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.provider, "ipapi");
    assert.equal(body.country_code, "US");
    assert.ok(requestedURL.includes("/8.8.8.8/json/"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testIpIntelRemoteIpapiError() {
  const prevFetch = global.fetch;
  global.fetch = async () => ({
    ok: false,
    status: 429,
    text: async () => JSON.stringify({ error: "rate limited" }),
  });
  try {
    const resp = await ipIntelRemoteHandler({
      query: { ip: "8.8.8.8" },
      env: { IPAPI_BASE_URL: "https://mock.ipapi.local" },
    });
    assert.equal(resp.status, 502);
    const body = JSON.parse(resp.body);
    assert.equal(body.error, "ipapi_lookup_failed");
  } finally {
    global.fetch = prevFetch;
  }
}

async function testIpIntelRemoteValidationAndNonJsonFailures() {
  const missing = await ipIntelRemoteHandler({ query: {}, client: {} });
  assert.equal(missing.status, 400);
  const missingBody = JSON.parse(missing.body);
  assert.ok(String(missingBody.error || "").includes("missing ip"));

  const invalid = await ipIntelRemoteHandler({ query: { ip: "999.999.1.1" } });
  assert.equal(invalid.status, 400);
  const invalidBody = JSON.parse(invalid.body);
  assert.ok(String(invalidBody.error || "").includes("invalid ip"));

  const prevFetch = global.fetch;
  global.fetch = async () => ({
    ok: true,
    status: 200,
    text: async () => "<html>not-json</html>",
  });
  try {
    const nonJson = await ipIntelRemoteHandler({ query: { ip: "8.8.8.8" } });
    assert.equal(nonJson.status, 502);
    const nonJsonBody = JSON.parse(nonJson.body);
    assert.equal(nonJsonBody.error, "ipapi_lookup_failed");
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramSendDryRun() {
  const resp = await telegramSendHandler({ query: { chat_id: "123", text: "hola", dry_run: "true" } });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.channel, "telegram");
  assert.equal(body.chat_id, "123");
  assert.equal(body.dry_run, true);
}

async function testTelegramSendErrorAndSendPaths() {
  const missing = await telegramSendHandler({ query: {}, body: "", env: {} });
  assert.equal(missing.status, 400);

  const parseBodyFallback = await telegramSendHandler({
    query: { chat_id: "555", dry_run: "true" },
    body: "{bad-json",
    env: {},
  });
  assert.equal(parseBodyFallback.status, 200);
  const parseBodyFallbackBody = JSON.parse(parseBodyFallback.body);
  assert.equal(parseBodyFallbackBody.chat_id, "555");

  const forcedDryRun = await telegramSendHandler({
    query: { chat_id: "777", text: "forced", dry_run: "false" },
    env: {},
  });
  assert.equal(forcedDryRun.status, 200);
  const forcedDryRunBody = JSON.parse(forcedDryRun.body);
  assert.equal(forcedDryRunBody.dry_run, false);
  assert.ok(String(forcedDryRunBody.note || "").includes("forced dry_run"));

  const prevFetch = global.fetch;
  const prevToken = process.env.TELEGRAM_BOT_TOKEN;
  process.env.TELEGRAM_BOT_TOKEN = "token-fallback";
  try {
    global.fetch = async () => ({
      ok: true,
      status: 200,
      text: async () => JSON.stringify({ ok: true, result: { message_id: 42 } }),
    });
    const sent = await telegramSendHandler({
      query: { dry_run: "false" },
      body: JSON.stringify({ chatId: "900", text: "from-body" }),
      env: { TELEGRAM_BOT_TOKEN: "<set-me>" },
    });
    assert.equal(sent.status, 200);
    const sentBody = JSON.parse(sent.body);
    assert.equal(sentBody.sent, true);
    assert.equal(sentBody.telegram.message_id, 42);

    global.fetch = async () => ({
      ok: false,
      status: 401,
      text: async () => JSON.stringify({ ok: false, description: "unauthorized" }),
    });
    const badStatus = await telegramSendHandler({
      query: { chat_id: "901", text: "bad", dry_run: "false" },
      env: { TELEGRAM_BOT_TOKEN: "token-env" },
    });
    assert.equal(badStatus.status, 502);

    global.fetch = async () => ({
      ok: true,
      status: 200,
      text: async () => "not-json",
    });
    const badPayload = await telegramSendHandler({
      query: { chat_id: "902", text: "bad-json", dry_run: "false" },
      env: { TELEGRAM_BOT_TOKEN: "token-env" },
    });
    assert.equal(badPayload.status, 502);

    global.fetch = async () => {
      throw new Error("telegram network down");
    };
    const networkFail = await telegramSendHandler({
      query: { chat_id: "903", text: "boom", dry_run: "false" },
      env: { TELEGRAM_BOT_TOKEN: "token-env" },
    });
    assert.equal(networkFail.status, 502);
    const networkBody = JSON.parse(networkFail.body);
    assert.ok(String(networkBody.error || "").includes("telegram send failed"));
  } finally {
    global.fetch = prevFetch;
    if (prevToken === undefined) {
      delete process.env.TELEGRAM_BOT_TOKEN;
    } else {
      process.env.TELEGRAM_BOT_TOKEN = prevToken;
    }
  }
}

async function testEdgeProxyDirectiveShape() {
  const resp = await edgeProxyHandler({ method: "GET", body: "", context: { request_id: "req-x", timeout_ms: 1234 } });
  assert.equal(resp.status, 200);
  assert.equal(typeof resp.proxy, "object");
  assert.ok(String(resp.proxy.path || "").startsWith("/request-inspector"), "proxy path should target public endpoint");
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
  const rewritten = new URL(String(ok.proxy.path), "http://fastfn.local");
  assert.equal(rewritten.pathname, "/request-inspector");
  const rewrittenUserId = rewritten.searchParams.get("edge_user_id") || rewritten.searchParams.get("edge-user-id");
  assert.equal(rewrittenUserId, "123");
  assert.equal(ok.proxy.timeout_ms, 10000);

  const okDefaultTimeout = await edgeFilterHandler({
    method: "GET",
    query: { user_id: "123" },
    headers: { "x-api-key": "dev" },
    env: { EDGE_FILTER_API_KEY: "dev", UPSTREAM_TOKEN: "" },
  });
  assert.equal(okDefaultTimeout.proxy.timeout_ms, 10000);
}

async function testRequestInspector() {
  const resp = await requestInspectorHandler({
    method: "POST",
    path: "/fn/request-inspector",
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
  const okUrl = new URL(String(ok.proxy.path), "http://fastfn.local");
  assert.equal(okUrl.pathname, "/request-inspector");
  assert.equal(okUrl.searchParams.get("target"), "health");
  assert.equal(ok.proxy.timeout_ms, 111);

  const badTarget = await edgeAuthGatewayHandler({
    method: "GET",
    query: { target: "invalid" },
    headers: { authorization: "Bearer dev-token" },
    env: { EDGE_AUTH_TOKEN: "dev-token" },
  });
  assert.equal(badTarget.status, 400);

  const openapi = await edgeAuthGatewayHandler({
    method: "POST",
    query: { target: "openapi" },
    headers: { authorization: "Bearer dev-token" },
    env: { EDGE_AUTH_TOKEN: "dev-token" },
    context: { request_id: "req-auth-openapi", timeout_ms: 123 },
    body: "payload",
  });
  assert.equal(typeof openapi.proxy, "object");
  const openapiUrl = new URL(String(openapi.proxy.path), "http://fastfn.local");
  assert.equal(openapiUrl.pathname, "/request-inspector");
  assert.equal(openapiUrl.searchParams.get("target"), "openapi");
  assert.equal(openapi.proxy.method, "POST");
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

  const missingSecret = await githubWebhookGuardHandler({
    method: "POST",
    headers: { "x-hub-signature-256": sig },
    env: {},
    body: payload,
  });
  assert.equal(missingSecret.status, 500);

  const missingSig = await githubWebhookGuardHandler({
    method: "POST",
    headers: {},
    env: { GITHUB_WEBHOOK_SECRET: secret },
    body: payload,
  });
  assert.equal(missingSig.status, 400);

  const forward = await githubWebhookGuardHandler({
    method: "POST",
    headers: { "x-hub-signature-256": sig, "x-github-event": "push", "x-github-delivery": "d2" },
    env: { GITHUB_WEBHOOK_SECRET: secret },
    body: payload,
    query: { forward: "1" },
    context: { request_id: "req-gh", timeout_ms: 321 },
  });
  assert.equal(typeof forward.proxy, "object");
  assert.equal(forward.proxy.path, "/request-inspector");
  assert.equal(forward.proxy.method, "POST");
}

async function testEdgeHeaderInject() {
  const resp = await edgeHeaderInjectHandler({
    method: "POST",
    query: { tenant: "acme" },
    body: "hello",
    context: { request_id: "req-h", timeout_ms: 222 },
  });
  assert.equal(typeof resp.proxy, "object");
  assert.equal(resp.proxy.path, "/request-inspector");
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
    if (u.includes("/fn/request-inspector")) {
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
        text: "Use [[fn:request-inspector?key=unit|GET]] and [[http:https://api.ipify.org?format=json]]",
        tools: "true",
        tool_allow_fn: "request-inspector",
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

async function testTelegramAiReplyWebhookExtractionAndEmptyPayloadBranches() {
  const callbackResp = await telegramAiReplyHandler({
    method: "POST",
    query: { dry_run: "true" },
    body: JSON.stringify({
      callback_query: {
        data: "clicked",
        message: { chat: { id: 777 }, message_id: 9 },
      },
    }),
    env: {},
  });
  assert.equal(callbackResp.status, 200);
  const callbackBody = JSON.parse(callbackResp.body);
  assert.equal(callbackBody.chat_id, 777);
  assert.equal(callbackBody.received_text, "clicked");

  const missingChat = await telegramAiReplyHandler({
    method: "POST",
    query: { dry_run: "false" },
    body: JSON.stringify({ update_id: 1 }),
    env: {},
  });
  assert.equal(missingChat.status, 200);
  const missingChatBody = JSON.parse(missingChat.body);
  assert.ok(String(missingChatBody.note || "").includes("no chat_id"));

  const missingText = await telegramAiReplyHandler({
    method: "POST",
    query: { dry_run: "false" },
    body: JSON.stringify({ message: { chat: { id: 111 } } }),
    env: {},
  });
  assert.equal(missingText.status, 200);
  const missingTextBody = JSON.parse(missingText.body);
  assert.ok(String(missingTextBody.note || "").includes("no text"));
}

async function testTelegramAiReplyToolsFailureAndCapabilityBranches() {
  const prevFetch = global.fetch;
  const openaiPayloads = [];
  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/fn/request-inspector")) {
      throw new Error("fetch failed tool fn");
    }
    if (u.includes("/fn/telegram-ai-digest")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, digest: "ok" }),
      };
    }
    if (u.includes("/chat/completions")) {
      openaiPayloads.push(JSON.parse(String(opts.body || "{}")));
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
        text: async () => JSON.stringify({ ok: true, result: { message_id: 700 } }),
      };
    }
    return { ok: false, status: 404, text: async () => "not found" };
  };

  try {
    const baseEnv = {
      TELEGRAM_BOT_TOKEN: "test-token",
      OPENAI_API_KEY: "test-key",
      OPENAI_BASE_URL: "https://api.openai.com/v1",
    };

    const capability = await telegramAiReplyHandler({
      method: "GET",
      query: {
        mode: "reply",
        dry_run: "false",
        chat_id: "123",
        text: "What tools can you do?",
        tools: "true",
        auto_tools: "true",
      },
      body: "",
      env: baseEnv,
      context: { timeout_ms: 1500 },
    });
    assert.equal(capability.status, 200);
    const capUser = (((openaiPayloads[0] || {}).messages || []).slice(-1)[0] || {}).content || "";
    assert.equal(String(capUser).includes("[Tool results]"), false);

    const failures = await telegramAiReplyHandler({
      method: "GET",
      query: {
        mode: "reply",
        dry_run: "false",
        chat_id: "123",
        text: "[[fn:not_allowed|GET]] [[fn:request-inspector|TRACE]] [[http:https://api.ipify.org?format=json]] [[fn:request-inspector?key=boom|GET]]",
        tools: "true",
        tool_allow_fn: "request-inspector",
        tool_allow_hosts: "wttr.in",
      },
      body: "",
      env: baseEnv,
      context: { timeout_ms: 1500 },
    });
    assert.equal(failures.status, 200);
    const failUser = (((openaiPayloads[1] || {}).messages || []).slice(-1)[0] || {}).content || "";
    assert.ok(String(failUser).includes("[Tool results]"));
    assert.ok(String(failUser).includes("function not allowed"));
    assert.ok(String(failUser).includes("method not allowed"));
    assert.ok(String(failUser).includes("host not allowed"));
    assert.ok(String(failUser).includes("fetch failed tool fn"));
    assert.ok(String(failUser).includes("Tool execution failed"));

    const autoNews = await telegramAiReplyHandler({
      method: "GET",
      query: {
        mode: "reply",
        dry_run: "false",
        chat_id: "123",
        text: "dame news digest",
        tools: "true",
        auto_tools: "true",
        tool_allow_fn: "telegram-ai-digest",
      },
      body: "",
      env: baseEnv,
      context: { timeout_ms: 1500 },
    });
    assert.equal(autoNews.status, 200);
    const autoUser = (((openaiPayloads[2] || {}).messages || []).slice(-1)[0] || {}).content || "";
    assert.ok(String(autoUser).includes("telegram-ai-digest"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyThinkingModesAndFallbackText() {
  const prevFetch = global.fetch;
  const sendTexts = [];
  let typingCalls = 0;
  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/sendChatAction")) {
      typingCalls += 1;
      if (typingCalls === 1) {
        throw new Error("fetch failed while typing");
      }
      throw new Error("typing blocked");
    }
    if (u.includes("/chat/completions")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ choices: [{ message: { content: "respuesta final" } }] }),
      };
    }
    if (u.includes("/sendMessage")) {
      const body = JSON.parse(String(opts.body || "{}"));
      sendTexts.push(String(body.text || ""));
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: { message_id: sendTexts.length } }),
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

    const typingMode = await telegramAiReplyHandler({
      method: "GET",
      query: {
        mode: "reply",
        dry_run: "false",
        chat_id: "333",
        text: "hola",
        show_thinking: "true",
        thinking_mode: "typing",
        thinking_fallback_text: "true",
        thinking_text: "Pensando...",
        thinking_min_ms: "0",
      },
      body: "",
      env,
      context: { timeout_ms: 1500 },
    });
    assert.equal(typingMode.status, 200);
    assert.equal(typingCalls, 2);
    assert.ok(sendTexts.includes("Pensando..."));
    assert.ok(sendTexts.includes("respuesta final"));

    const textMode = await telegramAiReplyHandler({
      method: "GET",
      query: {
        mode: "reply",
        dry_run: "false",
        chat_id: "333",
        text: "hola de nuevo",
        show_thinking: "true",
        thinking_mode: "text",
        thinking_text: "Escribiendo...",
        thinking_min_ms: "0",
      },
      body: "",
      env,
      context: { timeout_ms: 1500 },
    });
    assert.equal(textMode.status, 200);
    assert.ok(sendTexts.includes("Escribiendo..."));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyLoopPromptPollAndConflictBranches() {
  const os = require("node:os");
  const fs = require("node:fs");
  const statePath = path.join(os.tmpdir(), `fastfn-loop-state-branches-${Date.now()}-${Math.random()}.json`);
  const lockPath = path.join(os.tmpdir(), `fastfn-loop-lock-branches-${Date.now()}-${Math.random()}.lock`);
  const prevFetch = global.fetch;
  const prevState = process.env.FASTFN_TELEGRAM_LOOP_STATE;
  const prevLock = process.env.FASTFN_TELEGRAM_LOOP_LOCK;
  const sentTexts = [];
  let getUpdatesCalls = 0;

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/deleteWebhook")) {
      return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: true }) };
    }
    if (u.includes("/getUpdates")) {
      getUpdatesCalls += 1;
      if (getUpdatesCalls === 1) {
        return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: [] }) };
      }
      if (getUpdatesCalls === 2) {
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({
            ok: true,
            result: [
              {
                update_id: 50,
                message: {
                  message_id: 9,
                  chat: { id: 123 },
                  text: "hola loop",
                  from: { is_bot: false },
                },
              },
            ],
          }),
        };
      }
      if (getUpdatesCalls === 3) {
        throw new Error("fetch failed while polling");
      }
      return {
        ok: false,
        status: 409,
        text: async () => JSON.stringify({ ok: false, error_code: 409, description: "Conflict on poll" }),
      };
    }
    if (u.includes("/chat/completions")) {
      return { ok: false, status: 500, text: async () => "openai failed for loop" };
    }
    if (u.includes("/sendMessage")) {
      const body = JSON.parse(String(opts.body || "{}"));
      sentTexts.push(String(body.text || ""));
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true, result: { message_id: sentTexts.length } }),
      };
    }
    return { ok: false, status: 404, text: async () => "not found" };
  };

  process.env.FASTFN_TELEGRAM_LOOP_STATE = statePath;
  process.env.FASTFN_TELEGRAM_LOOP_LOCK = lockPath;

  try {
    const resp = await telegramAiReplyHandler({
      method: "GET",
      query: {
        mode: "loop",
        dry_run: "false",
        chat_id: "123",
        prompt: "hola prompt",
        send_prompt: "true",
        force_clear_webhook: "true",
        wait_secs: "5",
        poll_ms: "300",
        max_replies: "1",
      },
      body: "",
      env: {
        TELEGRAM_LOOP_ENABLED: "true",
        TELEGRAM_BOT_TOKEN: "test-token",
        OPENAI_API_KEY: "test-key",
        OPENAI_BASE_URL: "https://api.openai.com/v1",
      },
      context: { timeout_ms: 1500 },
    });

    assert.equal(resp.status, 409);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error || "").includes("getUpdates conflict"));
    assert.ok(sentTexts.includes("hola prompt"));
  } finally {
    global.fetch = prevFetch;
    if (prevState === undefined) {
      delete process.env.FASTFN_TELEGRAM_LOOP_STATE;
    } else {
      process.env.FASTFN_TELEGRAM_LOOP_STATE = prevState;
    }
    if (prevLock === undefined) {
      delete process.env.FASTFN_TELEGRAM_LOOP_LOCK;
    } else {
      process.env.FASTFN_TELEGRAM_LOOP_LOCK = prevLock;
    }
    try {
      fs.unlinkSync(statePath);
    } catch (_) {}
    try {
      fs.unlinkSync(lockPath);
    } catch (_) {}
  }
}

async function testTelegramAiReplySendFailureReturns502() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ choices: [{ message: { content: "ok-send" } }] }),
      };
    }
    if (u.includes("/sendMessage")) {
      return {
        ok: false,
        status: 500,
        text: async () => "telegram down",
      };
    }
    return { ok: false, status: 404, text: async () => "not found" };
  };
  try {
    const resp = await telegramAiReplyHandler({
      method: "GET",
      query: { mode: "reply", dry_run: "false", chat_id: "987", text: "hola" },
      body: "",
      env: {
        TELEGRAM_BOT_TOKEN: "test-token",
        OPENAI_API_KEY: "test-key",
        OPENAI_BASE_URL: "https://api.openai.com/v1",
      },
      context: { timeout_ms: 1500 },
    });
    assert.equal(resp.status, 502);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error || "").includes("telegram send failed"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyLoopDisabledBusyAndOuterErrorBranches() {
  const os = require("node:os");
  const fs = require("node:fs");
  const busyLockPath = path.join(os.tmpdir(), `fastfn-loop-busy-${Date.now()}-${Math.random()}.lock`);
  const errorLockPath = path.join(os.tmpdir(), `fastfn-loop-error-${Date.now()}-${Math.random()}.lock`);
  const prevLock = process.env.FASTFN_TELEGRAM_LOOP_LOCK;
  const prevFetch = global.fetch;
  const originalSet = global.Set;

  const disabled = await telegramAiReplyHandler({
    method: "GET",
    query: { mode: "loop", dry_run: "false" },
    body: "",
    env: { TELEGRAM_LOOP_ENABLED: "false" },
  });
  assert.equal(disabled.status, 403);

  process.env.FASTFN_TELEGRAM_LOOP_LOCK = busyLockPath;
  fs.writeFileSync(busyLockPath, JSON.stringify({ ts: Date.now(), pid: process.pid }), "utf8");
  try {
    const busy = await telegramAiReplyHandler({
      method: "GET",
      query: { mode: "loop", dry_run: "false", wait_secs: "5" },
      body: "",
      env: { TELEGRAM_LOOP_ENABLED: "true", TELEGRAM_BOT_TOKEN: "test-token" },
    });
    assert.equal(busy.status, 409);
    const busyBody = JSON.parse(busy.body);
    assert.equal(busyBody.reason, "in_progress");
  } finally {
    try {
      fs.unlinkSync(busyLockPath);
    } catch (_) {}
  }

  process.env.FASTFN_TELEGRAM_LOOP_LOCK = errorLockPath;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/getUpdates")) {
      return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: [] }) };
    }
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: {} }) };
  };
  global.Set = function BrokenSet() {
    throw new Error("set constructor failed");
  };

  try {
    const broken = await telegramAiReplyHandler({
      method: "GET",
      query: { mode: "loop", dry_run: "false", wait_secs: "5", poll_ms: "300" },
      body: "",
      env: { TELEGRAM_LOOP_ENABLED: "true", TELEGRAM_BOT_TOKEN: "test-token" },
      context: { timeout_ms: 1500 },
    });
    assert.equal(broken.status, 502);
    const brokenBody = JSON.parse(broken.body);
    assert.equal(brokenBody.mode, "loop");
  } finally {
    global.fetch = prevFetch;
    global.Set = originalSet;
    if (prevLock === undefined) {
      delete process.env.FASTFN_TELEGRAM_LOOP_LOCK;
    } else {
      process.env.FASTFN_TELEGRAM_LOOP_LOCK = prevLock;
    }
    try {
      fs.unlinkSync(errorLockPath);
    } catch (_) {}
  }
}

async function testTelegramAiReplyLoopThinkingAndForceClearWebhookBranches() {
  const os = require("node:os");
  const fs = require("node:fs");
  const prevFetch = global.fetch;
  const prevState = process.env.FASTFN_TELEGRAM_LOOP_STATE;
  const prevLock = process.env.FASTFN_TELEGRAM_LOOP_LOCK;

  const runLoop = async (fetchImpl, extraQuery = {}) => {
    const statePath = path.join(os.tmpdir(), `fastfn-loop-branches-${Date.now()}-${Math.random()}.json`);
    const lockPath = path.join(os.tmpdir(), `fastfn-loop-branches-${Date.now()}-${Math.random()}.lock`);
    process.env.FASTFN_TELEGRAM_LOOP_STATE = statePath;
    process.env.FASTFN_TELEGRAM_LOOP_LOCK = lockPath;
    global.fetch = fetchImpl;
    try {
      return await telegramAiReplyHandler({
        method: "GET",
        query: {
          mode: "loop",
          dry_run: "false",
          chat_id: "123",
          wait_secs: "5",
          poll_ms: "300",
          max_replies: "1",
          ...extraQuery,
        },
        body: "",
        env: {
          TELEGRAM_LOOP_ENABLED: "true",
          TELEGRAM_BOT_TOKEN: "test-token",
          OPENAI_API_KEY: "test-key",
          OPENAI_BASE_URL: "https://api.openai.com/v1",
        },
        context: { timeout_ms: 1500 },
      });
    } finally {
      try {
        fs.unlinkSync(statePath);
      } catch (_) {}
      try {
        fs.unlinkSync(lockPath);
      } catch (_) {}
    }
  };

  try {
    const clearConflict = await runLoop(async (url) => {
      const u = String(url);
      if (u.includes("/deleteWebhook")) {
        return { ok: false, status: 500, text: async () => "delete webhook failed" };
      }
      if (u.includes("/getUpdates")) {
        return {
          ok: false,
          status: 409,
          text: async () => JSON.stringify({ ok: false, error_code: 409, description: "Conflict active webhook" }),
        };
      }
      return { ok: false, status: 404, text: async () => "not found" };
    }, { force_clear_webhook: "true", send_prompt: "false" });
    assert.equal(clearConflict.status, 409);

    let loopThinkingCalls = 0;
    const thinkingWithFallback = await runLoop(async (url, opts = {}) => {
      const u = String(url);
      if (u.includes("/getUpdates")) {
        loopThinkingCalls += 1;
        if (loopThinkingCalls === 1) {
          return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: [] }) };
        }
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({
            ok: true,
            result: [
              {
                update_id: 200,
                message: { message_id: 10, chat: { id: 123 }, text: "loop thinking", from: { is_bot: false } },
              },
            ],
          }),
        };
      }
      if (u.includes("/sendChatAction")) {
        if (loopThinkingCalls < 3) {
          throw new Error("fetch failed typing");
        }
        throw new Error("typing hard failure");
      }
      if (u.includes("/chat/completions")) {
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({ choices: [{ message: { content: "loop-reply" } }] }),
        };
      }
      if (u.includes("/sendMessage")) {
        const body = JSON.parse(String(opts.body || "{}"));
        if (body && body.text === "Pensando...") {
          throw new Error("fallback send failed");
        }
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({ ok: true, result: { message_id: 12 } }),
        };
      }
      return { ok: false, status: 404, text: async () => "not found" };
    }, {
      show_thinking: "true",
      thinking_mode: "typing",
      thinking_fallback_text: "true",
      thinking_text: "Pensando...",
      thinking_min_ms: "0",
    });
    assert.equal(thinkingWithFallback.status, 200);

    let textModeCalls = 0;
    const textThinking = await runLoop(async (url) => {
      const u = String(url);
      if (u.includes("/getUpdates")) {
        textModeCalls += 1;
        if (textModeCalls === 1) {
          return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: [] }) };
        }
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({
            ok: true,
            result: [
              {
                update_id: 201,
                message: { message_id: 11, chat: { id: 123 }, text: "loop text mode", from: { is_bot: false } },
              },
            ],
          }),
        };
      }
      if (u.includes("/sendMessage")) {
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({ ok: true, result: { message_id: 13 } }),
        };
      }
      if (u.includes("/chat/completions")) {
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({ choices: [{ message: { content: "loop-reply-text" } }] }),
        };
      }
      return { ok: false, status: 404, text: async () => "not found" };
    }, {
      show_thinking: "true",
      thinking_mode: "text",
      thinking_text: "Procesando...",
    });
    assert.equal(textThinking.status, 200);
  } finally {
    global.fetch = prevFetch;
    if (prevState === undefined) {
      delete process.env.FASTFN_TELEGRAM_LOOP_STATE;
    } else {
      process.env.FASTFN_TELEGRAM_LOOP_STATE = prevState;
    }
    if (prevLock === undefined) {
      delete process.env.FASTFN_TELEGRAM_LOOP_LOCK;
    } else {
      process.env.FASTFN_TELEGRAM_LOOP_LOCK = prevLock;
    }
  }
}

function resetWhatsappRuntimeState() {
  const state = global.__fastfn_whatsapp_runtime;
  if (!state || typeof state !== "object") {
    return;
  }
  if (state.reconnectTimer) {
    clearTimeout(state.reconnectTimer);
  }
  state.socket = null;
  state.connecting = false;
  state.connected = false;
  state.me = null;
  state.lastQr = null;
  state.lastQrAt = null;
  state.lastError = null;
  state.reconnectTimer = null;
  state.inbox = [];
  state.outbox = [];
}

async function testWhatsappActionGuardsAndStatus() {
  resetWhatsappRuntimeState();

  const intro = await whatsappHandler({ method: "GET", query: { action: "intro" }, body: "", env: {} });
  assert.equal(intro.status, 200);
  const introBody = JSON.parse(intro.body);
  assert.equal(introBody.runtime, "node");
  assert.equal(introBody.function, "whatsapp");
  assert.ok(Array.isArray(introBody.actions));

  const intro405 = await whatsappHandler({ method: "POST", query: { action: "intro" }, body: "{}", env: {} });
  assert.equal(intro405.status, 405);

  const status = await whatsappHandler({ method: "GET", query: { action: "status" }, body: "", env: {} });
  assert.equal(status.status, 200);
  const statusBody = JSON.parse(status.body);
  assert.equal(statusBody.runtime, "node");
  assert.equal(statusBody.function, "whatsapp");

  const status405 = await whatsappHandler({ method: "POST", query: { action: "status" }, body: "{}", env: {} });
  assert.equal(status405.status, 405);

  const unknown = await whatsappHandler({ method: "GET", query: { action: "not-real" }, body: "", env: {} });
  assert.equal(unknown.status, 400);
}

async function testWhatsappInboxOutboxAndQrRaw() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_whatsapp_runtime;
  state.inbox = [
    { id: "i1", text: "one" },
    { id: "i2", text: "two" },
  ];
  state.outbox = [
    { id: "o1", text: "one" },
    { id: "o2", text: "two" },
  ];
  state.lastQr = "unit-qr-value";
  state.lastQrAt = 123456;

  const inbox = await whatsappHandler({ method: "GET", query: { action: "inbox", limit: "1" }, body: "", env: {} });
  assert.equal(inbox.status, 200);
  const inboxBody = JSON.parse(inbox.body);
  assert.equal(inboxBody.total, 2);
  assert.equal(inboxBody.messages.length, 1);

  const inbox405 = await whatsappHandler({ method: "POST", query: { action: "inbox" }, body: "{}", env: {} });
  assert.equal(inbox405.status, 405);

  const outbox = await whatsappHandler({ method: "GET", query: { action: "outbox", limit: "1" }, body: "", env: {} });
  assert.equal(outbox.status, 200);
  const outboxBody = JSON.parse(outbox.body);
  assert.equal(outboxBody.total, 2);
  assert.equal(outboxBody.messages.length, 1);

  const outbox405 = await whatsappHandler({ method: "POST", query: { action: "outbox" }, body: "{}", env: {} });
  assert.equal(outbox405.status, 405);

  const qrRaw = await whatsappHandler({ method: "GET", query: { action: "qr", format: "raw" }, body: "", env: {} });
  assert.equal(qrRaw.status, 200);
  const qrBody = JSON.parse(qrRaw.body);
  assert.equal(qrBody.qr, "unit-qr-value");
  assert.equal(qrBody.last_qr_at, 123456);
}

async function testWhatsappSendPathsAndBodyValidation() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_whatsapp_runtime;

  const badJson = await whatsappHandler({
    method: "POST",
    query: { action: "send" },
    body: "{invalid-json",
    env: {},
  });
  assert.equal(badJson.status, 400);

  const missingText = await whatsappHandler({
    method: "POST",
    query: { action: "send" },
    body: JSON.stringify({ to: "15551234567" }),
    env: {},
  });
  assert.equal(missingText.status, 400);

  const sentItems = [];
  state.connected = true;
  state.socket = {
    sendMessage: async (jid, payload) => {
      sentItems.push({ jid, payload });
      return { key: { id: "msg-unit-1" } };
    },
  };

  const ok = await whatsappHandler({
    method: "POST",
    query: { action: "send" },
    body: JSON.stringify({ to: "15551234567", text: "hola unit" }),
    env: {},
  });
  assert.equal(ok.status, 200);
  const okBody = JSON.parse(ok.body);
  assert.equal(okBody.ok, true);
  assert.equal(okBody.to, "15551234567@s.whatsapp.net");
  assert.equal(sentItems.length, 1);
  assert.equal(sentItems[0].jid, "15551234567@s.whatsapp.net");

  const invalidTo = await whatsappHandler({
    method: "POST",
    query: { action: "send" },
    body: JSON.stringify({ to: "123", text: "hola unit" }),
    env: {},
  });
  assert.equal(invalidTo.status, 500);
  const invalidBody = JSON.parse(invalidTo.body);
  assert.ok(String(invalidBody.error || "").includes("invalid WhatsApp number"));
}

async function testWhatsappChatErrorAndNoRecipientPaths() {
  resetWhatsappRuntimeState();

  const missingText = await whatsappHandler({
    method: "POST",
    query: { action: "chat" },
    body: JSON.stringify({}),
    env: {},
  });
  assert.equal(missingText.status, 400);

  const missingKey = await whatsappHandler({
    method: "POST",
    query: { action: "chat" },
    body: JSON.stringify({ text: "hola" }),
    env: {},
  });
  assert.equal(missingKey.status, 500);
  const missingKeyBody = JSON.parse(missingKey.body);
  assert.ok(String(missingKeyBody.error || "").includes("missing OPENAI_API_KEY"));

  const prevFetch = global.fetch;
  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/responses")) {
      return { ok: true, status: 200, json: async () => ({ output_text: "unit-chat-ok" }) };
    }
    return { ok: false, status: 404, text: async () => "not found", json: async () => ({}) };
  };
  try {
    const noRecipient = await whatsappHandler({
      method: "POST",
      query: { action: "chat" },
      body: JSON.stringify({ text: "responde sin destinatario" }),
      env: {
        OPENAI_API_KEY: "test-key",
        OPENAI_BASE_URL: "https://api.openai.com/v1",
      },
    });
    assert.equal(noRecipient.status, 200);
    const body = JSON.parse(noRecipient.body);
    assert.equal(body.ok, true);
    assert.equal(body.sent, false);
    assert.equal(body.ai_reply, "unit-chat-ok");
  } finally {
    global.fetch = prevFetch;
  }
}

async function testWhatsappChatToolsContext() {
  const prevFetch = global.fetch;
  let responsesPayload = null;

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/fn/request-inspector")) {
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
        text: "Usa [[fn:request-inspector?key=wa|GET]] y [[http:https://api.ipify.org?format=json]]",
      }),
      env: {
        OPENAI_API_KEY: "test-key",
        OPENAI_BASE_URL: "https://api.openai.com/v1",
        WHATSAPP_TOOLS_ENABLED: "true",
        WHATSAPP_TOOL_ALLOW_FN: "request-inspector",
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

async function testWhatsappMethodGuardsParseVariantsAndClosePaths() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_whatsapp_runtime;

  const nonObjectEvent = await whatsappHandler("not-an-object");
  assert.equal(nonObjectEvent.status, 200);

  const connect405 = await whatsappHandler({
    method: "GET",
    query: { action: "connect" },
    body: "",
    env: {},
  });
  assert.equal(connect405.status, 405);

  const disconnect405 = await whatsappHandler({
    method: "GET",
    query: { action: "disconnect" },
    body: "",
    env: {},
  });
  assert.equal(disconnect405.status, 405);

  const qr405 = await whatsappHandler({
    method: "POST",
    query: { action: "qr" },
    body: "",
    env: {},
  });
  assert.equal(qr405.status, 405);

  const send405 = await whatsappHandler({
    method: "GET",
    query: { action: "send" },
    body: { to: "15551234567", text: "hi" },
    env: {},
  });
  assert.equal(send405.status, 405);

  const send405Numeric = await whatsappHandler({
    method: "GET",
    query: { action: "send" },
    body: 42,
    env: {},
  });
  assert.equal(send405Numeric.status, 405);

  const chat405 = await whatsappHandler({
    method: "GET",
    query: { action: "chat" },
    body: {},
    env: {},
  });
  assert.equal(chat405.status, 405);

  state.connected = true;
  state.socket = {};
  const connectFast = await whatsappHandler({
    method: "POST",
    query: { action: "connect" },
    body: {},
    env: {},
  });
  assert.equal(connectFast.status, 200);

  state.reconnectTimer = setTimeout(() => {}, 10000);
  state.connected = true;
  state.socket = {
    end: () => {
      throw new Error("end failed");
    },
  };
  const disconnectOk = await whatsappHandler({
    method: "POST",
    query: { action: "disconnect" },
    body: "{}",
    env: {},
  });
  assert.equal(disconnectOk.status, 200);

  const fs = require("node:fs");
  const originalRmSync = fs.rmSync;
  fs.rmSync = () => {
    throw new Error("rm failed");
  };
  try {
    state.connected = true;
    state.socket = {
      logout: async () => {
        throw new Error("logout failed");
      },
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
}

async function testWhatsappChatAiOutputFallbacksAndErrors() {
  resetWhatsappRuntimeState();
  const prevFetch = global.fetch;
  const responsePayloads = [];

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/responses")) {
      const req = JSON.parse(String(opts.body || "{}"));
      responsePayloads.push(req);
      const call = responsePayloads.length;
      if (call === 1) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            output: [{ content: [{ text: "from-output-array" }] }],
          }),
        };
      }
      if (call === 2) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            choices: [{ message: { content: "from-choices" } }],
          }),
        };
      }
      if (call === 3) {
        return { ok: true, status: 200, json: async () => ({}) };
      }
      return {
        ok: false,
        status: 429,
        text: async () => "rate limited",
        json: async () => ({}),
      };
    }
    return { ok: false, status: 404, text: async () => "not found", json: async () => ({}) };
  };

  try {
    const env = {
      OPENAI_API_KEY: "test-key",
      OPENAI_BASE_URL: "https://api.openai.com/v1",
    };
    const ai1 = await whatsappHandler({
      method: "POST",
      query: { action: "chat" },
      body: JSON.stringify({
        text: "hola uno",
        ai: { max_output_tokens: 77, temperature: 0.2 },
      }),
      env,
    });
    assert.equal(ai1.status, 200);
    const ai1Body = JSON.parse(ai1.body);
    assert.equal(ai1Body.ai_reply, "from-output-array");
    assert.equal(responsePayloads[0].max_output_tokens, 77);
    assert.equal(responsePayloads[0].temperature, 0.2);

    const ai2 = await whatsappHandler({
      method: "POST",
      query: { action: "chat" },
      body: JSON.stringify({ text: "hola dos" }),
      env,
    });
    assert.equal(ai2.status, 200);
    const ai2Body = JSON.parse(ai2.body);
    assert.equal(ai2Body.ai_reply, "from-choices");

    const ai3 = await whatsappHandler({
      method: "POST",
      query: { action: "chat" },
      body: JSON.stringify({ text: "hola tres" }),
      env,
    });
    assert.equal(ai3.status, 500);
    const ai3Body = JSON.parse(ai3.body);
    assert.ok(String(ai3Body.error || "").includes("did not include text"));

    const ai4 = await whatsappHandler({
      method: "POST",
      query: { action: "chat" },
      body: JSON.stringify({ text: "hola cuatro" }),
      env,
    });
    assert.equal(ai4.status, 500);
    const ai4Body = JSON.parse(ai4.body);
    assert.ok(String(ai4Body.error || "").includes("ai request failed"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testWhatsappToolDirectiveFailureAndAutoNewsBranches() {
  resetWhatsappRuntimeState();
  const prevFetch = global.fetch;
  const responsePayloads = [];

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/fn/request-inspector")) {
      throw new Error("tool fn boom");
    }
    if (u.includes("/fn/telegram-ai-digest")) {
      return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, digest: "ok" }) };
    }
    if (u.includes("api.ipify.org")) {
      return { ok: true, status: 200, text: async () => "203.0.113.55" };
    }
    if (u.includes("wttr.in")) {
      return { ok: true, status: 200, text: async () => JSON.stringify({ current: "sun" }) };
    }
    if (u.includes("/responses")) {
      responsePayloads.push(JSON.parse(String(opts.body || "{}")));
      return { ok: true, status: 200, json: async () => ({ output_text: "ok-tools" }) };
    }
    return { ok: false, status: 404, text: async () => "not found", json: async () => ({}) };
  };

  try {
    const env = {
      OPENAI_API_KEY: "test-key",
      OPENAI_BASE_URL: "https://api.openai.com/v1",
      WHATSAPP_TOOLS_ENABLED: "true",
      WHATSAPP_TOOL_ALLOW_FN: "request-inspector,telegram-ai-digest",
      WHATSAPP_TOOL_ALLOW_HTTP_HOSTS: "api.ipify.org,wttr.in",
      WHATSAPP_AUTO_TOOLS: "true",
    };

    const failingTools = await whatsappHandler({
      method: "POST",
      query: { action: "chat", tool_allow_hosts: "wttr.in", tool_allow_fn: "request-inspector" },
      body: JSON.stringify({
        text: "[[fn:not_allowed|GET]] [[fn:request-inspector|TRACE]] [[http:https://api.ipify.org?format=json]] [[http:https://[bad]] [[fn:request-inspector?key=1|GET]]",
      }),
      env,
    });
    assert.equal(failingTools.status, 200);
    const failUser = (((responsePayloads[0] || {}).input || []).find((item) => item && item.role === "user") || {}).content || "";
    assert.ok(String(failUser).includes("function not allowed"));
    assert.ok(String(failUser).includes("method not allowed"));
    assert.ok(String(failUser).includes("host not allowed"));
    assert.ok(String(failUser).includes("invalid url"));
    assert.ok(String(failUser).includes("tool fn boom"));

    const autoNews = await whatsappHandler({
      method: "POST",
      query: { action: "chat", tool_allow_hosts: "ipify.org,wttr.in", auto_tools: "true" },
      body: JSON.stringify({ text: "dame mi ip y un news digest ahora" }),
      env,
    });
    assert.equal(autoNews.status, 200);
    const autoUser = (((responsePayloads[1] || {}).input || []).find((item) => item && item.role === "user") || {}).content || "";
    assert.ok(String(autoUser).includes("api.ipify.org"));
    assert.ok(String(autoUser).includes("telegram-ai-digest"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testWhatsappConnectQrLifecycleWithMocks() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_whatsapp_runtime;
  const listeners = {};
  const fakeSocket = {
    user: { id: "bot@s.whatsapp.net" },
    ev: {
      on: (name, cb) => {
        listeners[name] = cb;
        if (name === "connection.update") {
          cb({ qr: "unit-qr-token" });
          cb({ connection: "open" });
        }
      },
    },
    sendMessage: async (jid, payload) => ({ key: { id: `sent-${jid}-${payload.text.length}` } }),
    logout: async () => {},
    end: () => {},
  };

  const fakeBaileys = {
    useMultiFileAuthState: async () => ({ state: {}, saveCreds: () => {} }),
    fetchLatestBaileysVersion: async () => ({ version: [2, 3000, 999999] }),
    makeWASocket: () => fakeSocket,
    Browsers: {
      macOS: () => "FastFnTest",
    },
  };
  const fakeQr = {
    toString: async (value) => `<svg>${value}</svg>`,
    toBuffer: async () => Buffer.from([0, 1, 2, 3]),
  };

  await withPatchedModuleLoad(
    {
      "@whiskeysockets/baileys": fakeBaileys,
      qrcode: fakeQr,
    },
    async () => {
      const connect = await whatsappHandler({
        method: "POST",
        query: { action: "connect" },
        body: "{}",
        env: {},
      });
      assert.equal(connect.status, 200);
      const connectBody = JSON.parse(connect.body);
      assert.equal(connectBody.ok, true);
      assert.equal(connectBody.connected, true);

      const qrRaw = await whatsappHandler({
        method: "GET",
        query: { action: "qr", format: "raw" },
        body: "",
        env: {},
      });
      assert.equal(qrRaw.status, 200);
      const qrRawBody = JSON.parse(qrRaw.body);
      assert.equal(qrRawBody.qr, "unit-qr-token");

      const qrSvg = await whatsappHandler({
        method: "GET",
        query: { action: "qr", format: "svg" },
        body: "",
        env: {},
      });
      assert.equal(qrSvg.status, 200);
      assert.equal(qrSvg.headers["Content-Type"], "image/svg+xml");

      const qrPng = await whatsappHandler({
        method: "GET",
        query: { action: "qr", format: "png", size: "32" },
        body: "",
        env: {},
      });
      assert.equal(qrPng.status, 200);
      assert.equal(qrPng.is_base64, true);

      const upsert = listeners["messages.upsert"];
      assert.equal(typeof upsert, "function");
      upsert({
        messages: [
          {
            key: { id: "m1", fromMe: false, remoteJid: "111@s.whatsapp.net" },
            message: { conversation: "hola 1" },
            messageTimestamp: 1,
            pushName: "Unit A",
          },
          {
            key: { id: "m2", fromMe: false, remoteJid: "222@s.whatsapp.net" },
            message: { extendedTextMessage: { text: "hola 2" } },
            messageTimestamp: 2,
          },
          {
            key: { id: "m3", fromMe: false, remoteJid: "333@s.whatsapp.net" },
            message: { imageMessage: { caption: "img" } },
            messageTimestamp: 3,
          },
          {
            key: { id: "m4", fromMe: true, remoteJid: "444@s.whatsapp.net" },
            message: { videoMessage: { caption: "vid" } },
            messageTimestamp: 4,
          },
        ],
      });

      const inbox = await whatsappHandler({
        method: "GET",
        query: { action: "inbox", limit: "5" },
        body: "",
        env: {},
      });
      assert.equal(inbox.status, 200);
      const inboxBody = JSON.parse(inbox.body);
      assert.equal(inboxBody.total >= 3, true);

      const outbox = await whatsappHandler({
        method: "GET",
        query: { action: "outbox", limit: "5" },
        body: "",
        env: {},
      });
      assert.equal(outbox.status, 200);
      const outboxBody = JSON.parse(outbox.body);
      assert.equal(outboxBody.total >= 1, true);

      const closeUpdate = listeners["connection.update"];
      closeUpdate({ connection: "close", lastDisconnect: { error: { output: { statusCode: 401 } } } });
      assert.equal(state.lastError, "logged_out");
      closeUpdate({ connection: "close", lastDisconnect: { error: new Error("temporary network fail") } });
      assert.equal(typeof state.lastError, "string");
      assert.equal(state.lastError.includes("temporary network fail"), true);
      if (state.reconnectTimer) {
        clearTimeout(state.reconnectTimer);
        state.reconnectTimer = null;
      }

      const disconnect = await whatsappHandler({
        method: "DELETE",
        query: { action: "disconnect" },
        body: "",
        env: {},
      });
      assert.equal(disconnect.status, 200);

      const reset405 = await whatsappHandler({
        method: "GET",
        query: { action: "reset-session" },
        body: "",
        env: {},
      });
      assert.equal(reset405.status, 405);

      const resetOk = await whatsappHandler({
        method: "DELETE",
        query: { action: "reset-session" },
        body: "",
        env: {},
      });
      assert.equal(resetOk.status, 200);
      const resetBody = JSON.parse(resetOk.body);
      assert.equal(resetBody.ok, true);
    }
  );
}

async function testWhatsappConnectErrorPathsWithMocks() {
  resetWhatsappRuntimeState();
  const fs = require("node:fs");
  const originalMkdirSync = fs.mkdirSync;
  fs.mkdirSync = () => {
    throw new Error("auth state failed");
  };
  try {
    const connect = await whatsappHandler({
      method: "POST",
      query: { action: "connect" },
      body: "{}",
      env: {},
    });
    assert.equal(connect.status, 500);
    const connectBody = JSON.parse(connect.body);
    assert.ok(String(connectBody.error || "").includes("auth state failed"));

    const qr = await whatsappHandler({
      method: "GET",
      query: { action: "qr" },
      body: "",
      env: {},
    });
    assert.equal(qr.status, 500);
    const qrBody = JSON.parse(qr.body);
    assert.ok(String(qrBody.error || "").includes("auth state failed"));
  } finally {
    fs.mkdirSync = originalMkdirSync;
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

async function testTelegramAiDigestDryRunMinIntervalAndAiFallbacks() {
  const os = require("node:os");
  const fs = require("node:fs");
  const stateFile = path.join(os.tmpdir(), `fastfn-digest-state-branches-${Date.now()}-${Math.random()}.json`);
  const lockFile = stateFile + ".lock";
  const prevFetch = global.fetch;
  const prevState = process.env.FASTFN_DIGEST_STATE;
  const prevToken = process.env.TELEGRAM_BOT_TOKEN;
  process.env.FASTFN_DIGEST_STATE = stateFile;
  process.env.TELEGRAM_BOT_TOKEN = "test-token";
  try {
    const missingChat = await telegramAiDigestHandler({
      query: { dry_run: "false", preview: "false" },
      headers: {},
      env: {},
      context: { timeout_ms: 2000 },
    });
    assert.equal(missingChat.status, 400);

    const dryRun = await telegramAiDigestHandler({
      query: { chat_id: "444", dry_run: "true" },
      headers: {},
      env: {},
      context: { timeout_ms: 2000 },
    });
    assert.equal(dryRun.status, 200);
    const dryBody = JSON.parse(dryRun.body);
    assert.equal(dryBody.dry_run, true);

    fs.writeFileSync(stateFile, JSON.stringify({ ts: Date.now() }), "utf8");
    const minInterval = await telegramAiDigestHandler({
      query: {
        chat_id: "444",
        dry_run: "false",
        min_interval_secs: "3600",
        include_ai: "false",
        include_news: "false",
        include_weather: "false",
      },
      headers: {},
      env: {},
      context: { timeout_ms: 2000 },
    });
    assert.equal(minInterval.status, 200);
    const minIntervalBody = JSON.parse(minInterval.body);
    assert.equal(minIntervalBody.skipped, true);
    assert.equal(minIntervalBody.reason, "min_interval_secs");

    fs.writeFileSync(stateFile, JSON.stringify({ ts: 0 }), "utf8");
    let sendCalls = 0;
    global.fetch = async (url, opts = {}) => {
      const u = String(url);
      if (u.includes("/chat/completions")) {
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({ choices: [{ message: { content: "AI summary" } }] }),
        };
      }
      if (u.includes("/sendMessage")) {
        sendCalls += 1;
        if (sendCalls === 1) {
          return { ok: false, status: 400, text: async () => "parse_mode error" };
        }
        return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: { message_id: 88 } }) };
      }
      return { ok: false, status: 404, text: async () => "not found" };
    };

    const sent = await telegramAiDigestHandler({
      query: {
        chat_id: "444",
        dry_run: "false",
        min_interval_secs: "0",
        include_ai: "true",
        include_news: "false",
        include_weather: "false",
      },
      headers: {},
      env: { OPENAI_API_KEY: "test-openai-key" },
      context: { timeout_ms: 2000 },
    });
    assert.equal(sent.status, 200);
    const sentBody = JSON.parse(sent.body);
    assert.equal(sentBody.ok, true);
    assert.equal(sentBody.used_ai, true);
    assert.equal(sendCalls, 2);
  } finally {
    global.fetch = prevFetch;
    if (prevState === undefined) delete process.env.FASTFN_DIGEST_STATE; else process.env.FASTFN_DIGEST_STATE = prevState;
    if (prevToken === undefined) delete process.env.TELEGRAM_BOT_TOKEN; else process.env.TELEGRAM_BOT_TOKEN = prevToken;
    try { fs.unlinkSync(stateFile); } catch (_) {}
    try { fs.unlinkSync(lockFile); } catch (_) {}
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
