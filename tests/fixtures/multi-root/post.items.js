exports.handler = async (event) => {
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ok: true,
      route: "POST /items",
      runtime: "node",
      event,
    }),
  };
};

