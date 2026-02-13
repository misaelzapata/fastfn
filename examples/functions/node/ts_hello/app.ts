// @summary Hello (TypeScript)
// @methods GET
// @query {"name":"World"}
export const handler = async (event: any) => {
  const q = event.query || {};
  const name = q.name || "World";
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ hello: name, runtime: "node(ts)" }),
  };
};

