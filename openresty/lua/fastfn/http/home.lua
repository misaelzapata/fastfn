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
          <a class="btn" href="/docs">Open Swagger</a>
          <a class="btn" href="/openapi.json">OpenAPI JSON</a>
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
FN_CONSOLE_WRITE_ENABLED=1</pre>
        </article>

        <article class="card">
          <h2>Quick Invoke</h2>
          <p>Ready-to-run demos (JSON, HTML/CSV/PNG, QR, WhatsApp, Gmail, Telegram).</p>
          <pre>curl '/fn/qr?text=HelloQR'
curl '/fn/qr@v2?text=NodeQR'
curl '/fn/whatsapp'
curl '/fn/whatsapp?action=qr' --output /tmp/wa-qr.png
curl '/fn/gmail_send?to=demo@example.com&dry_run=true'
curl '/fn/telegram_send?chat_id=123456&dry_run=true'
curl '/fn/hello?name=World'
curl '/fn/hello@v2?name=World'
curl '/fn/php_profile?name=World'
curl '/fn/rust_profile?name=World'
curl '/fn/risk_score?email=a@b.com'</pre>
        </article>
      </section>

      <p class="muted" style="margin-top:12px;">Tip: if Swagger UI fails to load, open <code>/openapi.json</code> directly.</p>
    </div>

    <script>
      (async () => {
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
