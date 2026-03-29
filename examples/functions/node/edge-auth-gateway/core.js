exports.handler = async (event) => {
  const token = event.env?.EDGE_AUTH_TOKEN || "";
  const auth = event.headers?.authorization || "";

  if (!token || auth !== `Bearer ${token}`) {
    return {
      status: 401,
      headers: { "WWW-Authenticate": "Bearer" },
      body: JSON.stringify({ error: "unauthorized" }),
    };
  }

  const target = (event.query?.target || "openapi").toLowerCase();

  if (target !== "openapi" && target !== "health") {
    return {
      status: 400,
      body: JSON.stringify({ error: "use ?target=openapi or ?target=health" }),
    };
  }

  return {
    proxy: {
      path: `/request-inspector?target=${target}`,
      method: event.method || "GET",
      headers: { "x-fastfn-edge": "1" },
      body: event.body || "",
      timeout_ms: 2000,
    },
  };
};
