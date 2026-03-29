const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const telegramAiDigestModule = require(path.join(ROOT, "examples/functions/node/telegram-ai-digest/handler.js"));
const telegramAiDigestHandler = telegramAiDigestModule.handler;

describe("telegram-ai-digest handler", () => {
  test("skips when env missing or placeholders", async () => {
    const resp = await telegramAiDigestHandler({ env: {} });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.skipped, true);
    assert.deepEqual(body.missing_env, ["TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "OPENAI_API_KEY"]);

    const placeholderResp = await telegramAiDigestHandler({
      env: {
        TELEGRAM_BOT_TOKEN: "<set-me>",
        TELEGRAM_CHAT_ID: "changeme",
        OPENAI_API_KEY: "replace-me",
      },
    });
    assert.equal(placeholderResp.status, 200);
    const placeholderBody = JSON.parse(placeholderResp.body);
    assert.equal(placeholderBody.skipped, true);
    assert.deepEqual(placeholderBody.missing_env, ["TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "OPENAI_API_KEY"]);
  });

  test("uses process env fallback when function env has placeholders", async () => {
    const prevFetch = global.fetch;
    const prevBot = process.env.TELEGRAM_BOT_TOKEN;
    const prevChat = process.env.TELEGRAM_CHAT_ID;
    const prevOpenAI = process.env.OPENAI_API_KEY;

    global.fetch = async (url, opts = {}) => {
      const u = String(url);
      if (u.includes("/getUpdates")) {
        return {
          ok: true,
          status: 200,
          json: async () => ({ ok: true, result: [{ message: { text: "hello from env" } }] }),
        };
      }
      if (u.includes("/chat/completions")) {
        return {
          ok: true,
          status: 200,
          json: async () => ({ choices: [{ message: { content: "summary from env" } }] }),
        };
      }
      if (u.includes("/sendMessage")) {
        const payload = JSON.parse(String(opts.body || "{}"));
        assert.equal(payload.chat_id, "999");
        return { ok: true, json: async () => ({ ok: true, result: { message_id: 77 } }) };
      }
      return { ok: false, status: 404, json: async () => ({}) };
    };

    process.env.TELEGRAM_BOT_TOKEN = "process-bot";
    process.env.TELEGRAM_CHAT_ID = "999";
    process.env.OPENAI_API_KEY = "process-openai";

    try {
      const resp = await telegramAiDigestHandler({
        env: {
          TELEGRAM_BOT_TOKEN: "<set-me>",
          TELEGRAM_CHAT_ID: "<set-me>",
          OPENAI_API_KEY: "<set-me>",
        },
      });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.ok, true);
      assert.equal(body.message_count, 1);
    } finally {
      global.fetch = prevFetch;
      if (prevBot === undefined) {
        delete process.env.TELEGRAM_BOT_TOKEN;
      } else {
        process.env.TELEGRAM_BOT_TOKEN = prevBot;
      }
      if (prevChat === undefined) {
        delete process.env.TELEGRAM_CHAT_ID;
      } else {
        process.env.TELEGRAM_CHAT_ID = prevChat;
      }
      if (prevOpenAI === undefined) {
        delete process.env.OPENAI_API_KEY;
      } else {
        process.env.OPENAI_API_KEY = prevOpenAI;
      }
    }
  });

  test("skips when no messages", async () => {
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
  });

  test("successful digest", async () => {
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

      assert.ok(sendMessagePayload);
      assert.equal(sendMessagePayload.chat_id, "456");
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("OpenAI error returns 502", async () => {
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
  });

  test("getUpdates failure returns 502", async () => {
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
  });

  test("getUpdates data.ok=false", async () => {
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
  });

  test("sendMessage failure returns 502", async () => {
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
  });

  test("partial updates (missing message/text)", async () => {
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
              { update_id: 2 },
              { update_id: 3, message: {} },
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
      assert.ok(body.message_count <= 2);
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("empty choices from OpenAI", async () => {
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
  });
});
