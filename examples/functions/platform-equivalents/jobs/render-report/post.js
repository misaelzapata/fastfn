const fs = require("node:fs");
const path = require("node:path");

function json(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(payload),
  };
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

function jobFile(jobId) {
  const jobsDir = path.join("/tmp", "fastfn-platform-equivalents", "jobs");
  fs.mkdirSync(jobsDir, { recursive: true });
  return path.join(jobsDir, `${jobId}.json`);
}

function newJobId() {
  const now = Date.now();
  const rand = Math.random().toString(36).slice(2, 8);
  return `job_${now}_${rand}`;
}

exports.handler = async (event = {}) => {
  let data;
  try {
    data = parseBody(event.body);
  } catch {
    return json(400, { error: "invalid_json", message: "Body must be valid JSON." });
  }

  const reportType = String(data.report_type || "").trim();
  const items = Array.isArray(data.items) ? data.items : [];
  if (!reportType) {
    return json(400, { error: "validation_error", message: "report_type is required." });
  }

  const jobId = newJobId();
  const nowMs = Date.now();
  const spec = {
    id: jobId,
    report_type: reportType,
    items_count: items.length,
    created_at_ms: nowMs,
    payload: data,
  };
  fs.writeFileSync(jobFile(jobId), JSON.stringify(spec, null, 2), "utf8");

  return json(202, {
    accepted: true,
    job_id: jobId,
    poll_url: `/jobs/render-report/${jobId}`,
    recommended_poll_ms: 1200,
  });
};
