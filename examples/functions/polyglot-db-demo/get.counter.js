const path = require("path");
const { incrementCounter, json, openDb, readCounter } = require("./_sqlite");
const { incrementMemoryCounter, readMemoryCounter } = require("./_counter_state");

const COUNTER_KEY = "requests_total";
let localReads = 0;
const bootMs = Date.now();

function truthy(value) {
  const v = String(value || "").trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

function storageMode(query) {
  const raw = String((query && query.store) || "sqlite").trim().toLowerCase();
  return raw === "memory" ? "memory" : "sqlite";
}

exports.handler = async (event) => {
  const t0 = Date.now();
  localReads += 1;
  const now = new Date().toISOString();
  const query = (event && event.query) || {};
  const mode = storageMode(query);
  const inc = truthy(query.inc);

  if (mode === "memory") {
    const count = inc ? incrementMemoryCounter() : readMemoryCounter();
    return json(200, {
      runtime: "node",
      route: "GET /counter",
      process: {
        pid: process.pid,
        local_reads: localReads,
        uptime_ms: Date.now() - bootMs,
        storage: "memory",
      },
      shared: {
        key: COUNTER_KEY,
        count,
        updated_at: now,
        storage: "memory",
      },
      query: {
        inc,
      },
      timing: {
        elapsed_ms: Date.now() - t0,
      },
    });
  }

  const { db, dbPath } = openDb(event || {});
  try {
    const shared = inc ? incrementCounter(db, COUNTER_KEY, now) : readCounter(db, COUNTER_KEY, now);
    return json(200, {
      runtime: "node",
      route: "GET /counter",
      process: {
        pid: process.pid,
        local_reads: localReads,
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
      query: {
        inc,
      },
      timing: {
        elapsed_ms: Date.now() - t0,
      },
    });
  } catch (err) {
    return json(500, {
      error: String((err && err.message) || err),
      route: "GET /counter",
    });
  } finally {
    db.close();
  }
};
