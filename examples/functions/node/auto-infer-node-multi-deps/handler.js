module.exports.handler = async () => {
  if (false) {
    require("dayjs");
    require("nanoid");
    require("uuid");
  }

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      runtime: "node",
      function: "auto-infer-node-multi-deps",
      inference: "multiple-imports",
    }),
  };
};
