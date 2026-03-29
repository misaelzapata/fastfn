exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    step: 1,
    message: "Step 1 ready (node).",
    runtime: "node",
  }),
});
