exports.handler = async (event) => {
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      runtime: "node",
      route: "GET /nextstyle-clean/users",
      users: [{ id: "1" }, { id: "2" }],
      event,
    }),
  };
};

