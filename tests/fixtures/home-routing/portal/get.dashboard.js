exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ endpoint: "portal-dashboard", source: "folder-home" }),
});
