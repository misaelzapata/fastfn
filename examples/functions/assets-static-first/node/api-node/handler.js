exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    runtime: "node",
    title: "Node fallback route",
    summary: "Static assets own / first, but /api-node still resolves to the Node handler.",
    path: "/api-node",
  }),
});
