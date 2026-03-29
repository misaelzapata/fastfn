exports.handler = async (event) => {
  const slug = (event.path_params || {}).slug || "";
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      runtime: "node",
      route: "GET /nextstyle-clean/docs/:slug*",
      slug,
      event,
    }),
  };
};

