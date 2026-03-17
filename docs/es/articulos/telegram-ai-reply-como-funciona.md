# Como funciona `telegram-ai-reply` (Paso a Paso)


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
Este articulo explica como funciona por dentro la **funcion de ejemplo** `telegram-ai-reply`:

- recibe un update de Telegram (webhook POST),
- genera una respuesta con OpenAI,
- y manda el reply via la Telegram Bot API.

Codigo: `examples/functions/node/telegram-ai-reply/app.js`

## 1) Correrlo local

Opcion A (catalogo completo de ejemplos):

```bash
bin/fastfn dev examples/functions
```

Opcion B (solo esta funcion):

```bash
bin/fastfn dev examples/functions/node/telegram-ai-reply
```

La ruta publica es:

- `POST /telegram-ai-reply`

## 2) Smoke test

Mandá un POST simulando un webhook:

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply' \
  -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message":{"chat":{"id":123},"text":"Hola"}}'
```

Si `TELEGRAM_BOT_TOKEN` y `OPENAI_API_KEY` no estan configurados, la funcion devuelve un error indicando los secretos faltantes.

## 3) Parsing del request

El handler lee:

- `event.body` (el objeto update de Telegram)
- `event.env` (env por funcion)

Extrae del update:

- `chat_id`
- `text` (texto del mensaje)
- `message_id` (para responder en thread)

Si no hay texto (stickers, fotos, etc), devuelve:

```json
{"ok":true,"skipped":true,"reason":"no text message"}
```

## 4) Flujo de respuesta: OpenAI -> Telegram sendMessage

1. Llama OpenAI Chat Completions con el texto del usuario y un system prompt.
2. Envia la respuesta via Telegram `sendMessage`.

Devuelve un resumen como:

```json
{"ok":true,"chat_id":123,"reply":"...","message_id":321}
```

## 5) Referencia de config

### Env vars

- `TELEGRAM_BOT_TOKEN` (secret, requerido)
- `OPENAI_API_KEY` (secret, requerido)
- `OPENAI_MODEL` (default: `gpt-4o-mini`)
- `SYSTEM_PROMPT` (opcional, personaliza la personalidad del bot)

## 6) Nota de seguridad

- `/_fn/*` es control-plane. En prod, restringilo (o deshabilitá la consola).
- Si exponés `telegram-ai-reply` como webhook:
  - agregá verificacion (por ejemplo un header secreto compartido)
  - ajustá timeouts (en `fn.config.json` podés subir `timeout_ms` para esta función)

Relacionado:

- [Telegram E2E](../como-hacer/telegram-e2e.md)
- [Funciones de ejemplo](../referencia/funciones-ejemplo.md)

## Idea clave

Esta es la forma más chica y útil de un bot de Telegram: entra un webhook, se lee un mensaje, se consulta a OpenAI y se responde con un `sendMessage`. Si arrancás desde cero, copiá este patrón antes de sumar memoria, tools o jobs en segundo plano.

## Qué conviene tener en cuenta

- Telegram puede mandar updates sin `message.text`; conviene saltearlos sin tratarlos como error.
- Guardá `TELEGRAM_BOT_TOKEN` y `OPENAI_API_KEY` en `fn.env.json`.
- Dale al handler tiempo suficiente para dos llamadas salientes: una a OpenAI y otra a Telegram.

## Cuándo conviene otro patrón

- Usá una función programada cuando necesites polling o digests periódicos.
- Guardá estado fuera de la request si el bot tiene que recordar algo entre mensajes.
- Agregá verificación del request antes de exponer el webhook en público.

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
