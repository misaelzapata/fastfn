exports.handler = function(event) {
  const id = (event.params || {}).id || "0";
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      version: "v2",
      data: { id: Number(id), name: "Alice", email: "alice@example.com", role: "admin" },
    }),
  };
};
