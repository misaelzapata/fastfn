local function docs_enabled()
  local raw = os.getenv("FN_DOCS_ENABLED")
  if raw == nil or raw == "" then
    return true
  end
  raw = string.lower(raw)
  return not (raw == "0" or raw == "false" or raw == "off" or raw == "no")
end

if not docs_enabled() then
  ngx.status = 404
  ngx.header["Content-Type"] = "application/json"
  ngx.say('{"error":"docs disabled"}')
  return
end

ngx.status = 200
ngx.header["Content-Type"] = "text/html; charset=utf-8"

ngx.say([[
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>fastfn Swagger UI</title>
    <style>
      html, body { margin: 0; padding: 0; font-family: ui-sans-serif, system-ui, sans-serif; }
      .topbar { display: none; }
      #fallback { display:none; padding: 18px; }
      #fallback h1 { margin: 0 0 10px; font-size: 20px; }
      #fallback p { margin: 0 0 10px; color: #475569; }
      #fallback a { color: #0f172a; }
      #swagger-ui { min-height: 100vh; }
    </style>
  </head>
  <body>
    <div id="swagger-ui"></div>
    <div id="fallback">
      <h1>Docs unavailable from CDN</h1>
      <p>No se pudo cargar Swagger UI desde CDN en este navegador/red.</p>
      <p>Usa el schema directo: <a href="/_fn/openapi.json">/_fn/openapi.json</a></p>
      <p>O vuelve al inicio: <a href="/">/</a></p>
    </div>

    <script>
      (function() {
        function showFallback() {
          document.getElementById('swagger-ui').style.display = 'none';
          document.getElementById('fallback').style.display = 'block';
        }

        function initSwagger() {
          if (!window.SwaggerUIBundle) {
            showFallback();
            return;
          }

          window.SwaggerUIBundle({
            url: '/_fn/openapi.json',
            dom_id: '#swagger-ui',
            deepLinking: true,
            presets: [window.SwaggerUIBundle.presets.apis],
          });
        }

        function loadCss(href, done) {
          const l = document.createElement('link');
          l.rel = 'stylesheet';
          l.href = href;
          l.onload = () => done(true);
          l.onerror = () => done(false);
          document.head.appendChild(l);
        }

        function loadScript(src, done) {
          const s = document.createElement('script');
          s.src = src;
          s.onload = () => done(true);
          s.onerror = () => done(false);
          document.body.appendChild(s);
        }

        const cssSources = [
          'https://unpkg.com/swagger-ui-dist@5/swagger-ui.css',
          'https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css'
        ];

        const jsSources = [
          'https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js',
          'https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js'
        ];

        function tryLoad(list, loader, cb, idx) {
          idx = idx || 0;
          if (idx >= list.length) {
            cb(false);
            return;
          }
          loader(list[idx], (ok) => {
            if (ok) cb(true);
            else tryLoad(list, loader, cb, idx + 1);
          });
        }

        tryLoad(cssSources, loadCss, function(cssOk) {
          tryLoad(jsSources, loadScript, function(jsOk) {
            if (!cssOk || !jsOk) {
              showFallback();
              return;
            }
            initSwagger();
          });
        });
      })();
    </script>
  </body>
</html>
]])
