const INTERNAL_BASE = process.env.FASTFN_INTERNAL_BASE || "http://127.0.0.1:8080";

async function getJson(path) {
  const res = await fetch(`${INTERNAL_BASE}${path}`, {
    method: "GET",
    headers: {
      "x-fastfn-internal-call": "1",
    },
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`internal call failed ${path}: status=${res.status} body=${text}`);
  }
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new Error(`invalid json from ${path}: ${String(err && err.message ? err.message : err)}`);
  }
}

exports.handler = async (event) => {
  const query = event.query || {};
  const name = query.name || "friend";
  const encoded = encodeURIComponent(name);

  try {
    const [step1, step2, step3, step4] = await Promise.all([
      getJson("/polyglot-tutorial/step-1"),
      getJson(`/polyglot-tutorial/step-2?name=${encoded}`),
      getJson(`/polyglot-tutorial/step-3?name=${encoded}`),
      getJson("/polyglot-tutorial/step-4"),
    ]);

    return {
      status: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        step: 5,
        runtime: "node",
        name,
        flow: [step1, step2, step3, step4],
        summary: `Polyglot pipeline completed for ${name}`,
      }),
    };
  } catch (err) {
    return {
      status: 502,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        error: String(err && err.message ? err.message : err),
        runtime: "node",
        step: 5,
      }),
    };
  }
};
