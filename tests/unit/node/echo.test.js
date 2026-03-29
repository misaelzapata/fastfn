const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const nodeEchoHandler = require(path.join(ROOT, "examples/functions/node/node-echo/handler.js")).handler;
const nodeSimpleEchoHandler = require(path.join(ROOT, "examples/functions/node/echo/handler.js")).handler;

describe("echo handlers", () => {
  test("node-echo returns runtime and function name", async () => {
    const resp = await nodeEchoHandler({ query: { name: "NodeOnly" } });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.runtime, "node");
    assert.equal(body.function, "node-echo");
    assert.equal(body.hello, "NodeOnly");
  });

  test("simple echo returns query and context", async () => {
    const resp = await nodeSimpleEchoHandler({ query: { key: "test" }, context: { user: { trace_id: "z1" } } });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.key, "test");
    assert.equal(body.query.key, "test");
    assert.equal(body.context.user.trace_id, "z1");
  });
});
