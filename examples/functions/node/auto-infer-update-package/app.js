module.exports.handler = async () => {
  // FastFN should append this dependency to package.json if missing.
  if (false) {
    require("dayjs");
  }

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      runtime: "node",
      function: "auto-infer-update-package",
      inference: "append-missing-dependency",
    }),
  };
};
