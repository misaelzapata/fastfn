exports.handler = async (event, { path }) => {
  // GET /files/* — catch-all, path captures everything after /files/
  const segments = path ? path.split("/") : [];
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ path, segments, depth: segments.length }),
  };
};
