# Telegram Loop Mode: What Changed and What to Use Now


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
Older notes and screenshots may mention a self-contained Telegram loop that handled polling and replies inside one endpoint. That is no longer the default example in the repo.

Today, the recommended starting point is smaller and easier to follow:

1. Telegram sends a webhook POST to `/telegram-ai-reply`.
2. The handler reads the incoming text.
3. The function asks OpenAI for a reply.
4. The function sends that reply back with Telegram `sendMessage`.

The working example lives at `examples/functions/node/telegram-ai-reply/app.js`.

## Quick local test

Run the example catalog:

```bash
bin/fastfn dev examples/functions
```

Then send one sample webhook request:

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply' \
  -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message":{"chat":{"id":123},"text":"Hello from Telegram"}}'
```

If the function is configured correctly, it will call OpenAI and return a JSON summary of the reply it sent back to Telegram.

## If you need polling or scheduled work

Use a scheduled function instead of bringing the old loop shape back into the webhook handler.

The repo already includes `examples/functions/node/telegram-ai-digest`, which is a better starting point for timer-based Telegram work. Its schedule looks like this:

```json
"schedule": {
  "enabled": true,
  "every_seconds": 3600,
  "method": "GET"
}
```

That pattern is a better fit for:

- periodic digests,
- polling with `getUpdates`,
- cleanup jobs,
- summaries that should run even when no user is waiting on an HTTP response.

## Which shape should you choose?

- Use the webhook path when each message should trigger one immediate reply.
- Use the scheduled path when the job should run on a timer or when polling is easier than exposing a public webhook.
- Store memory outside the request if you need the bot to remember something across runs or messages.

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
