const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const edgeFilterHandler = require(path.join(ROOT, "examples/functions/node/edge-filter/handler.js")).handler;

describe("edge-filter handler", () => {
  test("denies request without api key", async () => {
    const denied = await edgeFilterHandler({ query: { user_id: "123" }, headers: {}, env: { EDGE_FILTER_API_KEY: "dev" } });
    assert.equal(denied.status, 401);
  });

  test("rejects invalid user_id", async () => {
    const bad = await edgeFilterHandler({
      query: { user_id: "abc" },
      headers: { "x-api-key": "dev" },
      env: { EDGE_FILTER_API_KEY: "dev" },
    });
    assert.equal(bad.status, 400);
  });

  test("proxies valid request", async () => {
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
  });

  test("default timeout", async () => {
    const okDefaultTimeout = await edgeFilterHandler({
      method: "GET",
      query: { user_id: "123" },
      headers: { "x-api-key": "dev" },
      env: { EDGE_FILTER_API_KEY: "dev", UPSTREAM_TOKEN: "" },
    });
    assert.equal(okDefaultTimeout.proxy.timeout_ms, 10000);
  });

  test("userId camelCase variant", async () => {
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
  });

  test("UPSTREAM_TOKEN header", async () => {
    const resp2 = await edgeFilterHandler({
      method: "GET",
      query: { user_id: "789" },
      headers: { "x-api-key": "dev" },
      env: { EDGE_FILTER_API_KEY: "dev", UPSTREAM_TOKEN: "bearer-tok" },
    });
    assert.equal(resp2.proxy.headers.authorization, "Bearer bearer-tok");
  });

  test("accepts uppercase api key header and preserves request metadata", async () => {
    const resp = await edgeFilterHandler({
      method: "GET",
      query: { user_id: "321" },
      headers: { "X-API-KEY": "dev" },
      env: { EDGE_FILTER_API_KEY: "dev" },
      context: { request_id: "req-upper", timeout_ms: 15000 },
    });
    assert.equal(typeof resp.proxy, "object");
    assert.equal(resp.proxy.headers["x-fastfn-request-id"], "req-upper");
    assert.equal(resp.proxy.timeout_ms, 15000);
  });

  test("accepts mixed-case api key header", async () => {
    const resp = await edgeFilterHandler({
      method: "GET",
      query: { user_id: "654" },
      headers: { "X-Api-Key": "dev" },
      env: { EDGE_FILTER_API_KEY: "dev" },
    });
    assert.equal(typeof resp.proxy, "object");
    const rewritten = new URL(String(resp.proxy.path), "http://fastfn.local");
    assert.equal(rewritten.searchParams.get("edge_user_id"), "654");
  });
});
