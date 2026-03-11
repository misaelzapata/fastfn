exports.handler = async (event, { id }) => {
  // GET /products/:id — id arrives directly from [id] filename
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id: Number(id), name: "Widget", price: 9.99 }),
  };
};
