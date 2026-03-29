const fs = require("node:fs");
const path = require("node:path");

const IMAGE_PATH = path.join(__dirname, "badge.svg");

exports.handler = async () => {
  const svg = fs.readFileSync(IMAGE_PATH, "utf8");
  return {
    status: 200,
    headers: {
      "Content-Type": "image/svg+xml; charset=utf-8",
      "Content-Disposition": 'attachment; filename="badge.svg"',
      "Cache-Control": "no-store",
    },
    body: svg,
  };
};
