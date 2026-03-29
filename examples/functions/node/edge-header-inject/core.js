exports.handler = async (event) => {
  const ctx = event.context || {};
  const q = event.query || {};
  const tenant = String(q.tenant || "demo");
  return {
    proxy: {
      path: "/request-inspector",
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
