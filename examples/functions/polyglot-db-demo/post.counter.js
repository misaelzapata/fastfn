const path = require("path");
const { incrementCounter, json, openDb } = require("./_sqlite");
const { incrementMemoryCounter } = require("./_counter_state");

const COUNTER_KEY = "requests_total";
let localCount = 0;
const bootMs = Date.now();

function storageMode(query) {
  const raw = String((query && query.store) || "sqlite").trim().toLowerCase();
  return raw === "memory" ? "memory" : "sqlite";
}

exports.handler = async (event) => {
  const t0 = Date.now();
  localCount += 1;
  const now = new Date().toISOString();
  const query = (event && event.query) || {};
  const mode = storageMode(query);

  if (mode === "memory") {
    const sharedCount = incrementMemoryCounter();
    return json(200, {
      runtime: "node",
      route: "POST /counter",
      process: {
        pid: process.pid,
        local_count: localCount,
        uptime_ms: Date.now() - bootMs,
        storage: "memory",
      },
      shared: {
        key: COUNTER_KEY,
        count: sharedCount,
        updated_at: now,
        storage: "memory",
      },
      timing: {
        elapsed_ms: Date.now() - t0,
      },
    });
  }

  const { db, dbPath } = openDb(event || {});
  try {
    const shared = incrementCounter(db, COUNTER_KEY, now);
    return json(200, {
      runtime: "node",
      route: "POST /counter",
      process: {
        pid: process.pid,
        local_count: localCount,
        uptime_ms: Date.now() - bootMs,
        storage: "memory",
      },
      shared: {
        key: shared.key,
        count: shared.value,
        updated_at: shared.updated_at,
        storage: "sqlite",
        db_file: path.basename(dbPath),
      },
      timing: {
        elapsed_ms: Date.now() - t0,
      },
    });
  } catch (err) {
    return json(500, {
      error: String((err && err.message) || err),
      route: "POST /counter",
    });
  } finally {
    db.close();
  }
};
