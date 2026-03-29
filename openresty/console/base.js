export function esc(s) {
  return String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
}

function buildJsonRequestOptions(opts = {}) {
  const next = { ...(opts || {}) };
  const method = String(next.method || 'GET').toUpperCase();
  next.method = method;

  const headers = new Headers(next.headers || {});
  if (!headers.has('Accept')) {
    headers.set('Accept', 'application/json');
  }
  if (!['GET', 'HEAD', 'OPTIONS'].includes(method) && !headers.has('x-fn-request') && !headers.has('X-Fn-Request')) {
    headers.set('x-fn-request', '1');
  }
  next.headers = headers;
  return next;
}

export async function getJson(url, opts) {
  const r = await fetch(url, buildJsonRequestOptions(opts));
  const t = await r.text();
  let obj;
  try { obj = JSON.parse(t); } catch { obj = { raw: t }; }
  if (!r.ok) throw new Error(obj.error || `HTTP ${r.status}`);
  return obj;
}
