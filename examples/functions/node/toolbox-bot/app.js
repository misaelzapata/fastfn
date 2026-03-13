// @summary Toolbox bot (safe tool runner for demos)
// @methods GET,POST
// @query {"text":"Use [[http:https://api.ipify.org?format=json]] and [[fn:request-inspector?key=demo|GET]]","dry_run":"true"}
// @body {"text":"my ip and weather in Buenos Aires","dry_run":true,"auto_tools":true}
//
// This function is intentionally safe by default:
// - dry_run defaults to true (no outbound calls)
// - when dry_run=false, it still enforces strict allowlists for:
//   - fn tools: only configured function names
//   - http tools: only configured hostnames

const {
  asBool,
  json,
  parseJson,
  hostAllowed,
  isLocalHostname,
  canonicalSegment,
  fetchWithTimeout,
  toolConfig,
  parseToolDirectives,
  extractWeatherLocation,
  inferAutoTools,
  executeTool
} = require("./_internal");

exports.handler = async (event) => {
  const env = event.env || {};
  const query = event.query || {};
  const bodyObj = parseJson(event.body) || {};

  const text = String(query.text ?? bodyObj.text ?? "").trim();
  const dryRun = asBool(query.dry_run ?? bodyObj.dry_run, true);
  const cfg = toolConfig(env, query, bodyObj);

  if (!cfg.enabled) {
    return json(200, { ok: true, tools: { enabled: false }, note: "tools disabled (set TOOLBOX_TOOLS_ENABLED=true)" });
  }

  if (!text) {
    return json(200, {
      ok: true,
      dry_run: dryRun,
      note: "Provide text=... with [[http:...]] and/or [[fn:...]] directives (or set auto_tools=true).",
      examples: [
        "/toolbox-bot?text=Use%20[[http:https://api.ipify.org?format=json]]%20and%20[[fn:request-inspector?key=demo|GET]]&dry_run=true",
        "/toolbox-bot?text=what%20is%20my%20ip%20and%20weather%20in%20Buenos%20Aires%3F&auto_tools=true&dry_run=true",
      ],
      allow: { fn: cfg.allowedFns, http_hosts: cfg.allowedHosts },
    });
  }

  let plan = parseToolDirectives(text);
  if (plan.length === 0 && cfg.autoTools) {
    plan = inferAutoTools(text, cfg);
  }

  if (plan.length === 0) {
    return json(200, {
      ok: true,
      dry_run: dryRun,
      text,
      plan: [],
      note: "No tool directives found. Add [[http:...]] / [[fn:...]] or set auto_tools=true.",
    });
  }

  if (dryRun) {
    return json(200, {
      ok: true,
      dry_run: true,
      text,
      plan,
      note: "Set dry_run=false to execute tools.",
      allow: { fn: cfg.allowedFns, http_hosts: cfg.allowedHosts },
    });
  }

  const results = [];
  for (const tool of plan) {
    try {
      results.push(await executeTool(tool, cfg));
    } catch (err) {
      results.push({
        ok: false,
        type: tool && tool.type ? tool.type : "unknown",
        target: tool && (tool.name || tool.url) ? (tool.name || tool.url) : null,
        error: String(err && err.message ? err.message : err),
      });
    }
  }

  return json(200, {
    ok: true,
    dry_run: false,
    text,
    plan,
    results,
    summary: {
      ok: results.every((r) => r && r.ok === true),
      total: results.length,
      failed: results.filter((r) => !(r && r.ok === true)).length,
    },
  });
};
