const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const telegramSendHandler = require(path.join(ROOT, "examples/functions/node/telegram-send/handler.js")).handler;

describe("telegram-send handler", () => {
  test("dry run returns preview", async () => {
    const resp = await telegramSendHandler({ query: { chat_id: "123", text: "hola", dry_run: "true" } });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.channel, "telegram");
    assert.equal(body.chat_id, "123");
    assert.equal(body.dry_run, true);
  });

  test("error and send paths", async () => {
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
  });

  test("branch coverage", async () => {
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

    // Body has dry_run property
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
  });
});
