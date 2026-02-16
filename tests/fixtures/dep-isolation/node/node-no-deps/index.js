exports.handler = async (event) => {
  try {
    const _ = require("lodash"); // should NOT be available — no package.json here
    return {
      status: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ok: true,
        runtime: "node",
        has_lodash: true,
        lodash_version: _.VERSION,
        isolation_broken: true,
      }),
    };
  } catch (err) {
    return {
      status: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ok: true,
        runtime: "node",
        has_lodash: false,
        isolation_ok: true,
      }),
    };
  }
};
