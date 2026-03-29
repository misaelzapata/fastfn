let value = 0;

exports.handler = async (_event) => {
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ok: true, runtime: "node", value }),
  };
};

