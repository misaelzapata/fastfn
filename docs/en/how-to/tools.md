# Tools (Function-to-Function + Limited HTTP)

FastFN "tools" are a **safe, opt-in** pattern used by some example bots (Telegram, WhatsApp) to:

- call other FastFN functions (`fn` tool), and
- fetch a small set of allowlisted URLs (`http` tool),

then pass those results into an AI prompt (or return them directly).

This guide shows the **exact directive syntax**, the **allowlist knobs**, and how to test it locally.

## 1) Run the examples

Recommended (multi-route app + showcase):

```bash
bin/fastfn dev examples/functions/next-style
```

Full example catalog (includes `toolbox-bot`):

```bash
bin/fastfn dev examples/functions
```

## 2) Tool directive syntax

Some example functions parse tool directives inside user text.

### 2.1 `http` tool

Fetch a URL (GET only):

- `[[http:https://api.ipify.org?format=json]]`

### 2.2 `fn` tool

Invoke another FastFN function by name:

- `[[fn:request-inspector?key=demo|GET]]`

Format:

- `[[fn:<function-name>?<query>|<METHOD>]]`
- `?query` and `|METHOD` are optional (defaults to `GET`)

## 3) Safest way to test: `toolbox-bot`

`toolbox-bot` is a small demo function that **returns the tool plan and results as JSON**, without requiring Telegram/OpenAI.

- Route: `GET /toolbox-bot`, `POST /toolbox-bot`
- Source: `examples/functions/node/toolbox-bot/app.js`

Note: `curl` treats `[` and `]` as URL "ranges" (globbing). Examples that include `[[...]]` in the URL use `curl -g` to disable globbing.

### 3.1 Plan-only (no outbound calls)

```bash
curl -g -sS \
"http://127.0.0.1:8080/toolbox-bot?dry_run=true&text=Use%20[[http:https://api.ipify.org?format=json]]%20and%20[[fn:request-inspector?key=demo|GET]]"
```

Expected response shape:

```json
{
  "ok": true,
  "dry_run": true,
  "plan": [
    { "type": "fn", "name": "request-inspector", "query": "?key=demo", "method": "GET" },
    { "type": "http", "url": "https://api.ipify.org?format=json" }
  ],
  "note": "Set dry_run=false to execute tools."
}
```

### 3.2 Execute tools (allowlisted only)

```bash
curl -g -sS \
"http://127.0.0.1:8080/toolbox-bot?dry_run=false&text=Use%20[[http:https://api.ipify.org?format=json]]%20and%20[[fn:request-inspector?key=demo|GET]]"
```

Expected result entries:

- `ok`, `status`, `elapsed_ms`
- `body` (truncated)
- `json` (parsed when `Content-Type` is JSON)

## 4) Auto-tools (intent-based selection)

If you do **not** include directives, you can enable auto-tools:

```bash
curl -sS \
"http://127.0.0.1:8080/toolbox-bot?dry_run=true&auto_tools=true&text=what%20is%20my%20ip%20and%20weather%20in%20Buenos%20Aires%3F"
```

Auto-tools are intentionally simple (keyword-based). If the bot picks nothing, use manual directives.

## 5) Allowlists (security controls)

Tools are never "open internet access".

### 5.1 Function allowlist (`fn` tool)

- Query override: `tool_allow_fn=request-inspector,telegram-ai-digest`
- Env default (per-function): `TOOLBOX_TOOL_ALLOW_FN=...`

Only names matching `[A-Za-z0-9_-]+` are accepted.

### 5.2 HTTP host allowlist (`http` tool)

- Query override: `tool_allow_hosts=api.ipify.org,wttr.in`
- Env default (per-function): `TOOLBOX_TOOL_ALLOW_HTTP_HOSTS=...`

Only URLs whose hostname matches the allowlist are fetched.

### 5.3 Timeout

- Query override: `tool_timeout_ms=5000`
- Env default (per-function): `TOOLBOX_TOOL_TIMEOUT_MS=5000`

## 6) Where tools are used

These examples support tools:

- `telegram-ai-reply` (Node): `TELEGRAM_*` tool knobs
- `telegram-ai-reply-py` (Python): tool query params + allowlists
- `whatsapp` (Node): `action=chat` + `WHATSAPP_*` tool knobs

See also:

- [How `telegram-ai-reply` Works](../articles/telegram-ai-reply-how-it-works.md)
- [WhatsApp Bot](../tutorial/whatsapp-bot-demo.md)

## 7) Production note

`/_fn/*` is the control-plane (config, reload, logs, health, OpenAPI toggles).

For production deployments, treat `/_fn/*` like an admin interface:

- restrict it by IP / auth / VPN,
- do not expose it to the public internet.
