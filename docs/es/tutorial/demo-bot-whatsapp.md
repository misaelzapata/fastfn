# Demo Bot de WhatsApp (Sesion Real)

Esta guia ejecuta una sesion real de WhatsApp Web desde una funcion Node.

## 1. Iniciar plataforma

```bash
docker compose up -d --build
```

## 2. Probar primero el demo QR

```bash
curl -sS 'http://127.0.0.1:8080/fn/qr?text=HolaQR' -o /tmp/qr.svg
```

## 3. Ver intro del demo WhatsApp

```bash
curl -sS 'http://127.0.0.1:8080/fn/whatsapp' | jq .
```

## 4. Pedir QR (auto-inicia conexion)

```bash
curl -sS 'http://127.0.0.1:8080/fn/whatsapp?action=qr' --output /tmp/wa-qr.png
```

Escanea `/tmp/wa-qr.png` desde WhatsApp:
- `Configuracion`
- `Dispositivos vinculados`
- `Vincular dispositivo`

## 5. Ver estado de sesion

```bash
curl -sS 'http://127.0.0.1:8080/fn/whatsapp?action=status' | jq .
```

Debes ver:
- `"connected": true`
- `"me": "<jid>"`

## 6. Enviar mensaje

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/whatsapp?action=send' \
  -H 'Content-Type: application/json' \
  --data '{"to":"15551234567","text":"hola desde fastfn"}' | jq .
```

## 7. Leer inbox/outbox

```bash
curl -sS 'http://127.0.0.1:8080/fn/whatsapp?action=inbox' | jq .
curl -sS 'http://127.0.0.1:8080/fn/whatsapp?action=outbox' | jq .
```

## 8. Respuesta AI (opcional)

Configura `fn.env.json` de la funcion:

`srv/fn/functions/node/whatsapp/fn.env.json`

```json
{
  "OPENAI_API_KEY": {"value":"sk-...","is_secret":true},
  "OPENAI_MODEL": {"value":"gpt-4o-mini","is_secret":false}
}
```

Luego:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/whatsapp?action=chat' \
  -H 'Content-Type: application/json' \
  --data '{"to":"15551234567","text":"Responde breve y amable en espanol"}' | jq .
```

### 8.1 Tools y auto-tools en WhatsApp

Agrega env opcional en `srv/fn/functions/node/whatsapp/fn.env.json`:

```json
{
  "WHATSAPP_TOOLS_ENABLED": {"value":"true","is_secret":false},
  "WHATSAPP_AUTO_TOOLS": {"value":"true","is_secret":false},
  "WHATSAPP_TOOL_ALLOW_FN": {"value":"request-inspector,telegram-ai-digest","is_secret":false},
  "WHATSAPP_TOOL_ALLOW_HTTP_HOSTS": {"value":"api.ipify.org,wttr.in,ipapi.co","is_secret":false},
  "WHATSAPP_TOOL_TIMEOUT_MS": {"value":"5000","is_secret":false}
}
```

Directivas manuales:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/whatsapp?action=chat' \
  -H 'Content-Type: application/json' \
  --data '{"text":"Usa [[http:https://api.ipify.org?format=json]] y [[fn:request-inspector?key=wa|GET]]"}' | jq .
```

Auto-tools desde texto natural:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/whatsapp?action=chat' \
  -H 'Content-Type: application/json' \
  --data '{"text":"Como esta el clima hoy y cual es mi IP?"}' | jq .
```

## 9. Resetear sesion

```bash
curl -sS -X DELETE 'http://127.0.0.1:8080/fn/whatsapp?action=reset-session' | jq .
```
