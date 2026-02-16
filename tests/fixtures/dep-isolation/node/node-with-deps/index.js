exports.handler = async (event) => {
  try {
    const _ = require("lodash");
    return {
      status: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ok: true,
        runtime: "node",
        has_lodash: true,
        lodash_version: _.VERSION,
      }),
    };
  } catch (err) {
    return {
      status: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ok: false,
        runtime: "node",
        has_lodash: false,
        error: String(err.message || err),
      }),
    };
  }
};
