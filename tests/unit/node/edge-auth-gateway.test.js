const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const edgeAuthGatewayHandler = require(path.join(ROOT, "examples/functions/node/edge-auth-gateway/handler.js")).handler;
const githubWebhookGuardHandler = require(path.join(ROOT, "examples/functions/node/github-webhook-guard/handler.js")).handler;

describe("edge-auth-gateway handler", () => {
  test("denies unauthenticated request", async () => {
    const denied = await edgeAuthGatewayHandler({
      method: "GET",
      query: { target: "openapi" },
      headers: {},
      env: { EDGE_AUTH_TOKEN: "dev-token" },
    });
    assert.equal(denied.status, 401);
  });

  test("proxies authenticated health request", async () => {
    const ok = await edgeAuthGatewayHandler({
      method: "GET",
      query: { target: "health" },
      headers: { authorization: "Bearer dev-token" },
      env: { EDGE_AUTH_TOKEN: "dev-token" },
      context: { request_id: "req-auth", timeout_ms: 111 },
      body: "",
    });
    assert.equal(typeof ok.proxy, "object");
    const okUrl = new URL(String(ok.proxy.path), "http://fastfn.local");
    assert.equal(okUrl.pathname, "/request-inspector");
    assert.equal(okUrl.searchParams.get("target"), "health");
    assert.equal(ok.proxy.timeout_ms, 2000);
  });

  test("rejects invalid target", async () => {
    const badTarget = await edgeAuthGatewayHandler({
      method: "GET",
      query: { target: "invalid" },
      headers: { authorization: "Bearer dev-token" },
      env: { EDGE_AUTH_TOKEN: "dev-token" },
    });
    assert.equal(badTarget.status, 400);
  });

  test("proxies openapi POST", async () => {
    const openapi = await edgeAuthGatewayHandler({
      method: "POST",
      query: { target: "openapi" },
      headers: { authorization: "Bearer dev-token" },
      env: { EDGE_AUTH_TOKEN: "dev-token" },
      context: { request_id: "req-auth-openapi", timeout_ms: 123 },
      body: "payload",
    });
    assert.equal(typeof openapi.proxy, "object");
    const openapiUrl = new URL(String(openapi.proxy.path), "http://fastfn.local");
    assert.equal(openapiUrl.pathname, "/request-inspector");
    assert.equal(openapiUrl.searchParams.get("target"), "openapi");
    assert.equal(openapi.proxy.method, "POST");
  });

  test("defaults target, method, and body when omitted", async () => {
    const openapi = await edgeAuthGatewayHandler({
      headers: { authorization: "Bearer dev-token" },
      env: { EDGE_AUTH_TOKEN: "dev-token" },
    });
    assert.equal(typeof openapi.proxy, "object");
    const openapiUrl = new URL(String(openapi.proxy.path), "http://fastfn.local");
    assert.equal(openapiUrl.pathname, "/request-inspector");
    assert.equal(openapiUrl.searchParams.get("target"), "openapi");
    assert.equal(openapi.proxy.method, "GET");
    assert.equal(openapi.proxy.body, "");
  });

  test("denies request when env and headers are missing", async () => {
    const denied = await edgeAuthGatewayHandler({});
    assert.equal(denied.status, 401);
    assert.equal(denied.headers["WWW-Authenticate"], "Bearer");
  });
});

describe("github-webhook-guard handler", () => {
  const crypto = require("node:crypto");
  const secret = "dev";
  const payload = JSON.stringify({ zen: "Keep it logically awesome.", hook_id: 123 });
  const sig =
    "sha256=" + crypto.createHmac("sha256", Buffer.from(secret, "utf8")).update(Buffer.from(payload, "utf8")).digest("hex");

  test("rejects bad signature", async () => {
    const bad = await githubWebhookGuardHandler({
      method: "POST",
      headers: { "x-hub-signature-256": "sha256=bad" },
      env: { GITHUB_WEBHOOK_SECRET: secret },
      body: payload,
    });
    assert.equal(bad.status, 401);
  });

  test("verifies valid signature", async () => {
    const ok = await githubWebhookGuardHandler({
      method: "POST",
      headers: { "x-hub-signature-256": sig, "x-github-event": "ping", "x-github-delivery": "d1" },
      env: { GITHUB_WEBHOOK_SECRET: secret },
      body: payload,
      query: {},
    });
    assert.equal(ok.status, 200);
    const body = JSON.parse(ok.body);
    assert.equal(body.verified, true);
  });

  test("fails without secret", async () => {
    const missingSecret = await githubWebhookGuardHandler({
      method: "POST",
      headers: { "x-hub-signature-256": sig },
      env: {},
      body: payload,
    });
    assert.equal(missingSecret.status, 500);
  });

  test("fails without signature header", async () => {
    const missingSig = await githubWebhookGuardHandler({
      method: "POST",
      headers: {},
      env: { GITHUB_WEBHOOK_SECRET: secret },
      body: payload,
    });
    assert.equal(missingSig.status, 400);
  });

  test("forwards to proxy with push event", async () => {
    const forward = await githubWebhookGuardHandler({
      method: "POST",
      headers: { "x-hub-signature-256": sig, "x-github-event": "push", "x-github-delivery": "d2" },
      env: { GITHUB_WEBHOOK_SECRET: secret },
      body: payload,
      query: { forward: "1" },
      context: { request_id: "req-gh", timeout_ms: 321 },
    });
    assert.equal(typeof forward.proxy, "object");
    assert.equal(forward.proxy.path, "/request-inspector");
    assert.equal(forward.proxy.method, "POST");
  });

  test("handles non-string body", async () => {
    const resp = await githubWebhookGuardHandler({
      method: "POST",
      headers: { "x-hub-signature-256": "sha256=bad" },
      env: { GITHUB_WEBHOOK_SECRET: secret },
      body: { zen: "test" },
    });
    assert.equal(resp.status, 401);
  });
});
