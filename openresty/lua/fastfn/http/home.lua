local home = require("fastfn.core.home")

local action = home.resolve_home_action(os.getenv("FN_FUNCTIONS_ROOT"))
for _, warning in ipairs(action.warnings or {}) do
  ngx.log(ngx.WARN, tostring(warning))
end

if action.mode == "function" then
  return ngx.exec(action.path, action.args)
end
if action.mode == "redirect" then
  return ngx.redirect(action.location, ngx.HTTP_MOVED_TEMPORARILY)
end

ngx.status = 200
ngx.header["Content-Type"] = "text/html; charset=utf-8"

ngx.say([[
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>fastfn</title>
    <style>
      :root {
        --bg: #f7fafc;
        --card: #ffffff;
        --text: #0f172a;
        --muted: #475569;
        --ok: #166534;
        --warn: #92400e;
        --border: #e2e8f0;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif;
        color: var(--text);
        background: radial-gradient(circle at 0% 0%, #dbeafe, var(--bg) 45%);
      }
      .wrap { max-width: 1080px; margin: 0 auto; padding: 28px 18px 36px; }
      .hero {
        background: linear-gradient(120deg, #0f172a, #1e293b);
        color: #f8fafc;
        border-radius: 14px;
        padding: 20px;
        margin-bottom: 16px;
      }
      .hero h1 { margin: 0 0 6px; font-size: 24px; }
      .hero p { margin: 0; color: #cbd5e1; }
      .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 12px; }
      .card {
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: 12px;
        padding: 14px;
      }
      h2 { margin: 0 0 8px; font-size: 15px; }
      p { margin: 0 0 10px; color: var(--muted); font-size: 14px; }
      a.btn {
        display: inline-block;
        text-decoration: none;
        border: 1px solid #0f172a;
        border-radius: 8px;
        padding: 7px 10px;
        color: #0f172a;
        font-weight: 600;
        font-size: 13px;
      }
      pre {
        margin: 10px 0 0;
        background: #0b1020;
        color: #e2e8f0;
        border-radius: 8px;
        padding: 9px;
        overflow: auto;
        font-size: 12px;
      }
      .status { margin-top: 12px; }
      .ok { color: var(--ok); }
      .warn { color: var(--warn); }
      .muted { color: var(--muted); font-size: 12px; }
    </style>
  </head>
  <body>
    <div class="wrap">
      <section class="hero">
        <h1>fastfn</h1>
        <p>OpenResty host with filesystem-discovered functions and runtime daemons (Python/Node/PHP/Rust).</p>
      </section>

      <section class="grid">
        <article class="card">
          <h2>API Docs</h2>
          <p>Interactive docs and OpenAPI schema.</p>
          <a class="btn" href="/_fn/docs">Open Swagger</a>
          <a class="btn" href="/_fn/openapi.json">OpenAPI JSON</a>
        </article>

        <article class="card">
          <h2>Health</h2>
          <p>Runtime health and route discovery status.</p>
          <a class="btn" href="/_fn/health">/_fn/health</a>
          <div id="health" class="status muted">Loading...</div>
        </article>

        <article class="card">
          <h2>Console</h2>
          <p>UI is disabled by default. Enable with Docker env vars.</p>
          <a class="btn" href="/console">Open Console</a>
          <pre>FN_UI_ENABLED=1
FN_CONSOLE_API_ENABLED=1
FN_CONSOLE_WRITE_ENABLED=0</pre>
        </article>

        <article class="card">
          <h2>Home Routing</h2>
          <p>Override <code>/</code> with redirect or internal function execution.</p>
          <pre>FN_HOME_FUNCTION=/showcase
# or
FN_HOME_REDIRECT=/_fn/docs

# Root fn.config.json (if present under FN_FUNCTIONS_ROOT)
{
  "home": { "route": "/showcase" }
}</pre>
        </article>

        <article class="card">
          <h2>Quick Invoke</h2>
          <p id="quick-invoke-summary">Loading live routes from OpenAPI...</p>
          <pre id="quick-invoke"># Loading current routes from /_fn/openapi.json...</pre>
        </article>
      </section>

      <p class="muted" style="margin-top:12px;">Tip: if Swagger UI fails to load, open <code>/_fn/openapi.json</code> directly.</p>
    </div>

    <script>
      (async () => {
        const METHOD_ORDER = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];
        const METHOD_INDEX = METHOD_ORDER.reduce((acc, method, idx) => {
          acc[method] = idx;
          return acc;
        }, {});

        const toSamplePath = (path) => String(path || '').replace(/\{([A-Za-z0-9_]+)\}/g, (_, key) => {
          const lower = String(key || '').toLowerCase();
          if (lower.includes('id')) return '1';
          if (lower.includes('slug')) return 'sample-slug';
          if (lower.includes('name')) return 'sample';
          if (lower.includes('date')) return '2026-01-01';
          return 'sample';
        });

        const firstExampleValue = (node) => {
          if (!node || typeof node !== 'object') return undefined;
          if (node.example !== undefined) return node.example;
          if (node.default !== undefined) return node.default;
          const examples = node.examples;
          if (examples && typeof examples === 'object') {
            const firstKey = Object.keys(examples)[0];
            const first = firstKey ? examples[firstKey] : undefined;
            if (first && typeof first === 'object' && first.value !== undefined) return first.value;
          }
          return undefined;
        };

        const sampleQueryValue = (param) => {
          const candidate = firstExampleValue(param) ?? firstExampleValue(param && param.schema);
          if (candidate !== undefined && candidate !== null && candidate !== '') return String(candidate);
          const name = String((param && param.name) || '').toLowerCase();
          if (name.includes('id')) return '1';
          if (name.includes('page')) return '1';
          if (name.includes('limit')) return '10';
          if (name.includes('slug')) return 'sample';
          return 'demo';
        };

        const buildQueryString = (op) => {
          const params = Array.isArray(op && op.parameters) ? op.parameters : [];
          const out = [];
          for (const p of params) {
            if (!p || p.in !== 'query') continue;
            const key = String(p.name || '').trim();
            if (!key) continue;
            out.push([key, sampleQueryValue(p)]);
            if (out.length >= 4) break;
          }
          if (out.length === 0) return '';
          const qs = new URLSearchParams(out);
          return qs.toString();
        };

        const sampleBody = (op) => {
          const content = op && op.requestBody && op.requestBody.content;
          if (!content || typeof content !== 'object') return null;
          const jsonContent = content['application/json'];
          if (!jsonContent || typeof jsonContent !== 'object') return null;
          const example = firstExampleValue(jsonContent) ?? firstExampleValue(jsonContent.schema);
          if (example !== undefined) {
            try {
              return JSON.stringify(example);
            } catch (_) {
              return '{"ok":true}';
            }
          }
          return '{"ok":true}';
        };

        const buildCurl = (path, method, op) => {
          let route = toSamplePath(path);
          const query = buildQueryString(op);
          if (query) route += `?${query}`;
          const body = sampleBody(op);
          if (method === 'GET') {
            return `curl '${route}'`;
          }
          if (!body) {
            return `curl -X ${method} '${route}'`;
          }
          return `curl -X ${method} '${route}' -H 'content-type: application/json' --data '${body}'`;
        };

        const extractOpenApiRoutes = (spec) => {
          const paths = (spec && spec.paths && typeof spec.paths === 'object') ? spec.paths : {};
          const rows = [];
          for (const [path, ops] of Object.entries(paths)) {
            if (!path.startsWith('/') || path.startsWith('/_fn/')) continue;
            if (!ops || typeof ops !== 'object') continue;
            for (const method of METHOD_ORDER) {
              const op = ops[method.toLowerCase()];
              if (!op || typeof op !== 'object') continue;
              rows.push({ path, method, op });
            }
          }
          rows.sort((a, b) => {
            if (a.path !== b.path) return a.path < b.path ? -1 : 1;
            return (METHOD_INDEX[a.method] || 99) - (METHOD_INDEX[b.method] || 99);
          });
          return rows;
        };

        const renderQuickInvoke = (routes) => {
          const summaryEl = document.getElementById('quick-invoke-summary');
          if (summaryEl) {
            summaryEl.textContent = `Showing ${routes.length} live function routes from OpenAPI.`;
          }
          const pre = document.getElementById('quick-invoke');
          if (!pre) return;
          if (routes.length === 0) {
            pre.textContent = '# No public function routes discovered yet.\n# Create a function and refresh this page.';
            return;
          }
          const lines = ['# Live quick invoke commands from /_fn/openapi.json'];
          for (const row of routes) {
            lines.push(buildCurl(row.path, row.method, row.op));
          }
          pre.textContent = lines.join('\n');
        };

        const loadQuickInvoke = async () => {
          try {
            const openapiRes = await fetch('/_fn/openapi.json');
            if (!openapiRes.ok) throw new Error('openapi not available');
            const openapi = await openapiRes.json();
            const discovered = extractOpenApiRoutes(openapi);
            renderQuickInvoke(discovered);
          } catch (_) {
            const summaryEl = document.getElementById('quick-invoke-summary');
            if (summaryEl) {
              summaryEl.textContent = 'OpenAPI is not reachable right now; showing no cached demo list.';
            }
            const pre = document.getElementById('quick-invoke');
            if (pre) {
              pre.textContent = "# Unable to load /_fn/openapi.json\n# Check /_fn/health and refresh.";
            }
          }
        };

        await loadQuickInvoke();
        setInterval(loadQuickInvoke, 5000);

        try {
          const r = await fetch('/_fn/health');
          const t = await r.text();
          const data = JSON.parse(t);
          const runtimes = data.runtimes || {};
          const lines = Object.keys(runtimes).sort().map((k) => {
            const up = runtimes[k] && runtimes[k].health && runtimes[k].health.up;
            return `${k}: ${up ? 'UP' : 'DOWN'}`;
          });
          const el = document.getElementById('health');
          el.textContent = lines.join(' | ') || 'No runtimes';
          el.className = 'status ' + (lines.some((x) => x.includes('DOWN')) ? 'warn' : 'ok');
        } catch (_) {
          const el = document.getElementById('health');
          el.textContent = 'Unavailable';
          el.className = 'status warn';
        }
      })();
    </script>
  </body>
</html>
]])
