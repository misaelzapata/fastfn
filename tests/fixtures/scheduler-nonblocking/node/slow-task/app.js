const fs = require("node:fs");
const path = require("node:path");

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

exports.handler = async (event) => {
  const ctx = event && event.context ? event.context : {};
  const out = {
    trigger: ctx.trigger || null,
    worker_pool: ctx.worker_pool || null,
  };

  const fastfnDir = path.join(__dirname, ".fastfn");
  const outPath = path.join(fastfnDir, "scheduler-worker-pool.json");
  try {
    fs.mkdirSync(fastfnDir, { recursive: true });
    fs.writeFileSync(outPath, JSON.stringify(out), "utf8");
  } catch (_err) {
    // Best-effort: the scheduler should still succeed even if disk is read-only.
  }

  // Make the scheduled job non-trivial so the non-blocking assertion is meaningful.
  await sleep(650);

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ok: true }),
  };
};

