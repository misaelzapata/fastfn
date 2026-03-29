const assert = require("node:assert/strict");
const path = require("node:path");
const os = require("node:os");
const fs = require("node:fs");
const { ROOT } = require("./helpers");

const aiToolAgentModule = require(path.join(ROOT, "examples/functions/node/ai-tool-agent/handler.js"));
const aiToolAgentHandler = aiToolAgentModule.handler;
const aiToolAgentInternal = require(path.join(ROOT, "examples/functions/node/ai-tool-agent/_internal.js"));

describe("ai-tool-agent handler", () => {
  test("dry run", async () => {
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
  });

  test("tool calling loop and memory", async () => {
    const prevFetch = global.fetch;
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
            text: async () => JSON.stringify({
              choices: [{
                message: {
                  content: null,
                  tool_calls: [
                    { id: "call_http", function: { name: "http_get", arguments: JSON.stringify({ url: "https://api.ipify.org?format=json" }) } },
                    { id: "call_fn", function: { name: "fn_get", arguments: JSON.stringify({ name: "request-inspector", query: { key: "demo" } }) } },
                  ],
                },
              }],
            }),
          };
        }
        if (openaiCalls === 2) {
          return { ok: true, status: 200, text: async () => JSON.stringify({ choices: [{ message: { content: "final-1" } }] }) };
        }
        return { ok: true, status: 200, text: async () => JSON.stringify({ choices: [{ message: { content: "final-2" } }] }) };
      }

      if (u.startsWith("https://api.ipify.org")) {
        return { ok: true, status: 200, headers: { get: () => "application/json" }, text: async () => JSON.stringify({ ip: "203.0.113.10" }) };
      }
      if (u.includes("/request-inspector")) {
        return { ok: true, status: 200, headers: { get: () => "application/json" }, text: async () => JSON.stringify({ ok: true, path: "/request-inspector", query: { key: "demo" } }) };
      }
      return { ok: false, status: 404, text: async () => "not found" };
    };

    process.env.FASTFN_AGENT_MEMORY_PATH = memPath;
    try {
      const env = { OPENAI_API_KEY: "test-openai-key", OPENAI_BASE_URL: "https://api.openai.com/v1" };

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

      assert.ok(openaiPayloads.length >= 3);
      const secondRunPayload = openaiPayloads[2];
      const msgs = Array.isArray(secondRunPayload.messages) ? secondRunPayload.messages : [];
      const hasPrevUser = msgs.some((m) => m && m.role === "user" && m.content === "ip + inspector");
      const hasPrevAssistant = msgs.some((m) => m && m.role === "assistant" && m.content === "final-1");
      assert.equal(hasPrevUser, true);
      assert.equal(hasPrevAssistant, true);
    } finally {
      global.fetch = prevFetch;
      if (prevMem === undefined) delete process.env.FASTFN_AGENT_MEMORY_PATH;
      else process.env.FASTFN_AGENT_MEMORY_PATH = prevMem;
      try { fs.unlinkSync(memPath); } catch (_) {}
    }
  });

  test("blocks local host tool", async () => {
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
            text: async () => JSON.stringify({
              choices: [{
                message: {
                  content: null,
                  tool_calls: [{ id: "call_local", function: { name: "http_get", arguments: JSON.stringify({ url: "http://127.0.0.1:8080/_fn/health" }) } }],
                },
              }],
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
        query: { dry_run: "false", text: "try local host", tool_allow_hosts: "127.0.0.1" },
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
  });

  test("private and error branches", async () => {
    assert.equal(aiToolAgentInternal.asBool("invalid", false), false);
    assert.equal(aiToolAgentInternal.parseJson("{bad"), null);
    assert.equal(aiToolAgentInternal.chooseSecret("<set-me>", "fallback"), "fallback");
    assert.equal(aiToolAgentInternal.chooseSecret("<set-me>", " "), "");
    assert.equal(aiToolAgentInternal.hostAllowed("sub.api.ipify.org", ["ipify.org"]), true);
    assert.equal(aiToolAgentInternal.hostAllowed("example.com", ["ipify.org"]), false);

    const oldWrite = fs.writeFileSync;
    fs.writeFileSync = () => { throw new Error("write denied"); };
    try {
      aiToolAgentInternal.saveMemory(
        { enabled: true, maxTurns: 1, ttlSecs: 60, agentId: "unit", memPath: path.join(os.tmpdir(), "fastfn-ai-tool-save-fail.json") },
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
          text: async () => JSON.stringify({
            choices: [{ message: { content: null, tool_calls: [{ id: "call-1", function: { name: "unknown_tool", arguments: "{}" } }] } }],
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

    global.fetch = async () => { throw new Error("openai hard fail"); };
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
  });

  test("loop termination and tool call validation", async () => {
    const noText = await aiToolAgentHandler({ query: {}, body: "", env: {}, context: {} });
    assert.equal(noText.status, 200);
    const noTextBody = JSON.parse(noText.body);
    assert.ok(noTextBody.note.includes("Provide text="));
    assert.ok(Array.isArray(noTextBody.tools));

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
              tool_calls: [{ id: `call_${callCount}`, type: "function", function: { name: "http_get", arguments: '{"url":"https://api.ipify.org"}' } }],
            },
          }],
        });
        return { ok: true, status: 200, text: async () => body };
      }
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

    global.fetch = async () => { throw new Error("openai unreachable"); };
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
  });

  test("malformed tool call", async () => {
    const prevFetch = global.fetch;
    let callCount = 0;
    global.fetch = async (url, opts = {}) => {
      const u = String(url);
      if (u.includes("/chat/completions")) {
        callCount++;
        if (callCount === 1) {
          return {
            ok: true,
            status: 200,
            text: async () => JSON.stringify({
              choices: [{
                message: {
                  content: null,
                  tool_calls: [
                    { id: "c1", function: { arguments: '{}' } },
                    { id: "c2", function: { name: "http_get", arguments: 123 } },
                    { id: "c3" },
                  ],
                },
              }],
            }),
          };
        }
        return { ok: true, status: 200, text: async () => JSON.stringify({ choices: [{ message: { content: "done" } }] }) };
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
  });

  test("error without message", async () => {
    const prevFetch = global.fetch;
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
  });
});

describe("ai-tool-agent _internal", () => {
  test("http_get with JSON content-type", async () => {
    const prevFetch = global.fetch;
    global.fetch = async () => ({
      ok: true,
      status: 200,
      text: async () => '{"ip":"1.2.3.4"}',
      headers: { get: (name) => name === "content-type" ? "application/json" : null },
    });
    try {
      const cfg = { fnBaseUrl: "http://127.0.0.1:8080", timeoutMs: 2000, allowedFns: ["request-inspector"], allowedHosts: ["api.ipify.org"] };
      const result = await aiToolAgentInternal.executeToolCall("http_get", { url: "https://api.ipify.org/?format=json" }, cfg);
      assert.equal(result.ok, true);
      assert.equal(result.status, 200);
      assert.deepEqual(result.json, { ip: "1.2.3.4" });
      assert.equal(result.content_type, "application/json");
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("fn_get with query params", async () => {
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
      const cfg = { fnBaseUrl: "http://127.0.0.1:8080", timeoutMs: 2000, allowedFns: ["request-inspector"], allowedHosts: ["api.ipify.org"] };
      const result = await aiToolAgentInternal.executeToolCall("fn_get", { name: "request-inspector", query: { foo: "bar", baz: "qux" } }, cfg);
      assert.equal(result.ok, true);
      assert.equal(result.tool, "fn_get");
      assert.equal(result.name, "request-inspector");
      assert.deepEqual(result.json, { result: "ok" });
      assert.ok(capturedUrl.includes("foo=bar"));
      assert.ok(capturedUrl.includes("baz=qux"));

      const result2 = await aiToolAgentInternal.executeToolCall("fn_get", { name: "request-inspector", query: {} }, cfg);
      assert.equal(result2.ok, true);

      const result3 = await aiToolAgentInternal.executeToolCall("fn_get", { name: "request-inspector", query: { "": "skip", valid: "keep" } }, cfg);
      assert.equal(result3.ok, true);
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("openaiChat error body", async () => {
    const prevFetch = global.fetch;

    global.fetch = async () => ({
      ok: false,
      status: 429,
      text: async () => "rate limited",
    });
    try {
      await assert.rejects(
        () => aiToolAgentInternal.openaiChat({ OPENAI_API_KEY: "test-key" }, [{ role: "user", content: "hi" }], [], 2000),
        (err) => {
          assert.ok(String(err.message).includes("openai error status=429"));
          assert.ok(String(err.message).includes("rate limited"));
          return true;
        }
      );
    } finally {
      global.fetch = prevFetch;
    }

    global.fetch = async () => ({
      ok: true,
      status: 200,
      text: async () => JSON.stringify({ choices: [{}] }),
    });
    try {
      await assert.rejects(
        () => aiToolAgentInternal.openaiChat({ OPENAI_API_KEY: "test-key" }, [{ role: "user", content: "hi" }], [], 2000),
        (err) => {
          assert.ok(String(err.message).includes("no message"));
          return true;
        }
      );
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("summarizeAssistantMessage", async () => {
    const summarize = aiToolAgentInternal.summarizeAssistantMessage;

    const r1 = summarize(null);
    assert.equal(r1.role, "assistant");

    const r2 = summarize("string");
    assert.equal(r2.role, "assistant");

    const r3 = summarize({ content: "hello world", tool_calls: [{ id: "c1", function: { name: "http_get" } }] });
    assert.equal(r3.role, "assistant");
    assert.equal(r3.content, "hello world");
    assert.equal(r3.tool_calls.length, 1);
    assert.equal(r3.tool_calls[0].id, "c1");
    assert.equal(r3.tool_calls[0].name, "http_get");

    const r4 = summarize({ content: "just text" });
    assert.equal(r4.content, "just text");
    assert.deepEqual(r4.tool_calls, []);

    const r5 = summarize({ content: 123 });
    assert.equal(r5.content, null);

    const r6 = summarize({ tool_calls: [null, { id: "c2", function: { name: "fn_get" } }] });
    assert.equal(r6.tool_calls.length, 2);
    assert.equal(r6.tool_calls[0].id, null);
    assert.equal(r6.tool_calls[1].name, "fn_get");
  });

  test("fn_get empty/invalid name", async () => {
    const cfg = { fnBaseUrl: "http://127.0.0.1:8080", timeoutMs: 500, allowedFns: ["request-inspector"], allowedHosts: [] };
    const r1 = await aiToolAgentInternal.executeToolCall("fn_get", {}, cfg);
    assert.equal(r1.error, "invalid function name");
    const r2 = await aiToolAgentInternal.executeToolCall("fn_get", { name: 123 }, cfg);
    assert.equal(r2.error, "invalid function name");
  });

  test("isLocalHostname variants", async () => {
    const cfg = { fnBaseUrl: "http://127.0.0.1:8080", timeoutMs: 500, allowedFns: [], allowedHosts: ["localhost", "127.0.0.1"] };
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
  });
});
