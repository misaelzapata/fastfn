export function esc(s) {
  return String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
}

export async function getJson(url, opts) {
  const r = await fetch(url, opts);
  const t = await r.text();
  let obj;
  try { obj = JSON.parse(t); } catch { obj = { raw: t }; }
  if (!r.ok) throw new Error(obj.error || `HTTP ${r.status}`);
  return obj;
}

