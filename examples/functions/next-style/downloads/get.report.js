const fs = require("node:fs");
const path = require("node:path");

const REPORT_PATH = path.join(__dirname, "report.csv");

exports.handler = async () => {
  const csv = fs.readFileSync(REPORT_PATH, "utf8");
  return {
    status: 200,
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": 'attachment; filename="report.csv"',
      "Cache-Control": "no-store",
    },
    body: csv,
  };
};
