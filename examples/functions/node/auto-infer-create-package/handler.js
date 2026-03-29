module.exports.handler = async () => {
  // FastFN should infer this dependency and create package.json automatically.
  if (false) {
    require("uuid");
  }

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      runtime: "node",
      function: "auto-infer-create-package",
      inference: "enabled",
    }),
  };
};
