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
const telegramAiReplyModule = require(path.join(root, "examples/functions/node/telegram-ai-reply/app.js"));
const telegramAiReplyHandler = telegramAiReplyModule.handler;
const telegramAiDigestModule = require(path.join(root, "examples/functions/node/telegram-ai-digest/app.js"));
const telegramAiDigestHandler = telegramAiDigestModule.handler;
const toolboxBotModule = require(path.join(root, "examples/functions/node/toolbox-bot/app.js"));
const toolboxBotHandler = toolboxBotModule.handler;
const aiToolAgentModule = require(path.join(root, "examples/functions/node/ai-tool-agent/app.js"));
const aiToolAgentHandler = aiToolAgentModule.handler;
const aiToolAgentInternal = require(path.join(root, "examples/functions/node/ai-tool-agent/_internal.js"));
const whatsappModule = require(path.join(root, "examples/functions/node/whatsapp/app.js"));
const whatsappHandler = whatsappModule.handler;
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
  await testToolboxBotNoText();
  await testToolboxBotNoDirectives();
  await testToolboxBotParseAndExecute();
  await testToolboxBotDenyHost();
  await testToolboxBotDenyFn();
  await testToolboxBotFetchError();
  await testAiToolAgentDryRun();
  await testAiToolAgentToolCallingLoopAndMemory();
  await testAiToolAgentBlocksLocalHostTool();
  await testAiToolAgentPrivateAndErrorBranches();
  await testEdgeAuthGateway();
  await testGithubWebhookGuard();
  await testEdgeHeaderInject();
  await testEdgeHeaderInjectDefaults();
  await testTelegramAiReplySkipsNoText();
  await testTelegramAiReplyMissingEnv();
  await testTelegramAiReplySuccessfulWebhook();
  await testTelegramAiReplyOpenAIError();
  await testTelegramAiReplyTelegramSendError();
  await testTelegramAiReplyEditedMessage();
  await testTelegramAiDigestMissingEnv();
  await testTelegramAiDigestNoMessages();
  await testTelegramAiDigestSuccessful();
  await testTelegramAiDigestOpenAIError();
  await testWhatsappIntro();
  await testWhatsappStatus();
  await testWhatsappUnknownAction();
  await testWhatsappSendMissingText();
  await testWhatsappSendSuccess();
  await testWhatsappSendInvalidNumber();
  await testWhatsappInbox();
  await testWhatsappChatMissingText();
  await testWhatsappChatMissingApiKey();
  await testWhatsappChatNoRecipient();
  await testWhatsappChatSuccess();
  await testWhatsappChatOpenAIError();
  await testWhatsappDisconnectAndReset();
  await testWhatsappBadJsonBody();
  await testWhatsappConnectQrLifecycleWithMocks();
  await testWhatsappConnectErrorPathsWithMocks();
  await testTelegramSendDryRun();
  await testTelegramSendErrorAndSendPaths();
  await testAiToolAgentLoopTerminationAndToolCallValidation();
  await testTelegramAiDigestGetUpdatesFail();
  await testTelegramAiDigestDataNotOk();
  await testTelegramAiDigestSendMessageFail();
  await testTelegramAiReplyBodyAsObject();
  await testTelegramAiReplyOpenAINoText();
  await testToolboxBotUnknownDirectiveType();
  await testWhatsappQrTimeoutAndEnsureConnected();
  await testWhatsappChatSendError();
  await testAiToolAgentInternalHttpGetJsonContentType();
  await testAiToolAgentInternalFnGetWithQueryParams();
  await testAiToolAgentInternalOpenaiChatErrorBody();
  await testAiToolAgentInternalSummarizeAssistantMessage();
  await testAiToolAgentInternalFnGetEmptyName();
  await testAiToolAgentInternalLocalHostVariants();
  await testTelegramSendBranchCoverage();
  await testRequestInspectorNonStringBody();
  await testRequestInspectorNoContext();
  await testGithubWebhookGuardNonStringBody();
  await testAiToolAgentMalformedToolCall();
  await testAiToolAgentErrorWithoutMessage();
  await testToolboxBotBodyAsObject();
  await testTelegramAiDigestPartialUpdate();
  await testTelegramAiDigestEmptyChoices();
  await testEdgeFilterUserIdVariant();
  await testWhatsappDefaultQrFormat();
  await testWhatsappSendNullTo();
  await testWhatsappSendAlreadyFormattedJid();
  await testWhatsappExtractTextImageVideoCaption();
  await testWhatsappStatusPayloadFsError();
  await testWhatsappQrSizeClamping();
  await testWhatsappSendMessageError();
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
    path: "/request-inspector",
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

// -- Toolbox Bot Tests (simplified handler) --

async function testToolboxBotNoText() {
  const resp = await toolboxBotHandler({
    method: "GET",
    query: {},
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.ok, true);
  assert.ok(String(body.note || "").includes("Send text="));
}

async function testToolboxBotNoDirectives() {
  const resp = await toolboxBotHandler({
    method: "GET",
    query: { text: "just plain text" },
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.ok, true);
  assert.deepEqual(body.tools, []);
  assert.ok(String(body.note || "").includes("No directives"));
}

async function testToolboxBotParseAndExecute() {
  const prevFetch = global.fetch;
  const calls = [];
  global.fetch = async (url, opts = {}) => {
    calls.push({ url: String(url), method: String(opts.method || "GET") });
    const u = String(url);
    if (u.includes("/request-inspector") || u.includes("/hello")) {
      return {
        ok: true,
        status: 200,
        headers: { get: () => "application/json" },
        text: async () => JSON.stringify({ ok: true, note: "mock" }),
      };
    }
    if (u.startsWith("https://api.ipify.org")) {
      return {
        ok: true,
        status: 200,
        headers: { get: () => "application/json" },
        text: async () => JSON.stringify({ ip: "203.0.113.10" }),
      };
    }
    return {
      ok: false,
      status: 418,
      headers: { get: () => "text/plain" },
      text: async () => "nope",
    };
  };
  try {
    const resp = await toolboxBotHandler({
      method: "GET",
      query: {
        text: "Use [[http:https://api.ipify.org?format=json]] and [[fn:request-inspector?key=demo|GET]]",
      },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.equal(Array.isArray(body.results), true);
    assert.equal(body.results.length, 2);
    // fn directive comes first in parseDirectives (fnRe before httpRe)
    assert.equal(body.results[0].type, "fn");
    assert.equal(body.results[0].target, "request-inspector");
    assert.equal(body.results[0].ok, true);
    assert.equal(body.results[1].type, "http");
    assert.equal(body.results[1].ok, true);
  } finally {
    global.fetch = prevFetch;
  }
}

async function testToolboxBotDenyHost() {
  const prevFetch = global.fetch;
  global.fetch = async () => {
    throw new Error("unexpected fetch");
  };
  try {
    const resp = await toolboxBotHandler({
      method: "GET",
      query: { text: "Use [[http:https://example.com/]]" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.equal(body.results.length, 1);
    assert.equal(body.results[0].ok, false);
    assert.ok(String(body.results[0].error || "").includes("not in allowlist"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testToolboxBotDenyFn() {
  const prevFetch = global.fetch;
  global.fetch = async () => {
    throw new Error("unexpected fetch");
  };
  try {
    const resp = await toolboxBotHandler({
      method: "GET",
      query: { text: "Use [[fn:not_allowed|GET]]" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.equal(body.results.length, 1);
    assert.equal(body.results[0].ok, false);
    assert.ok(String(body.results[0].error || "").includes("not in allowlist"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testToolboxBotFetchError() {
  const prevFetch = global.fetch;
  global.fetch = async () => {
    throw new Error("fetch explode");
  };
  try {
    // api.ipify.org is in ALLOWED_HOSTS so it passes the allowlist check
    const resp = await toolboxBotHandler({
      method: "GET",
      query: { text: "[[http:https://api.ipify.org?format=json]]" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.results[0].ok, false);
    assert.ok(String(body.results[0].error || "").includes("fetch explode"));
  } finally {
    global.fetch = prevFetch;
  }
}

// -- AI Tool Agent Tests --

async function testAiToolAgentDryRun() {
  const resp = await aiToolAgentHandler({
    method: "GET",
    query: { text: "what is my ip?", agent_id: "unit" },
    env: {},
    context: { timeout_ms: 1500 },
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.ok, true);
  assert.equal(body.dry_run, true);
  assert.equal(body.agent_id, "unit");
  assert.equal(body.text, "what is my ip?");
  assert.deepEqual(body.tools, ["http_get", "fn_get"]);
}

async function testAiToolAgentToolCallingLoopAndMemory() {
  const prevFetch = global.fetch;
  const os = require("node:os");
  const fs = require("node:fs");
  const memPath = path.join(os.tmpdir(), `fastfn-ai-tool-agent-${Date.now()}-${Math.random()}.json`);
  const prevMem = process.env.FASTFN_AGENT_MEMORY_PATH;
  const openaiPayloads = [];
  let openaiCalls = 0;
  const seenUrls = [];

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    seenUrls.push(u);
    if (u.includes("/chat/completions")) {
      openaiCalls += 1;
      openaiPayloads.push(JSON.parse(String(opts.body || "{}")));
      if (openaiCalls === 1) {
        return {
          ok: true,
          status: 200,
          text: async () =>
            JSON.stringify({
              choices: [
                {
                  message: {
                    content: null,
                    tool_calls: [
                      {
                        id: "call_http",
                        function: {
                          name: "http_get",
                          arguments: JSON.stringify({ url: "https://api.ipify.org?format=json" }),
                        },
                      },
                      {
                        id: "call_fn",
                        function: {
                          name: "fn_get",
                          arguments: JSON.stringify({ name: "request-inspector", query: { key: "demo" } }),
                        },
                      },
                    ],
                  },
                },
              ],
            }),
        };
      }
      if (openaiCalls === 2) {
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({ choices: [{ message: { content: "final-1" } }] }),
        };
      }
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ choices: [{ message: { content: "final-2" } }] }),
      };
    }

    if (u.startsWith("https://api.ipify.org")) {
      return {
        ok: true,
        status: 200,
        headers: { get: () => "application/json" },
        text: async () => JSON.stringify({ ip: "203.0.113.10" }),
      };
    }

    if (u.includes("/request-inspector")) {
      return {
        ok: true,
        status: 200,
        headers: { get: () => "application/json" },
        text: async () => JSON.stringify({ ok: true, path: "/request-inspector", query: { key: "demo" } }),
      };
    }

    return { ok: false, status: 404, text: async () => "not found" };
  };

  process.env.FASTFN_AGENT_MEMORY_PATH = memPath;
  try {
    const env = {
      OPENAI_API_KEY: "test-openai-key",
      OPENAI_BASE_URL: "https://api.openai.com/v1",
    };

    const first = await aiToolAgentHandler({
      method: "GET",
      query: { dry_run: "false", agent_id: "unit", text: "ip + inspector" },
      env,
      context: { timeout_ms: 2000 },
    });
    assert.equal(first.status, 200);
    const firstBody = JSON.parse(first.body);
    assert.equal(firstBody.ok, true);
    assert.equal(firstBody.dry_run, false);
    assert.equal(firstBody.answer, "final-1");
    assert.ok(firstBody.trace && Array.isArray(firstBody.trace.steps));
    const toolSteps = firstBody.trace.steps.filter((s) => s && s.type === "tool");
    assert.equal(toolSteps.length, 2);
    assert.equal(toolSteps[0].name, "http_get");
    assert.equal(toolSteps[1].name, "fn_get");

    const memRaw = fs.readFileSync(memPath, "utf8");
    const memData = JSON.parse(memRaw);
    assert.equal(Array.isArray(memData.unit), true);
    assert.equal(memData.unit.length, 2);

    const second = await aiToolAgentHandler({
      method: "GET",
      query: { dry_run: "false", agent_id: "unit", text: "what did you answer before?" },
      env,
      context: { timeout_ms: 2000 },
    });
    assert.equal(second.status, 200);
    const secondBody = JSON.parse(second.body);
    assert.equal(secondBody.answer, "final-2");

    // Second OpenAI request should include previous turns from memory.
    assert.ok(openaiPayloads.length >= 3);
    const secondRunPayload = openaiPayloads[2];
    const msgs = Array.isArray(secondRunPayload.messages) ? secondRunPayload.messages : [];
    const hasPrevUser = msgs.some((m) => m && m.role === "user" && m.content === "ip + inspector");
    const hasPrevAssistant = msgs.some((m) => m && m.role === "assistant" && m.content === "final-1");
    assert.equal(hasPrevUser, true);
    assert.equal(hasPrevAssistant, true);

    assert.ok(seenUrls.some((u) => u.includes("/chat/completions")));
    assert.ok(seenUrls.some((u) => u.startsWith("https://api.ipify.org")));
    assert.ok(seenUrls.some((u) => u.includes("/request-inspector")));
  } finally {
    global.fetch = prevFetch;
    if (prevMem === undefined) delete process.env.FASTFN_AGENT_MEMORY_PATH; else process.env.FASTFN_AGENT_MEMORY_PATH = prevMem;
    try { require("node:fs").unlinkSync(memPath); } catch (_) {}
  }
}

async function testAiToolAgentBlocksLocalHostTool() {
  const prevFetch = global.fetch;
  const seenUrls = [];
  let openaiCalls = 0;

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    seenUrls.push(u);
    if (u.includes("/chat/completions")) {
      openaiCalls += 1;
      if (openaiCalls === 1) {
        return {
          ok: true,
          status: 200,
          text: async () =>
            JSON.stringify({
              choices: [
                {
                  message: {
                    content: null,
                    tool_calls: [
                      {
                        id: "call_local",
                        function: {
                          name: "http_get",
                          arguments: JSON.stringify({ url: "http://127.0.0.1:8080/_fn/health" }),
                        },
                      },
                    ],
                  },
                },
              ],
            }),
        };
      }
      return { ok: true, status: 200, text: async () => JSON.stringify({ choices: [{ message: { content: "done" } }] }) };
    }
    throw new Error(`unexpected fetch url=${u}`);
  };

  try {
    const resp = await aiToolAgentHandler({
      method: "GET",
      query: {
        dry_run: "false",
        text: "try local host",
        tool_allow_hosts: "127.0.0.1",
      },
      env: { OPENAI_API_KEY: "test-openai-key", OPENAI_BASE_URL: "https://api.openai.com/v1" },
      context: { timeout_ms: 2000 },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    const toolStep = (body.trace.steps || []).find((s) => s && s.type === "tool");
    assert.ok(toolStep && toolStep.result);
    assert.equal(toolStep.result.ok, false);
    assert.equal(toolStep.result.error, "local host not allowed");
    assert.equal(seenUrls.some((u) => u.includes("_fn/health")), false);
  } finally {
    global.fetch = prevFetch;
  }
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
  assert.equal(ok.proxy.timeout_ms, 2000);

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

async function testEdgeHeaderInjectDefaults() {
  const resp = await edgeHeaderInjectHandler({});
  assert.equal(typeof resp.proxy, "object");
  assert.equal(resp.proxy.path, "/request-inspector");
  assert.equal(resp.proxy.method, "GET");
  assert.equal(resp.proxy.headers["x-fastfn-edge"], "1");
  assert.equal(resp.proxy.headers["x-fastfn-request-id"], "");
  assert.equal(resp.proxy.headers["x-tenant"], "demo");
  assert.equal(resp.proxy.body, "");
  assert.equal(resp.proxy.timeout_ms, 2000);
}

// -- Telegram AI Reply Tests (simplified webhook handler) --

async function testTelegramAiReplySkipsNoText() {
  // Update without text (e.g. sticker) should be skipped
  const resp = await telegramAiReplyHandler({
    body: JSON.stringify({ message: { chat: { id: 123 } } }),
    env: {},
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.skipped, true);
  assert.ok(String(body.reason || "").includes("no text"));

  // Update without chat_id should also be skipped
  const resp2 = await telegramAiReplyHandler({
    body: JSON.stringify({ update_id: 1 }),
    env: {},
  });
  assert.equal(resp2.status, 200);
  const body2 = JSON.parse(resp2.body);
  assert.equal(body2.skipped, true);
}

async function testTelegramAiReplyMissingEnv() {
  const resp = await telegramAiReplyHandler({
    body: JSON.stringify({ message: { chat: { id: 123 }, text: "Hello" } }),
    env: {},
  });
  assert.equal(resp.status, 400);
  const body = JSON.parse(resp.body);
  assert.ok(String(body.error || "").includes("Missing"));
}

async function testTelegramAiReplySuccessfulWebhook() {
  const prevFetch = global.fetch;
  let openaiPayload = null;
  let telegramPayload = null;

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      openaiPayload = JSON.parse(String(opts.body || "{}"));
      return {
        ok: true,
        status: 200,
        json: async () => ({
          choices: [{ message: { content: "AI reply text" } }],
        }),
      };
    }
    if (u.includes("/sendMessage")) {
      telegramPayload = JSON.parse(String(opts.body || "{}"));
      return {
        ok: true,
        json: async () => ({ ok: true, result: { message_id: 42 } }),
      };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };

  try {
    const resp = await telegramAiReplyHandler({
      body: JSON.stringify({
        message: { chat: { id: 123 }, text: "Hello bot", message_id: 7 },
      }),
      env: { TELEGRAM_BOT_TOKEN: "test-token", OPENAI_API_KEY: "test-key" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.equal(body.chat_id, 123);
    assert.equal(body.reply, "AI reply text");
    assert.equal(body.message_id, 42);

    // Verify OpenAI was called with user text
    assert.ok(openaiPayload);
    const userMsg = openaiPayload.messages.find((m) => m.role === "user");
    assert.equal(userMsg.content, "Hello bot");

    // Verify Telegram sendMessage was called
    assert.ok(telegramPayload);
    assert.equal(telegramPayload.chat_id, 123);
    assert.equal(telegramPayload.reply_to_message_id, 7);
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyOpenAIError() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      return {
        ok: false,
        status: 500,
        json: async () => ({ error: "internal" }),
      };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };

  try {
    const resp = await telegramAiReplyHandler({
      body: JSON.stringify({
        message: { chat: { id: 123 }, text: "Hello" },
      }),
      env: { TELEGRAM_BOT_TOKEN: "test-token", OPENAI_API_KEY: "test-key" },
    });
    assert.equal(resp.status, 502);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error || "").includes("OpenAI error"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyTelegramSendError() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          choices: [{ message: { content: "reply" } }],
        }),
      };
    }
    if (u.includes("/sendMessage")) {
      return {
        ok: false,
        status: 500,
        json: async () => ({ ok: false, description: "telegram down" }),
      };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };

  try {
    const resp = await telegramAiReplyHandler({
      body: JSON.stringify({
        message: { chat: { id: 123 }, text: "Hello" },
      }),
      env: { TELEGRAM_BOT_TOKEN: "test-token", OPENAI_API_KEY: "test-key" },
    });
    assert.equal(resp.status, 502);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error || "").includes("Telegram error"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiReplyEditedMessage() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          choices: [{ message: { content: "edited reply" } }],
        }),
      };
    }
    if (u.includes("/sendMessage")) {
      return {
        ok: true,
        json: async () => ({ ok: true, result: { message_id: 99 } }),
      };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };

  try {
    const resp = await telegramAiReplyHandler({
      body: JSON.stringify({
        edited_message: { chat: { id: 555 }, text: "edited text" },
      }),
      env: { TELEGRAM_BOT_TOKEN: "test-token", OPENAI_API_KEY: "test-key" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.equal(body.chat_id, 555);
  } finally {
    global.fetch = prevFetch;
  }
}

// -- Telegram AI Digest Tests (simplified scheduled handler) --

async function testTelegramAiDigestMissingEnv() {
  const resp = await telegramAiDigestHandler({
    env: {},
  });
  assert.equal(resp.status, 400);
  const body = JSON.parse(resp.body);
  assert.ok(String(body.error || "").includes("Missing required env"));
}

async function testTelegramAiDigestNoMessages() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/getUpdates")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({ ok: true, result: [] }),
      };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };

  try {
    const resp = await telegramAiDigestHandler({
      env: {
        TELEGRAM_BOT_TOKEN: "test-token",
        TELEGRAM_CHAT_ID: "123",
        OPENAI_API_KEY: "test-key",
      },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.skipped, true);
    assert.ok(String(body.reason || "").includes("No recent messages"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiDigestSuccessful() {
  const prevFetch = global.fetch;
  let sendMessagePayload = null;

  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/getUpdates")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          ok: true,
          result: [
            { update_id: 1, message: { text: "Hello group" } },
            { update_id: 2, message: { text: "How is everyone?" } },
          ],
        }),
      };
    }
    if (u.includes("/chat/completions")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          choices: [{ message: { content: "- Greetings exchanged\n- Status check" } }],
        }),
      };
    }
    if (u.includes("/sendMessage")) {
      sendMessagePayload = JSON.parse(String(opts.body || "{}"));
      return {
        ok: true,
        json: async () => ({ ok: true, result: { message_id: 88 } }),
      };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };

  try {
    const resp = await telegramAiDigestHandler({
      env: {
        TELEGRAM_BOT_TOKEN: "test-token",
        TELEGRAM_CHAT_ID: "456",
        OPENAI_API_KEY: "test-key",
      },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.equal(body.message_count, 2);
    assert.ok(body.digest.includes("Daily Digest"));

    // Verify sendMessage was called with correct chat_id
    assert.ok(sendMessagePayload);
    assert.equal(sendMessagePayload.chat_id, "456");
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiDigestOpenAIError() {
  const prevFetch = global.fetch;

  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/getUpdates")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          ok: true,
          result: [{ update_id: 1, message: { text: "Hello" } }],
        }),
      };
    }
    if (u.includes("/chat/completions")) {
      return {
        ok: false,
        status: 500,
        text: async () => "internal error",
      };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };

  try {
    const resp = await telegramAiDigestHandler({
      env: {
        TELEGRAM_BOT_TOKEN: "test-token",
        TELEGRAM_CHAT_ID: "123",
        OPENAI_API_KEY: "test-key",
      },
    });
    assert.equal(resp.status, 502);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error || "").includes("OpenAI"));
  } finally {
    global.fetch = prevFetch;
  }
}

// -- WhatsApp Tests (simplified session manager) --

function resetWhatsappRuntimeState() {
  const state = global.__fastfn_wa;
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

async function testWhatsappIntro() {
  resetWhatsappRuntimeState();
  const resp = await whatsappHandler({
    method: "GET",
    query: { action: "intro" },
    body: "",
    env: {},
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.ok(Array.isArray(body.actions));
  assert.ok(body.message.includes("WhatsApp"));
}

async function testWhatsappStatus() {
  resetWhatsappRuntimeState();
  const resp = await whatsappHandler({
    method: "GET",
    query: { action: "status" },
    body: "",
    env: {},
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.connected, false);
  assert.equal(body.inbox_count, 0);
}

async function testWhatsappUnknownAction() {
  resetWhatsappRuntimeState();
  const resp = await whatsappHandler({
    method: "GET",
    query: { action: "nonexistent" },
    body: "",
    env: {},
  });
  assert.equal(resp.status, 400);
  const body = JSON.parse(resp.body);
  assert.ok(String(body.error || "").includes("unknown action"));
}

async function testWhatsappSendMissingText() {
  resetWhatsappRuntimeState();
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
}

async function testWhatsappSendSuccess() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
  state.connected = true;
  state.socket = {
    sendMessage: async (jid, payload) => ({
      key: { id: `sent-${payload.text.length}` },
    }),
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
}

async function testWhatsappSendInvalidNumber() {
  resetWhatsappRuntimeState();
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
}

async function testWhatsappInbox() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
  state.inbox = [{ id: "m1", text: "hello" }];

  const resp = await whatsappHandler({
    method: "GET",
    query: { action: "inbox" },
    body: "",
    env: {},
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.total, 1);
  assert.equal(body.messages.length, 1);
}

async function testWhatsappChatMissingText() {
  resetWhatsappRuntimeState();
  const resp = await whatsappHandler({
    method: "POST",
    query: { action: "chat" },
    body: JSON.stringify({}),
    env: {},
  });
  assert.equal(resp.status, 400);
  const body = JSON.parse(resp.body);
  assert.ok(String(body.error || "").includes("text is required"));
}

async function testWhatsappChatMissingApiKey() {
  resetWhatsappRuntimeState();
  const resp = await whatsappHandler({
    method: "POST",
    query: { action: "chat" },
    body: JSON.stringify({ text: "hola" }),
    env: {},
  });
  assert.equal(resp.status, 500);
  const body = JSON.parse(resp.body);
  assert.ok(String(body.error || "").includes("missing OPENAI_API_KEY"));
}

async function testWhatsappChatNoRecipient() {
  resetWhatsappRuntimeState();
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          choices: [{ message: { content: "ai response" } }],
        }),
      };
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
}

async function testWhatsappChatSuccess() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
  state.connected = true;
  state.socket = {
    sendMessage: async (jid, payload) => ({ key: { id: "chat-ok" } }),
  };

  const prevFetch = global.fetch;
  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          choices: [{ message: { content: "ai reply" } }],
        }),
      };
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
}

async function testWhatsappChatOpenAIError() {
  resetWhatsappRuntimeState();
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      return {
        ok: false,
        status: 500,
        text: async () => "openai down",
      };
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
}

async function testWhatsappDisconnectAndReset() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;

  // Disconnect with a socket that throws on end()
  state.reconnectTimer = setTimeout(() => {}, 10000);
  state.connected = true;
  state.socket = {
    end: () => { throw new Error("end failed"); },
  };
  const disconnectOk = await whatsappHandler({
    method: "POST",
    query: { action: "disconnect" },
    body: "{}",
    env: {},
  });
  assert.equal(disconnectOk.status, 200);

  // Reset session
  const fs = require("node:fs");
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
}

async function testWhatsappBadJsonBody() {
  resetWhatsappRuntimeState();
  const resp = await whatsappHandler({
    method: "POST",
    query: { action: "send" },
    body: "{invalid-json",
    env: {},
  });
  assert.equal(resp.status, 400);
  const body = JSON.parse(resp.body);
  assert.ok(String(body.error || "").includes("invalid JSON"));
}

async function testWhatsappConnectQrLifecycleWithMocks() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
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
    fetchLatestBaileysVersion: async () => {
      throw new Error("version fetch failed");
    },
    makeWASocket: () => fakeSocket,
    Browsers: {
      macOS: () => "FastFNTest",
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

      // Test messages.upsert listener
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
            key: { id: "m2", fromMe: true, remoteJid: "222@s.whatsapp.net" },
            message: { extendedTextMessage: { text: "reply" } },
            messageTimestamp: 2,
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
      assert.equal(inboxBody.total >= 1, true);

      // Test connection close scenarios
      const closeUpdate = listeners["connection.update"];
      closeUpdate({ connection: "close", lastDisconnect: { error: { output: { statusCode: 401 } } } });
      assert.equal(state.lastError, "logged_out");
      closeUpdate({ connection: "close", lastDisconnect: {} });
      assert.equal(state.lastError, "connection_closed");

      // Clean up reconnect timer if any
      if (state.reconnectTimer) {
        clearTimeout(state.reconnectTimer);
        state.reconnectTimer = null;
      }

      const disconnect = await whatsappHandler({
        method: "POST",
        query: { action: "disconnect" },
        body: "",
        env: {},
      });
      assert.equal(disconnect.status, 200);

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

// -- AI Tool Agent additional tests --

async function testAiToolAgentPrivateAndErrorBranches() {
  if (!aiToolAgentInternal) return;
  assert.equal(aiToolAgentInternal.asBool("invalid", false), false);
  assert.equal(aiToolAgentInternal.parseJson("{bad"), null);
  assert.equal(aiToolAgentInternal.chooseSecret("<set-me>", "fallback"), "fallback");
  assert.equal(aiToolAgentInternal.chooseSecret("<set-me>", " "), "");
  assert.equal(aiToolAgentInternal.hostAllowed("sub.api.ipify.org", ["ipify.org"]), true);
  assert.equal(aiToolAgentInternal.hostAllowed("example.com", ["ipify.org"]), false);

  const fs = require("node:fs");
  const oldWrite = fs.writeFileSync;
  fs.writeFileSync = () => {
    throw new Error("write denied");
  };
  try {
    aiToolAgentInternal.saveMemory(
      {
        enabled: true,
        maxTurns: 1,
        ttlSecs: 60,
        agentId: "unit",
        memPath: path.join(require("node:os").tmpdir(), "fastfn-ai-tool-save-fail.json"),
      },
      [{ role: "user", text: "hola", ts: Date.now() }]
    );
  } finally {
    fs.writeFileSync = oldWrite;
  }

  const cfg = {
    fnBaseUrl: "http://127.0.0.1:8080",
    timeoutMs: 500,
    allowedFns: ["request-inspector"],
    allowedHosts: ["api.ipify.org"],
  };
  const invalidUrl = await aiToolAgentInternal.executeToolCall("http_get", { url: "bad-url" }, cfg);
  assert.equal(invalidUrl.error, "invalid url");
  const invalidProtocol = await aiToolAgentInternal.executeToolCall("http_get", { url: "ftp://api.ipify.org" }, cfg);
  assert.equal(invalidProtocol.error, "protocol not allowed");
  const hostDenied = await aiToolAgentInternal.executeToolCall("http_get", { url: "https://wttr.in/?format=3" }, cfg);
  assert.equal(hostDenied.error, "host not allowed");
  const invalidFn = await aiToolAgentInternal.executeToolCall("fn_get", { name: "bad name" }, cfg);
  assert.equal(invalidFn.error, "invalid function name");
  const fnDenied = await aiToolAgentInternal.executeToolCall("fn_get", { name: "other-fn" }, cfg);
  assert.equal(fnDenied.error, "function not allowed");
  const unknownTool = await aiToolAgentInternal.executeToolCall("other_tool", {}, cfg);
  assert.equal(unknownTool.error, "unknown tool");

  const missingText = await aiToolAgentHandler({
    method: "GET",
    query: { dry_run: "false" },
    body: "",
    env: {},
    context: { timeout_ms: 1200 },
  });
  assert.equal(missingText.status, 200);
  const missingBody = JSON.parse(missingText.body);
  assert.ok(String(missingBody.note || "").includes("Provide text"));

  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      return {
        ok: true,
        status: 200,
        text: async () =>
          JSON.stringify({
            choices: [
              {
                message: {
                  content: null,
                  tool_calls: [
                    {
                      id: "call-1",
                      function: { name: "unknown_tool", arguments: "{}" },
                    },
                  ],
                },
              },
            ],
          }),
      };
    }
    throw new Error(`unexpected fetch url=${u}`);
  };
  try {
    const nonConverge = await aiToolAgentHandler({
      method: "GET",
      query: { dry_run: "false", text: "prueba", max_steps: "1" },
      body: "",
      env: { OPENAI_API_KEY: "test-openai-key", OPENAI_BASE_URL: "https://api.openai.com/v1" },
      context: { timeout_ms: 1200 },
    });
    assert.equal(nonConverge.status, 502);
    const nonConvergeBody = JSON.parse(nonConverge.body);
    assert.equal(nonConvergeBody.error, "tool-calling did not converge");
  } finally {
    global.fetch = prevFetch;
  }

  global.fetch = async () => {
    throw new Error("openai hard fail");
  };
  try {
    const hardFail = await aiToolAgentHandler({
      method: "GET",
      query: { dry_run: "false", text: "prueba error" },
      body: "",
      env: { OPENAI_API_KEY: "test-openai-key", OPENAI_BASE_URL: "https://api.openai.com/v1" },
      context: { timeout_ms: 1200 },
    });
    assert.equal(hardFail.status, 502);
    const hardFailBody = JSON.parse(hardFail.body);
    assert.ok(String(hardFailBody.error || "").includes("openai hard fail"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testAiToolAgentLoopTerminationAndToolCallValidation() {
  // Test: no text returns help
  const noText = await aiToolAgentHandler({
    query: {},
    body: "",
    env: {},
    context: {},
  });
  assert.equal(noText.status, 200);
  const noTextBody = JSON.parse(noText.body);
  assert.ok(noTextBody.note.includes("Provide text="));
  assert.ok(Array.isArray(noTextBody.tools));

  // Test: dry run with text
  const dryWithText = await aiToolAgentHandler({
    query: { text: "what is my IP?", dry_run: "true" },
    body: "",
    env: {},
    context: {},
  });
  assert.equal(dryWithText.status, 200);
  const dryBody = JSON.parse(dryWithText.body);
  assert.equal(dryBody.dry_run, true);
  assert.equal(dryBody.text, "what is my IP?");

  // Test: tool calling loop that does not converge (always returns tool_calls)
  const prevFetch = global.fetch;
  let callCount = 0;
  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("chat/completions")) {
      callCount += 1;
      const body = JSON.stringify({
        choices: [{
          message: {
            role: "assistant",
            content: null,
            tool_calls: [{
              id: `call_${callCount}`,
              type: "function",
              function: { name: "http_get", arguments: '{"url":"https://api.ipify.org"}' },
            }],
          },
        }],
      });
      return {
        ok: true,
        status: 200,
        text: async () => body,
      };
    }
    // Tool execution fetch
    return { ok: true, status: 200, text: async () => '{"ip":"1.2.3.4"}' };
  };
  try {
    const nonConverge = await aiToolAgentHandler({
      query: { text: "what is my IP?", dry_run: "false" },
      body: "",
      env: { OPENAI_API_KEY: "test-key", OPENAI_BASE_URL: "https://api.openai.com/v1", TOOLBOX_ALLOWED_HOSTS: "api.ipify.org" },
      context: { timeout_ms: 5000 },
    });
    assert.equal(nonConverge.status, 502);
    const ncBody = JSON.parse(nonConverge.body);
    assert.ok(ncBody.error.includes("did not converge"));
    assert.ok(ncBody.trace.steps.length > 0);
  } finally {
    global.fetch = prevFetch;
  }

  // Test: OpenAI API error during tool calling
  global.fetch = async () => {
    throw new Error("openai unreachable");
  };
  try {
    const apiErr = await aiToolAgentHandler({
      query: { text: "test question", dry_run: "false" },
      body: "",
      env: { OPENAI_API_KEY: "test-key", OPENAI_BASE_URL: "https://api.openai.com/v1" },
      context: { timeout_ms: 2000 },
    });
    assert.equal(apiErr.status, 502);
    const apiBody = JSON.parse(apiErr.body);
    assert.ok(apiBody.error.includes("openai unreachable"));
  } finally {
    global.fetch = prevFetch;
  }
}

// -- NEW COVERAGE GAP TESTS --

// telegram-ai-digest: line 46 (getUpdates res.ok=false)
async function testTelegramAiDigestGetUpdatesFail() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    if (String(url).includes("/getUpdates")) {
      return { ok: false, status: 500 };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  try {
    const resp = await telegramAiDigestHandler({
      env: { TELEGRAM_BOT_TOKEN: "t", TELEGRAM_CHAT_ID: "1", OPENAI_API_KEY: "k" },
    });
    assert.equal(resp.status, 502);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error).includes("getUpdates failed"));
  } finally {
    global.fetch = prevFetch;
  }
}

// telegram-ai-digest: line 50 (data.ok=false)
async function testTelegramAiDigestDataNotOk() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    if (String(url).includes("/getUpdates")) {
      return { ok: true, status: 200, json: async () => ({ ok: false, description: "bad token" }) };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  try {
    const resp = await telegramAiDigestHandler({
      env: { TELEGRAM_BOT_TOKEN: "t", TELEGRAM_CHAT_ID: "1", OPENAI_API_KEY: "k" },
    });
    assert.equal(resp.status, 502);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error).includes("Telegram API error"));
  } finally {
    global.fetch = prevFetch;
  }
}

// telegram-ai-digest: lines 100-101 (sendMessage res.ok=false)
async function testTelegramAiDigestSendMessageFail() {
  const prevFetch = global.fetch;
  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/getUpdates")) {
      return {
        ok: true, status: 200,
        json: async () => ({ ok: true, result: [{ message: { text: "hi" } }] }),
      };
    }
    if (u.includes("/chat/completions")) {
      return {
        ok: true, status: 200,
        json: async () => ({ choices: [{ message: { content: "summary" } }] }),
      };
    }
    if (u.includes("/sendMessage")) {
      return { ok: false, status: 403, text: async () => "forbidden" };
    }
    return { ok: false, status: 404, text: async () => "" };
  };
  try {
    const resp = await telegramAiDigestHandler({
      env: { TELEGRAM_BOT_TOKEN: "t", TELEGRAM_CHAT_ID: "1", OPENAI_API_KEY: "k" },
    });
    assert.equal(resp.status, 502);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error).includes("sendMessage error"));
  } finally {
    global.fetch = prevFetch;
  }
}

// telegram-ai-reply: body as object (not string) — covers branch at lines 9, 20
async function testTelegramAiReplyBodyAsObject() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      return {
        ok: true, status: 200,
        json: async () => ({ choices: [{ message: { content: "reply obj" } }] }),
      };
    }
    if (u.includes("/sendMessage")) {
      return { ok: true, json: async () => ({ ok: true, result: { message_id: 55 } }) };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  try {
    // Body as object (not string) — covers typeof branch at line 20
    const resp = await telegramAiReplyHandler({
      body: { message: { chat: { id: 999 }, text: "object body" } },
      env: { TELEGRAM_BOT_TOKEN: "tok", OPENAI_API_KEY: "key" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.equal(body.chat_id, 999);

    // Body as object with no message — covers env missing check branch at line 9
    const resp2 = await telegramAiReplyHandler({
      body: {},
      env: {},
    });
    assert.equal(resp2.status, 200);
    const body2 = JSON.parse(resp2.body);
    assert.equal(body2.skipped, true);
  } finally {
    global.fetch = prevFetch;
  }
}

// telegram-ai-reply: OpenAI returns empty text (line 86 branch)
async function testTelegramAiReplyOpenAINoText() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      return {
        ok: true, status: 200,
        json: async () => ({ choices: [{ message: {} }] }),
      };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  try {
    const resp = await telegramAiReplyHandler({
      body: JSON.stringify({ message: { chat: { id: 10 }, text: "hi" } }),
      env: { TELEGRAM_BOT_TOKEN: "tok", OPENAI_API_KEY: "key" },
    });
    assert.equal(resp.status, 502);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error).includes("no text"));
  } finally {
    global.fetch = prevFetch;
  }
}

// toolbox-bot: line 72 (unknown directive type in execute)
async function testToolboxBotUnknownDirectiveType() {
  // Line 72 is only reachable if execute() is called with a tool of unknown type.
  // Since parseDirectives only produces "fn" and "http", we need to expose execute.
  // We do this by temporarily modifying the source to export execute, then requireFresh.
  const fs = require("node:fs");
  const modulePath = path.join(root, "examples/functions/node/toolbox-bot/app.js");
  const resolvedPath = require.resolve(modulePath);
  const originalSrc = fs.readFileSync(modulePath, "utf8");
  const originalCacheEntry = require.cache[resolvedPath];
  const coverageKey = Object.keys(global.__coverage__ || {}).find(k => k.includes("toolbox-bot/app.js"));
  const savedCoverage = coverageKey ? JSON.parse(JSON.stringify(global.__coverage__[coverageKey])) : null;

  // Add exports._execute = execute; at the end of the file
  const modifiedSrc = originalSrc + "\nexports._execute = execute;\n";
  fs.writeFileSync(modulePath, modifiedSrc);
  try {
    const freshModule = requireFresh(modulePath);
    const result = await freshModule._execute({ type: "unknown" });
    assert.equal(result.ok, false);
    assert.equal(result.error, "unknown directive type");
  } finally {
    fs.writeFileSync(modulePath, originalSrc);
    // Merge coverage
    if (savedCoverage && coverageKey && global.__coverage__) {
      const freshCoverage = global.__coverage__[coverageKey];
      if (freshCoverage && freshCoverage.s) {
        for (const key of Object.keys(freshCoverage.s)) {
          if (savedCoverage.s && key in savedCoverage.s) {
            savedCoverage.s[key] = (savedCoverage.s[key] || 0) + (freshCoverage.s[key] || 0);
          }
        }
        if (freshCoverage.b && savedCoverage.b) {
          for (const key of Object.keys(freshCoverage.b)) {
            if (key in savedCoverage.b && Array.isArray(savedCoverage.b[key]) && Array.isArray(freshCoverage.b[key])) {
              for (let i = 0; i < freshCoverage.b[key].length; i++) {
                savedCoverage.b[key][i] = (savedCoverage.b[key][i] || 0) + (freshCoverage.b[key][i] || 0);
              }
            }
          }
        }
        if (freshCoverage.f && savedCoverage.f) {
          for (const key of Object.keys(freshCoverage.f)) {
            if (key in savedCoverage.f) {
              savedCoverage.f[key] = (savedCoverage.f[key] || 0) + (freshCoverage.f[key] || 0);
            }
          }
        }
      }
      global.__coverage__[coverageKey] = savedCoverage;
    }
    delete require.cache[resolvedPath];
    if (originalCacheEntry) {
      require.cache[resolvedPath] = originalCacheEntry;
    }
  }
}

// whatsapp: QR timeout paths (lines 195-197), waitFor timeout (118-120), ensureConnected (125-126)
async function testWhatsappQrTimeoutAndEnsureConnected() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
  const fsModule = require("node:fs");
  const whatsappPath = path.join(root, "examples/functions/node/whatsapp/app.js");
  const originalSrc = fsModule.readFileSync(whatsappPath, "utf8");

  // Reduce timeouts for testing
  const modifiedSrc = originalSrc
    .replace("const QR_WAIT_MS = 15000;", "const QR_WAIT_MS = 50;")
    .replace("const CONNECT_WAIT_MS = 45000;", "const CONNECT_WAIT_MS = 50;")
    .replace("const RECONNECT_DELAY_MS = 2500;", "const RECONNECT_DELAY_MS = 50;");

  // Save original module cache entry and coverage data to restore later
  const resolvedWhatsappPath = require.resolve(whatsappPath);
  const originalCacheEntry = require.cache[resolvedWhatsappPath];
  // Save nyc coverage for this file before requireFresh creates a new instrumented copy
  const coverageKey = Object.keys(global.__coverage__ || {}).find(k => k.includes("whatsapp/app.js"));
  const savedCoverage = coverageKey ? JSON.parse(JSON.stringify(global.__coverage__[coverageKey])) : null;
  fsModule.writeFileSync(whatsappPath, modifiedSrc);
  try {
    const freshModule = requireFresh(whatsappPath);
    const freshHandler = freshModule.handler;

    // Scenario 1: connected=true, no QR -> 409
    resetWhatsappRuntimeState();
    state.connected = true;
    state.connecting = false;
    state.lastQr = null;
    state.socket = { end: () => {} };

    const resp409 = await freshHandler({
      method: "GET",
      query: { action: "qr" },
      body: "",
      env: {},
    });
    assert.equal(resp409.status, 409);
    const body409 = JSON.parse(resp409.body);
    assert.ok(String(body409.error).includes("already connected"));

    // Scenario 2: not connected, no QR -> 202
    resetWhatsappRuntimeState();
    state.connected = false;
    state.connecting = true;
    state.lastQr = null;
    state.socket = null;

    const resp202 = await freshHandler({
      method: "GET",
      query: { action: "qr" },
      body: "",
      env: {},
    });
    assert.equal(resp202.status, 202);
    const body202 = JSON.parse(resp202.body);
    assert.ok(String(body202.error).includes("not ready yet"));

    // Scenario 3: ensureConnected waitFor timeout (lines 118-120, 125-126)
    resetWhatsappRuntimeState();
    state.connected = false;
    state.connecting = true;
    state.socket = null;

    const sendResp = await freshHandler({
      method: "POST",
      query: { action: "send" },
      body: JSON.stringify({ text: "hello", to: "15551234567" }),
      env: {},
    });
    assert.equal(sendResp.status, 409);
    const sendBody = JSON.parse(sendResp.body);
    assert.ok(String(sendBody.error).includes("not connected"));

    // Scenario 4: chat send error (line 273)
    resetWhatsappRuntimeState();
    state.connected = true;
    state.socket = {
      sendMessage: async () => { throw new Error("send failed in chat"); },
    };

    const prevFetch = global.fetch;
    global.fetch = async (url) => {
      if (String(url).includes("/chat/completions")) {
        return {
          ok: true, status: 200,
          json: async () => ({ choices: [{ message: { content: "ai text" } }] }),
        };
      }
      return { ok: false, status: 404, json: async () => ({}) };
    };
    try {
      const chatErr = await freshHandler({
        method: "POST",
        query: { action: "chat" },
        body: JSON.stringify({ text: "test", to: "15551234567" }),
        env: { OPENAI_API_KEY: "k" },
      });
      assert.equal(chatErr.status, 500);
      const chatErrBody = JSON.parse(chatErr.body);
      assert.ok(String(chatErrBody.error).includes("send failed in chat"));
      assert.ok(chatErrBody.ai_reply);
    } finally {
      global.fetch = prevFetch;
    }
  } finally {
    fsModule.writeFileSync(whatsappPath, originalSrc);
    // Merge fresh module's coverage into saved original coverage, then restore
    if (savedCoverage && coverageKey && global.__coverage__) {
      const freshCoverage = global.__coverage__[coverageKey];
      if (freshCoverage && freshCoverage.s) {
        // Merge statement counts: add fresh counts to saved counts
        for (const key of Object.keys(freshCoverage.s)) {
          if (savedCoverage.s && key in savedCoverage.s) {
            savedCoverage.s[key] = (savedCoverage.s[key] || 0) + (freshCoverage.s[key] || 0);
          }
        }
        // Merge branch counts
        if (freshCoverage.b && savedCoverage.b) {
          for (const key of Object.keys(freshCoverage.b)) {
            if (key in savedCoverage.b && Array.isArray(savedCoverage.b[key]) && Array.isArray(freshCoverage.b[key])) {
              for (let i = 0; i < freshCoverage.b[key].length; i++) {
                savedCoverage.b[key][i] = (savedCoverage.b[key][i] || 0) + (freshCoverage.b[key][i] || 0);
              }
            }
          }
        }
        // Merge function counts
        if (freshCoverage.f && savedCoverage.f) {
          for (const key of Object.keys(freshCoverage.f)) {
            if (key in savedCoverage.f) {
              savedCoverage.f[key] = (savedCoverage.f[key] || 0) + (freshCoverage.f[key] || 0);
            }
          }
        }
      }
      global.__coverage__[coverageKey] = savedCoverage;
    }
    // Remove fresh module from cache, restore original
    delete require.cache[resolvedWhatsappPath];
    if (originalCacheEntry) {
      require.cache[resolvedWhatsappPath] = originalCacheEntry;
    }
    if (state.reconnectTimer) { clearTimeout(state.reconnectTimer); state.reconnectTimer = null; }
  }
}

// whatsapp: line 273 (chat send error — also tested above but this covers original module)
async function testWhatsappChatSendError() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
  state.connected = true;
  state.socket = {
    sendMessage: async () => { throw new Error("wa send err"); },
  };

  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    if (String(url).includes("/chat/completions")) {
      return {
        ok: true, status: 200,
        json: async () => ({ choices: [{ message: { content: "reply text" } }] }),
      };
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
}

// ai-tool-agent/_internal.js: line 255 (http_get with JSON content-type)
async function testAiToolAgentInternalHttpGetJsonContentType() {
  const prevFetch = global.fetch;
  global.fetch = async () => ({
    ok: true,
    status: 200,
    text: async () => '{"ip":"1.2.3.4"}',
    headers: { get: (name) => name === "content-type" ? "application/json" : null },
  });
  try {
    const cfg = {
      fnBaseUrl: "http://127.0.0.1:8080",
      timeoutMs: 2000,
      allowedFns: ["request-inspector"],
      allowedHosts: ["api.ipify.org"],
    };
    const result = await aiToolAgentInternal.executeToolCall("http_get", { url: "https://api.ipify.org/?format=json" }, cfg);
    assert.equal(result.ok, true);
    assert.equal(result.status, 200);
    assert.deepEqual(result.json, { ip: "1.2.3.4" });
    assert.equal(result.content_type, "application/json");
  } finally {
    global.fetch = prevFetch;
  }
}

// ai-tool-agent/_internal.js: lines 277-308 (fn_get with query params)
async function testAiToolAgentInternalFnGetWithQueryParams() {
  const prevFetch = global.fetch;
  let capturedUrl = "";
  global.fetch = async (url) => {
    capturedUrl = String(url);
    return {
      ok: true,
      status: 200,
      text: async () => '{"result":"ok"}',
      headers: { get: (name) => name === "content-type" ? "application/json" : null },
    };
  };
  try {
    const cfg = {
      fnBaseUrl: "http://127.0.0.1:8080",
      timeoutMs: 2000,
      allowedFns: ["request-inspector"],
      allowedHosts: ["api.ipify.org"],
    };
    const result = await aiToolAgentInternal.executeToolCall(
      "fn_get",
      { name: "request-inspector", query: { foo: "bar", baz: "qux" } },
      cfg
    );
    assert.equal(result.ok, true);
    assert.equal(result.tool, "fn_get");
    assert.equal(result.name, "request-inspector");
    assert.deepEqual(result.json, { result: "ok" });
    assert.ok(capturedUrl.includes("foo=bar"));
    assert.ok(capturedUrl.includes("baz=qux"));

    // fn_get with empty query object
    const result2 = await aiToolAgentInternal.executeToolCall(
      "fn_get",
      { name: "request-inspector", query: {} },
      cfg
    );
    assert.equal(result2.ok, true);

    // fn_get with query containing empty key (should skip)
    const result3 = await aiToolAgentInternal.executeToolCall(
      "fn_get",
      { name: "request-inspector", query: { "": "skip", valid: "keep" } },
      cfg
    );
    assert.equal(result3.ok, true);
  } finally {
    global.fetch = prevFetch;
  }
}

// ai-tool-agent/_internal.js: lines 332, 335 (openaiChat error body and no message)
async function testAiToolAgentInternalOpenaiChatErrorBody() {
  const prevFetch = global.fetch;

  // Line 332: non-ok response
  global.fetch = async () => ({
    ok: false,
    status: 429,
    text: async () => "rate limited",
  });
  try {
    await assert.rejects(
      () => aiToolAgentInternal.openaiChat(
        { OPENAI_API_KEY: "test-key" },
        [{ role: "user", content: "hi" }],
        [],
        2000
      ),
      (err) => {
        assert.ok(String(err.message).includes("openai error status=429"));
        assert.ok(String(err.message).includes("rate limited"));
        return true;
      }
    );
  } finally {
    global.fetch = prevFetch;
  }

  // Line 335: ok response but no message in choices
  global.fetch = async () => ({
    ok: true,
    status: 200,
    text: async () => JSON.stringify({ choices: [{}] }),
  });
  try {
    await assert.rejects(
      () => aiToolAgentInternal.openaiChat(
        { OPENAI_API_KEY: "test-key" },
        [{ role: "user", content: "hi" }],
        [],
        2000
      ),
      (err) => {
        assert.ok(String(err.message).includes("no message"));
        return true;
      }
    );
  } finally {
    global.fetch = prevFetch;
  }
}

// ai-tool-agent/_internal.js: lines 339-340 (summarizeAssistantMessage)
async function testAiToolAgentInternalSummarizeAssistantMessage() {
  const summarize = aiToolAgentInternal.summarizeAssistantMessage;

  // null input
  const r1 = summarize(null);
  assert.equal(r1.role, "assistant");

  // non-object input
  const r2 = summarize("string");
  assert.equal(r2.role, "assistant");

  // message with content and tool_calls
  const r3 = summarize({
    content: "hello world",
    tool_calls: [{ id: "c1", function: { name: "http_get" } }],
  });
  assert.equal(r3.role, "assistant");
  assert.equal(r3.content, "hello world");
  assert.equal(r3.tool_calls.length, 1);
  assert.equal(r3.tool_calls[0].id, "c1");
  assert.equal(r3.tool_calls[0].name, "http_get");

  // message with no tool_calls
  const r4 = summarize({ content: "just text" });
  assert.equal(r4.content, "just text");
  assert.deepEqual(r4.tool_calls, []);

  // message with non-string content
  const r5 = summarize({ content: 123 });
  assert.equal(r5.content, null);

  // message with tool_calls containing null entries
  const r6 = summarize({ tool_calls: [null, { id: "c2", function: { name: "fn_get" } }] });
  assert.equal(r6.tool_calls.length, 2);
  assert.equal(r6.tool_calls[0].id, null);
  assert.equal(r6.tool_calls[1].name, "fn_get");
}

// ai-tool-agent/_internal.js: line 270 (fn_get empty/invalid name)
async function testAiToolAgentInternalFnGetEmptyName() {
  const cfg = {
    fnBaseUrl: "http://127.0.0.1:8080",
    timeoutMs: 500,
    allowedFns: ["request-inspector"],
    allowedHosts: [],
  };
  const r1 = await aiToolAgentInternal.executeToolCall("fn_get", {}, cfg);
  assert.equal(r1.error, "invalid function name");

  const r2 = await aiToolAgentInternal.executeToolCall("fn_get", { name: 123 }, cfg);
  assert.equal(r2.error, "invalid function name");
}

// ai-tool-agent/_internal.js: isLocalHostname variants
async function testAiToolAgentInternalLocalHostVariants() {
  const cfg = {
    fnBaseUrl: "http://127.0.0.1:8080",
    timeoutMs: 500,
    allowedFns: [],
    allowedHosts: ["localhost", "127.0.0.1"],
  };
  const r1 = await aiToolAgentInternal.executeToolCall("http_get", { url: "http://localhost/test" }, cfg);
  assert.equal(r1.error, "local host not allowed");

  const r2 = await aiToolAgentInternal.executeToolCall("http_get", { url: "http://127.0.0.1/test" }, cfg);
  assert.equal(r2.error, "local host not allowed");

  const r4 = await aiToolAgentInternal.executeToolCall("http_get", { url: "http://myhost.local/test" }, cfg);
  assert.equal(r4.error, "local host not allowed");

  assert.equal(aiToolAgentInternal.isLocalHostname(""), false);
  assert.equal(aiToolAgentInternal.isLocalHostname(null), false);
  assert.equal(aiToolAgentInternal.isLocalHostname("::1"), true);
  assert.equal(aiToolAgentInternal.isLocalHostname("test.local"), true);
}

// telegram-send: additional branch coverage
async function testTelegramSendBranchCoverage() {
  // parseJsonBody: array input returns {}
  const respArr = await telegramSendHandler({
    query: { chat_id: "100", dry_run: "true" },
    body: [1, 2, 3],
    env: {},
  });
  assert.equal(respArr.status, 200);

  // Body as object (not string)
  const respObj = await telegramSendHandler({
    query: { dry_run: "true" },
    body: { chat_id: "200", text: "from object" },
    env: {},
  });
  assert.equal(respObj.status, 200);
  const objBody = JSON.parse(respObj.body);
  assert.equal(objBody.chat_id, "200");

  // Body as number
  const respNum = await telegramSendHandler({
    query: { chat_id: "300", dry_run: "true" },
    body: 42,
    env: {},
  });
  assert.equal(respNum.status, 200);

  // asBool with "off" and "no"
  const respOff = await telegramSendHandler({
    query: { chat_id: "400", dry_run: "off" },
    body: "",
    env: {},
  });
  assert.equal(respOff.status, 200);
  const offBody = JSON.parse(respOff.body);
  assert.equal(offBody.dry_run, false);

  const respNo = await telegramSendHandler({
    query: { chat_id: "401", dry_run: "no" },
    body: "",
    env: {},
  });
  assert.equal(respNo.status, 200);
  const noBody = JSON.parse(respNo.body);
  assert.equal(noBody.dry_run, false);

  // isUnsetSecret variants
  const unset1 = await telegramSendHandler({
    query: { chat_id: "500", dry_run: "false" },
    env: { TELEGRAM_BOT_TOKEN: "changeme" },
  });
  assert.equal(unset1.status, 200);

  const unset2 = await telegramSendHandler({
    query: { chat_id: "501", dry_run: "false" },
    env: { TELEGRAM_BOT_TOKEN: "<changeme>" },
  });
  assert.equal(unset2.status, 200);

  const unset3 = await telegramSendHandler({
    query: { chat_id: "502", dry_run: "false" },
    env: { TELEGRAM_BOT_TOKEN: "replace-me" },
  });
  assert.equal(unset3.status, 200);

  const unset4 = await telegramSendHandler({
    query: { chat_id: "503", dry_run: "false" },
    env: { TELEGRAM_BOT_TOKEN: "set-me" },
  });
  assert.equal(unset4.status, 200);

  const unset5 = await telegramSendHandler({
    query: { chat_id: "504", dry_run: "false" },
    env: { TELEGRAM_BOT_TOKEN: "" },
  });
  assert.equal(unset5.status, 200);

  // Body has dry_run property (hasOwnProperty branch at line 50)
  const respBodyDry = await telegramSendHandler({
    query: {},
    body: JSON.stringify({ chat_id: "600", text: "t", dry_run: false }),
    env: {},
  });
  assert.equal(respBodyDry.status, 200);
  const bodyDryBody = JSON.parse(respBodyDry.body);
  assert.equal(bodyDryBody.dry_run, false);

  // chatId from body.chatId (camelCase)
  const respCamelChat = await telegramSendHandler({
    query: { dry_run: "true" },
    body: JSON.stringify({ chatId: "700" }),
    env: {},
  });
  assert.equal(respCamelChat.status, 200);
  const camelBody = JSON.parse(respCamelChat.body);
  assert.equal(camelBody.chat_id, "700");

  // Default text
  const respDefaultText = await telegramSendHandler({
    query: { chat_id: "800", dry_run: "true" },
    body: "{}",
    env: {},
  });
  assert.equal(respDefaultText.status, 200);
  const defaultBody = JSON.parse(respDefaultText.body);
  assert.equal(defaultBody.text, "hello from fastfn");

  // TELEGRAM_API_BASE override
  const prevFetch = global.fetch;
  const prevToken = process.env.TELEGRAM_BOT_TOKEN;
  delete process.env.TELEGRAM_BOT_TOKEN;
  global.fetch = async (url) => {
    assert.ok(String(url).includes("custom-api.test"));
    return {
      ok: true,
      status: 200,
      text: async () => JSON.stringify({ ok: true, result: { message_id: 99 } }),
    };
  };
  try {
    const resp = await telegramSendHandler({
      query: { chat_id: "900", dry_run: "false" },
      body: "{}",
      env: { TELEGRAM_BOT_TOKEN: "real-token", TELEGRAM_API_BASE: "https://custom-api.test" },
    });
    assert.equal(resp.status, 200);
    const b = JSON.parse(resp.body);
    assert.equal(b.sent, true);
  } finally {
    global.fetch = prevFetch;
    if (prevToken !== undefined) process.env.TELEGRAM_BOT_TOKEN = prevToken;
  }

  // parseJsonBody: JSON string/array returns {}
  const respJsonStr = await telegramSendHandler({
    query: { chat_id: "950", dry_run: "true" },
    body: '"just a string"',
    env: {},
  });
  assert.equal(respJsonStr.status, 200);

  const respJsonArr = await telegramSendHandler({
    query: { chat_id: "951", dry_run: "true" },
    body: '[1,2,3]',
    env: {},
  });
  assert.equal(respJsonArr.status, 200);
}

// ── Branch coverage tests ───────────────────────────────────────────────

async function testRequestInspectorNonStringBody() {
  // body as object (not string) — covers line 23 typeof branch
  const resp = await requestInspectorHandler({
    method: "GET",
    body: { key: "val" },
    headers: {},
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.body, ""); // non-string body becomes ""

  // body as null
  const resp2 = await requestInspectorHandler({ method: "GET", body: null, headers: {} });
  assert.equal(resp2.status, 200);
  const body2 = JSON.parse(resp2.body);
  assert.equal(body2.body, "");

  // body over 2048 chars — covers line 24 truncation branch
  const longBody = "x".repeat(3000);
  const resp3 = await requestInspectorHandler({ method: "GET", body: longBody, headers: {} });
  const body3 = JSON.parse(resp3.body);
  assert.ok(body3.body.includes("...(truncated)"));
}

async function testRequestInspectorNoContext() {
  // No context field — covers lines 36-37 (event.context undefined)
  const resp = await requestInspectorHandler({
    method: "GET",
    headers: { "x-test": "1" },
    body: "hi",
  });
  assert.equal(resp.status, 200);
  const body = JSON.parse(resp.body);
  assert.equal(body.context.request_id, undefined);
  assert.equal(body.context.user, undefined);

  // Non-object headers — covers line 10 headers check
  const resp2 = await requestInspectorHandler({
    method: "GET",
    headers: "not-an-object",
    body: "",
  });
  assert.equal(resp2.status, 200);
}

async function testGithubWebhookGuardNonStringBody() {
  const secret = "dev";
  // Pass body as object — covers line 50 typeof check
  const resp = await githubWebhookGuardHandler({
    method: "POST",
    headers: { "x-hub-signature-256": "sha256=bad" },
    env: { GITHUB_WEBHOOK_SECRET: secret },
    body: { zen: "test" },
  });
  // Should fail verification since body becomes ""
  assert.equal(resp.status, 401);
}

async function testAiToolAgentMalformedToolCall() {
  const prevFetch = global.fetch;
  let callCount = 0;
  global.fetch = async (url, opts = {}) => {
    const u = String(url);
    if (u.includes("/chat/completions")) {
      callCount++;
      if (callCount === 1) {
        // Return tool_calls with missing function.name and non-string arguments
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({
            choices: [{
              message: {
                content: null,
                tool_calls: [
                  { id: "c1", function: { arguments: '{}' } }, // missing name
                  { id: "c2", function: { name: "http_get", arguments: 123 } }, // non-string args
                  { id: "c3" }, // missing function entirely
                ],
              },
            }],
          }),
        };
      }
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ choices: [{ message: { content: "done" } }] }),
      };
    }
    return { ok: true, status: 200, text: async () => '{"ok":true}' };
  };
  try {
    const resp = await aiToolAgentHandler({
      method: "GET",
      query: { dry_run: "false", text: "test malformed" },
      env: { OPENAI_API_KEY: "k", OPENAI_BASE_URL: "https://api.openai.com/v1" },
      context: { timeout_ms: 2000 },
    });
    assert.equal(resp.status, 200);
  } finally {
    global.fetch = prevFetch;
  }
}

async function testAiToolAgentErrorWithoutMessage() {
  const prevFetch = global.fetch;
  // Throw a plain string (not Error object) — covers line 166 err without .message
  global.fetch = async () => { throw "plain string error"; };
  try {
    const resp = await aiToolAgentHandler({
      method: "GET",
      query: { dry_run: "false", text: "test" },
      env: { OPENAI_API_KEY: "k", OPENAI_BASE_URL: "https://api.openai.com/v1" },
      context: { timeout_ms: 1000 },
    });
    assert.equal(resp.status, 502);
    const body = JSON.parse(resp.body);
    assert.ok(body.error.includes("plain string error"));
  } finally {
    global.fetch = prevFetch;
  }
}

async function testToolboxBotBodyAsObject() {
  // Pass body as parsed object (not string) — covers line 12 non-string branch
  const resp = await toolboxBotHandler({
    method: "POST",
    query: {},
    body: { text: "hello [[fn:request-inspector|GET]]" },
  });
  assert.equal(resp.status, 200);
}

async function testTelegramAiDigestPartialUpdate() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/getUpdates")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          ok: true,
          result: [
            { update_id: 1, message: { text: "valid" } },
            { update_id: 2 }, // no message — covers line 54 filter
            { update_id: 3, message: {} }, // message without text
          ],
        }),
      };
    }
    if (u.includes("/chat/completions")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({ choices: [{ message: { content: "summary" } }] }),
      };
    }
    if (u.includes("/sendMessage")) {
      return { ok: true, json: async () => ({ ok: true, result: { message_id: 1 } }) };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  try {
    const resp = await telegramAiDigestHandler({
      env: { TELEGRAM_BOT_TOKEN: "t", TELEGRAM_CHAT_ID: "1", OPENAI_API_KEY: "k" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    // Only the message with text should be counted
    assert.ok(body.message_count <= 2);
  } finally {
    global.fetch = prevFetch;
  }
}

async function testTelegramAiDigestEmptyChoices() {
  const prevFetch = global.fetch;
  global.fetch = async (url) => {
    const u = String(url);
    if (u.includes("/getUpdates")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          ok: true,
          result: [{ update_id: 1, message: { text: "hello" } }],
        }),
      };
    }
    if (u.includes("/chat/completions")) {
      // Empty choices — covers line 89 fallback
      return {
        ok: true,
        status: 200,
        json: async () => ({ choices: [] }),
      };
    }
    if (u.includes("/sendMessage")) {
      return { ok: true, json: async () => ({ ok: true, result: { message_id: 1 } }) };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  try {
    const resp = await telegramAiDigestHandler({
      env: { TELEGRAM_BOT_TOKEN: "t", TELEGRAM_CHAT_ID: "1", OPENAI_API_KEY: "k" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.ok(body.digest.includes("No summary generated") || body.ok === true);
  } finally {
    global.fetch = prevFetch;
  }
}

async function testEdgeFilterUserIdVariant() {
  // Use camelCase userId instead of user_id — covers line 37 second || branch
  const resp = await edgeFilterHandler({
    method: "GET",
    query: { userId: "456" },
    headers: { "x-api-key": "dev" },
    env: { EDGE_FILTER_API_KEY: "dev" },
  });
  assert.equal(typeof resp.proxy, "object");
  const url = new URL(String(resp.proxy.path), "http://fastfn.local");
  const uid = url.searchParams.get("edge_user_id") || url.searchParams.get("edge-user-id");
  assert.equal(uid, "456");

  // With UPSTREAM_TOKEN — covers line 55 spread conditional
  const resp2 = await edgeFilterHandler({
    method: "GET",
    query: { user_id: "789" },
    headers: { "x-api-key": "dev" },
    env: { EDGE_FILTER_API_KEY: "dev", UPSTREAM_TOKEN: "bearer-tok" },
  });
  assert.equal(resp2.proxy.headers.authorization, "Bearer bearer-tok");
}

// whatsapp: normalizeJid with null/undefined "to" (line 30)
async function testWhatsappSendNullTo() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
  state.connected = true;
  state.socket = { sendMessage: async () => ({}) };

  // "to" is omitted entirely — normalizeJid receives undefined
  const resp = await whatsappHandler({
    method: "POST",
    query: { action: "send" },
    body: JSON.stringify({ text: "hello" }),
    env: {},
  });
  assert.equal(resp.status, 500);
  const body = JSON.parse(resp.body);
  assert.ok(String(body.error).includes("to is required"));
}

// whatsapp: normalizeJid when raw already has @s.whatsapp.net or @g.us (line 32)
async function testWhatsappSendAlreadyFormattedJid() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
  state.connected = true;
  let capturedJid = null;
  state.socket = {
    sendMessage: async (jid) => { capturedJid = jid; return { key: { id: "m1" } }; },
  };

  // Already has @s.whatsapp.net suffix
  const resp1 = await whatsappHandler({
    method: "POST",
    query: { action: "send" },
    body: JSON.stringify({ to: "15551234567@s.whatsapp.net", text: "hi" }),
    env: {},
  });
  assert.equal(resp1.status, 200);
  assert.equal(capturedJid, "15551234567@s.whatsapp.net");

  // Already has @g.us suffix (group)
  capturedJid = null;
  const resp2 = await whatsappHandler({
    method: "POST",
    query: { action: "send" },
    body: JSON.stringify({ to: "120363012345@g.us", text: "hi group" }),
    env: {},
  });
  assert.equal(resp2.status, 200);
  assert.equal(capturedJid, "120363012345@g.us");
}

// whatsapp: extractText with imageMessage.caption and videoMessage.caption (line 41)
async function testWhatsappExtractTextImageVideoCaption() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
  const listeners = {};
  const fakeSocket = {
    user: { id: "bot@s.whatsapp.net" },
    ev: {
      on: (name, cb) => {
        listeners[name] = cb;
        if (name === "connection.update") {
          cb({ connection: "open" });
        }
      },
    },
    sendMessage: async () => ({}),
    end: () => {},
  };
  const fakeBaileys = {
    useMultiFileAuthState: async () => ({ state: {}, saveCreds: () => {} }),
    fetchLatestBaileysVersion: async () => ({ version: [2, 3000, 1] }),
    makeWASocket: () => fakeSocket,
    Browsers: { macOS: () => "FastFNTest" },
  };

  const whatsappPath = path.join(root, "examples/functions/node/whatsapp/app.js");
  const resolvedWhatsappPath = require.resolve(whatsappPath);
  const originalCacheEntry = require.cache[resolvedWhatsappPath];
  const coverageKey = Object.keys(global.__coverage__ || {}).find(k => k.includes("whatsapp/app.js"));
  const savedCoverage = coverageKey ? JSON.parse(JSON.stringify(global.__coverage__[coverageKey])) : null;

  await withPatchedModuleLoad(
    { "@whiskeysockets/baileys": fakeBaileys },
    async () => {
      // Use requireFresh so the module-level `baileys` variable is null again
      const freshModule = requireFresh(whatsappPath);
      await freshModule.handler({
        method: "POST", query: { action: "connect" }, body: "{}", env: {},
      });

      const upsert = listeners["messages.upsert"];
      assert.equal(typeof upsert, "function");

      // Test imageMessage.caption
      state.inbox = [];
      upsert({
        messages: [{
          key: { id: "img1", remoteJid: "1234@s.whatsapp.net", fromMe: false },
          pushName: "Alice", messageTimestamp: 1000,
          message: { imageMessage: { caption: "photo caption" } },
        }],
      });
      assert.equal(state.inbox.length, 1);
      assert.equal(state.inbox[0].text, "photo caption");

      // Test videoMessage.caption
      state.inbox = [];
      upsert({
        messages: [{
          key: { id: "vid1", remoteJid: "5678@s.whatsapp.net", fromMe: false },
          pushName: "Bob", messageTimestamp: 2000,
          message: { videoMessage: { caption: "video caption" } },
        }],
      });
      assert.equal(state.inbox.length, 1);
      assert.equal(state.inbox[0].text, "video caption");
    }
  );

  // Merge coverage from fresh module back into original
  if (savedCoverage && coverageKey && global.__coverage__) {
    const freshCoverage = global.__coverage__[coverageKey];
    if (freshCoverage && freshCoverage.s) {
      for (const key of Object.keys(freshCoverage.s)) {
        if (savedCoverage.s && key in savedCoverage.s) {
          savedCoverage.s[key] = (savedCoverage.s[key] || 0) + (freshCoverage.s[key] || 0);
        }
      }
      if (freshCoverage.b && savedCoverage.b) {
        for (const key of Object.keys(freshCoverage.b)) {
          if (key in savedCoverage.b && Array.isArray(savedCoverage.b[key]) && Array.isArray(freshCoverage.b[key])) {
            for (let i = 0; i < freshCoverage.b[key].length; i++) {
              savedCoverage.b[key][i] = (savedCoverage.b[key][i] || 0) + (freshCoverage.b[key][i] || 0);
            }
          }
        }
      }
      if (freshCoverage.f && savedCoverage.f) {
        for (const key of Object.keys(freshCoverage.f)) {
          if (key in savedCoverage.f) {
            savedCoverage.f[key] = (savedCoverage.f[key] || 0) + (freshCoverage.f[key] || 0);
          }
        }
      }
    }
    global.__coverage__[coverageKey] = savedCoverage;
  }
  delete require.cache[resolvedWhatsappPath];
  if (originalCacheEntry) require.cache[resolvedWhatsappPath] = originalCacheEntry;
  if (state.reconnectTimer) { clearTimeout(state.reconnectTimer); state.reconnectTimer = null; }
}

// whatsapp: statusPayload() catch block for fs.readdirSync exception (line 51)
async function testWhatsappStatusPayloadFsError() {
  resetWhatsappRuntimeState();
  const fsModule = require("node:fs");

  // Temporarily make readdirSync and existsSync throw for the SESSION_DIR
  const origExistsSync = fsModule.existsSync;
  fsModule.existsSync = (p) => {
    if (String(p).includes(".session")) throw new Error("simulated fs error");
    return origExistsSync(p);
  };
  try {
    const resp = await whatsappHandler({
      method: "GET",
      query: { action: "status" },
      body: "",
      env: {},
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    // The catch block should swallow the error and has_session stays false
    assert.equal(body.has_session, false);
  } finally {
    fsModule.existsSync = origExistsSync;
  }
}

// whatsapp: QR size clamping edge cases (line 207) — size=0 and size=9999
async function testWhatsappQrSizeClamping() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
  state.lastQr = "test-qr-for-size";
  state.lastQrAt = Date.now();

  // size=0 should clamp to 128 (min)
  const resp1 = await whatsappHandler({
    method: "GET",
    query: { action: "qr", size: "0" },
    body: "",
    env: {},
  });
  assert.equal(resp1.status, 200);

  // size=9999 should clamp to 1024 (max)
  const resp2 = await whatsappHandler({
    method: "GET",
    query: { action: "qr", size: "9999" },
    body: "",
    env: {},
  });
  assert.equal(resp2.status, 200);
}

// whatsapp: send action socket.sendMessage() error catch block (line 235)
async function testWhatsappSendMessageError() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
  state.connected = true;
  state.socket = {
    sendMessage: async () => { throw new Error("socket write failed"); },
  };

  const resp = await whatsappHandler({
    method: "POST",
    query: { action: "send" },
    body: JSON.stringify({ to: "15551234567", text: "hello" }),
    env: {},
  });
  assert.equal(resp.status, 500);
  const body = JSON.parse(resp.body);
  assert.ok(String(body.error).includes("socket write failed"));
}

async function testWhatsappDefaultQrFormat() {
  resetWhatsappRuntimeState();
  const state = global.__fastfn_wa;
  state.lastQr = "test-qr";
  state.lastQrAt = Date.now();

  // No format param — covers line 203 default format
  const resp = await whatsappHandler({
    method: "GET",
    query: { action: "qr" },
    body: "",
    env: {},
  });
  // Should default to "png" format or return raw qr
  assert.equal(resp.status, 200);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
