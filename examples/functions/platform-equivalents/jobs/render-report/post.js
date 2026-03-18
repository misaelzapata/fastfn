// POST /jobs/render-report — Accept a report request and return a job ID
const fs = require("node:fs");

const JOBS_DIR = "/tmp/fastfn-platform-equivalents/jobs";

exports.handler = async (event = {}) => {
  const body =
    typeof event.body === "string" ? JSON.parse(event.body) : event.body || {};

  const reportType = (body.report_type || "").trim();
  if (!reportType) {
    return { status: 400, body: JSON.stringify({ error: "report_type is required" }) };
  }

  // Create a job record on disk (simulates a queue)
  const jobId = `job_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
  const job = {
    id: jobId,
    report_type: reportType,
    items_count: Array.isArray(body.items) ? body.items.length : 0,
    created_at_ms: Date.now(),
  };
  fs.mkdirSync(JOBS_DIR, { recursive: true });
  fs.writeFileSync(`${JOBS_DIR}/${jobId}.json`, JSON.stringify(job, null, 2));

  // Return 202 Accepted — the caller polls GET /jobs/render-report/:id
  return {
    status: 202,
    body: JSON.stringify({
      accepted: true,
      job_id: jobId,
      poll_url: `/jobs/render-report/${jobId}`,
    }),
  };
};
