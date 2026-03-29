const path = require("path");
const { json, openDb, parseBody, rowToApi } = require("./_sqlite");

exports.handler = async (event) => {
  const id = String(event?.params?.id || "").trim();
  if (!id) {
    return json(400, { error: "id is required" });
  }

  const input = parseBody(event?.body);
  const name = String(input.name || "").trim();
  if (!name) {
    return json(400, { error: "name is required" });
  }

  const { db, dbPath } = openDb(event || {});
  try {
    const now = new Date().toISOString();
    const update = db.prepare("UPDATE items SET name = ?, updated_by = ?, updated_at = ? WHERE id = ?");
    const result = update.run(name, "php", now, id);
    if (!result.changes) {
      return json(404, { error: "item not found", id });
    }
    const row = db
      .prepare("SELECT id, name, created_by, updated_by, created_at, updated_at FROM items WHERE id = ?")
      .get(id);
    const count = db.prepare("SELECT COUNT(*) AS c FROM items").get().c;
    return json(200, {
      runtime: "node",
      route: "PUT /internal/items/:id",
      item: rowToApi(row),
      count,
      db_file: path.basename(dbPath),
      db_kind: "sqlite",
    });
  } finally {
    db.close();
  }
};
