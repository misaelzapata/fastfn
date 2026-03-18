// GET /api/v1/orders — List all orders, optionally filtered by ?status=
const fs = require("node:fs");

const STATE_FILE = "/tmp/fastfn-platform-equivalents/orders.json";

function loadOrders() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
  } catch {
    return [];
  }
}

exports.handler = async (event = {}) => {
  const filter = (event.query?.status || "").toLowerCase();
  const orders = loadOrders();

  // Optional filter: GET /api/v1/orders?status=pending
  const result = filter
    ? orders.filter((o) => (o.status || "").toLowerCase() === filter)
    : orders;

  return {
    status: 200,
    body: JSON.stringify({ ok: true, total: result.length, orders: result }),
  };
};
