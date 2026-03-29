# Scheduled Telegram Bots with FastFN


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
## Why this article exists

Use a scheduled Telegram function when the work should happen on a timer: polling for updates, sending digests, or generating summaries for a chat. The repo includes `telegram-ai-digest`, a working example that reads recent Telegram messages, asks OpenAI for a summary, and posts the digest back to Telegram.

If you need one immediate reply per incoming message, see [How `telegram-ai-reply` Works](telegram-ai-reply-how-it-works.md).

## Quick docs map
- First run platform: [Run & Test](../how-to/run-and-test.md)
- Full Telegram setup: [Telegram E2E](../how-to/telegram-e2e.md)
- Function file format: [Function Spec](../reference/function-spec.md)
- Internal endpoints used here (`/_fn/reload`, `/_fn/schedules`): [HTTP API](../reference/http-api.md)
- Runtime behavior and payload contract: [Runtime Contract](../reference/runtime-contract.md)
- Full request lifecycle: [Invocation Flow](../explanation/invocation-flow.md)

## Architecture

```text
Telegram chat
  -> Telegram Bot API (getUpdates)
  -> FastFN schedule
  -> telegram-ai-digest
  -> OpenAI
  -> Telegram Bot API (sendMessage)
  -> Telegram chat
```

## Prerequisites
- Docker Desktop running
- Telegram bot token from `@BotFather`
- Telegram chat ID for the destination chat
- OpenAI API key

Optional but recommended:
- console enabled only locally (`FN_UI_ENABLED=1`, `FN_CONSOLE_LOCAL_ONLY=1`)

## Step 1: Start FastFN

```bash
docker compose up -d --build
curl -sS http://127.0.0.1:8080/_fn/health
```

Expected:
- `node` and `python` runtimes reported as up.

## Step 2: Configure function secrets
Edit `<FN_FUNCTIONS_ROOT>/telegram-ai-digest/fn.env.json`:

```json
{
  "TELEGRAM_BOT_TOKEN": { "value": "<set-me>", "is_secret": true },
  "TELEGRAM_CHAT_ID": { "value": "<set-me>", "is_secret": false },
  "OPENAI_API_KEY": { "value": "<set-me>", "is_secret": true }
}
```

Notes:
- Keep real secrets with `is_secret: true`.
- Function env values are exposed at runtime as `event.env`.

## Step 3: Review the schedule

The example runs on an interval from `telegram-ai-digest/fn.config.json`:

```json
"schedule": {
  "enabled": true,
  "every_seconds": 3600,
  "method": "GET"
}
```

Change the interval to match your use case, then reload.

## Step 4: Run the function once by hand

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-digest'
```

Example response:

```json
{
  "ok": true,
  "message_count": 42,
  "digest": "Daily Digest (2026-03-17T12:00 UTC)\n\n..."
}
```

## Step 5: Hot reload instead of restart

```bash
curl -sS -X POST http://127.0.0.1:8080/_fn/reload
```

You usually do not need a container restart for function code/config/env edits.

## Step 6: Verify scheduler status

```bash
curl -sS http://127.0.0.1:8080/_fn/schedules
```

## Production-minded checklist
1. `/_fn/health` shows runtimes up.
2. Secrets are in `fn.env.json` with `is_secret=true`.
3. Only one polling source is active for the same bot token.
4. If you need memory across runs, store it outside the request in a database, file, or another durable store.

## Related docs
- [Telegram E2E](../how-to/telegram-e2e.md)
- [Telegram Digest (Cron)](../how-to/telegram-digest.md)
- [HTTP API](../reference/http-api.md)
- [Function Spec](../reference/function-spec.md)
- [Architecture](../explanation/architecture.md)

## Key takeaway

Scheduled Telegram work is a different shape from webhook replies. Use it when your bot needs to wake up on a timer, read recent activity, and publish a result without waiting for an incoming HTTP request.

## What to keep in mind

- Scheduled jobs are a good fit for digests, polling, cleanup, and other background work.
- Keep polling, deduplication, and storage concerns explicit instead of hiding them inside a webhook handler.
- Put durable state outside the request if the bot needs to remember something between runs.

## When to choose the webhook path instead

- Use the webhook guide when each incoming Telegram message should trigger one immediate reply.
- Use the scheduled path when the job is periodic or when polling is easier than exposing a public webhook.
- Combine both only when the responsibilities are clearly separated.

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
