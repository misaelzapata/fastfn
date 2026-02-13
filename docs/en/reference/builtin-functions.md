# Built-in Function Catalog

This document lists the real sample functions included in the repository, with concrete request/response examples.

## Python runtime

### `cron_tick` (scheduler demo)

- Route: `/fn/cron_tick`
- Methods: `GET`
- Goal: simple counter you can increment via schedule

Read current count:

```bash
curl -sS 'http://127.0.0.1:8080/fn/cron_tick?action=read'
```

Enable schedule (every 1s) via Console API:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=cron_tick' \
  -X PUT -H 'Content-Type: application/json' \
  --data '{"schedule":{"enabled":true,"every_seconds":1,"method":"GET","query":{"action":"inc"},"headers":{},"body":"","context":{}}}'
curl -sS -X POST 'http://127.0.0.1:8080/_fn/reload'
```

Observe scheduler state:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/schedules'
```

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

### `risk_score`

- Route: `/fn/risk_score`
- Methods: `GET`, `POST`
- Inputs:
  - `query.email`
  - fallback header `x-user-email`

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/risk_score?email=user@example.com'
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/risk_score' \
  -H 'x-user-email: user@example.com' \
  -H 'Content-Type: application/json' \
  -d '{}'
```

Typical response:

```json
{"runtime":"python","function":"risk_score","score":60,"risk":"high","signals":{"email":true,"ip":"172.19.0.1"}}
```

### `slow`

- Route: `/fn/slow`
- Methods: `GET`
- Query: `sleep_ms`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/slow?sleep_ms=100'
```

### `html_demo`

- Route: `/fn/html_demo`
- Methods: `GET`
- Content-Type: `text/html; charset=utf-8`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/html_demo?name=Web'
```

### `csv_demo`

- Route: `/fn/csv_demo`
- Methods: `GET`
- Content-Type: `text/csv; charset=utf-8`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/csv_demo?name=Alice'
```

### `png_demo`

- Route: `/fn/png_demo`
- Methods: `GET`
- Content-Type: `image/png`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/png_demo' --output out.png
```

### `lambda_echo`

- Route: `/fn/lambda_echo`
- Methods: `GET`

### `custom_echo`

- Route: `/fn/custom_echo`
- Methods: `GET`
- Query: `v`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/custom_echo?v=demo'
```

### `requirements_demo`

- Route: `/fn/requirements_demo`
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

### `gmail_send`

- Route: `/fn/gmail_send`
- Methods: `GET`, `POST`
- Goal: Gmail SMTP helper for demos/integrations
- Default behavior: `dry_run=true` (safe local testing without real credentials)

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/gmail_send?to=demo@example.com&subject=Hi&text=Hello&dry_run=true'
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/gmail_send' \
  -H 'Content-Type: application/json' \
  -d '{"to":"demo@example.com","subject":"Hi","text":"Hello","dry_run":true}'
```

### `sendgrid_send`

- Route: `/fn/sendgrid_send`
- Methods: `GET`, `POST`
- Goal: SendGrid email helper (safe by default)
- Default behavior: `dry_run=true`
- Env: `SENDGRID_API_KEY` (secret), `SENDGRID_FROM`

GET (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/sendgrid_send?to=demo@example.com&subject=Hi&text=Hello&dry_run=true'
```

### `sheets_webapp_append`

- Route: `/fn/sheets_webapp_append`
- Methods: `GET`
- Goal: append a row via a Google Apps Script Web App (safe by default)
- Default behavior: `dry_run=true`
- Env: `SHEETS_WEBAPP_URL` (secret)

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/sheets_webapp_append?sheet=Sheet1&values=a,b,c&dry_run=true'
```

### `nombre`

- Route: `/fn/nombre`
- Methods: `GET` (default policy)

### `stripe_webhook_verify`

- Route: `/fn/stripe_webhook_verify`
- Methods: `POST`
- Goal: verify Stripe webhook signature (safe by default)
- Default behavior: `dry_run=true`
- Env: `STRIPE_WEBHOOK_SECRET` (secret)

Dry run:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/stripe_webhook_verify' \
  -H 'Content-Type: application/json' \
  -d '{"id":"evt_test"}'
```

Enforce verification:

- set `dry_run=false`
- include `Stripe-Signature` header
- set `STRIPE_WEBHOOK_SECRET` in `fn.env.json`

### `github_webhook_verify`

- Route: `/fn/github_webhook_verify`
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

### `node_echo`

- Route: `/fn/node_echo`
- Methods: `GET`, `POST` (editable in `fn.config.json`)
- Query: `name`

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/node_echo?name=Node'
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/node_echo?name=NodePost' \
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

### `telegram_send`

- Route: `/fn/telegram_send`
- Methods: `GET`, `POST`
- Goal: Telegram Bot API helper for demos/integrations
- Default behavior: `dry_run=true` (safe local testing without real credentials)

GET example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram_send?chat_id=123456&text=Hello&dry_run=true'
```

POST example:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/telegram_send' \
  -H 'Content-Type: application/json' \
  -d '{"chat_id":"123456","text":"Hello","dry_run":true}'
```

### `telegram_ai_reply`

- Route: `/fn/telegram_ai_reply`
- Methods: `GET`, `POST`
- Goal: Telegram webhook -> OpenAI -> Telegram reply
- Default behavior: `dry_run=true` (safe local testing without sending messages)
- Env (secrets): `TELEGRAM_BOT_TOKEN`, `OPENAI_API_KEY`

Dry run example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram_ai_reply?dry_run=true' \
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
- `TELEGRAM_TOOL_ALLOW_FN=request_inspector,telegram_ai_digest`
- `TELEGRAM_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `TELEGRAM_TOOL_TIMEOUT_MS=5000`

Manual tool directives inside user message:

- `[[fn:request_inspector?key=test|GET]]`
- `[[http:https://api.ipify.org?format=json]]`

Memory behavior:

- Per-chat memory file: `srv/fn/functions/node/telegram_ai_reply/.memory.json`
- Loop offset file: `srv/fn/functions/node/telegram_ai_reply/.loop_state.json`
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
- `WHATSAPP_TOOL_ALLOW_FN=request_inspector,telegram_ai_digest`
- `WHATSAPP_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `WHATSAPP_TOOL_TIMEOUT_MS=5000`

### Logs (internal)

Tail OpenResty logs (requires console API access):

```bash
curl -sS 'http://127.0.0.1:8080/_fn/logs?file=error&lines=200'
curl -sS 'http://127.0.0.1:8080/_fn/logs?file=access&lines=50&format=json'
```

### `request_inspector`

- Route: `/fn/request_inspector`
- Methods: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`
- Goal: show what the gateway passed into the handler (method/query/headers/body/context)

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/request_inspector?key=test' \
  -X POST \
  -H 'x-demo: 1' \
  --data 'hello'
```

### Edge / gateway patterns

These functions demonstrate a "Workers-like" pattern: validate the inbound request, rewrite it, then return a `proxy` directive.

#### `edge_proxy`

- Route: `/fn/edge_proxy`
- Goal: minimal passthrough demo (proxies to `/_fn/health`)

```bash
curl -sS 'http://127.0.0.1:8080/fn/edge_proxy' | jq .
```

#### `edge_filter`

- Route: `/fn/edge_filter`
- Goal: API key filter + rewrite + passthrough

```bash
curl -sS -i 'http://127.0.0.1:8080/fn/edge_filter?user_id=123' | sed -n '1,12p'
curl -sS 'http://127.0.0.1:8080/fn/edge_filter?user_id=123' -H 'x-api-key: dev' | jq '.openapi, .info.title'
```

#### `edge_auth_gateway`

- Route: `/fn/edge_auth_gateway`
- Goal: Bearer auth gateway + passthrough

```bash
curl -sS -i 'http://127.0.0.1:8080/fn/edge_auth_gateway?target=health' | sed -n '1,12p'
curl -sS 'http://127.0.0.1:8080/fn/edge_auth_gateway?target=health' -H 'Authorization: Bearer dev-token' | jq .
```

#### `edge_header_inject`

- Route: `/fn/edge_header_inject`
- Goal: inject headers and proxy to `/fn/request_inspector` (so you can see them)

```bash
curl -sS 'http://127.0.0.1:8080/fn/edge_header_inject?tenant=acme' -X POST --data 'hello' | jq .
```

#### `github_webhook_guard`

- Route: `/fn/github_webhook_guard`
- Methods: `POST`
- Goal: verify `x-hub-signature-256` (GitHub HMAC) and optionally forward
- Env: `GITHUB_WEBHOOK_SECRET` (secret)

```bash
curl -sS -i 'http://127.0.0.1:8080/fn/github_webhook_guard' \
  -X POST \
  -H 'x-hub-signature-256: sha256=bad' \
  --data '{"zen":"Keep it logically awesome.","hook_id":123}' | sed -n '1,12p'
```

### `slack_webhook`

- Route: `/fn/slack_webhook`
- Methods: `GET`
- Goal: send a Slack Incoming Webhook (safe by default)
- Default behavior: `dry_run=true`
- Env: `SLACK_WEBHOOK_URL` (secret)

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/slack_webhook?text=Hello&dry_run=true'
```

### `discord_webhook`

- Route: `/fn/discord_webhook`
- Methods: `GET`
- Goal: send a Discord webhook (safe by default)
- Default behavior: `dry_run=true`
- Env: `DISCORD_WEBHOOK_URL` (secret)

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/discord_webhook?content=Hello&dry_run=true'
```

### `notion_create_page`

- Route: `/fn/notion_create_page`
- Methods: `GET`
- Goal: create a Notion page (safe by default)
- Default behavior: `dry_run=true`
- Env: `NOTION_TOKEN` (secret)

Example (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/fn/notion_create_page?title=Hello&content=World&dry_run=true'
```

To send for real:

- set `dry_run=false`
- provide `parent_page_id`
- set `NOTION_TOKEN` in `fn.env.json`

## PHP runtime

### `php_profile`

- Route: `/fn/php_profile`
- Methods: `GET`
- Query: `name`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/php_profile?name=PHP'
```

Typical response:

```json
{"runtime":"php","function":"php_profile","hello":"php-PHP"}
```

## Rust runtime

### `rust_profile`

- Route: `/fn/rust_profile`
- Methods: `GET`
- Query: `name`

Example:

```bash
curl -sS 'http://127.0.0.1:8080/fn/rust_profile?name=Rust'
```

Typical response:

```json
{"runtime":"rust","function":"rust_profile","hello":"rust-Rust"}
```

## Operations tip

After editing function files, refresh discovery:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/_fn/reload'
```
