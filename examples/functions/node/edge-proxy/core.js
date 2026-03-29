exports.handler = async (event) => {
  const ctx = event.context || {};

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    proxy: {
      path: "/request-inspector?via=edge-proxy",
      method: event.method || "GET",
      headers: {
        "x-fastfn-edge": "1",
        "x-fastfn-request-id": String(ctx.request_id || ""),
      },
      body: event.body || "",
      timeout_ms: ctx.timeout_ms || 2000,
    },
  };
};
