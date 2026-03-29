const assert = require("node:assert/strict");
const path = require("node:path");
const { ROOT } = require("./helpers");

const ipIntelRemoteHandler = require(path.join(ROOT, "examples/functions/ip-intel/get.remote.js")).handler;

describe("ip-intel handler", () => {
  test("mock mode returns mocked data", async () => {
    const resp = await ipIntelRemoteHandler({ query: { ip: "8.8.8.8", mock: "1" } });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.provider, "ipapi-mock");
    assert.equal(body.country_code, "US");
  });

  test("ipapi success", async () => {
    const prevFetch = global.fetch;
    let requestedURL = "";
    global.fetch = async (url) => {
      requestedURL = String(url);
      return {
        ok: true,
        status: 200,
        text: async () =>
          JSON.stringify({
            ip: "8.8.8.8",
            country_code: "US",
            country_name: "United States",
            city: "Mountain View",
            region: "California",
          }),
      };
    };
    try {
      const resp = await ipIntelRemoteHandler({
        query: { ip: "8.8.8.8" },
        env: { IPAPI_BASE_URL: "https://mock.ipapi.local" },
      });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.provider, "ipapi");
      assert.equal(body.country_code, "US");
      assert.ok(requestedURL.includes("/8.8.8.8/json/"));
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("ipapi error returns 502", async () => {
    const prevFetch = global.fetch;
    global.fetch = async () => ({
      ok: false,
      status: 429,
      text: async () => JSON.stringify({ error: "rate limited" }),
    });
    try {
      const resp = await ipIntelRemoteHandler({
        query: { ip: "8.8.8.8" },
        env: { IPAPI_BASE_URL: "https://mock.ipapi.local" },
      });
      assert.equal(resp.status, 502);
      const body = JSON.parse(resp.body);
      assert.equal(body.error, "ipapi_lookup_failed");
    } finally {
      global.fetch = prevFetch;
    }
  });

  test("validation and non-JSON failures", async () => {
    const missing = await ipIntelRemoteHandler({ query: {}, client: {} });
    assert.equal(missing.status, 400);
    const missingBody = JSON.parse(missing.body);
    assert.ok(String(missingBody.error || "").includes("missing ip"));

    const invalid = await ipIntelRemoteHandler({ query: { ip: "999.999.1.1" } });
    assert.equal(invalid.status, 400);
    const invalidBody = JSON.parse(invalid.body);
    assert.ok(String(invalidBody.error || "").includes("invalid ip"));

    const prevFetch = global.fetch;
    global.fetch = async () => ({
      ok: true,
      status: 200,
      text: async () => "<html>not-json</html>",
    });
    try {
      const nonJson = await ipIntelRemoteHandler({ query: { ip: "8.8.8.8" } });
      assert.equal(nonJson.status, 502);
      const nonJsonBody = JSON.parse(nonJson.body);
      assert.equal(nonJsonBody.error, "ipapi_lookup_failed");
    } finally {
      global.fetch = prevFetch;
    }
  });
});
