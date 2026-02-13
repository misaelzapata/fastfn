# Telegram AI Digest (cron)

This function sends a periodic digest to your Telegram chat using free sources (no API keys required for weather/news) and optional AI summarization.

## Function

- Function: `telegram_ai_digest`
- Route: `/fn/telegram_ai_digest`
- Methods: `GET`, `POST`
- Schedule: defined in `srv/fn/functions/node/telegram_ai_digest/fn.config.json`

## Configure secrets

Edit `srv/fn/functions/node/telegram_ai_digest/fn.env.json`:

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- `OPENAI_API_KEY`

`OPENAI_API_KEY` is optional: if missing, the digest is sent without AI rewriting.

## Cron schedule

The cron schedule is defined per function in `fn.config.json`:

```json
"schedule": {
  "enabled": true,
  "every_seconds": 60,
  "method": "GET",
  "query": {"dry_run": "false"},
  "context": {"type": "cron"}
}
```

To disable:

```json
"enabled": false
```

## Manual test

Dry run:

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram_ai_digest?chat_id=1160337817&dry_run=true'
```

Send to your phone:

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram_ai_digest?chat_id=1160337817&dry_run=false'
```

Optional query flags:

- `include_ai=true|false` (default `false`)
- `include_weather=true|false` (default `true`)
- `include_news=true|false` (default `true`)
- `max_items=5` (1–10)
- `min_interval_secs=60` (0–86400). Set `0` to send every time.

## What it sends

- Weather: Open‑Meteo (no API key)
- News: Google News RSS (no API key)
- Location: derived from caller IP (ipapi.co)
- Language: inferred from country (es/en)
 - Format: HTML (for clean formatting in Telegram)

## Response example

```json
{
  "ok": true,
  "dry_run": false,
  "chat_id": "1160337817",
  "used_ai": true,
  "telegram": {"message_id": 123},
  "preview": "..."
}
```
