exports.handler = async (event) => {
  // GET /products — list all products
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      products: [
        { id: 1, name: "Widget", price: 9.99 },
        { id: 2, name: "Gadget", price: 24.99 },
      ],
      total: 2,
    }),
  };
};
