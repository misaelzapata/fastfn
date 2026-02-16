const path = require("path");
const { json, openDb, parseBody, rowToApi } = require("./_sqlite");

exports.handler = async (event) => {
  const input = parseBody(event && event.body);
  const name = String(input.name || "").trim();
  if (!name) {
    return json(400, { error: "name is required" });
  }

  const now = new Date().toISOString();
  const { db, dbPath } = openDb(event || {});
  try {
    const insert = db.prepare(
      "INSERT INTO items (name, created_by, updated_by, created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
    );
    const result = insert.run(name, "node", "node", now, now);
    const id = Number(result.lastInsertRowid);
    const row = db
      .prepare("SELECT id, name, created_by, updated_by, created_at, updated_at FROM items WHERE id = ?")
      .get(id);
    const count = db.prepare("SELECT COUNT(*) AS c FROM items").get().c;
    return json(201, {
      runtime: "node",
      route: "POST /items",
      item: rowToApi(row),
      count,
      db_file: path.basename(dbPath),
      db_kind: "sqlite",
    });
  } finally {
    db.close();
  }
};
