# WhatsApp Bot Demo (Real Session)

This tutorial runs a real WhatsApp Web session from a function.

## 1. Start platform

```bash
docker compose up -d --build
```

## 2. Run the first demo (QR)

```bash
curl -sS 'http://127.0.0.1:8080/fn/qr?text=HelloQR' -o /tmp/qr.svg
```

## 3. Open WhatsApp demo intro

```bash
curl -sS 'http://127.0.0.1:8080/fn/whatsapp' | jq .
```

## 4. Get login QR and scan it (auto-start)

```bash
curl -sS 'http://127.0.0.1:8080/fn/whatsapp?action=qr' --output /tmp/wa-qr.png
```

Open `/tmp/wa-qr.png` and scan from WhatsApp:
- `Settings`
- `Linked devices`
- `Link a device`

## 5. Check session status

```bash
curl -sS 'http://127.0.0.1:8080/fn/whatsapp?action=status' | jq .
```

Look for:
- `"connected": true`
- `"me": "<jid>"`

## 6. Send a message

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/whatsapp?action=send' \
  -H 'Content-Type: application/json' \
  --data '{"to":"15551234567","text":"hello from fastfn"}' | jq .
```

## 7. Read inbox/outbox

```bash
curl -sS 'http://127.0.0.1:8080/fn/whatsapp?action=inbox' | jq .
curl -sS 'http://127.0.0.1:8080/fn/whatsapp?action=outbox' | jq .
```

## 8. AI reply (optional)

Set API key in function env file:

`srv/fn/functions/node/whatsapp/fn.env.json`

```json
{
  "OPENAI_API_KEY": {"value":"sk-...","is_secret":true},
  "OPENAI_MODEL": {"value":"gpt-4o-mini","is_secret":false}
}
```

Then:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/whatsapp?action=chat' \
  -H 'Content-Type: application/json' \
  --data '{"to":"15551234567","text":"Write a short friendly reply in Spanish"}' | jq .
```

### 8.1 WhatsApp tools and auto-tools

Add optional tool env values in `srv/fn/functions/node/whatsapp/fn.env.json`:

```json
{
  "WHATSAPP_TOOLS_ENABLED": {"value":"true","is_secret":false},
  "WHATSAPP_AUTO_TOOLS": {"value":"true","is_secret":false},
  "WHATSAPP_TOOL_ALLOW_FN": {"value":"request_inspector,telegram_ai_digest","is_secret":false},
  "WHATSAPP_TOOL_ALLOW_HTTP_HOSTS": {"value":"api.ipify.org,wttr.in,ipapi.co","is_secret":false},
  "WHATSAPP_TOOL_TIMEOUT_MS": {"value":"5000","is_secret":false}
}
```

Manual tool directives:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/whatsapp?action=chat' \
  -H 'Content-Type: application/json' \
  --data '{"text":"Use [[http:https://api.ipify.org?format=json]] and [[fn:request_inspector?key=wa|GET]]"}' | jq .
```

Auto tools from natural text:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/whatsapp?action=chat' \
  -H 'Content-Type: application/json' \
  --data '{"text":"How is the weather today and what is my IP?"}' | jq .
```

## 9. Reset session

```bash
curl -sS -X DELETE 'http://127.0.0.1:8080/fn/whatsapp?action=reset-session' | jq .
```
