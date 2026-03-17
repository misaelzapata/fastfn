# How `telegram-ai-reply` Works (Step-by-Step)


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
This article explains how the **example function** `telegram-ai-reply` works internally:

- it accepts a Telegram webhook update (POST),
- generates a reply with OpenAI,
- and sends the reply back via the Telegram Bot API.

Code: `examples/functions/node/telegram-ai-reply/app.js`

## 1) Run it locally

Run the full example catalog:

```bash
bin/fastfn dev examples/functions
```

Or run just this function folder:

```bash
bin/fastfn dev examples/functions/node/telegram-ai-reply
```

The public route is:

- `POST /telegram-ai-reply`

## 2) Smoke test

Send a simulated webhook POST:

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply' \
  -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message":{"chat":{"id":123},"text":"Hola"}}'
```

If `TELEGRAM_BOT_TOKEN` and `OPENAI_API_KEY` are not configured, the function returns an error indicating the missing secrets.

## 3) Request parsing

The handler reads:

- `event.body` (the Telegram update object)
- `event.env` (per-function env)

It extracts from the update:

- `chat_id`
- `text` (message text)
- `message_id` (for threaded replies)

If the message has no text (e.g. stickers, photos), it returns:

```json
{"ok":true,"skipped":true,"reason":"no text message"}
```

## 4) Reply flow: OpenAI -> Telegram sendMessage

1. Call OpenAI Chat Completions with the user text and a system prompt.
2. Send the reply back via Telegram `sendMessage`.

It returns a JSON summary like:

```json
{"ok":true,"chat_id":123,"reply":"...","message_id":321}
```

## 5) Config reference

### Environment variables

- `TELEGRAM_BOT_TOKEN` (secret, required)
- `OPENAI_API_KEY` (secret, required)
- `OPENAI_MODEL` (default: `gpt-4o-mini`)
- `SYSTEM_PROMPT` (optional, customizes the AI personality)

## 6) Security notes

- Treat `/_fn/*` as a control-plane. In production, restrict it (or disable the console UI).
- If you expose `telegram-ai-reply` publicly as a webhook:
  - add your own verification (for example, check a shared secret header)
  - keep timeouts reasonable (`fn.config.json` can raise `timeout_ms` for this function)

Related:

- [Telegram E2E](../how-to/telegram-e2e.md)
- [Example Function Catalog](../reference/builtin-functions.md)

## Key takeaway

This is the smallest useful Telegram bot shape: accept one webhook request, read one message, ask OpenAI for a reply, send one `sendMessage` call back. If you are starting from zero, copy this pattern before adding memory, tools, or background jobs.

## What to keep in mind

- Telegram may send updates without `message.text`; skip them cleanly instead of treating them as failures.
- Keep `TELEGRAM_BOT_TOKEN` and `OPENAI_API_KEY` in `fn.env.json`.
- Give the function enough timeout budget for two outbound calls: one to OpenAI and one to Telegram.

## When to use another Telegram pattern

- Use a scheduled function when you need polling or periodic digests.
- Store conversation state outside the request if you need memory across messages.
- Add request verification before exposing the webhook publicly.

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
