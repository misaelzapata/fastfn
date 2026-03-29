const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const edgeProxyHandler = require(path.join(ROOT, "examples/functions/node/edge-proxy/handler.js")).handler;

describe("edge-proxy handler", () => {
  test("returns proxy directive shape", async () => {
    const resp = await edgeProxyHandler({ method: "GET", body: "", context: { request_id: "req-x", timeout_ms: 1234 } });
    assert.equal(resp.status, 200);
    assert.equal(typeof resp.proxy, "object");
    assert.ok(String(resp.proxy.path || "").startsWith("/request-inspector"), "proxy path should target public endpoint");
    assert.equal(resp.proxy.timeout_ms, 1234);
  });
});
