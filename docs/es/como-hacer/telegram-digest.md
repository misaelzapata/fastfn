# Telegram AI Digest (cron)

Esta funcion envia un digest periodico a tu chat de Telegram usando fuentes gratuitas (sin keys para clima/noticias) y un resumen opcional con IA.

## Funcion

- Funcion: `telegram_ai_digest`
- Ruta: `/fn/telegram_ai_digest`
- Metodos: `GET`, `POST`
- Schedule: definido en `srv/fn/functions/node/telegram_ai_digest/fn.config.json`

## Configurar secretos

Editar `srv/fn/functions/node/telegram_ai_digest/fn.env.json`:

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- `OPENAI_API_KEY`

`OPENAI_API_KEY` es opcional: si falta, se envia el digest sin reescritura IA.

## Cron schedule

El schedule vive en `fn.config.json`:

```json
"schedule": {
  "enabled": true,
  "every_seconds": 60,
  "method": "GET",
  "query": {"dry_run": "false"},
  "context": {"type": "cron"}
}
```

Para desactivar:

```json
"enabled": false
```

## Test manual

Dry run:

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram_ai_digest?chat_id=1160337817&dry_run=true'
```

Enviar al celular:

```bash
curl -sS 'http://127.0.0.1:8080/fn/telegram_ai_digest?chat_id=1160337817&dry_run=false'
```

Opciones:

- `include_ai=true|false` (default `false`)
- `include_weather=true|false` (default `true`)
- `include_news=true|false` (default `true`)
- `max_items=5` (1–10)
- `min_interval_secs=60` (0–86400). Con `0` envia siempre.

## Que envia

- Clima: Open‑Meteo (sin API key)
- Noticias: Google News RSS (sin API key)
- Ubicacion: por IP del caller (ipapi.co)
- Idioma: inferido por pais (es/en)
 - Formato: HTML (mejor render en Telegram)

## Ejemplo de respuesta

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
