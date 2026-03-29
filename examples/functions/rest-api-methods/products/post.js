exports.handler = async (event) => {
  // POST /products — create a product
  let data;
  try {
    data = typeof event.body === "string" ? JSON.parse(event.body) : event.body || {};
  } catch {
    return { status: 400, body: JSON.stringify({ error: "Invalid JSON" }) };
  }

  const name = (data.name || "").trim();
  const price = data.price || 0;

  if (!name) {
    return { status: 400, body: JSON.stringify({ error: "name is required" }) };
  }

  return {
    status: 201,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id: 42, name, price, created: true }),
  };
};
