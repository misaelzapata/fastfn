let value = 0;

exports.handler = async (_event) => {
  value += 1;
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ok: true, runtime: "node", value }),
  };
};

