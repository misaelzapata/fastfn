const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const telegramAiReplyModule = require(path.join(ROOT, "examples/functions/node/telegram-ai-reply/handler.js"));
const telegramAiReplyHandler = telegramAiReplyModule.handler;

async function withSilencedConsoleError(fn) {
  const prevError = console.error;
  console.error = () => {};
  try {
    return await fn();
  } finally {
    console.error = prevError;
  }
}

describe("telegram-ai-reply handler", () => {
  test("skips update without text", async () => {
    const resp = await telegramAiReplyHandler({
      body: JSON.stringify({ message: { chat: { id: 123 } } }),
      env: {},
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.skipped, true);
    assert.ok(String(body.reason || "").includes("no text"));

    const resp2 = await telegramAiReplyHandler({
      body: JSON.stringify({ update_id: 1 }),
      env: {},
    });
    assert.equal(resp2.status, 200);
    const body2 = JSON.parse(resp2.body);
    assert.equal(body2.skipped, true);
  });

  test("skips when env vars missing or placeholders", async () => {
    const resp = await telegramAiReplyHandler({
      body: JSON.stringify({ message: { chat: { id: 123 }, text: "Hello" } }),
      env: {},
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.skipped, true);
    assert.deepEqual(body.missing_env, ["TELEGRAM_BOT_TOKEN", "OPENAI_API_KEY"]);

    const placeholderResp = await telegramAiReplyHandler({
      body: JSON.stringify({ message: { chat: { id: 123 }, text: "Hello" } }),
      env: { TELEGRAM_BOT_TOKEN: "<set-me>", OPENAI_API_KEY: "changeme" },
    });
    assert.equal(placeholderResp.status, 200);
    const placeholderBody = JSON.parse(placeholderResp.body);
    assert.equal(placeholderBody.skipped, true);
    assert.deepEqual(placeholderBody.missing_env, ["TELEGRAM_BOT_TOKEN", "OPENAI_API_KEY"]);
  });

  test("returns 400 on invalid JSON body", async () => {
    const resp = await telegramAiReplyHandler({
      body: "{not-json",
      env: {},
    });
    assert.equal(resp.status, 400);
    const body = JSON.parse(resp.body);
    assert.ok(String(body.error || "").includes("invalid JSON"));
  });

  test("accepts caption-only messages", async () => {
    const prevFetch = global.fetch;
    let openaiPayload = null;

    global.fetch = async (url, opts = {}) => {
      const u = String(url);
      if (u.includes("/chat/completions")) {
        openaiPayload = JSON.parse(String(opts.body || "{}"));
        return {
          ok: true,
          status: 200,
          json: async () => ({
            choices: [{ message: { content: "caption reply" } }],
          }),
        };
      }
      if (u.includes("/sendMessage")) {
        return {
          ok: true,
          json: async () => ({ ok: true, result: { message_id: 77 } }),
        };
      }
      return { ok: false, status: 404, json: async () => ({}) };
    };

    try {
      const resp = await telegramAiReplyHandler({
        body: JSON.stringify({
          message: { chat: { id: 123 }, caption: "Describe this photo", message_id: 9 },
        }),
        env: { TELEGRAM_BOT_TOKEN: "test-token", OPENAI_API_KEY: "test-key" },
      });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.ok, true);
      assert.equal(body.message_id, 77);
      const userMsg = openaiPayload.messages.find((m) => m.role === "user");
      assert.equal(userMsg.content, "Describe this photo");
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("uses process env fallback when function env has placeholders", async () => {
    const prevFetch = global.fetch;
    const prevBot = process.env.TELEGRAM_BOT_TOKEN;
    const prevOpenAI = process.env.OPENAI_API_KEY;
    let telegramPayload = null;

    global.fetch = async (url, opts = {}) => {
      const u = String(url);
      if (u.includes("/chat/completions")) {
        return {
          ok: true,
          status: 200,
          json: async () => ({ choices: [{ message: { content: "reply from process env" } }] }),
        };
      }
      if (u.includes("/sendMessage")) {
        telegramPayload = JSON.parse(String(opts.body || "{}"));
        return {
          ok: true,
          json: async () => ({ ok: true, result: { message_id: 64 } }),
        };
      }
      return { ok: false, status: 404, json: async () => ({}) };
    };

    process.env.TELEGRAM_BOT_TOKEN = "process-bot";
    process.env.OPENAI_API_KEY = "process-openai";

    try {
      const resp = await telegramAiReplyHandler({
        body: JSON.stringify({ message: { chat: { id: 321 }, text: "Hello" } }),
        env: { TELEGRAM_BOT_TOKEN: "<set-me>", OPENAI_API_KEY: "<set-me>" },
      });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.ok, true);
      assert.equal(body.message_id, 64);
      assert.ok(telegramPayload);
      assert.equal(telegramPayload.chat_id, 321);
    } finally {
      global.fetch = prevFetch;
      if (prevBot === undefined) {
        delete process.env.TELEGRAM_BOT_TOKEN;
      } else {
        process.env.TELEGRAM_BOT_TOKEN = prevBot;
      }
      if (prevOpenAI === undefined) {
        delete process.env.OPENAI_API_KEY;
      } else {
        process.env.OPENAI_API_KEY = prevOpenAI;
      }
    }
  });

  test("successful webhook flow", async () => {
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

      assert.ok(openaiPayload);
      const userMsg = openaiPayload.messages.find((m) => m.role === "user");
      assert.equal(userMsg.content, "Hello bot");

      assert.ok(telegramPayload);
      assert.equal(telegramPayload.chat_id, 123);
      assert.equal(telegramPayload.reply_to_message_id, 7);
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("OpenAI error returns 502", async () => {
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
      const resp = await withSilencedConsoleError(() => telegramAiReplyHandler({
        body: JSON.stringify({
          message: { chat: { id: 123 }, text: "Hello" },
        }),
        env: { TELEGRAM_BOT_TOKEN: "test-token", OPENAI_API_KEY: "test-key" },
      }));
      assert.equal(resp.status, 502);
      const body = JSON.parse(resp.body);
      assert.ok(String(body.error || "").includes("OpenAI error"));
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("Telegram send error returns 502", async () => {
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
      const resp = await withSilencedConsoleError(() => telegramAiReplyHandler({
        body: JSON.stringify({
          message: { chat: { id: 123 }, text: "Hello" },
        }),
        env: { TELEGRAM_BOT_TOKEN: "test-token", OPENAI_API_KEY: "test-key" },
      }));
      assert.equal(resp.status, 502);
      const body = JSON.parse(resp.body);
      assert.ok(String(body.error || "").includes("Telegram error"));
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("edited message", async () => {
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
  });

  test("body as object (not string)", async () => {
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
      const resp = await telegramAiReplyHandler({
        body: { message: { chat: { id: 999 }, text: "object body" } },
        env: { TELEGRAM_BOT_TOKEN: "tok", OPENAI_API_KEY: "key" },
      });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.ok, true);
      assert.equal(body.chat_id, 999);

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
  });

  test("OpenAI returns empty text", async () => {
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
      const resp = await withSilencedConsoleError(() => telegramAiReplyHandler({
        body: JSON.stringify({ message: { chat: { id: 10 }, text: "hi" } }),
        env: { TELEGRAM_BOT_TOKEN: "tok", OPENAI_API_KEY: "key" },
      }));
      assert.equal(resp.status, 502);
      const body = JSON.parse(resp.body);
      assert.ok(String(body.error).includes("no text"));
    } finally {
      global.fetch = prevFetch;
    }
  });
});
