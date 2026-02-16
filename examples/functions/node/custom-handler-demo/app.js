exports.main = async (event) => {
  const q = (event && event.query) || {};
  const name = q.name || "world";
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ runtime: "node", handler: "main", hello: name }),
  };
};
