exports.handler = async (event, { id }) => {
  // PUT /products/:id — id arrives directly from [id] filename
  let data;
  try {
    data = typeof event.body === "string" ? JSON.parse(event.body) : event.body || {};
  } catch {
    return { status: 400, body: JSON.stringify({ error: "Invalid JSON" }) };
  }

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id: Number(id), ...data, updated: true }),
  };
};
