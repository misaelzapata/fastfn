# Node Examples

This folder groups Node.js demos that cover routes, auth, edge patterns, and integrations.

## Run

```bash
fastfn dev examples/functions/node
```

## Routes

### Basic handlers

| Route | Method | What it does |
|-------|--------|-------------|
| `/node-echo` | GET | Minimal handler. `?name=Node` |
| `/echo` | GET | Echoes query and context. `?key=value` |
| `/hello/v2` | GET | Versioned routing. `?name=World` |
| `/custom-handler-demo` | GET | Custom handler name (`main`) |
| `/request-inspector` | GET/POST/PUT/PATCH/DELETE | Echoes full request details |
| `/session-demo` | GET | Cookie/session inspection. Send `Cookie: session_id=abc123` |
| `/ts-hello` | GET | TypeScript handler via shared ts_pack. `?name=World` |

### Edge/gateway patterns

| Route | Method | What it does | Needs env vars? |
|-------|--------|-------------|-----------------|
| `/edge-proxy` | GET | Passthrough proxy | — |
| `/edge-filter` | GET | Auth + rewrite + passthrough | — |
| `/edge-header-inject` | GET | Injects headers, proxies to `/request-inspector`. `?tenant=acme` | — |
| `/edge-auth-gateway` | GET | Auth gateway. Requires `Authorization: Bearer` header | — |

### Integrations (dry_run=true by default)

| Route | Method | What it does | Needs env vars? |
|-------|--------|-------------|-----------------|
| `/slack-webhook` | GET | Send Slack message. `?text=hello` | `SLACK_WEBHOOK_URL` |
| `/discord-webhook` | GET | Send Discord message. `?content=hello` | `DISCORD_WEBHOOK_URL` |
| `/telegram-send` | GET | Send Telegram message. `?chat_id=...&text=hello` | `TELEGRAM_BOT_TOKEN` |
| `/telegram-ai-reply` | POST | Telegram AI reply bot | `TELEGRAM_BOT_TOKEN`, `OPENAI_API_KEY` |
| `/telegram-ai-digest` | GET | Scheduled Telegram digest | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `OPENAI_API_KEY` |
| `/notion-create-page` | GET | Create Notion page. `?title=...&content=...` | `NOTION_TOKEN` |
| `/github-webhook-guard` | POST | GitHub webhook signature check | `GITHUB_WEBHOOK_SECRET` |

### AI and tools

| Route | Method | What it does | Needs env vars? |
|-------|--------|-------------|-----------------|
| `/ai-tool-agent` | GET/POST | Tool-calling agent. `?text=...` | `OPENAI_API_KEY` (optional) |
| `/toolbox-bot` | GET/POST | Tool directives via `[[http:...]]` and `[[fn:...]]` | — |
| `/whatsapp` | GET/POST/DELETE | WhatsApp bot with session management | `OPENAI_API_KEY` |

### QR and images

| Route | Method | What it does |
|-------|--------|-------------|
| `/qr/v2` | GET | QR code as PNG. `?text=hello&size=320` |
| `/pack-qr-node` | GET | QR via shared pack (qrcode_pack). `?text=hello` |

### Dependency inference demos

| Route | Method | What it does |
|-------|--------|-------------|
| `/auto-infer-create-package` | GET | Infers deps and creates package.json |
| `/auto-infer-update-package` | GET | Infers deps and updates existing package.json |
| `/auto-infer-node-multi-deps` | GET | Multi-package inference demo |

## Test

```bash
curl -sS 'http://127.0.0.1:8080/node-echo?name=Test'
curl -sS http://127.0.0.1:8080/hello/v2
curl -sS http://127.0.0.1:8080/request-inspector
curl -sS -H 'Cookie: session_id=abc; theme=dark' http://127.0.0.1:8080/session-demo
curl -sS 'http://127.0.0.1:8080/slack-webhook?text=hello&dry_run=true'
curl -sS 'http://127.0.0.1:8080/qr/v2?text=fastfn'
```

## Notes

- Integration functions default to `dry_run=true` — they log what they would do without calling the real API
- Edge functions demonstrate gateway patterns (auth, proxy, header injection) using FastFN's edge config
- Dependencies auto-install from `package.json`; inference is optional and best for quick bootstrap
