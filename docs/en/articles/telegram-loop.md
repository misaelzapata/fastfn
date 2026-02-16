# Telegram Loop Mode (Self-Contained)

This article explains how `telegram-ai-reply` can run a full E2E loop **inside a single endpoint**. The same URL can:

- send a prompt to your chat,
- wait for your reply using `getUpdates`,
- call OpenAI,
- and reply back to Telegram.

## Why this exists

We want to demonstrate that fastfn can handle a multi-step integration flow without any external worker or script. Everything happens inside:

`/fn/telegram-ai-reply`

## One command (loop mode)

```bash
curl -sS -X POST \
"http://127.0.0.1:8080/fn/telegram-ai-reply?mode=loop&dry_run=false&chat_id=YOUR_CHAT_ID&prompt=fastfn%20loop%20demo&wait_secs=120&max_replies=5&force_clear_webhook=true"
```

What happens:

1. fastfn sends the prompt to your Telegram chat.
2. It polls Telegram `getUpdates` for your reply.
3. It calls OpenAI and replies to your message.

If you respond inside the `wait_secs` window, you will get an AI reply back.

## Default behavior

If you call loop mode without `chat_id`, it runs in **all-chats poller mode** (scheduler-friendly): it reads incoming updates and replies per chat.

To force a single reply (no loop), use:

```bash
curl -sS -X POST \
"http://127.0.0.1:8080/fn/telegram-ai-reply?mode=reply&dry_run=false&chat_id=YOUR_CHAT_ID&text=Hola"
```

## Parameters

- `chat_id` (optional): If present, loop is restricted to one chat. If omitted, loop listens to all incoming chats.
- `prompt`: The text sent to you before waiting for a reply.
- `wait_secs`: Max time to wait for a response (default 120).
- `max_replies`: How many replies to send before the loop exits (default 5).
- `poll_ms`: Polling interval for `getUpdates` (default 2000).
- `force_clear_webhook`: If `true`, clears webhook to avoid 409 conflicts.
- `dry_run`: If `true`, no outbound calls are made.
- `memory`: `true|false` (default `true`). When enabled, uses a small per-chat memory window.
- `memory_max_turns`: How many turns to keep (default 8).
- `memory_ttl_secs`: Expire memory entries after this many seconds (default 3600).

## Common errors

`409 Conflict`:

You are already polling `getUpdates` elsewhere or have a webhook set. Use:

`force_clear_webhook=true`

or stop the other poller/webhook.

## Security note

The endpoint uses:

- `TELEGRAM_BOT_TOKEN`
- `OPENAI_API_KEY`

These can be provided in `fn.env.json` for `telegram-ai-reply`, or via container environment.

Memory is stored locally in `srv/fn/functions/node/telegram-ai-reply/.memory.json`.
Loop offset state is stored in `srv/fn/functions/node/telegram-ai-reply/.loop_state.json`.
