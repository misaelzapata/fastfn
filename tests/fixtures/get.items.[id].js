exports.handler = async (event) => {
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ok: true,
      route: "GET /items/:id",
      runtime: "node",
      id: (event.path_params || {}).id || null,
      event,
    }),
  };
};

