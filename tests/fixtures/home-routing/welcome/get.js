exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ endpoint: "welcome", source: "route" }),
});
