# Catalogo de funciones de ejemplo


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
Este documento describe las **funciones de ejemplo** incluidas en el repo, con requests y responses concretos.

Diferencia importante:

- Las rutas publicas de ejemplo viven en paths normales como `/hello` o `/telegram-ai-reply`.
- Los endpoints de control-plane viven bajo `/_fn/*` (health, OpenAPI, config, logs).

## Ejecutar los ejemplos

Recomendado (rutas estilo Next.js + showcase):

```bash
bin/fastfn dev examples/functions/next-style
```

Luego prueba:

- `GET /showcase`
- `GET /openapi.json`
- `GET /docs`

Catalogo completo (todo bajo `examples/functions/`):

```bash
bin/fastfn dev examples/functions
```

Layout de codigo fuente:

- Python: `examples/functions/python/<name>/`
- Node: `examples/functions/node/<name>/`
- PHP: `examples/functions/php/<name>/`
- Rust: `examples/functions/rust/<name>/`
- App estilo Next.js: `examples/functions/next-style/` (file routes)

## Python runtime

### `cron-tick` (demo scheduler)

- Ruta: `/cron-tick`
- Metodos: `GET`
- Objetivo: contador simple que se incrementa via schedule

Leer el contador:

```bash
curl -sS 'http://127.0.0.1:8080/cron-tick?action=read'
```

Habilitar schedule (cada 1s) via API de consola:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=cron-tick' \
  -X PUT -H 'Content-Type: application/json' \
  --data '{"schedule":{"enabled":true,"every_seconds":1,"method":"GET","query":{"action":"inc"},"headers":{},"body":"","context":{}}}'
curl -sS -X POST 'http://127.0.0.1:8080/_fn/reload'
```

Ver estado del scheduler:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/schedules'
```

### `utc-time` (demo cron + timezone)

- Ruta: `/utc-time`
- Metodos: `GET`
- Objetivo: mostrar timestamps UTC/local + contexto del trigger del scheduler
- Schedule: diario a las `09:00` en `UTC` (cron)

Probar:

```bash
curl -sS 'http://127.0.0.1:8080/utc-time'
```

### `offset-time` (demo cron + timezone)

- Ruta: `/offset-time`
- Metodos: `GET`
- Objetivo: igual que `utc-time`, pero con timezone de offset fijo
- Schedule: diario a las `09:00` en `-05:00` (cron)

Probar:

```bash
curl -sS 'http://127.0.0.1:8080/offset-time'
```

Tip: comparar los `next` via `/_fn/schedules`, o desde el devtools del browser:

```js
fetch('/_fn/schedules').then((r) => r.json()).then(console.log)
```

### `tools-loop` (demo tools loop, inspired by agent loops)

- Ruta: `/tools-loop`
- Metodos: `GET`, `POST`
- Objetivo: planner/ejecutor minimo estilo "agent loop" para probar tools (sin keys).
- Comportamiento por defecto: `dry_run=true`

Dry run (solo plan):

```bash
curl -sS 'http://127.0.0.1:8080/tools-loop?text=quiero%20mi%20ip%20y%20clima&dry_run=true'
```

Ejecutar tools:

```bash
curl -sS 'http://127.0.0.1:8080/tools-loop?tool=ip_lookup,weather&city=Buenos%20Aires&dry_run=false'
```

Ejecutar tools (mock offline):

```bash
curl -sS 'http://127.0.0.1:8080/tools-loop?tool=ip_lookup,weather&city=Buenos%20Aires&dry_run=false&mock=true'
```

### `telegram-ai-reply-py` (bot Telegram con IA, Python)

- Ruta: `/telegram-ai-reply-py`
- Metodos: `GET`, `POST`
- Objetivo: webhook/query Telegram -> OpenAI -> reply a Telegram (Python), con tools + memoria + loop
- Comportamiento por defecto: `dry_run=true`
- Env (secretos): `TELEGRAM_BOT_TOKEN`, `OPENAI_API_KEY`

Dry run (query-mode):

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply-py?mode=reply&chat_id=123&text=Hola&dry_run=true'
```

Envio real (query-mode):

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply-py?mode=reply&chat_id=123&text=Hola&dry_run=false'
```

Tools (directivas manuales dentro del texto):

```bash
curl -g -sS \
"http://127.0.0.1:8080/telegram-ai-reply-py?mode=reply&chat_id=123&dry_run=false&tools=true&tool_allow_fn=tools-loop,request-inspector&text=Usa%20[[http:https://api.ipify.org?format=json]]%20y%20[[fn:tools-loop?text=mi%20ip%20y%20clima&dry_run=true|GET]]"
```

Auto-tools (desde intencion):

```bash
curl -sS \
"http://127.0.0.1:8080/telegram-ai-reply-py?mode=reply&chat_id=123&dry_run=false&tools=true&auto_tools=true&text=Como%20esta%20el%20clima%20hoy%20y%20cual%20es%20mi%20IP%3F"
```

Modo loop (dry-run):

```bash
curl -sS \
"http://127.0.0.1:8080/telegram-ai-reply-py?mode=loop&dry_run=true&wait_secs=20"
```

Archivos de memoria/offset (se crean en runtime):

- `<FN_FUNCTIONS_ROOT>/telegram-ai-reply-py/.memory.json`
- `<FN_FUNCTIONS_ROOT>/telegram-ai-reply-py/.loop_state.json`

### `hello`

- Ruta: `/hello`
- Metodos: `GET`
- Query: `name` opcional

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/hello?name=Mundo'
```

Response tipica:

```json
{"hello":"saludos Mundo"}
```

### `risk-score`

- Ruta: `/risk-score`
- Metodos: `GET`, `POST`
- Inputs:
  - `query.email`
  - header `x-user-email` (fallback)

Ejemplo GET:

```bash
curl -sS 'http://127.0.0.1:8080/risk-score?email=user@example.com'
```

Ejemplo POST:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/risk-score' \
  -H 'x-user-email: user@example.com' \
  -H 'Content-Type: application/json' \
  -d '{}'
```

Response tipica:

```json
{"runtime":"python","function":"risk-score","score":60,"risk":"high","signals":{"email":true,"ip":"172.19.0.1"}}
```

### `slow`

- Ruta: `/slow`
- Metodos: `GET`
- Query: `sleep_ms`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/slow?sleep_ms=100'
```

### `html-demo`

- Ruta: `/html-demo`
- Metodos: `GET`
- Content-Type: `text/html; charset=utf-8`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/html-demo?name=Web'
```

### `csv-demo`

- Ruta: `/csv-demo`
- Metodos: `GET`
- Content-Type: `text/csv; charset=utf-8`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/csv-demo?name=Alice'
```

### `png-demo`

- Ruta: `/png-demo`
- Metodos: `GET`
- Content-Type: `image/png`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/png-demo' --output out.png
```

### `lambda-echo`

- Ruta: `/lambda-echo`
- Metodos: `GET`

### `custom-echo`

- Ruta: `/custom-echo`
- Metodos: `GET`
- Query: `v`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/custom-echo?v=demo'
```

### `requirements-demo`

- Ruta: `/requirements-demo`
- Metodos: `GET`
- Dependencias:
  - `requirements.txt`
  - comentario inline `#@requirements`

### `qr`

- Ruta: `/qr`
- Metodos: `GET`
- Query: `text` o `url`
- Content-Type: `image/svg+xml`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/qr?text=PythonQR'
```

### `gmail-send`

- Ruta: `/gmail-send`
- Metodos: `GET`, `POST`
- Objetivo: helper Gmail SMTP para demos/integraciones
- Comportamiento por defecto: `dry_run=true` (pruebas locales sin credenciales reales)

Ejemplo GET:

```bash
curl -sS 'http://127.0.0.1:8080/gmail-send?to=demo@example.com&subject=Hi&text=Hola&dry_run=true'
```

Ejemplo POST:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/gmail-send' \
  -H 'Content-Type: application/json' \
  -d '{"to":"demo@example.com","subject":"Hi","text":"Hola","dry_run":true}'
```

### `sendgrid-send`

- Ruta: `/sendgrid-send`
- Metodos: `GET`, `POST`
- Objetivo: helper SendGrid (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `SENDGRID_API_KEY` (secreto), `SENDGRID_FROM`

Ejemplo GET (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/sendgrid-send?to=demo@example.com&subject=Hi&text=Hola&dry_run=true'
```

### `sheets-webapp-append`

- Ruta: `/sheets-webapp-append`
- Metodos: `GET`
- Objetivo: append de fila via Google Apps Script Web App (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `SHEETS_WEBAPP_URL` (secreto)

Ejemplo (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/sheets-webapp-append?sheet=Sheet1&values=a,b,c&dry_run=true'
```

### `nombre`

- Ruta: `/nombre`
- Metodos: `GET` (politica default)

### `stripe-webhook-verify`

- Ruta: `/stripe-webhook-verify`
- Metodos: `POST`
- Objetivo: verificar firma de webhooks Stripe (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `STRIPE_WEBHOOK_SECRET` (secreto)

### `github-webhook-verify`

- Ruta: `/github-webhook-verify`
- Metodos: `POST`
- Objetivo: verificar firma de webhooks GitHub (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `GITHUB_WEBHOOK_SECRET` (secreto)

## Node runtime

### `hello@v2`

- Ruta: `/hello@v2`
- Metodos: `GET`
- Query: `name`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/hello@v2?name=NodeWay'
```

Response tipica:

```json
{"hello":"v2-NodeWay"}
```

### `node-echo`

- Ruta: `/node-echo`
- Metodos: `GET`, `POST` (editable en `fn.config.json`)
- Query: `name`

Ejemplo GET:

```bash
curl -sS 'http://127.0.0.1:8080/node-echo?name=Node'
```

Ejemplo POST:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/node-echo?name=NodePost' \
  -H 'Content-Type: application/json' \
  -d '{}'
```

### `echo`

- Ruta: `/echo`
- Metodos: `GET`
- Query: `key`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/echo?key=test'
```

Response tipica:

```json
{"key":"test","query":{"key":"test"},"context":{"user":null}}
```

### `qr@v2`

- Ruta: `/qr@v2`
- Metodos: `GET`
- Query: `text` o `url`, opcional `size`
- Content-Type: `image/png`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/qr@v2?text=NodeQR' --output qr-node.png
```

### `telegram-send`

- Ruta: `/telegram-send`
- Metodos: `GET`, `POST`
- Objetivo: helper Telegram Bot API para demos/integraciones
- Comportamiento por defecto: `dry_run=true` (pruebas locales sin credenciales reales)

Ejemplo GET:

```bash
curl -sS 'http://127.0.0.1:8080/telegram-send?chat_id=123456&text=Hola&dry_run=true'
```

Ejemplo POST:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/telegram-send' \
  -H 'Content-Type: application/json' \
  -d '{"chat_id":"123456","text":"Hola","dry_run":true}'
```

### `telegram-ai-reply`

- Ruta: `/telegram-ai-reply`
- Metodos: `GET`, `POST`
- Objetivo: webhook Telegram -> OpenAI -> reply a Telegram
- Comportamiento por defecto: `dry_run=true` (seguro, no envia mensajes)
- Env (secretos): `TELEGRAM_BOT_TOKEN`, `OPENAI_API_KEY`

Ejemplo (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply?dry_run=true' \
  -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message":{"chat":{"id":123},"text":"Hola"}}'
```

Para enviar de verdad:

- set `dry_run=false`
- setear `TELEGRAM_BOT_TOKEN` y `OPENAI_API_KEY` en `fn.env.json`

Tools (opcional):

- `TELEGRAM_TOOLS_ENABLED=true`
- `TELEGRAM_AUTO_TOOLS=true` (seleccion automatica de tools segun intencion)
- `TELEGRAM_TOOL_ALLOW_FN=request-inspector,telegram-ai-digest`
- `TELEGRAM_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `TELEGRAM_TOOL_TIMEOUT_MS=5000`

Directivas manuales dentro del mensaje del usuario:

- `[[fn:request-inspector?key=test|GET]]`
- `[[http:https://api.ipify.org?format=json]]`

Memoria:

- Archivo de memoria por chat: `<FN_FUNCTIONS_ROOT>/telegram-ai-reply/.memory.json`
- Archivo de offset del loop: `<FN_FUNCTIONS_ROOT>/telegram-ai-reply/.loop_state.json`
- El prompt de sistema evita respuestas falsas del tipo "no recuerdo" cuando existe historial.

### `whatsapp`

- Ruta: `/whatsapp`
- Metodos: `GET`, `POST`, `DELETE`
- Objetivo: gestor de sesion real de WhatsApp (QR, conexion, envio, inbox/outbox, chat AI)
- Actions:
  - `GET /whatsapp?action=qr`
  - `GET /whatsapp?action=status`
  - `POST /whatsapp?action=send`
  - `POST /whatsapp?action=chat`
  - `GET /whatsapp?action=inbox`
  - `DELETE /whatsapp?action=reset-session`

Tools para WhatsApp (`action=chat`):

- `WHATSAPP_TOOLS_ENABLED=true`
- `WHATSAPP_AUTO_TOOLS=true`
- `WHATSAPP_TOOL_ALLOW_FN=request-inspector,telegram-ai-digest`
- `WHATSAPP_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `WHATSAPP_TOOL_TIMEOUT_MS=5000`

### `toolbox-bot` (runner seguro de tools)

- Ruta: `/toolbox-bot`
- Métodos: `GET`, `POST`
- Objetivo: ejecutar directivas de tools (`[[http:...]]`, `[[fn:...]]`) y devolver plan + resultados como JSON
- Comportamiento por defecto: `dry_run=true`
- Código: `examples/functions/node/toolbox-bot/app.js`
- Doc: [Herramientas](../como-hacer/herramientas.md)

Solo plan (sin llamadas externas):

```bash
curl -g -sS \
"http://127.0.0.1:8080/toolbox-bot?dry_run=true&text=Usa%20[[http:https://api.ipify.org?format=json]]%20y%20[[fn:request-inspector?key=demo|GET]]"
```

Ejecutar (solo allowlisted):

```bash
curl -g -sS \
"http://127.0.0.1:8080/toolbox-bot?dry_run=false&text=Usa%20[[http:https://api.ipify.org?format=json]]%20y%20[[fn:request-inspector?key=demo|GET]]"
```

### `ai-tool-agent` (agent con OpenAI tool-calling)

- Ruta: `/ai-tool-agent`
- Métodos: `GET`, `POST`
- Objetivo: OpenAI elige tools (`http_get`, `fn_get`) y la función las ejecuta con allowlists
- Comportamiento por defecto: `dry_run=true`
- Código: `examples/functions/node/ai-tool-agent/app.js`
- Doc: [Herramientas](../como-hacer/herramientas.md#61-openai-tool-calling-el-modelo-elige-tools)

Dry run:

```bash
curl -sS "http://127.0.0.1:8080/ai-tool-agent?dry_run=true&text=cual%20es%20mi%20ip%20y%20como%20esta%20el%20clima%20en%20Buenos%20Aires%3F"
```

Ejecución real (requiere `OPENAI_API_KEY`):

```bash
curl -sS "http://127.0.0.1:8080/ai-tool-agent?dry_run=false&text=cual%20es%20mi%20ip%20y%20como%20esta%20el%20clima%20en%20Buenos%20Aires%3F"
```

La respuesta incluye `trace.steps[]` con tool calls, resultados, y memoria.

Scheduler / cron:

- `ai-tool-agent` trae un bloque `schedule` de ejemplo en `examples/functions/node/ai-tool-agent/fn.config.json` (desactivado por defecto).
- Podés activar schedules vía Console API, o editando `fn.config.json` y haciendo reload.
- Ver: [Gestionar funciones](../como-hacer/gestionar-funciones.md)

### Logs (interno)

Tail de logs de OpenResty (requiere API de consola):

```bash
curl -sS 'http://127.0.0.1:8080/_fn/logs?file=error&lines=200'
curl -sS 'http://127.0.0.1:8080/_fn/logs?file=access&lines=50&format=json'
```

### `request-inspector`

- Ruta: `/request-inspector`
- Metodos: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`
- Objetivo: mostrar method/query/headers/body/context que recibe el handler

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/request-inspector?key=test' \
  -X POST \
  -H 'x-demo: 1' \
  --data 'hello'
```

### Ejemplos edge / gateway (Workers-like)

Estas funciones demuestran el patrón: validar request, reescribir, y devolver una directiva `proxy`.

#### `edge-proxy`

- Ruta: `/edge-proxy`
- Objetivo: passthrough minimo (proxy a `/request-inspector`)

```bash
curl -sS 'http://127.0.0.1:8080/edge-proxy' | jq .
```

#### `edge-filter`

- Ruta: `/edge-filter`
- Objetivo: filtro con API key + rewrite + passthrough

```bash
curl -sS -i 'http://127.0.0.1:8080/edge-filter?user_id=123' | sed -n '1,12p'
curl -sS 'http://127.0.0.1:8080/edge-filter?user_id=123' -H 'x-api-key: dev' | jq .
```

#### `edge-auth-gateway`

- Ruta: `/edge-auth-gateway`
- Objetivo: auth Bearer + passthrough

```bash
curl -sS -i 'http://127.0.0.1:8080/edge-auth-gateway?target=health' | sed -n '1,12p'
curl -sS 'http://127.0.0.1:8080/edge-auth-gateway?target=health' -H 'Authorization: Bearer dev-token' | jq .
```

#### `edge-header-inject`

- Ruta: `/edge-header-inject`
- Objetivo: inyectar headers y proxy a `/request-inspector`

```bash
curl -sS 'http://127.0.0.1:8080/edge-header-inject?tenant=acme' -X POST --data 'hello' | jq .
```

#### `github-webhook-guard`

- Ruta: `/github-webhook-guard`
- Metodos: `POST`
- Objetivo: verificar `x-hub-signature-256` (HMAC GitHub) y opcionalmente forward
- Env: `GITHUB_WEBHOOK_SECRET` (secreto)

```bash
curl -sS -i 'http://127.0.0.1:8080/github-webhook-guard' \
  -X POST \
  -H 'x-hub-signature-256: sha256=bad' \
  --data '{"zen":"Keep it logically awesome.","hook_id":123}' | sed -n '1,12p'
```

### `slack-webhook`

- Ruta: `/slack-webhook`
- Metodos: `GET`
- Objetivo: enviar Slack Incoming Webhook (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `SLACK_WEBHOOK_URL` (secreto)

Ejemplo (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/slack-webhook?text=Hola&dry_run=true'
```

### `discord-webhook`

- Ruta: `/discord-webhook`
- Metodos: `GET`
- Objetivo: enviar webhook Discord (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `DISCORD_WEBHOOK_URL` (secreto)

Ejemplo (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/discord-webhook?content=Hola&dry_run=true'
```

### `notion-create-page`

- Ruta: `/notion-create-page`
- Metodos: `GET`
- Objetivo: crear pagina Notion (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `NOTION_TOKEN` (secreto)

Ejemplo (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/notion-create-page?title=Hola&content=Mundo&dry_run=true'
```

## Ejemplos de Auto-install Autónomo

### Python (inferencia)

- `auto-infer-no-requirements`
  Código: `examples/functions/python/auto-infer-no-requirements/app.py`
- `auto-infer-alias`
  Código: `examples/functions/python/auto-infer-alias/app.py` (`PIL` -> `Pillow`)

```bash
curl -sS 'http://127.0.0.1:8080/auto-infer-no-requirements'
curl -sS 'http://127.0.0.1:8080/auto-infer-alias'
```

### Node (inferencia)

- `auto-infer-create-package`
  Código: `examples/functions/node/auto-infer-create-package/app.js`
- `auto-infer-update-package`
  Código: `examples/functions/node/auto-infer-update-package/app.js`

```bash
curl -sS 'http://127.0.0.1:8080/auto-infer-create-package'
curl -sS 'http://127.0.0.1:8080/auto-infer-update-package'
```

### PHP (composer por manifiesto)

- `auto-composer-basic`
  Código: `examples/functions/php/auto-composer-basic/app.php`
- `auto-composer-existing`
  Código: `examples/functions/php/auto-composer-existing/app.php`

```bash
curl -sS 'http://127.0.0.1:8080/auto-composer-basic'
curl -sS 'http://127.0.0.1:8080/auto-composer-existing'
```

Inspeccionar estado de resolución:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=node&name=auto-infer-create-package' \
| python3 - <<'PY'
import json,sys
obj=json.load(sys.stdin)
print(json.dumps((obj.get("metadata") or {}).get("dependency_resolution"), indent=2))
PY
```

## Patrones Avanzados Equivalentes a Otras Plataformas

Paquete fuente: `examples/functions/platform-equivalents/`

Estos ejemplos replican patrones típicos de Cloudflare/Vercel/Netlify/AWS, adaptados al enrutamiento por archivos de FastFN.

### Auth + perfil con RBAC

- `POST /auth/login` (Node): emite token bearer firmado con HMAC
- `GET /auth/profile` (Python): valida firma y expiración

```bash
TOKEN="$(curl -sS -X POST 'http://127.0.0.1:8080/auth/login' \
  -H 'content-type: application/json' \
  --data '{"username":"demo-admin","role":"admin"}' | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"

curl -sS 'http://127.0.0.1:8080/auth/profile' \
  -H "authorization: Bearer ${TOKEN}"
```

### Webhook firmado + idempotencia

- `POST /webhooks/github-signed` (Python): verifica `x-hub-signature-256`, deduplica `x-github-delivery`

```bash
PAYLOAD='{"action":"opened","repository":"fastfn"}'
SIG="$(python3 - <<'PY'
import hashlib,hmac
body=b'{"action":"opened","repository":"fastfn"}'
print("sha256=" + hmac.new(b"fastfn-webhook-secret", body, hashlib.sha256).hexdigest())
PY
)"
curl -sS -X POST 'http://127.0.0.1:8080/webhooks/github-signed' \
  -H "x-hub-signature-256: ${SIG}" \
  -H 'x-github-delivery: demo-1' \
  -H 'content-type: application/json' \
  --data "${PAYLOAD}"
```

### API versionada de orders (polyglot)

- `POST /api/v1/orders` (Python)
- `GET /api/v1/orders` (Node)
- `GET /api/v1/orders/:id` (PHP)
- `PUT /api/v1/orders/:id` (Node)

```bash
ORDER_ID="$(curl -sS -X POST 'http://127.0.0.1:8080/api/v1/orders' \
  -H 'content-type: application/json' \
  --data '{"customer":"acme","items":[{"sku":"A-1","qty":2}]}' | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["order"]["id"])')"

curl -sS "http://127.0.0.1:8080/api/v1/orders/${ORDER_ID}"
curl -sS -X PUT "http://127.0.0.1:8080/api/v1/orders/${ORDER_ID}" \
  -H 'content-type: application/json' \
  --data '{"status":"shipped","tracking_number":"TRK-1001"}'
```

### Job asíncrono tipo background + polling

- `POST /jobs/render-report` (Node): acepta trabajo y devuelve `202`
- `GET /jobs/render-report/:id` (PHP): expone `queued/running/succeeded`

```bash
JOB_JSON="$(curl -sS -X POST 'http://127.0.0.1:8080/jobs/render-report' \
  -H 'content-type: application/json' \
  --data '{"report_type":"sales","items":[1,2,3,4]}')"
POLL_URL="$(printf '%s' "${JOB_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["poll_url"])')"
curl -sS "http://127.0.0.1:8080${POLL_URL}"
sleep 3
curl -sS "http://127.0.0.1:8080${POLL_URL}"
```

## PHP runtime

### `php-profile`

- Ruta: `/php-profile`
- Metodos: `GET`
- Query: `name`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/php-profile?name=PHP'
```

Response tipica:

```json
{"runtime":"php","function":"php-profile","hello":"php-PHP"}
```

## Rust runtime

### `rust-profile`

- Ruta: `/rust-profile`
- Metodos: `GET`
- Query: `name`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/rust-profile?name=Rust'
```

Response tipica:

```json
{"runtime":"rust","function":"rust-profile","hello":"rust-Rust"}
```

## Operacion

Despues de editar archivos de funciones, recarga discovery:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/_fn/reload'
```

## Contrato

Define la forma esperada de request/response, campos de configuración y garantías de comportamiento.

## Ejemplo End-to-End

Usa los ejemplos de esta página como plantillas canónicas para implementación y testing.

## Casos Límite

- Fallbacks ante configuración faltante
- Conflictos de rutas y precedencia
- Matices por runtime

## Ver también

- [Especificación de Funciones](especificacion-funciones.md)
- [Referencia API HTTP](api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
