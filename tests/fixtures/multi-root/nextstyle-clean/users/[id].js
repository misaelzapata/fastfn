exports.handler = async (event) => {
  const id = (event.path_params || {}).id || null;
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      runtime: "node",
      route: "GET /nextstyle-clean/users/:id",
      id,
      event,
    }),
  };
};

