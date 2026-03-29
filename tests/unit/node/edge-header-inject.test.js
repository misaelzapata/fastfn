const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const edgeHeaderInjectHandler = require(path.join(ROOT, "examples/functions/node/edge-header-inject/handler.js")).handler;

describe("edge-header-inject handler", () => {
  test("injects tenant and timeout headers", async () => {
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
  });

  test("uses defaults when no params", async () => {
    const resp = await edgeHeaderInjectHandler({});
    assert.equal(typeof resp.proxy, "object");
    assert.equal(resp.proxy.path, "/request-inspector");
    assert.equal(resp.proxy.method, "GET");
    assert.equal(resp.proxy.headers["x-fastfn-edge"], "1");
    assert.equal(resp.proxy.headers["x-fastfn-request-id"], "");
    assert.equal(resp.proxy.headers["x-tenant"], "demo");
    assert.equal(resp.proxy.body, "");
    assert.equal(resp.proxy.timeout_ms, 2000);
  });
});
