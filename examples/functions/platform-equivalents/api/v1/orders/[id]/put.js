// PUT /api/v1/orders/:id — Update an order's status
const fs = require("node:fs");

const STATE_FILE = "/tmp/fastfn-platform-equivalents/orders.json";

function loadOrders() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
  } catch {
    return [];
  }
}

exports.handler = async (event = {}, params = {}) => {
  const id = Number(params.id || 0);
  const body =
    typeof event.body === "string" ? JSON.parse(event.body) : event.body || {};

  const status = (body.status || "").toLowerCase();
  const allowed = ["pending", "processing", "shipped", "delivered", "cancelled"];
  if (!allowed.includes(status)) {
    return {
      status: 400,
      body: JSON.stringify({ error: `status must be one of: ${allowed.join(", ")}` }),
    };
  }

  // Find and update the order
  const orders = loadOrders();
  const idx = orders.findIndex((o) => o.id === id);
  if (idx < 0) {
    return { status: 404, body: JSON.stringify({ error: "Order not found" }) };
  }

  orders[idx] = {
    ...orders[idx],
    status,
    tracking_number: body.tracking_number || null,
    updated_at: Math.floor(Date.now() / 1000),
  };
  fs.mkdirSync("/tmp/fastfn-platform-equivalents", { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(orders, null, 2));

  return {
    status: 200,
    body: JSON.stringify({ ok: true, order: orders[idx] }),
  };
};
