const path = require("path");
const { json, openDb, rowToApi } = require("./_sqlite");

exports.handler = async (event) => {
  const id = String(event?.params?.id || "").trim();
  if (!id) {
    return json(400, { error: "id is required" });
  }

  const { db, dbPath } = openDb(event || {});
  try {
    const row = db
      .prepare("SELECT id, name, created_by, updated_by, created_at, updated_at FROM items WHERE id = ?")
      .get(id);
    if (!row) {
      return json(404, { error: "item not found", id });
    }
    db.prepare("DELETE FROM items WHERE id = ?").run(id);
    const count = db.prepare("SELECT COUNT(*) AS c FROM items").get().c;
    return json(200, {
      runtime: "node",
      route: "DELETE /internal/items/:id",
      deleted: rowToApi(row),
      count,
      db_file: path.basename(dbPath),
      db_kind: "sqlite",
    });
  } finally {
    db.close();
  }
};
