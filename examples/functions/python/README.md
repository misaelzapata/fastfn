# Python Examples

This folder groups Python demos that cover routing, data handling, QR generation, and auth patterns.

## Run

```bash
fastfn dev examples/functions/python
```

## Routes

| Route | Method | What it does | Needs env vars? |
|-------|--------|-------------|-----------------|
| `/hello` | GET | Minimal handler. `?name=World` | — |
| `/nombre` | GET | Same as hello, in Spanish | — |
| `/custom-echo` | GET | Echoes full event for debugging | — |
| `/lambda-echo` | GET | Same as echo, lambda-style handler | — |
| `/slow` | GET | Sleeps 2s, useful for timeout testing | — |
| `/utc-time` | GET | Current UTC time | — |
| `/offset-time` | GET | Current time with timezone offset | — |
| `/csv-demo` | GET | Returns CSV (Content-Type: text/csv) | — |
| `/html-demo` | GET | Returns HTML page | — |
| `/png-demo` | GET | Returns PNG image (base64) | — |
| `/qr` | GET | QR code as SVG. `?text=hello` | — |
| `/pack-qr` | GET | QR via shared pack (qrcode_pack). `?text=hello` | — |
| `/risk-score` | GET | Mock risk score from headers | — |
| `/requirements-demo` | GET | Shows explicit requirements.txt deps | — |
| `/session-demo` | GET | Cookie/session inspection. Send `Cookie: session_id=abc123` | — |
| `/custom-handler-demo` | GET | Custom handler name (`main` instead of `handler`) | — |
| `/cron-tick` | GET | Counter that increments. `?action=inc` | — |
| `/github-webhook-verify` | POST | GitHub webhook signature verification (dry_run by default) | `GITHUB_WEBHOOK_SECRET` |
| `/stripe-webhook-verify` | POST | Stripe webhook signature verification (dry_run by default) | `STRIPE_WEBHOOK_SECRET` |
| `/gmail-send` | GET | Send email via SMTP (dry_run by default). `?to=...&subject=...` | `GMAIL_USER`, `GMAIL_APP_PASSWORD` |
| `/sendgrid-send` | GET | Send email via SendGrid (dry_run by default) | `SENDGRID_API_KEY`, `SENDGRID_FROM` |
| `/sheets-webapp-append` | GET | Append to Google Sheets (dry_run by default) | `SHEETS_WEBAPP_URL` |
| `/telegram-ai-reply-py` | POST | Telegram AI reply bot | `TELEGRAM_BOT_TOKEN`, `OPENAI_API_KEY` |
| `/tools-loop` | GET | Agentic tool-calling loop (dry_run by default) | `OPENAI_API_KEY` (optional) |
| `/auto-infer-alias` | GET | Dependency inference with package aliases | — |
| `/auto-infer-no-requirements` | GET | Dependency inference from imports | — |
| `/auto-infer-python-multi-deps` | GET | Multi-package inference | — |

## Scheduled functions

Three functions have `schedule` in their `fn.config.json`:

- `cron-tick` — fires every N seconds (`every_seconds`)
- `utc-time` — cron expression `0 9 * * *` (UTC)
- `offset-time` — cron expression `0 9 * * *` (UTC-5)

Schedules require runtime-scoped directory layout to work (see main docs).

## Test

```bash
curl -sS 'http://127.0.0.1:8080/hello?name=Developer'
curl -sS http://127.0.0.1:8080/csv-demo
curl -sS 'http://127.0.0.1:8080/qr?text=fastfn'
curl -sS -H 'Cookie: session_id=abc123; theme=dark' http://127.0.0.1:8080/session-demo
curl -sS http://127.0.0.1:8080/cron-tick?action=inc
```

## Notes

- Functions that call external APIs default to `dry_run=true` for safety
- Webhook verification functions validate signatures without forwarding by default
- If you already know the packages, prefer `requirements.txt`; the inference demos are for fast bootstrap
