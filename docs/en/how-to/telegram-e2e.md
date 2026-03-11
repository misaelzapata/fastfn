# Telegram E2E (Send a Real Message)


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
## Quick View

- Complexity: Intermediate
- Typical time: 15-25 minutes
- Use this when: you need to validate real Telegram send flow end-to-end
- Outcome: token and chat wiring are verified with a real message


This guide verifies a real end-to-end path:

`fastfn` -> `telegram-send` -> Telegram Bot API -> your Telegram app.

!!! warning "Secrets"
    Do not commit real tokens. Store secrets in `fn.env.json` and keep them out of git history.

## 1) Create a bot token

1. Open Telegram and talk to **@BotFather**
2. Create a new bot and copy the token (`TELEGRAM_BOT_TOKEN`)

## 2) Configure the function secret (fastfn env)

Edit the function env (Console UI):

- Open `http://127.0.0.1:8080/console/explorer/node/telegram-send`
- Set `TELEGRAM_BOT_TOKEN` in the **Env** editor
- Mark it as `is_secret=true` so the Console won’t display it

The file on disk is:

`<FN_FUNCTIONS_ROOT>/node/telegram-send/fn.env.json`

In this repository (when running `fastfn dev examples/functions`), that path is:

`examples/functions/node/telegram-send/fn.env.json`

!!! tip "Console disabled?"
    The Console UI is disabled by default. If you run with Docker Compose, enable it with:

    - `FN_UI_ENABLED=1`
    - keep `FN_CONSOLE_LOCAL_ONLY=1` (default) so it is not exposed remotely

## 3) Get your `chat_id`

1. Send `/start` to your bot (or any message)
2. Fetch updates:

```bash
export TELEGRAM_BOT_TOKEN='...'
curl -sS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
```

Look for:

`result[].message.chat.id`

That is your `CHAT_ID`.

## 4) Send a real message via fastfn

### Option A: one-liner curl

```bash
export CHAT_ID='123456789'
curl -sS "http://127.0.0.1:8080/telegram-send?chat_id=${CHAT_ID}&text=Hello&dry_run=false"
```

Expected: JSON includes `"sent":true`.

!!! tip "Using secrets from docker-compose/.env"
    The `telegram-send` demo prefers `fn.env.json`, but it can also fall back to process env:

    - `TELEGRAM_BOT_TOKEN`
    - `TELEGRAM_API_BASE` (optional)

    This is useful if you keep secrets in a local `.env` used by Docker Compose and don't want to write them into `fn.env.json`.

    If you run `fastfn` with `docker compose`, `docker-compose.yml` already passes these variables into the container.

### Option B: manual script (recommended)

This script calls fastfn and fails if the response indicates `dry_run=true` or `sent!=true`.

```bash
CHAT_ID='123456789' TEXT='hello from fastfn' ./scripts/manual/telegram-e2e.sh
```

### Option C: docker-only script (when host loopback is blocked)

```bash
CHAT_ID='123456789' TEXT='hello from fastfn' ./scripts/manual/telegram-e2e-docker.sh
```

## 5) Optional: AI reply without setting a webhook

You can test the AI bot function without configuring a Telegram webhook by using query-mode:

```bash
export CHAT_ID='123456789'
curl -sS "http://127.0.0.1:8080/telegram-ai-reply?mode=reply&dry_run=false&chat_id=${CHAT_ID}&text=Hola"
```

This will call OpenAI and then send a reply through Telegram (requires `OPENAI_API_KEY` and `TELEGRAM_BOT_TOKEN`).

### 5.1 Tools and auto-tools (reply mode)

See also: [Tools (Function-to-Function + Limited HTTP)](./tools.md)

Manual tools:

```bash
curl -g -sS \
"http://127.0.0.1:8080/telegram-ai-reply?mode=reply&dry_run=false&chat_id=${CHAT_ID}&tools=true&text=Use%20[[http:https://api.ipify.org?format=json]]%20and%20[[fn:request-inspector?key=e2e|GET]]"
```

Auto-tools from natural language intent:

```bash
curl -sS \
"http://127.0.0.1:8080/telegram-ai-reply?mode=reply&dry_run=false&chat_id=${CHAT_ID}&tools=true&auto_tools=true&text=How%20is%20the%20weather%20today%20and%20what%20is%20my%20IP%3F"
```

Recommended env in `telegram-ai-reply/fn.env.json`:

- `TELEGRAM_TOOLS_ENABLED=true`
- `TELEGRAM_AUTO_TOOLS=true`
- `TELEGRAM_TOOL_ALLOW_FN=request-inspector,telegram-ai-digest`
- `TELEGRAM_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `TELEGRAM_TOOL_TIMEOUT_MS=5000`

### Full E2E loop (all inside `telegram-ai-reply`)

The loop now runs entirely inside the endpoint. It sends a prompt, waits for your reply via Telegram `getUpdates`, then replies via OpenAI.

```bash
curl -sS \
"http://127.0.0.1:8080/telegram-ai-reply?mode=loop&dry_run=false&chat_id=${CHAT_ID}&prompt=fastfn%20loop%20demo&wait_secs=120&max_replies=5&memory=true&force_clear_webhook=true"
```

For scheduler-style operation, you can omit `chat_id` and run loop as all-chats poller mode.

To force single-shot reply, use `mode=reply`.

Notes:
- `force_clear_webhook=true` clears an existing webhook to avoid `getUpdates` conflicts (HTTP 409).
- If you already poll Telegram elsewhere, leave `force_clear_webhook=false` and stop the other poller.
- Conversation memory is per chat and stored at `<FN_FUNCTIONS_ROOT>/node/telegram-ai-reply/.memory.json`.
- Loop offset is persisted at `<FN_FUNCTIONS_ROOT>/node/telegram-ai-reply/.loop_state.json`.
- If memory is present, the prompt instructs the model not to claim it cannot remember prior messages in the same chat.

!!! tip "Timeouts"
    `telegram-ai-reply` performs real outbound network calls (OpenAI + Telegram). Ensure it has a larger timeout in `<FN_FUNCTIONS_ROOT>/node/telegram-ai-reply/fn.config.json`, for example:

    ```json
    { "timeout_ms": 20000 }
    ```

## Notes

- `dry_run` is **true by default** in most integration demos to prevent accidental sends.
- Setting `dry_run=false` enables real sends, but only works if `TELEGRAM_BOT_TOKEN` is configured.

## Cleanup (recommended)

After the E2E check, remove secrets from the function env:

- Console: set the value to empty (or delete the key) and save.
- Or edit `<FN_FUNCTIONS_ROOT>/node/telegram-send/fn.env.json` and remove the entry.

## 6) Python variant (Telegram AI reply with tools)

This repository includes a Python version of the Telegram AI bot:

- Function: `telegram-ai-reply-py`
- Route: `/telegram-ai-reply-py`

Dry run (safe):

```bash
export CHAT_ID='123456789'
curl -sS "http://127.0.0.1:8080/telegram-ai-reply-py?mode=reply&dry_run=true&chat_id=${CHAT_ID}&text=Hola%20desde%20python&tools=true&auto_tools=true"
```

Real send:

```bash
export CHAT_ID='123456789'
curl -sS "http://127.0.0.1:8080/telegram-ai-reply-py?mode=reply&dry_run=false&chat_id=${CHAT_ID}&text=Hola%20desde%20python&tools=true&auto_tools=true"
```

Loop mode dry run:

```bash
curl -sS "http://127.0.0.1:8080/telegram-ai-reply-py?mode=loop&dry_run=true&wait_secs=20"
```

Files (created at runtime):

- `<FN_FUNCTIONS_ROOT>/python/telegram-ai-reply-py/.memory.json`
- `<FN_FUNCTIONS_ROOT>/python/telegram-ai-reply-py/.loop_state.json`

## Flow Diagram

```mermaid
flowchart LR
  A["Client request"] --> B["Route discovery"]
  B --> C["Policy and method validation"]
  C --> D["Runtime handler execution"]
  D --> E["HTTP response + OpenAPI parity"]
```

## Objective

Clear scope, expected outcome, and who should use this page.

## Prerequisites

- FastFN CLI available
- Runtime dependencies by mode verified (Docker for `fastfn dev`, OpenResty+runtimes for `fastfn dev --native`)

## Validation Checklist

- Command examples execute with expected status codes
- Routes appear in OpenAPI where applicable
- References at the end are reachable

## Troubleshooting

- If runtime is down, verify host dependencies and health endpoint
- If routes are missing, re-run discovery and check folder layout

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](run-and-test.md)
