const fs = require("node:fs");
const path = require("node:path");

const ALLOWED_STATUS = new Set(["pending", "processing", "shipped", "delivered", "cancelled"]);

function json(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(payload),
  };
}

function resolveStateFile() {
  const stateDir = path.join("/tmp", "fastfn-platform-equivalents");
  fs.mkdirSync(stateDir, { recursive: true });
  return path.join(stateDir, "orders.json");
}

function loadOrders(filePath) {
  if (!fs.existsSync(filePath)) {
    return [];
  }
  try {
    const data = JSON.parse(fs.readFileSync(filePath, "utf8"));
    return Array.isArray(data) ? data : [];
  } catch {
    return [];
  }
}

function saveOrders(filePath, orders) {
  fs.writeFileSync(filePath, JSON.stringify(orders, null, 2), "utf8");
}

function parseBody(body) {
  if (body == null || body === "") {
    return {};
  }
  if (typeof body === "object") {
    return body;
  }
  return JSON.parse(String(body));
}

exports.handler = async (event = {}, params = {}) => {
  const idCandidate = (params && params.id)
    || ((event && event.params) ? event.params.id : undefined)
    || (event ? event.id : undefined);
  const id = Number(idCandidate || 0);
  if (!Number.isInteger(id) || id <= 0) {
    return json(400, { error: "validation_error", message: "id must be a positive integer." });
  }

  let update;
  try {
    update = parseBody(event.body);
  } catch {
    return json(400, { error: "invalid_json", message: "Body must be valid JSON." });
  }

  const status = String(update.status || "").trim().toLowerCase();
  if (!ALLOWED_STATUS.has(status)) {
    return json(400, {
      error: "validation_error",
      message: "status must be one of pending/processing/shipped/delivered/cancelled.",
    });
  }

  const tracking = update.tracking_number == null ? null : String(update.tracking_number);
  const stateFile = resolveStateFile();
  const orders = loadOrders(stateFile);
  const idx = orders.findIndex((item) => Number((item && item.id) || 0) === id);
  if (idx < 0) {
    return json(404, { error: "not_found", message: "Order not found." });
  }

  const next = {
    ...orders[idx],
    status,
    tracking_number: tracking,
    updated_at: Math.floor(Date.now() / 1000),
  };
  orders[idx] = next;
  saveOrders(stateFile, orders);

  return json(200, { ok: true, order: next });
};
