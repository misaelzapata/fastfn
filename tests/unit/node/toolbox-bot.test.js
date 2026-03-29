const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const toolboxBotModule = require(path.join(ROOT, "examples/functions/node/toolbox-bot/handler.js"));
const toolboxBotHandler = toolboxBotModule.handler;

describe("toolbox-bot", () => {
  test("no text", async () => {
    const resp = await toolboxBotHandler({ method: "GET", query: {} });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.ok(String(body.note || "").includes("Send text="));
  });

  test("no directives", async () => {
    const resp = await toolboxBotHandler({ method: "GET", query: { text: "just plain text" } });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.ok, true);
    assert.deepEqual(body.tools, []);
    assert.ok(String(body.note || "").includes("No directives"));
  });

  test("parse and execute", async () => {
    const prevFetch = global.fetch;
    global.fetch = async (url, opts = {}) => {
      const u = String(url);
      if (u.includes("/request-inspector") || u.includes("/hello")) {
        return { ok: true, status: 200, headers: { get: () => "application/json" }, text: async () => JSON.stringify({ ok: true, note: "mock" }) };
      }
      if (u.startsWith("https://api.ipify.org")) {
        return { ok: true, status: 200, headers: { get: () => "application/json" }, text: async () => JSON.stringify({ ip: "203.0.113.10" }) };
      }
      return { ok: false, status: 418, headers: { get: () => "text/plain" }, text: async () => "nope" };
    };
    try {
      const resp = await toolboxBotHandler({
        method: "GET",
        query: { text: "Use [[http:https://api.ipify.org?format=json]] and [[fn:request-inspector?key=demo|GET]]" },
      });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.ok, true);
      assert.equal(body.results.length, 2);
      assert.equal(body.results[0].type, "fn");
      assert.equal(body.results[0].target, "request-inspector");
      assert.equal(body.results[0].ok, true);
      assert.equal(body.results[1].type, "http");
      assert.equal(body.results[1].ok, true);
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("deny host", async () => {
    const prevFetch = global.fetch;
    global.fetch = async () => { throw new Error("unexpected fetch"); };
    try {
      const resp = await toolboxBotHandler({ method: "GET", query: { text: "Use [[http:https://example.com/]]" } });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.results[0].ok, false);
      assert.ok(String(body.results[0].error || "").includes("not in allowlist"));
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("deny fn", async () => {
    const prevFetch = global.fetch;
    global.fetch = async () => { throw new Error("unexpected fetch"); };
    try {
      const resp = await toolboxBotHandler({ method: "GET", query: { text: "Use [[fn:not_allowed|GET]]" } });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.results[0].ok, false);
      assert.ok(String(body.results[0].error || "").includes("not in allowlist"));
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("fetch error", async () => {
    const prevFetch = global.fetch;
    global.fetch = async () => { throw new Error("fetch explode"); };
    try {
      const resp = await toolboxBotHandler({ method: "GET", query: { text: "[[http:https://api.ipify.org?format=json]]" } });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.results[0].ok, false);
      assert.ok(String(body.results[0].error || "").includes("fetch explode"));
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("invalid url directive", async () => {
    const resp = await toolboxBotHandler({ method: "GET", query: { text: "Use [[http:http://%]]" } });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.results[0].ok, false);
    assert.ok(String(body.results[0].error || "").includes("invalid url"));
  });

  test("body as object", async () => {
    const resp = await toolboxBotHandler({ method: "POST", query: {}, body: { text: "hello [[fn:request-inspector|GET]]" } });
    assert.equal(resp.status, 200);
  });

  test("body string uses JSON text, caps directives at six, and preserves explicit methods", async () => {
    const prevFetch = global.fetch;
    const seen = [];
    global.fetch = async (url, opts = {}) => {
      seen.push({ url: String(url), method: opts.method });
      return {
        ok: true,
        status: 200,
        headers: { get: () => "text/plain" },
        text: async () => "plain text tool output",
      };
    };
    try {
      const resp = await toolboxBotHandler({
        method: "POST",
        query: null,
        body: JSON.stringify({
          text: [
            "[[fn:hello|POST]]",
            "[[fn:request-inspector|GET]]",
            "[[http:https://api.ipify.org?format=json]]",
            "[[fn:hello]]",
            "[[fn:request-inspector]]",
            "[[http:https://api.ipify.org?format=json]]",
            "[[fn:hello]]",
          ].join(" "),
        }),
      });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.results.length, 6);
      assert.equal(seen.length, 6);
      assert.deepEqual(
        seen.map((item) => item.method),
        ["POST", "GET", "GET", "GET", "GET", "GET"],
      );
      assert.equal(body.results[0].body, "plain text tool output");
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("allows subdomain hosts and falls back to raw text for invalid json responses", async () => {
    const prevFetch = global.fetch;
    global.fetch = async () => ({
      ok: true,
      status: 200,
      headers: { get: () => "application/json; charset=utf-8" },
      text: async () => "{not-json",
    });
    try {
      const resp = await toolboxBotHandler({
        method: "GET",
        query: { text: "Use [[http:https://weather.wttr.in/?format=j1]]" },
      });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.results.length, 1);
      assert.equal(body.results[0].ok, true);
      assert.equal(body.results[0].body, "{not-json");
    } finally {
      global.fetch = prevFetch;
    }
  });
});
