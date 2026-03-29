const fs = require("fs");
const path = require("path");
const { DatabaseSync } = require("node:sqlite");

const DEMO_DIR = "polyglot-db-demo";

function json(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
}

function parseBody(raw) {
  if (!raw) return {};
  if (typeof raw === "object" && !Array.isArray(raw)) return raw;
  if (typeof raw !== "string") return {};
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch (_) {
    return {};
  }
}

function resolveDbPath(event) {
  const root = process.env.FN_FUNCTIONS_ROOT || __dirname;
  const reqPath = String((event && event.path) || "");
  if (reqPath.startsWith(`/${DEMO_DIR}/`)) {
    return path.join(root, DEMO_DIR, ".db.sqlite3");
  }
  return path.join(root, ".db.sqlite3");
}

function ensureSchema(db) {
  // WAL + busy timeout make concurrent writers far less fragile in local stress runs.
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA busy_timeout = 5000;
  `);
  db.exec(`
    CREATE TABLE IF NOT EXISTS items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      created_by TEXT NOT NULL,
      updated_by TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  `);
  db.exec(`
    CREATE TABLE IF NOT EXISTS counters (
      key TEXT PRIMARY KEY,
      value INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    );
  `);
}

function openDb(event) {
  const dbPath = resolveDbPath(event);
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath);
  ensureSchema(db);
  return { db, dbPath };
}

function rowToApi(row) {
  if (!row || typeof row !== "object") return null;
  return {
    id: String(row.id),
    name: row.name,
    created_by: row.created_by,
    updated_by: row.updated_by,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

function readCounter(db, key, nowIso) {
  const now = nowIso || new Date().toISOString();
  db.prepare("INSERT INTO counters (key, value, updated_at) VALUES (?, 0, ?) ON CONFLICT(key) DO NOTHING").run(key, now);
  const row = db.prepare("SELECT key, value, updated_at FROM counters WHERE key = ?").get(key);
  return {
    key,
    value: Number(row && row.value ? row.value : 0),
    updated_at: row && row.updated_at ? row.updated_at : now,
  };
}

function incrementCounter(db, key, nowIso) {
  const now = nowIso || new Date().toISOString();
  db.prepare("INSERT INTO counters (key, value, updated_at) VALUES (?, 0, ?) ON CONFLICT(key) DO NOTHING").run(key, now);
  db.prepare("UPDATE counters SET value = value + 1, updated_at = ? WHERE key = ?").run(now, key);
  return readCounter(db, key, now);
}

module.exports = {
  DEMO_DIR,
  incrementCounter,
  json,
  openDb,
  parseBody,
  readCounter,
  rowToApi,
};
