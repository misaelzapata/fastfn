const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const requestInspectorHandler = require(path.join(ROOT, "examples/functions/node/request-inspector/handler.js")).handler;

describe("request-inspector handler", () => {
  test("returns request details", async () => {
    const resp = await requestInspectorHandler({
      method: "POST",
      path: "/request-inspector",
      query: { key: "v" },
      headers: { "x-test": "1", "Content-Type": "text/plain" },
      body: "hello",
      context: { request_id: "req-ri", user: { trace_id: "t1" } },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.method, "POST");
    assert.equal(body.query.key, "v");
    assert.equal(body.headers["x-test"], "1");
    assert.equal(body.body, "hello");
    assert.equal(body.context.request_id, "req-ri");
  });

  test("non-string body becomes empty", async () => {
    const resp = await requestInspectorHandler({
      method: "GET",
      body: { key: "val" },
      headers: {},
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.body, "");

    const resp2 = await requestInspectorHandler({ method: "GET", body: null, headers: {} });
    assert.equal(resp2.status, 200);
    const body2 = JSON.parse(resp2.body);
    assert.equal(body2.body, "");
  });

  test("truncates long body", async () => {
    const longBody = "x".repeat(3000);
    const resp3 = await requestInspectorHandler({ method: "GET", body: longBody, headers: {} });
    const body3 = JSON.parse(resp3.body);
    assert.ok(body3.body.includes("...(truncated)"));
  });

  test("handles missing context", async () => {
    const resp = await requestInspectorHandler({
      method: "GET",
      headers: { "x-test": "1" },
      body: "hi",
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.context.request_id, undefined);
    assert.equal(body.context.user, undefined);
  });

  test("handles non-object headers", async () => {
    const resp2 = await requestInspectorHandler({
      method: "GET",
      headers: "not-an-object",
      body: "",
    });
    assert.equal(resp2.status, 200);
  });

  test("keeps allowlisted headers, lowercases them, and drops others", async () => {
    const resp = await requestInspectorHandler({
      headers: {
        Authorization: "Bearer test-token",
        "User-Agent": "fastfn-test",
        "X-Trace-Id": "trace-1",
        Accept: "application/json",
      },
      body: "",
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.method, null);
    assert.equal(body.path, null);
    assert.deepEqual(body.headers, {
      authorization: "Bearer test-token",
      "user-agent": "fastfn-test",
      "x-trace-id": "trace-1",
    });
  });
});
