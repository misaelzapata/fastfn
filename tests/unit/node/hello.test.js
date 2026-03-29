const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const handler = require(path.join(ROOT, "examples/functions/node/hello/v2/handler.js")).handler;

describe("hello handler", () => {
  test("returns greeting with name from query", async () => {
    const resp = await handler({ query: { name: "Unit" }, id: "req-2" });
    assert.equal(typeof resp, "object");
    assert.equal(resp.status, 200);
    assert.equal(typeof resp.headers, "object");
    assert.equal(typeof resp.body, "string");
    const body = JSON.parse(resp.body);
    assert.equal(body.hello, "v2-Unit");
    assert.equal(body.debug, undefined);
  });

  test("returns debug info when debug enabled", async () => {
    const resp = await handler({
      query: { name: "Unit" },
      id: "req-3",
      context: { debug: { enabled: true }, user: { trace_id: "trace-9" } },
    });
    const body = JSON.parse(resp.body);
    assert.equal(body.hello, "v2-Unit");
    assert.equal(body.debug.request_id, "req-3");
    assert.equal(body.debug.trace_id, "trace-9");
  });
});
