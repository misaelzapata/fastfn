# Catalogo de funciones de ejemplo

Este documento describe las funciones reales incluidas en el repo, con request y response esperados.

## Python runtime

### `cron_tick` (demo scheduler)

- Ruta: `/fn/cron_tick`
- Metodos: `GET`
- Objetivo: contador simple que se incrementa via schedule

Leer el contador:

```bash
curl -sS 'http://127.0.0.1:8080/fn/cron_tick?action=read'
```

Habilitar schedule (cada 1s) via API de consola:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=cron_tick' \
  -X PUT -H 'Content-Type: application/json' \
  --data '{"schedule":{"enabled":true,"every_seconds":1,"method":"GET","query":{"action":"inc"},"headers":{},"body":"","context":{}}}'
curl -sS -X POST 'http://127.0.0.1:8080/_fn/reload'
```

Ver estado del scheduler:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/schedules'
```

### `hello`

- Ruta: `/fn/hello`
- Metodos: `GET`
- Query: `name` opcional

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello?name=Mundo'
```

Response tipica:

```json
{"hello":"saludos Mundo"}
```

### `risk_score`

- Ruta: `/fn/risk_score`
- Metodos: `GET`, `POST`
- Inputs:
  - `query.email`
  - header `x-user-email` (fallback)

Ejemplo GET:

```bash
curl -sS 'http://127.0.0.1:8080/fn/risk_score?email=user@example.com'
```

Ejemplo POST:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/risk_score' \
  -H 'x-user-email: user@example.com' \
  -H 'Content-Type: application/json' \
  -d '{}'
```

Response tipica:

```json
{"runtime":"python","function":"risk_score","score":60,"risk":"high","signals":{"email":true,"ip":"172.19.0.1"}}
```

### `slow`

- Ruta: `/fn/slow`
- Metodos: `GET`
- Query: `sleep_ms`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/slow?sleep_ms=100'
```

### `html_demo`

- Ruta: `/fn/html_demo`
- Metodos: `GET`
- Content-Type: `text/html; charset=utf-8`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/html_demo?name=Web'
```

### `csv_demo`

- Ruta: `/fn/csv_demo`
- Metodos: `GET`
- Content-Type: `text/csv; charset=utf-8`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/csv_demo?name=Alice'
```

### `png_demo`

- Ruta: `/fn/png_demo`
- Metodos: `GET`
- Content-Type: `image/png`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/png_demo' --output out.png
```

### `lambda_echo`

- Ruta: `/fn/lambda_echo`
- Metodos: `GET`

### `custom_echo`

- Ruta: `/fn/custom_echo`
- Metodos: `GET`
- Query: `v`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/custom_echo?v=demo'
```

### `requirements_demo`

- Ruta: `/fn/requirements_demo`
- Metodos: `GET`
- Dependencias:
  - `requirements.txt`
  - comentario inline `#@requirements`

### `qr`

- Ruta: `/fn/qr`
- Metodos: `GET`
- Query: `text` o `url`
- Content-Type: `image/svg+xml`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/qr?text=PythonQR'
```

### `gmail_send`

- Ruta: `/fn/gmail_send`
- Metodos: `GET`, `POST`
- Objetivo: helper Gmail SMTP para demos/integraciones
- Comportamiento por defecto: `dry_run=true` (pruebas locales sin credenciales reales)

Ejemplo GET:

```bash
curl -sS 'http://127.0.0.1:8080/fn/gmail_send?to=demo@example.com&subject=Hi&text=Hola&dry_run=true'
```

Ejemplo POST:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/gmail_send' \
  -H 'Content-Type: application/json' \
  -d '{"to":"demo@example.com","subject":"Hi","text":"Hola","dry_run":true}'
```

### `sendgrid_send`

- Ruta: `/fn/sendgrid_send`
- Metodos: `GET`, `POST`
- Objetivo: helper SendGrid (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `SENDGRID_API_KEY` (secreto), `SENDGRID_FROM`

Ejemplo GET (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/sendgrid_send?to=demo@example.com&subject=Hi&text=Hola&dry_run=true'
```

### `sheets_webapp_append`

- Ruta: `/fn/sheets_webapp_append`
- Metodos: `GET`
- Objetivo: append de fila via Google Apps Script Web App (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `SHEETS_WEBAPP_URL` (secreto)

Ejemplo (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/sheets_webapp_append?sheet=Sheet1&values=a,b,c&dry_run=true'
```

### `nombre`

- Ruta: `/fn/nombre`
- Metodos: `GET` (politica default)

### `stripe_webhook_verify`

- Ruta: `/fn/stripe_webhook_verify`
- Metodos: `POST`
- Objetivo: verificar firma de webhooks Stripe (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `STRIPE_WEBHOOK_SECRET` (secreto)

### `github_webhook_verify`

- Ruta: `/fn/github_webhook_verify`
- Metodos: `POST`
- Objetivo: verificar firma de webhooks GitHub (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `GITHUB_WEBHOOK_SECRET` (secreto)

## Node runtime

### `hello@v2`

- Ruta: `/fn/hello@v2`
- Metodos: `GET`
- Query: `name`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello@v2?name=NodeWay'
```

Response tipica:

```json
{"hello":"v2-NodeWay"}
```

### `node_echo`

- Ruta: `/fn/node_echo`
- Metodos: `GET`, `POST` (editable en `fn.config.json`)
- Query: `name`

Ejemplo GET:

```bash
curl -sS 'http://127.0.0.1:8080/fn/node_echo?name=Node'
```

Ejemplo POST:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/node_echo?name=NodePost' \
  -H 'Content-Type: application/json' \
  -d '{}'
```

### `echo`

- Ruta: `/fn/echo`
- Metodos: `GET`
- Query: `key`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/echo?key=test'
```

Response tipica:

```json
{"key":"test","query":{"key":"test"},"context":{"user":null}}
```

### `qr@v2`

- Ruta: `/fn/qr@v2`
- Metodos: `GET`
- Query: `text` o `url`, opcional `size`
- Content-Type: `image/png`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/qr@v2?text=NodeQR' --output qr-node.png
```

### `telegram_send`

- Ruta: `/fn/telegram_send`
- Metodos: `GET`, `POST`
- Objetivo: helper Telegram Bot API para demos/integraciones
- Comportamiento por defecto: `dry_run=true` (pruebas locales sin credenciales reales)

Ejemplo GET:

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram_send?chat_id=123456&text=Hola&dry_run=true'
```

Ejemplo POST:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/telegram_send' \
  -H 'Content-Type: application/json' \
  -d '{"chat_id":"123456","text":"Hola","dry_run":true}'
```

### `telegram_ai_reply`

- Ruta: `/fn/telegram_ai_reply`
- Metodos: `GET`, `POST`
- Objetivo: webhook Telegram -> OpenAI -> reply a Telegram
- Comportamiento por defecto: `dry_run=true` (seguro, no envia mensajes)
- Env (secretos): `TELEGRAM_BOT_TOKEN`, `OPENAI_API_KEY`

Ejemplo (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram_ai_reply?dry_run=true' \
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
- `TELEGRAM_TOOL_ALLOW_FN=request_inspector,telegram_ai_digest`
- `TELEGRAM_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `TELEGRAM_TOOL_TIMEOUT_MS=5000`

Directivas manuales dentro del mensaje del usuario:

- `[[fn:request_inspector?key=test|GET]]`
- `[[http:https://api.ipify.org?format=json]]`

Memoria:

- Archivo de memoria por chat: `srv/fn/functions/node/telegram_ai_reply/.memory.json`
- Archivo de offset del loop: `srv/fn/functions/node/telegram_ai_reply/.loop_state.json`
- El prompt de sistema evita respuestas falsas del tipo "no recuerdo" cuando existe historial.

### `whatsapp`

- Ruta: `/fn/whatsapp`
- Metodos: `GET`, `POST`, `DELETE`
- Objetivo: gestor de sesion real de WhatsApp (QR, conexion, envio, inbox/outbox, chat AI)
- Actions:
  - `GET /fn/whatsapp?action=qr`
  - `GET /fn/whatsapp?action=status`
  - `POST /fn/whatsapp?action=send`
  - `POST /fn/whatsapp?action=chat`
  - `GET /fn/whatsapp?action=inbox`
  - `DELETE /fn/whatsapp?action=reset-session`

Tools para WhatsApp (`action=chat`):

- `WHATSAPP_TOOLS_ENABLED=true`
- `WHATSAPP_AUTO_TOOLS=true`
- `WHATSAPP_TOOL_ALLOW_FN=request_inspector,telegram_ai_digest`
- `WHATSAPP_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `WHATSAPP_TOOL_TIMEOUT_MS=5000`

### Logs (interno)

Tail de logs de OpenResty (requiere API de consola):

```bash
curl -sS 'http://127.0.0.1:8080/_fn/logs?file=error&lines=200'
curl -sS 'http://127.0.0.1:8080/_fn/logs?file=access&lines=50&format=json'
```

### `request_inspector`

- Ruta: `/fn/request_inspector`
- Metodos: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`
- Objetivo: mostrar method/query/headers/body/context que recibe el handler

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/request_inspector?key=test' \
  -X POST \
  -H 'x-demo: 1' \
  --data 'hello'
```

### Ejemplos edge / gateway (Workers-like)

Estas funciones demuestran el patrón: validar request, reescribir, y devolver una directiva `proxy`.

#### `edge_proxy`

- Ruta: `/fn/edge_proxy`
- Objetivo: passthrough minimo (proxy a `/_fn/health`)

```bash
curl -sS 'http://127.0.0.1:8080/fn/edge_proxy' | jq .
```

#### `edge_filter`

- Ruta: `/fn/edge_filter`
- Objetivo: filtro con API key + rewrite + passthrough

```bash
curl -sS -i 'http://127.0.0.1:8080/fn/edge_filter?user_id=123' | sed -n '1,12p'
curl -sS 'http://127.0.0.1:8080/fn/edge_filter?user_id=123' -H 'x-api-key: dev' | jq '.openapi, .info.title'
```

#### `edge_auth_gateway`

- Ruta: `/fn/edge_auth_gateway`
- Objetivo: auth Bearer + passthrough

```bash
curl -sS -i 'http://127.0.0.1:8080/fn/edge_auth_gateway?target=health' | sed -n '1,12p'
curl -sS 'http://127.0.0.1:8080/fn/edge_auth_gateway?target=health' -H 'Authorization: Bearer dev-token' | jq .
```

#### `edge-header-inject`

- Ruta: `/fn/edge-header-inject`
- Objetivo: inyectar headers y proxy a `/fn/request_inspector`

```bash
curl -sS 'http://127.0.0.1:8080/fn/edge-header-inject?tenant=acme' -X POST --data 'hello' | jq .
```

#### `github_webhook_guard`

- Ruta: `/fn/github_webhook_guard`
- Metodos: `POST`
- Objetivo: verificar `x-hub-signature-256` (HMAC GitHub) y opcionalmente forward
- Env: `GITHUB_WEBHOOK_SECRET` (secreto)

```bash
curl -sS -i 'http://127.0.0.1:8080/fn/github_webhook_guard' \
  -X POST \
  -H 'x-hub-signature-256: sha256=bad' \
  --data '{"zen":"Keep it logically awesome.","hook_id":123}' | sed -n '1,12p'
```

### `slack_webhook`

- Ruta: `/fn/slack_webhook`
- Metodos: `GET`
- Objetivo: enviar Slack Incoming Webhook (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `SLACK_WEBHOOK_URL` (secreto)

Ejemplo (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/slack_webhook?text=Hola&dry_run=true'
```

### `discord_webhook`

- Ruta: `/fn/discord_webhook`
- Metodos: `GET`
- Objetivo: enviar webhook Discord (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `DISCORD_WEBHOOK_URL` (secreto)

Ejemplo (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/discord_webhook?content=Hola&dry_run=true'
```

### `notion_create_page`

- Ruta: `/fn/notion_create_page`
- Metodos: `GET`
- Objetivo: crear pagina Notion (seguro por defecto)
- Comportamiento por defecto: `dry_run=true`
- Env: `NOTION_TOKEN` (secreto)

Ejemplo (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/notion_create_page?title=Hola&content=Mundo&dry_run=true'
```

## PHP runtime

### `php_profile`

- Ruta: `/fn/php_profile`
- Metodos: `GET`
- Query: `name`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/php_profile?name=PHP'
```

Response tipica:

```json
{"runtime":"php","function":"php_profile","hello":"php-PHP"}
```

## Rust runtime

### `rust_profile`

- Ruta: `/fn/rust_profile`
- Metodos: `GET`
- Query: `name`

Ejemplo:

```bash
curl -sS 'http://127.0.0.1:8080/fn/rust_profile?name=Rust'
```

Response tipica:

```json
{"runtime":"rust","function":"rust_profile","hello":"rust-Rust"}
```

## Operacion

Despues de editar archivos de funciones, recarga discovery:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/_fn/reload'
```
