// @summary Edge header injection + passthrough
// @methods GET,POST,PUT,PATCH,DELETE
// @query {"tenant":"demo"}
// @body hello
//
// Pattern:
// - compute/inject gateway headers (tenant, request id, etc)
// - proxy to an upstream endpoint
//
// Demo upstream: /fn/request_inspector (so you can see injected headers).

exports.handler = async (event) => {
  const ctx = event.context || {};
  const q = event.query || {};
  const tenant = String(q.tenant || "demo");

  return {
    proxy: {
      path: "/fn/request_inspector",
      method: event.method || "GET",
      headers: {
        "x-fastfn-edge": "1",
        "x-fastfn-request-id": String(ctx.request_id || ""),
        "x-tenant": tenant,
      },
      body: event.body || "",
      timeout_ms: ctx.timeout_ms || 2000,
    },
  };
};

