// @summary Edge auth gateway — validate a Bearer token, then proxy upstream
// @methods GET,POST
// @query {"target":"openapi"}
// @body hello

exports.handler = async (event) => {
  const token = event.env?.EDGE_AUTH_TOKEN || "";
  const auth = event.headers?.authorization || "";

  // 1. Check the Bearer token
  if (!token || auth !== `Bearer ${token}`) {
    return {
      status: 401,
      headers: { "WWW-Authenticate": "Bearer" },
      body: JSON.stringify({ error: "unauthorized" }),
    };
  }

  // 2. Pick the upstream path from ?target=
  const target = (event.query?.target || "openapi").toLowerCase();

  if (target !== "openapi" && target !== "health") {
    return {
      status: 400,
      body: JSON.stringify({ error: "use ?target=openapi or ?target=health" }),
    };
  }

  // 3. Proxy the request upstream
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
