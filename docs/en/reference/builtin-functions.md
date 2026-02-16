# Built-in Function Catalog

This document lists the real sample functions included in the repository, with concrete request/response examples.

## Python runtime

### `cron-tick` (scheduler demo)

- Route: `/fn/cron-tick`
- Methods: `GET`
- Goal: simple counter you can increment via schedule

Read current count:

```bash
curl -sS 'http://127.0.0.1:8080/fn/cron-tick?action=read'
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

- Route: `/fn/utc-time`
- Methods: `GET`
- Goal: show UTC/local timestamps + scheduler trigger context
- Schedule: daily at `09:00` in `UTC` (cron)

Call it:

```bash
curl -sS 'http://127.0.0.1:8080/fn/utc-time'
```

### `offset-time` (cron + timezone demo)

- Route: `/fn/offset-time`
- Methods: `GET`
- Goal: same as `utc-time`, but scheduled using a fixed offset timezone
- Schedule: daily at `09:00` in `-05:00` (cron)

Call it:

```bash
curl -sS 'http://127.0.0.1:8080/fn/offset-time'
```

Tip: compare `next` values via `/_fn/schedules`, or from the browser devtools:

```js
fetch('/_fn/schedules').then((r) => r.json()).then(console.log)
```

### `tools-loop` (tools loop demo, inspired by agent loops)

- Route: `/fn/tools-loop`
- Methods: `GET`, `POST`
- Goal: minimal "agent loop" style planner/executor for testing tools (no API keys).
- Default behavior: `dry_run=true`

Dry run (plan only):

```bash
curl -sS 'http://127.0.0.1:8080/fn/tools-loop?text=quiero%20mi%20ip%20y%20clima&dry_run=true'
```

Execute tools:

```bash
curl -sS 'http://127.0.0.1:8080/fn/tools-loop?tool=ip_lookup,weather&city=Buenos%20Aires&dry_run=false'
```

Execute tools (offline mock):

```bash
curl -sS 'http://127.0.0.1:8080/fn/tools-loop?tool=ip_lookup,weather&city=Buenos%20Aires&dry_run=false&mock=true'
```

### `telegram-ai-reply-py` (Telegram AI bot, Python)

- Route: `/fn/telegram-ai-reply-py`
- Methods: `GET`, `POST`
- Goal: Telegram webhook/query -> OpenAI -> Telegram reply (Python), with tools + memory + loop mode
- Default behavior: `dry_run=true`
- Env (secrets): `TELEGRAM_BOT_TOKEN`, `OPENAI_API_KEY`

Dry run (query-mode):

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram-ai-reply-py?mode=reply&chat_id=123&text=Hola&dry_run=true'
```

Real send (query-mode):

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram-ai-reply-py?mode=reply&chat_id=123&text=Hola&dry_run=false'
```

Tools (manual directives inside the user text):

```bash
curl -sS \
"http://127.0.0.1:8080/fn/telegram-ai-reply-py?mode=reply&chat_id=123&dry_run=false&tools=true&tool_allow_fn=tools-loop,request-inspector&text=Use%20[[http:https://api.ipify.org?format=json]]%20and%20[[fn:tools-loop?text=my%20ip%20and%20weather&dry_run=true|GET]]"
```

Tools (auto-tools from intent):

```bash
curl -sS \
"http://127.0.0.1:8080/fn/telegram-ai-reply-py?mode=reply&chat_id=123&dry_run=false&tools=true&auto_tools=true&text=How%20is%20the%20weather%20today%20and%20what%20is%20my%20IP%3F"
```

Loop mode (dry-run):

```bash
curl -sS \
"http://127.0.0.1:8080/fn/telegram-ai-reply-py?mode=loop&dry_run=true&wait_secs=20"
```

Memory/loop state files (created at runtime):

- `<FN_FUNCTIONS_ROOT>/python/telegram-ai-reply-py/.memory.json`
- `<FN_FUNCTIONS_ROOT>/python/telegram-ai-reply-py/.loop_state.json`

### `hello`

- Route: `/fn/hello`
- Methods: `GET`
- Query: optional `name`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello?name=World'
```

Typical response:

```json
{"hello":"saludos World"}
```

### `risk-score`

- Route: `/fn/risk-score`
- Methods: `GET`, `POST`
- Inputs:
  - `query.email`
  - fallback header `x-user-email`

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/risk-score?email=user@example.com'
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/risk-score' \
  -H 'x-user-email: user@example.com' \
  -H 'Content-Type: application/json' \
  -d '{}'
```

Typical response:

```json
{"runtime":"python","function":"risk-score","score":60,"risk":"high","signals":{"email":true,"ip":"172.19.0.1"}}
```

### `slow`

- Route: `/fn/slow`
- Methods: `GET`
- Query: `sleep_ms`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/slow?sleep_ms=100'
```

### `html-demo`

- Route: `/fn/html-demo`
- Methods: `GET`
- Content-Type: `text/html; charset=utf-8`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/html-demo?name=Web'
```

### `csv-demo`

- Route: `/fn/csv-demo`
- Methods: `GET`
- Content-Type: `text/csv; charset=utf-8`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/csv-demo?name=Alice'
```

### `png-demo`

- Route: `/fn/png-demo`
- Methods: `GET`
- Content-Type: `image/png`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/png-demo' --output out.png
```

### `lambda-echo`

- Route: `/fn/lambda-echo`
- Methods: `GET`

### `custom-echo`

- Route: `/fn/custom-echo`
- Methods: `GET`
- Query: `v`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/custom-echo?v=demo'
```

### `requirements-demo`

- Route: `/fn/requirements-demo`
- Methods: `GET`
- Dependency hints:
  - `requirements.txt`
  - inline `#@requirements` comment

### `qr`

- Route: `/fn/qr`
- Methods: `GET`
- Query: `text` or `url`
- Content-Type: `image/svg+xml`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/qr?text=PythonQR'
```

### `gmail-send`

- Route: `/fn/gmail-send`
- Methods: `GET`, `POST`
- Goal: Gmail SMTP helper for demos/integrations
- Default behavior: `dry_run=true` (safe local testing without real credentials)

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/gmail-send?to=demo@example.com&subject=Hi&text=Hello&dry_run=true'
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/gmail-send' \
  -H 'Content-Type: application/json' \
  -d '{"to":"demo@example.com","subject":"Hi","text":"Hello","dry_run":true}'
```

### `sendgrid-send`

- Route: `/fn/sendgrid-send`
- Methods: `GET`, `POST`
- Goal: SendGrid email helper (safe by default)
- Default behavior: `dry_run=true`
- Env: `SENDGRID_API_KEY` (secret), `SENDGRID_FROM`

GET (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/sendgrid-send?to=demo@example.com&subject=Hi&text=Hello&dry_run=true'
```

### `sheets-webapp-append`

- Route: `/fn/sheets-webapp-append`
- Methods: `GET`
- Goal: append a row via a Google Apps Script Web App (safe by default)
- Default behavior: `dry_run=true`
- Env: `SHEETS_WEBAPP_URL` (secret)

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/sheets-webapp-append?sheet=Sheet1&values=a,b,c&dry_run=true'
```

### `nombre`

- Route: `/fn/nombre`
- Methods: `GET` (default policy)

### `stripe-webhook-verify`

- Route: `/fn/stripe-webhook-verify`
- Methods: `POST`
- Goal: verify Stripe webhook signature (safe by default)
- Default behavior: `dry_run=true`
- Env: `STRIPE_WEBHOOK_SECRET` (secret)

Dry run:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/stripe-webhook-verify' \
  -H 'Content-Type: application/json' \
  -d '{"id":"evt_test"}'
```

Enforce verification:

- set `dry_run=false`
- include `Stripe-Signature` header
- set `STRIPE_WEBHOOK_SECRET` in `fn.env.json`

### `github-webhook-verify`

- Route: `/fn/github-webhook-verify`
- Methods: `POST`
- Goal: verify GitHub webhook signature (safe by default)
- Default behavior: `dry_run=true`
- Env: `GITHUB_WEBHOOK_SECRET` (secret)

## Node runtime

### `hello@v2`

- Route: `/fn/hello@v2`
- Methods: `GET`
- Query: `name`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello@v2?name=NodeWay'
```

Typical response:

```json
{"hello":"v2-NodeWay"}
```

### `node-echo`

- Route: `/fn/node-echo`
- Methods: `GET`, `POST` (editable in `fn.config.json`)
- Query: `name`

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/node-echo?name=Node'
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/node-echo?name=NodePost' \
  -H 'Content-Type: application/json' \
  -d '{}'
```

### `echo`

- Route: `/fn/echo`
- Methods: `GET`
- Query: `key`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/echo?key=test'
```

Typical response:

```json
{"key":"test","query":{"key":"test"},"context":{"user":null}}
```

### `qr@v2`

- Route: `/fn/qr@v2`
- Methods: `GET`
- Query: `text` or `url`, optional `size`
- Content-Type: `image/png`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/qr@v2?text=NodeQR' --output qr-node.png
```

### `telegram-send`

- Route: `/fn/telegram-send`
- Methods: `GET`, `POST`
- Goal: Telegram Bot API helper for demos/integrations
- Default behavior: `dry_run=true` (safe local testing without real credentials)

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram-send?chat_id=123456&text=Hello&dry_run=true'
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/telegram-send' \
  -H 'Content-Type: application/json' \
  -d '{"chat_id":"123456","text":"Hello","dry_run":true}'
```

### `telegram-ai-reply`

- Route: `/fn/telegram-ai-reply`
- Methods: `GET`, `POST`
- Goal: Telegram webhook -> OpenAI -> Telegram reply
- Default behavior: `dry_run=true` (safe local testing without sending messages)
- Env (secrets): `TELEGRAM_BOT_TOKEN`, `OPENAI_API_KEY`

Dry run example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram-ai-reply?dry_run=true' \
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

- Route: `/fn/whatsapp`
- Methods: `GET`, `POST`, `DELETE`
- Goal: WhatsApp real session manager (QR, connect, send, inbox/outbox, AI chat)
- Actions:
  - `GET /fn/whatsapp?action=qr`
  - `GET /fn/whatsapp?action=status`
  - `POST /fn/whatsapp?action=send`
  - `POST /fn/whatsapp?action=chat`
  - `GET /fn/whatsapp?action=inbox`
  - `DELETE /fn/whatsapp?action=reset-session`

WhatsApp tools (for `action=chat`):

- `WHATSAPP_TOOLS_ENABLED=true`
- `WHATSAPP_AUTO_TOOLS=true`
- `WHATSAPP_TOOL_ALLOW_FN=request-inspector,telegram-ai-digest`
- `WHATSAPP_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `WHATSAPP_TOOL_TIMEOUT_MS=5000`

### Logs (internal)

Tail OpenResty logs (requires console API access):

```bash
curl -sS 'http://127.0.0.1:8080/_fn/logs?file=error&lines=200'
curl -sS 'http://127.0.0.1:8080/_fn/logs?file=access&lines=50&format=json'
```

### `request-inspector`

- Route: `/request-inspector`
- Methods: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`
- Goal: show what the gateway passed into the handler (method/query/headers/body/context)

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

```bash
curl -sS 'http://127.0.0.1:8080/edge-proxy' | jq .
```

#### `edge-filter`

- Route: `/edge-filter`
- Goal: API key filter + rewrite + passthrough

```bash
curl -sS -i 'http://127.0.0.1:8080/edge-filter?user_id=123' | sed -n '1,12p'
curl -sS 'http://127.0.0.1:8080/edge-filter?user_id=123' -H 'x-api-key: dev' | jq .
```

#### `edge-auth-gateway`

- Route: `/edge-auth-gateway`
- Goal: Bearer auth gateway + passthrough

```bash
curl -sS -i 'http://127.0.0.1:8080/edge-auth-gateway?target=health' | sed -n '1,12p'
curl -sS 'http://127.0.0.1:8080/edge-auth-gateway?target=health' -H 'Authorization: Bearer dev-token' | jq .
```

#### `edge-header-inject`

- Route: `/edge-header-inject`
- Goal: inject headers and proxy to `/request-inspector` (so you can see them)

```bash
curl -sS 'http://127.0.0.1:8080/edge-header-inject?tenant=acme' -X POST --data 'hello' | jq .
```

#### `github-webhook-guard`

- Route: `/fn/github-webhook-guard`
- Methods: `POST`
- Goal: verify `x-hub-signature-256` (GitHub HMAC) and optionally forward
- Env: `GITHUB_WEBHOOK_SECRET` (secret)

```bash
curl -sS -i 'http://127.0.0.1:8080/fn/github-webhook-guard' \
  -X POST \
  -H 'x-hub-signature-256: sha256=bad' \
  --data '{"zen":"Keep it logically awesome.","hook_id":123}' | sed -n '1,12p'
```

### `slack-webhook`

- Route: `/fn/slack-webhook`
- Methods: `GET`
- Goal: send a Slack Incoming Webhook (safe by default)
- Default behavior: `dry_run=true`
- Env: `SLACK_WEBHOOK_URL` (secret)

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/slack-webhook?text=Hello&dry_run=true'
```

### `discord-webhook`

- Route: `/fn/discord-webhook`
- Methods: `GET`
- Goal: send a Discord webhook (safe by default)
- Default behavior: `dry_run=true`
- Env: `DISCORD_WEBHOOK_URL` (secret)

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/discord-webhook?content=Hello&dry_run=true'
```

### `notion-create-page`

- Route: `/fn/notion-create-page`
- Methods: `GET`
- Goal: create a Notion page (safe by default)
- Default behavior: `dry_run=true`
- Env: `NOTION_TOKEN` (secret)

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/notion-create-page?title=Hello&content=World&dry_run=true'
```

To send for real:

- set `dry_run=false`
- provide `parent_page_id`
- set `NOTION_TOKEN` in `fn.env.json`

## PHP runtime

### `php-profile`

- Route: `/fn/php-profile`
- Methods: `GET`
- Query: `name`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/php-profile?name=PHP'
```

Typical response:

```json
{"runtime":"php","function":"php-profile","hello":"php-PHP"}
```

## Rust runtime

### `rust-profile`

- Route: `/fn/rust-profile`
- Methods: `GET`
- Query: `name`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/rust-profile?name=Rust'
```

Typical response:

```json
{"runtime":"rust","function":"rust-profile","hello":"rust-Rust"}
```

## Operations tip

After editing function files, refresh discovery:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/_fn/reload'
```
