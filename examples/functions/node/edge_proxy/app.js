// @summary Edge passthrough (proxy)
// @methods GET,POST,PUT,PATCH,DELETE
// @query {"key":"demo"}
// @body hello
exports.handler = async (event) => {
  const ctx = event.context || {};

  // This is a "Cloudflare Workers style" response: return a proxy directive and let fastfn do the fetch.
  // For local dev/tests, proxy to the built-in health endpoint.
  return {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
    proxy: {
      path: '/_fn/health',
      method: event.method || 'GET',
      headers: {
        'x-fastfn-edge': '1',
        'x-fastfn-request-id': String(ctx.request_id || ''),
      },
      body: event.body || '',
      timeout_ms: ctx.timeout_ms || 2000,
    },
  };
};
