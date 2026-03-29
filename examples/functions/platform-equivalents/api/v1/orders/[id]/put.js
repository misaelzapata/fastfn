// PUT /api/v1/orders/:id — Update an order's status
const fs = require("node:fs");
const path = require("node:path");

const STATE_DIR = path.join(__dirname, "..", ".state");
const STATE_FILE = path.join(STATE_DIR, "orders.json");

function loadOrders() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
  } catch {
    return [];
  }
}

exports.handler = async (event = {}, params = {}) => {
  const pathFallback = String(event.path || "")
    .split("/")
    .filter(Boolean)
    .pop();
  const routeId =
    (params && typeof params === "object" ? params.id : undefined) ??
    (event.params && typeof event.params === "object" ? event.params.id : undefined) ??
    pathFallback ??
    0;
  const id = Number(routeId || 0);
  const body =
    typeof event.body === "string" ? JSON.parse(event.body) : event.body || {};

  const status = (body.status || "").toLowerCase();
  const allowed = ["pending", "processing", "shipped", "delivered", "cancelled"];
  if (!allowed.includes(status)) {
    return {
      status: 400,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error: `status must be one of: ${allowed.join(", ")}` }),
    };
  }

  // Find and update the order
  const orders = loadOrders();
  const idx = orders.findIndex((o) => o.id === id);
  if (idx < 0) {
    return {
      status: 404,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error: "Order not found" }),
    };
  }

  orders[idx] = {
    ...orders[idx],
    status,
    tracking_number: body.tracking_number || null,
    updated_at: Math.floor(Date.now() / 1000),
  };
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(orders, null, 2));

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ok: true, order: orders[idx] }),
  };
};
