const fs = require("node:fs");
const path = require("node:path");

function json(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(payload),
  };
}

function loadOrders() {
  const stateDir = path.join("/tmp", "fastfn-platform-equivalents");
  const stateFile = path.join(stateDir, "orders.json");
  if (!fs.existsSync(stateFile)) {
    return [];
  }
  try {
    const data = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    return Array.isArray(data) ? data : [];
  } catch {
    return [];
  }
}

exports.handler = async (event = {}) => {
  const query = (event && event.query) || {};
  const statusFilter = String(query.status || "").trim().toLowerCase();
  const orders = loadOrders();
  const filtered = statusFilter
    ? orders.filter((item) => String((item && item.status) || "").toLowerCase() === statusFilter)
    : orders;

  return json(200, {
    ok: true,
    total: filtered.length,
    orders: filtered,
  });
};
