// @summary IP intel via remote provider (ipapi)
// @methods GET
// @query {"ip":"8.8.8.8","mock":"1"}

const net = require("node:net");

function toJson(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
}

function pickIp(event) {
  const query = (event && event.query) || {};
  const client = (event && event.client) || {};
  const ip = String(query.ip || client.ip || "").trim();
  if (!ip) {
    return { ok: false, error: "missing ip. Use ?ip=8.8.8.8" };
  }
  if (net.isIP(ip) !== 4) {
    return { ok: false, error: "invalid ip (IPv4 expected)", ip };
  }
  return { ok: true, ip };
}

function normalizeBaseURL(baseURL) {
  return String(baseURL || "https://ipapi.co").replace(/\/+$/, "");
}

async function fetchIpapi(ip, baseURL) {
  const endpoint = `${normalizeBaseURL(baseURL)}/${encodeURIComponent(ip)}/json/`;
  const resp = await fetch(endpoint, {
    method: "GET",
    headers: { Accept: "application/json" },
  });
  const text = await resp.text();
  if (!resp.ok) {
    throw new Error(`ipapi status=${resp.status} body=${text.slice(0, 180)}`);
  }
  let parsed = {};
  try {
    parsed = JSON.parse(text || "{}");
  } catch (_) {
    throw new Error("ipapi returned non-json payload");
  }
  return {
    endpoint,
    provider: "ipapi",
    ip: parsed.ip || ip,
    country_code: parsed.country_code || "",
    country_name: parsed.country_name || "",
    region: parsed.region || "",
    city: parsed.city || "",
  };
}

exports.handler = async (event) => {
  const query = (event && event.query) || {};
  const env = (event && event.env) || {};

  const ipPick = pickIp(event || {});
  if (!ipPick.ok) {
    return toJson(400, { ok: false, error: ipPick.error, ip: ipPick.ip || null });
  }
  const ip = ipPick.ip;

  // Deterministic mode for CI/integration checks without external network calls.
  if (String(query.mock || "").toLowerCase() === "1" || String(query.mock || "").toLowerCase() === "true") {
    return toJson(200, {
      ok: true,
      provider: "ipapi-mock",
      ip,
      country_code: "US",
      country_name: "United States",
      city: "Austin",
      region: "Texas",
    });
  }

  const baseURL = query.base_url || env.IPAPI_BASE_URL || process.env.IPAPI_BASE_URL || "https://ipapi.co";

  try {
    const data = await fetchIpapi(ip, baseURL);
    return toJson(200, { ok: true, ...data });
  } catch (err) {
    return toJson(502, {
      ok: false,
      error: "ipapi_lookup_failed",
      message: err && err.message ? err.message : "unexpected ipapi error",
      ip,
      provider: "ipapi",
    });
  }
};
