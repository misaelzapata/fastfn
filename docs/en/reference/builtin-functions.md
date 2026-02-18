# Example Function Catalog

This page is a guided tour of the **example functions** shipped with this repository.

Important distinction:

- Public example routes live at normal paths like `/hello` and `/telegram-ai-reply`.
- Platform control-plane endpoints live under `/_fn/*` (health, OpenAPI, config, logs).

## Run the examples

Recommended (Next.js-style routes + showcase):

```bash
bin/fastfn dev examples/functions/next-style
```

Then try:

- `GET /showcase`
- `GET /openapi.json`
- `GET /docs`

Full catalog (everything under `examples/functions/`):

```bash
bin/fastfn dev examples/functions
```

Note about paths:

- When you run a **subfolder** (like `examples/functions/next-style`), its routes live at the root (for example `/users`, `/showcase`).
- When you run the **full catalog** (`examples/functions`), each app folder becomes a namespace:
  - `next-style/*` is served under `/next-style/*`
  - `polyglot-tutorial/*` is served under `/polyglot-tutorial/*`
  - `polyglot-db-demo/*` is served under `/polyglot-db-demo/*`

Source code layout:

- Python: `examples/functions/python/<name>/`
- Node: `examples/functions/node/<name>/`
- PHP: `examples/functions/php/<name>/`
- Rust: `examples/functions/rust/<name>/`
- Next.js-style app: `examples/functions/next-style/` (file routes)

## Beginner tour (10 minutes)

If you're new to FastFN, start here. You only need one terminal.

1. Start the demo app:

```bash
bin/fastfn dev examples/functions/next-style
```

2. Open the UI and docs:

- `GET /showcase` (browser)
- `GET /docs` (Swagger UI for public functions)
- `GET /openapi.json` (raw OpenAPI JSON)

3. Call a JSON endpoint:

```bash
curl -sS 'http://127.0.0.1:8080/hello?name=World'
```

Example response:

```json
{"hello":"saludos World"}
```

4. Inspect what the gateway sends to handlers:

```bash
curl -sS 'http://127.0.0.1:8080/request-inspector?key=test' \
  -X POST \
  -H 'x-demo: 1' \
  --data 'hello'
```

You should see JSON including `method`, `path`, `query`, `headers` (only a safe subset), and `body`.

5. Try non-JSON responses:

- HTML:

```bash
curl -sS 'http://127.0.0.1:8080/html-demo?name=Web'
```

- CSV:

```bash
curl -sS 'http://127.0.0.1:8080/csv-demo?name=Alice'
```

- Binary (PNG):

```bash
curl -sS 'http://127.0.0.1:8080/png-demo' --output out.png
```

## How these examples work

Every example function is “just code” plus optional local config:

- `app.py` / `app.js` / `handler.js` / `app.ts` etc: the handler file
- `fn.config.json` (optional): methods/routes/handler name/timeouts/etc
- `fn.env.json` (optional): per-function env vars (secrets supported)

Handlers receive a single `event` object (method/query/headers/body/context/env/client).
Handlers return:

- JSON helpers: `{ status, headers, body }`
- Binary: `{ status, headers, is_base64: true, body_base64 }`
- Edge proxy: `{ proxy: { path, method, headers, body, timeout_ms } }` (FastFN performs the upstream fetch)

### `custom-handler-demo` (custom handler name, Python + Node variants)

This demo shows that you can pick a handler name other than `handler` using `fn.config.json`:

- Python variant:

```bash
bin/fastfn dev examples/functions/python/custom-handler-demo
curl -sS 'http://127.0.0.1:8080/custom-handler-demo?name=World'
```

Expected response:

```json
{"runtime":"python","handler":"main","hello":"World"}
```

- Node variant:

```bash
bin/fastfn dev examples/functions/node/custom-handler-demo
curl -sS 'http://127.0.0.1:8080/custom-handler-demo?name=World'
```

Expected response:

```json
{"runtime":"node","handler":"main","hello":"World"}
```

## Multi-route demo apps

These folders contain multiple routes (an “app”), not just one endpoint.

### `next-style` (recommended: Next.js-style file routing)

- Run:

```bash
bin/fastfn dev examples/functions/next-style
```

- What it demonstrates:
  - Next.js-style routing (`index.*`, `[id].*`, `[...slug].*`, method prefixes)
  - Polyglot handlers living side-by-side (node/python/php/rust)
  - A small “showcase” UI to click through the demos

- Try:
  - `GET /showcase`
  - `GET /users`
  - `GET /users/123`

### `polyglot-tutorial` (step-by-step multi-runtime pipeline)

Run (namespaced under the catalog root):

```bash
bin/fastfn dev examples/functions
```

Try:

```bash
curl -sS 'http://127.0.0.1:8080/polyglot-tutorial/step-1'
curl -sS 'http://127.0.0.1:8080/polyglot-tutorial/step-2?name=Ada'
curl -sS 'http://127.0.0.1:8080/polyglot-tutorial/step-3?name=Ada'
curl -sS 'http://127.0.0.1:8080/polyglot-tutorial/step-4'
curl -sS 'http://127.0.0.1:8080/polyglot-tutorial/step-5?name=Ada'
```

What to look for:

- Each step is a different runtime (node -> python -> php -> rust -> node)
- Step 5 performs internal HTTP calls to earlier steps and returns a combined `flow`

### `polyglot-db-demo` (shared SQLite across runtimes)

Run it directly (routes at the root):

```bash
bin/fastfn dev examples/functions/polyglot-db-demo
```

Try:

```bash
curl -sS 'http://127.0.0.1:8080/items'
curl -sS -X POST 'http://127.0.0.1:8080/items' -H 'content-type: application/json' --data '{"name":"first item"}'
curl -sS 'http://127.0.0.1:8080/items'
curl -sS -X PUT 'http://127.0.0.1:8080/items/1' -H 'content-type: application/json' --data '{"name":"updated item"}'
curl -sS -X DELETE 'http://127.0.0.1:8080/items/1'
```

What to look for:

- A single SQLite file is shared across node/python/php/rust handlers
- Some internal helper routes are intentionally not public (they require an internal-call header)

### `ip-intel` (file routes + optional deps + deterministic mock mode)

Run (namespaced under the catalog root):

```bash
bin/fastfn dev examples/functions
```

Try without external network calls:

```bash
curl -sS 'http://127.0.0.1:8080/ip-intel/maxmind?ip=8.8.8.8&mock=1'
curl -sS 'http://127.0.0.1:8080/ip-intel/remote?ip=8.8.8.8&mock=1'
```

## Python runtime

### `cron-tick` (scheduler demo)

- Route: `/cron-tick`
- Methods: `GET`
- Goal: simple counter you can increment via schedule
- Source: `examples/functions/python/cron-tick/app.py`

Read current count:

```bash
curl -sS 'http://127.0.0.1:8080/cron-tick?action=read'
```

Example response:

```json
{"function":"cron-tick","action":"read","count":0}
```

Enable schedule (every 1s) via Console API:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=cron-tick' \
  -X PUT -H 'Content-Type: application/json' \
  --data '{"schedule":{"enabled":true,"every_seconds":1,"method":"GET","query":{"action":"inc"},"headers":{},"body":"","context":{}}}'
curl -sS -X POST 'http://127.0.0.1:8080/_fn/reload'
```

Observe scheduler state:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/schedules'
```

### `utc-time` (cron + timezone demo)

- Route: `/utc-time`
- Methods: `GET`
- Goal: show UTC/local timestamps + scheduler trigger context
- Schedule: daily at `09:00` in `UTC` (cron)
- Source: `examples/functions/python/utc-time/app.py`

Call it:

```bash
curl -sS 'http://127.0.0.1:8080/utc-time'
```

What to look for:

- `now_utc` vs `now_local`
- `trigger` (when invoked by the scheduler)

### `offset-time` (cron + timezone demo)

- Route: `/offset-time`
- Methods: `GET`
- Goal: same as `utc-time`, but scheduled using a fixed offset timezone
- Schedule: daily at `09:00` in `-05:00` (cron)
- Source: `examples/functions/python/offset-time/app.py`

Call it:

```bash
curl -sS 'http://127.0.0.1:8080/offset-time'
```

Tip: compare `next` values via `/_fn/schedules`, or from the browser devtools:

```js
fetch('/_fn/schedules').then((r) => r.json()).then(console.log)
```

### `tools-loop` (tools loop demo, inspired by agent loops)

- Route: `/tools-loop`
- Methods: `GET`, `POST`
- Goal: minimal "agent loop" style planner/executor for testing tools (no API keys).
- Default behavior: `dry_run=true`
- Source: `examples/functions/python/tools-loop/app.py`

Dry run (plan only):

```bash
curl -sS 'http://127.0.0.1:8080/tools-loop?text=quiero%20mi%20ip%20y%20clima&dry_run=true'
```

What to look for:

- `plan`: selected tools
- `results`: in `dry_run=true` they are placeholders

Execute tools:

```bash
curl -sS 'http://127.0.0.1:8080/tools-loop?tool=ip_lookup,weather&city=Buenos%20Aires&dry_run=false'
```

Execute tools (offline mock):

```bash
curl -sS 'http://127.0.0.1:8080/tools-loop?tool=ip_lookup,weather&city=Buenos%20Aires&dry_run=false&mock=true'
```

### `telegram-ai-reply-py` (Telegram AI bot, Python)

- Route: `/telegram-ai-reply-py`
- Methods: `GET`, `POST`
- Goal: Telegram webhook/query -> OpenAI -> Telegram reply (Python), with tools + memory + loop mode
- Default behavior: `dry_run=true`
- Env (secrets): `TELEGRAM_BOT_TOKEN`, `OPENAI_API_KEY`
- Source: `examples/functions/python/telegram-ai-reply-py/app.py`

Dry run (query-mode):

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply-py?mode=reply&chat_id=123&text=Hola&dry_run=true'
```

Example response (when `chat_id` is missing):

```json
{"ok":true,"note":"no chat_id provided; nothing to do"}
```

Real send (query-mode):

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply-py?mode=reply&chat_id=123&text=Hola&dry_run=false'
```

Tools (manual directives inside the user text):

```bash
curl -g -sS \
"http://127.0.0.1:8080/telegram-ai-reply-py?mode=reply&chat_id=123&dry_run=false&tools=true&tool_allow_fn=tools-loop,request-inspector&text=Use%20[[http:https://api.ipify.org?format=json]]%20and%20[[fn:tools-loop?text=my%20ip%20and%20weather&dry_run=true|GET]]"
```

Tools (auto-tools from intent):

```bash
curl -sS \
"http://127.0.0.1:8080/telegram-ai-reply-py?mode=reply&chat_id=123&dry_run=false&tools=true&auto_tools=true&text=How%20is%20the%20weather%20today%20and%20what%20is%20my%20IP%3F"
```

Loop mode (dry-run):

```bash
curl -sS \
"http://127.0.0.1:8080/telegram-ai-reply-py?mode=loop&dry_run=true&wait_secs=20"
```

Memory/loop state files (created at runtime):

- `<FN_FUNCTIONS_ROOT>/python/telegram-ai-reply-py/.memory.json`
- `<FN_FUNCTIONS_ROOT>/python/telegram-ai-reply-py/.loop_state.json`

### `hello`

- Route: `/hello`
- Methods: `GET`
- Query: optional `name`
- Source: `examples/functions/python/hello/app.py`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/hello?name=World'
```

Typical response:

```json
{"hello":"saludos World"}
```

### `risk-score`

- Route: `/risk-score`
- Methods: `GET`, `POST`
- Inputs:
  - `query.email`
  - fallback header `x-user-email`
- Source: `examples/functions/python/risk-score/app.py`

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/risk-score?email=user@example.com'
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/risk-score' \
  -H 'x-user-email: user@example.com' \
  -H 'Content-Type: application/json' \
  -d '{}'
```

Typical response:

```json
{"runtime":"python","function":"risk-score","score":60,"risk":"high","signals":{"email":true,"ip":"172.19.0.1"}}
```

### `slow`

- Route: `/slow`
- Methods: `GET`
- Query: `sleep_ms`
- Source: `examples/functions/python/slow/app.py`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/slow?sleep_ms=100'
```

Example response:

```json
{"runtime":"python","function":"slow","slept_ms":100}
```

### `html-demo`

- Route: `/html-demo`
- Methods: `GET`
- Content-Type: `text/html; charset=utf-8`
- Source: `examples/functions/python/html-demo/app.py`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/html-demo?name=Web'
```

Example response:

```html
<html><body><h1>Hello Web</h1><p>html-demo</p></body></html>
```

### `csv-demo`

- Route: `/csv-demo`
- Methods: `GET`
- Content-Type: `text/csv; charset=utf-8`
- Source: `examples/functions/python/csv-demo/app.py`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/csv-demo?name=Alice'
```

Example response:

```csv
id,name,runtime
1,Alice,python
```

### `png-demo`

- Route: `/png-demo`
- Methods: `GET`
- Content-Type: `image/png`
- Source: `examples/functions/python/png-demo/app.py`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/png-demo' --output out.png
```

### `lambda-echo`

- Route: `/lambda-echo`
- Methods: `GET`
- Source: `examples/functions/python/lambda-echo/app.py`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/lambda-echo?name=Lambda'
```

Example response:

```json
{"hello":"Lambda"}
```

### `custom-echo`

- Route: `/custom-echo`
- Methods: `GET`
- Query: `v`
- Source: `examples/functions/python/custom-echo/app.py`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/custom-echo?v=demo'
```

Example response:

```json
{"value":"demo"}
```

### `requirements-demo`

- Route: `/requirements-demo`
- Methods: `GET`
- Dependency hints:
  - `requirements.txt`
  - inline `#@requirements` comment
- Source: `examples/functions/python/requirements-demo/app.py`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/requirements-demo'
```

Example response:

```json
{"runtime":"python","function":"requirements-demo"}
```

### `qr`

- Route: `/qr`
- Methods: `GET`
- Query: `text` or `url`
- Content-Type: `image/svg+xml`
- Source: `examples/functions/python/qr/app.py`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/qr?text=PythonQR'
```

Tip: write it to a file:

```bash
curl -sS 'http://127.0.0.1:8080/qr?text=PythonQR' --output qr.svg
```

### `pack-qr` (Python QR, minimal packaging demo)

- Route: `/pack-qr`
- Methods: `GET`
- Query: `text`
- Content-Type: `image/svg+xml`
- Source: `examples/functions/python/pack-qr/app.py`

```bash
curl -sS 'http://127.0.0.1:8080/pack-qr?text=Hello' --output pack-qr.svg
```

### `gmail-send`

- Route: `/gmail-send`
- Methods: `GET`, `POST`
- Goal: Gmail SMTP helper for demos/integrations
- Default behavior: `dry_run=true` (safe local testing without real credentials)
- Source: `examples/functions/python/gmail-send/app.py`

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/gmail-send?to=demo@example.com&subject=Hi&text=Hello&dry_run=true'
```

Example response:

```json
{"channel":"gmail","to":"demo@example.com","subject":"Hi","dry_run":true}
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/gmail-send' \
  -H 'Content-Type: application/json' \
  -d '{"to":"demo@example.com","subject":"Hi","text":"Hello","dry_run":true}'
```

### `sendgrid-send`

- Route: `/sendgrid-send`
- Methods: `GET`, `POST`
- Goal: SendGrid email helper (safe by default)
- Default behavior: `dry_run=true`
- Env: `SENDGRID_API_KEY` (secret), `SENDGRID_FROM`
- Source: `examples/functions/python/sendgrid-send/app.py`

GET (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/sendgrid-send?to=demo@example.com&subject=Hi&text=Hello&dry_run=true'
```

Example response (dry run):

```json
{"function":"sendgrid-send","dry_run":true,"ok":true}
```

### `sheets-webapp-append`

- Route: `/sheets-webapp-append`
- Methods: `GET`
- Goal: append a row via a Google Apps Script Web App (safe by default)
- Default behavior: `dry_run=true`
- Env: `SHEETS_WEBAPP_URL` (secret)
- Source: `examples/functions/python/sheets-webapp-append/app.py`

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/sheets-webapp-append?sheet=Sheet1&values=a,b,c&dry_run=true'
```

### `nombre`

- Route: `/nombre`
- Methods: `GET` (default policy)
- Source: `examples/functions/python/nombre/handler.py`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/nombre?name=Ana'
```

Example response:

```json
{"runtime":"python","function":"hello","hello":"Ana","request_id":"<request_id>"}
```

### `stripe-webhook-verify`

- Route: `/stripe-webhook-verify`
- Methods: `POST`
- Goal: verify Stripe webhook signature (safe by default)
- Default behavior: `dry_run=true`
- Env: `STRIPE_WEBHOOK_SECRET` (secret)
- Source: `examples/functions/python/stripe-webhook-verify/app.py`

Dry run:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/stripe-webhook-verify' \
  -H 'Content-Type: application/json' \
  -d '{"id":"evt_test"}'
```

Enforce verification:

- set `dry_run=false`
- include `Stripe-Signature` header
- set `STRIPE_WEBHOOK_SECRET` in `fn.env.json`

### `github-webhook-verify`

- Route: `/github-webhook-verify`
- Methods: `POST`
- Goal: verify GitHub webhook signature (safe by default)
- Default behavior: `dry_run=true`
- Env: `GITHUB_WEBHOOK_SECRET` (secret)
- Source: `examples/functions/python/github-webhook-verify/app.py`

## Node runtime

### `hello@v2`

- Route: `/hello@v2`
- Methods: `GET`
- Query: `name`
- Source: `examples/functions/node/hello/v2/app.js`
- What it demonstrates: versioned endpoint (`@v2`) living in a version folder

Example:

```bash
curl -sS 'http://127.0.0.1:8080/hello@v2?name=NodeWay'
```

Typical response:

```json
{"hello":"v2-NodeWay"}
```

### `node-echo`

- Route: `/node-echo`
- Methods: `GET`, `POST` (editable in `fn.config.json`)
- Query: `name`
- Source: `examples/functions/node/node-echo/app.js`

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/node-echo?name=Node'
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/node-echo?name=NodePost' \
  -H 'Content-Type: application/json' \
  -d '{}'
```

Example response:

```json
{"runtime":"node","function":"node-echo","hello":"Node"}
```

### `echo`

- Route: `/echo`
- Methods: `GET`
- Query: `key`
- Source: `examples/functions/node/echo/handler.js`
- What it demonstrates: what FastFN passes in `event.query` and `event.context.user`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/echo?key=test'
```

Typical response:

```json
{"key":"test","query":{"key":"test"},"context":{"user":null}}
```

### `qr@v2`

- Route: `/qr@v2`
- Methods: `GET`
- Query: `text` or `url`, optional `size`
- Content-Type: `image/png`
- Source: `examples/functions/node/qr/v2/app.js`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/qr@v2?text=NodeQR' --output qr-node.png
```

### `pack-qr-node` (Node QR, PNG output)

- Route: `/pack-qr-node`
- Methods: `GET`
- Query: `text`
- Content-Type: `image/png`
- Source: `examples/functions/node/pack-qr-node/app.js`

```bash
curl -sS 'http://127.0.0.1:8080/pack-qr-node?text=Hello' --output pack-qr-node.png
```

### `ts-hello` (TypeScript handler)

- Route: `/ts-hello`
- Methods: `GET`
- Query: `name`
- Source: `examples/functions/node/ts-hello/app.ts`

```bash
curl -sS 'http://127.0.0.1:8080/ts-hello?name=TypeScript'
```

### `telegram-send`

- Route: `/telegram-send`
- Methods: `GET`, `POST`
- Goal: Telegram Bot API helper for demos/integrations
- Default behavior: `dry_run=true` (safe local testing without real credentials)
- Source: `examples/functions/node/telegram-send/app.js`

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/telegram-send?chat_id=123456&text=Hello&dry_run=true'
```

Example response (dry run):

```json
{"channel":"telegram","chat_id":"123456","text":"Hello","dry_run":true}
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/telegram-send' \
  -H 'Content-Type: application/json' \
  -d '{"chat_id":"123456","text":"Hello","dry_run":true}'
```

### `telegram-ai-digest` (scheduled digest demo)

- Route: `/telegram-ai-digest`
- Methods: `GET`, `POST`
- Goal: build a daily digest (weather + headlines) and optionally send it to Telegram
- Default behavior: `dry_run=true`
- Source: `examples/functions/node/telegram-ai-digest/app.js`

Dry run:

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-digest?dry_run=true'
```

Preview (build the message but do not send):

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-digest?preview=true'
```

### `telegram-ai-reply`

- Route: `/telegram-ai-reply`
- Methods: `GET`, `POST`
- Goal: Telegram webhook -> OpenAI -> Telegram reply
- Default behavior: `dry_run=true` (safe local testing without sending messages)
- Env (secrets): `TELEGRAM_BOT_TOKEN`, `OPENAI_API_KEY`
- Source: `examples/functions/node/telegram-ai-reply/app.js`
- Deep dive: [How `telegram-ai-reply` Works](../articles/telegram-ai-reply-how-it-works.md)

Dry run example:

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply?dry_run=true' \
  -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message":{"chat":{"id":123},"text":"Hola"}}'
```

To send for real:

- set `dry_run=false`
- set `TELEGRAM_BOT_TOKEN` and `OPENAI_API_KEY` in `fn.env.json`

Process env fallback (optional):

- `TELEGRAM_BOT_TOKEN`
- `OPENAI_API_KEY`

Tools (optional):

- `TELEGRAM_TOOLS_ENABLED=true`
- `TELEGRAM_AUTO_TOOLS=true` (auto-select tools from user intent)
- `TELEGRAM_TOOL_ALLOW_FN=request-inspector,telegram-ai-digest`
- `TELEGRAM_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `TELEGRAM_TOOL_TIMEOUT_MS=5000`

Manual tool directives inside user message:

- `[[fn:request-inspector?key=test|GET]]`
- `[[http:https://api.ipify.org?format=json]]`

Memory behavior:

- Per-chat memory file: `<FN_FUNCTIONS_ROOT>/node/telegram-ai-reply/.memory.json`
- Loop offset file: `<FN_FUNCTIONS_ROOT>/node/telegram-ai-reply/.loop_state.json`
- The system prompt explicitly instructs the model not to claim "I can't remember" when history exists.

### `whatsapp`

- Route: `/whatsapp`
- Methods: `GET`, `POST`, `DELETE`
- Goal: WhatsApp real session manager (QR, connect, send, inbox/outbox, AI chat)
- Source: `examples/functions/node/whatsapp/app.js`
- Actions:
  - `GET /whatsapp?action=qr`
  - `GET /whatsapp?action=status`
  - `POST /whatsapp?action=send`
  - `POST /whatsapp?action=chat`
  - `GET /whatsapp?action=inbox`
  - `DELETE /whatsapp?action=reset-session`

Tip: if you call `POST /whatsapp` without an action, you may get `405` because some actions are intentionally method-specific.

WhatsApp tools (for `action=chat`):

- `WHATSAPP_TOOLS_ENABLED=true`
- `WHATSAPP_AUTO_TOOLS=true`
- `WHATSAPP_TOOL_ALLOW_FN=request-inspector,telegram-ai-digest`
- `WHATSAPP_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `WHATSAPP_TOOL_TIMEOUT_MS=5000`

### `toolbox-bot` (safe tools runner)

- Route: `/toolbox-bot`
- Methods: `GET`, `POST`
- Goal: run tool directives (`[[http:...]]`, `[[fn:...]]`) and return the plan + results as JSON
- Default behavior: `dry_run=true`
- Source: `examples/functions/node/toolbox-bot/app.js`
- Docs: [Tools](../how-to/tools.md)

Plan only (no outbound calls):

```bash
curl -g -sS \
"http://127.0.0.1:8080/toolbox-bot?dry_run=true&text=Use%20[[http:https://api.ipify.org?format=json]]%20and%20[[fn:request-inspector?key=demo|GET]]"
```

Execute (allowlisted only):

```bash
curl -g -sS \
"http://127.0.0.1:8080/toolbox-bot?dry_run=false&text=Use%20[[http:https://api.ipify.org?format=json]]%20and%20[[fn:request-inspector?key=demo|GET]]"
```

### `ai-tool-agent` (OpenAI tool-calling agent)

- Route: `/ai-tool-agent`
- Methods: `GET`, `POST`
- Goal: OpenAI chooses tools (`http_get`, `fn_get`) and the function executes them with allowlists
- Default behavior: `dry_run=true`
- Source: `examples/functions/node/ai-tool-agent/app.js`
- Docs: [Tools](../how-to/tools.md#61-openai-tool-calling-model-chooses-tools)

Dry run:

```bash
curl -sS "http://127.0.0.1:8080/ai-tool-agent?dry_run=true&text=what%20is%20my%20ip%20and%20weather%20in%20Buenos%20Aires%3F"
```

Real run (requires `OPENAI_API_KEY`):

```bash
curl -sS "http://127.0.0.1:8080/ai-tool-agent?dry_run=false&text=what%20is%20my%20ip%20and%20weather%20in%20Buenos%20Aires%3F"
```

The response includes a `trace.steps[]` array with tool calls, tool results, and memory info.

Scheduler / cron:

- `ai-tool-agent` ships with an example `schedule` block in `examples/functions/node/ai-tool-agent/fn.config.json` (disabled by default).
- Enable schedules via the Console API, or by editing `fn.config.json` and reloading.
- See: [Manage Functions](../how-to/manage-functions.md#4b-add-a-schedule-interval-cron)

### `request-inspector`

- Route: `/request-inspector`
- Methods: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`
- Goal: show what the gateway passed into the handler (method/query/headers/body/context)
- Source: `examples/functions/node/request-inspector/app.js`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/request-inspector?key=test' \
  -X POST \
  -H 'x-demo: 1' \
  --data 'hello'
```

### Edge / gateway patterns

These functions demonstrate a "Workers-like" pattern: validate the inbound request, rewrite it, then return a `proxy` directive.

#### `edge-proxy`

- Route: `/edge-proxy`
- Goal: minimal passthrough demo (proxies to `/request-inspector`)
- Source: `examples/functions/node/edge-proxy/app.js`

```bash
curl -sS 'http://127.0.0.1:8080/edge-proxy' | jq .
```

#### `edge-filter`

- Route: `/edge-filter`
- Goal: API key filter + rewrite + passthrough
- Source: `examples/functions/node/edge-filter/app.js`

```bash
curl -sS -i 'http://127.0.0.1:8080/edge-filter?user_id=123' | sed -n '1,12p'
curl -sS 'http://127.0.0.1:8080/edge-filter?user_id=123' -H 'x-api-key: dev' | jq .
```

#### `edge-auth-gateway`

- Route: `/edge-auth-gateway`
- Goal: Bearer auth gateway + passthrough
- Source: `examples/functions/node/edge-auth-gateway/app.js`

```bash
curl -sS -i 'http://127.0.0.1:8080/edge-auth-gateway?target=health' | sed -n '1,12p'
curl -sS 'http://127.0.0.1:8080/edge-auth-gateway?target=health' -H 'Authorization: Bearer dev-token' | jq .
```

#### `edge-header-inject`

- Route: `/edge-header-inject`
- Goal: inject headers and proxy to `/request-inspector` (so you can see them)
- Source: `examples/functions/node/edge-header-inject/app.js`

```bash
curl -sS 'http://127.0.0.1:8080/edge-header-inject?tenant=acme' -X POST --data 'hello' | jq .
```

#### `github-webhook-guard`

- Route: `/github-webhook-guard`
- Methods: `POST`
- Goal: verify `x-hub-signature-256` (GitHub HMAC) and optionally forward
- Env: `GITHUB_WEBHOOK_SECRET` (secret)
- Source: `examples/functions/node/github-webhook-guard/app.js`

```bash
curl -sS -i 'http://127.0.0.1:8080/github-webhook-guard' \
  -X POST \
  -H 'x-hub-signature-256: sha256=bad' \
  --data '{"zen":"Keep it logically awesome.","hook_id":123}' | sed -n '1,12p'
```

### `slack-webhook`

- Route: `/slack-webhook`
- Methods: `GET`
- Goal: send a Slack Incoming Webhook (safe by default)
- Default behavior: `dry_run=true`
- Env: `SLACK_WEBHOOK_URL` (secret)
- Source: `examples/functions/node/slack-webhook/app.js`

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/slack-webhook?text=Hello&dry_run=true'
```

### `discord-webhook`

- Route: `/discord-webhook`
- Methods: `GET`
- Goal: send a Discord webhook (safe by default)
- Default behavior: `dry_run=true`
- Env: `DISCORD_WEBHOOK_URL` (secret)
- Source: `examples/functions/node/discord-webhook/app.js`

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/discord-webhook?content=Hello&dry_run=true'
```

### `notion-create-page`

- Route: `/notion-create-page`
- Methods: `GET`
- Goal: create a Notion page (safe by default)
- Default behavior: `dry_run=true`
- Env: `NOTION_TOKEN` (secret)
- Source: `examples/functions/node/notion-create-page/app.js`

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/notion-create-page?title=Hello&content=World&dry_run=true'
```

To send for real:

- set `dry_run=false`
- provide `parent_page_id`
- set `NOTION_TOKEN` in `fn.env.json`

## PHP runtime

### `php-profile`

- Route: `/php-profile`
- Methods: `GET`
- Query: `name`
- Source: `examples/functions/php/php-profile/app.php`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/php-profile?name=PHP'
```

Typical response:

```json
{"runtime":"php","function":"php-profile","hello":"php-PHP"}
```

## Rust runtime

### `rust-profile`

- Route: `/rust-profile`
- Methods: `GET`
- Query: `name`
- Source: `examples/functions/rust/rust-profile/lib.rs`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/rust-profile?name=Rust'
```

Typical response:

```json
{"runtime":"rust","function":"rust-profile","hello":"rust-Rust"}
```

## Control-plane endpoints (advanced)

Public example routes are things like `/hello` and `/edge-filter`.
The platform control-plane lives under `/_fn/*` (OpenAPI, config, logs, reload).

In production, you normally restrict access to `/_fn/*` (or disable the console UI),
and you should never let untrusted traffic reach it.

### Reload discovery

After editing function files, refresh discovery:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/_fn/reload'
```

### Tail logs

Tail OpenResty logs (requires console API access):

```bash
curl -sS 'http://127.0.0.1:8080/_fn/logs?file=error&lines=200'
curl -sS 'http://127.0.0.1:8080/_fn/logs?file=access&lines=50&format=json'
```
