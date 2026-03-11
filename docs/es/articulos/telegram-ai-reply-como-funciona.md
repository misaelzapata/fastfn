# Como funciona `telegram-ai-reply` (Paso a Paso)


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
Este articulo explica como funciona por dentro la **funcion de ejemplo** `telegram-ai-reply`:

- recibe un update de Telegram (webhook) o un request simple en modo query,
- genera una respuesta con OpenAI,
- y manda el reply via la Telegram Bot API.

Es **segura por defecto**: `dry_run` es `true` si no lo seteas.

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
- `GET /telegram-ai-reply` (modo query)

## 2) Smoke test seguro (dry run)

Estilo webhook (POST body con un update de Telegram):

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply?dry_run=true' \
  -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message":{"chat":{"id":123},"text":"Hola"}}'
```

Respuesta esperada (forma):

```json
{"ok":true,"dry_run":true,"chat_id":123,"received_text":"Hola","note":"..."}
```

Modo query (util para testear sin configurar webhook):

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply?mode=reply&dry_run=true&chat_id=123&text=Hola'
```

## 3) Parsing del request: webhook vs modo query

El handler arranca leyendo:

- `event.query` (query string)
- `event.body` (string u object)
- `event.env` (env por funcion)
- `event.context` (request id, timeouts, trigger del scheduler, etc)

Luego elige el input:

1. **Webhook update** (`event.body` es JSON valido): extrae:
   - `chat_id`
   - `text` (texto o caption)
   - `message_id` (para responder en thread)
2. **Modo query** (no hay JSON): usa `chat_id` + `text` desde el query string

Si falta `chat_id`, devuelve:

```json
{"ok":true,"note":"no chat_id provided; nothing to do"}
```

Si no hay texto, devuelve:

```json
{"ok":true,"chat_id":123,"note":"no text in update; nothing to do"}
```

## 4) Gate de `dry_run` (para no spamear Telegram)

Antes de hacer llamadas externas, chequea `dry_run`:

- default: `dry_run=true`
- envio real: `dry_run=false`

En dry run, responde `200` y no llama ni Telegram ni OpenAI.

## 5) Modo reply: OpenAI -> Telegram sendMessage

Con `dry_run=false`, en reply hace:

1. Opcional: “thinking” (typing o texto).
2. Arma el prompt de OpenAI:
   - system prompt (`OPENAI_SYSTEM_PROMPT`)
   - memoria por chat (opcional)
   - contexto de tools (opcional)
3. Llama OpenAI Chat Completions (`/v1/chat/completions`).
4. Envia el mensaje a Telegram (`sendMessage`).
5. Persiste memoria (solo si el send fue OK).

Devuelve un resumen como:

```json
{"ok":true,"dry_run":false,"chat_id":123,"reply_preview":"...","telegram":{"message_id":321}}
```

## 6) Modo loop (polling + reply auto-contenido)

El modo loop existe para demostrar un flow E2E completo **en un solo endpoint**:

- manda un prompt inicial (opcional),
- hace polling de `getUpdates`,
- llama OpenAI,
- responde,
- persiste `last_update_id` para no reprocesar updates.

Para habilitar loop (env):

- `TELEGRAM_LOOP_ENABLED=true`

Llamada (dry run):

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply?mode=loop&dry_run=true'
```

Mecanismos internos:

- lock file (`.loop.lock`) para evitar loops concurrentes.
- state file (`.loop_state.json`) con `last_update_id`.
- `force_clear_webhook=true` puede ejecutar `deleteWebhook` para evitar `409 Conflict`.

Relacionado: [Telegram Loop](../articulos/telegram-loop.md)

## 7) Indicador de “thinking”

Opcional, controlado por:

- `TELEGRAM_SHOW_THINKING=true`
- `TELEGRAM_THINKING_MODE=typing|text` (default: `typing`)
- `TELEGRAM_THINKING_TEXT=Escribiendo...` (si `mode=text`)
- `TELEGRAM_THINKING_MIN_MS=600` (para que el typing parezca real)

## 8) Tools: fetches controlados (allowlists)

Si esta habilitado, puede ejecutar “tools” antes de llamar a OpenAI y agregar un bloque `[Tool results]` al mensaje.

Habilitar tools:

- `TELEGRAM_TOOLS_ENABLED=true`

Seleccion de tools:

1. Directivas manuales dentro del texto:
   - `[[http:https://api.ipify.org?format=json]]`
   - `[[fn:request-inspector?key=e2e|GET]]`
2. Auto-tools (deteccion simple de intencion):
   - `TELEGRAM_AUTO_TOOLS=true`

Seguridad (allowlists):

- `TELEGRAM_TOOL_ALLOW_FN=request-inspector,telegram-ai-digest,cron-tick`
- `TELEGRAM_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `TELEGRAM_TOOL_TIMEOUT_MS=20000`

Importante: tools no es “internet libre”. El codigo valida allowlists.

Si quieres probar directivas de tools **sin** Telegram/OpenAI, usa el demo:

- `GET /toolbox-bot` (plan + resultados como JSON)

Ver: [Herramientas (Función-a-Función + HTTP Limitado)](../como-hacer/herramientas.md)

## 9) Memoria: historial por chat en disco

Con memoria habilitada (default `memory=true`), guarda un historial por chat en:

- `<FN_FUNCTIONS_ROOT>/node/telegram-ai-reply/.memory.json`

Comportamiento:

- Solo persiste si el envio a Telegram fue OK.
- Limita por `memory_max_turns` (default: 8).
- Expira por `memory_ttl_secs` (default: 3600s).

## 10) Referencia de config

### Query params

- `dry_run=true|false` (default `true`)
- `mode=reply|loop`
- `chat_id=<id>`
- `text=<mensaje>`
- `tools=true|false`
- `auto_tools=true|false`
- `tool_timeout_ms=<ms>`
- `tool_allow_fn=...` (CSV)
- `tool_allow_hosts=...` (CSV)
- `memory=true|false`
- `memory_max_turns=<n>`
- `memory_ttl_secs=<n>`
- Loop:
  - `prompt=...`
  - `wait_secs=<n>`
  - `poll_ms=<n>`
  - `max_replies=<n>`
  - `force_clear_webhook=true|false`
  - `loop_token=...` (si está configurado)

### Env vars

- Telegram:
  - `TELEGRAM_BOT_TOKEN` (secret, requerido para enviar)
  - `TELEGRAM_API_BASE` (default: `https://api.telegram.org`)
  - `TELEGRAM_HTTP_TIMEOUT_MS` (default: `15000`)
  - `TELEGRAM_LOOP_ENABLED` (default: `false`)
  - `TELEGRAM_LOOP_TOKEN` (opcional)
- OpenAI:
  - `OPENAI_API_KEY` (secret, requerido)
  - `OPENAI_BASE_URL` (default: `https://api.openai.com/v1`)
  - `OPENAI_MODEL` (default: `gpt-4o-mini`)
  - `OPENAI_SYSTEM_PROMPT` (opcional)
  - `OPENAI_TOOL_MODEL` (opcional)

## 11) Nota de seguridad (si lo expones a internet)

- Mantén `dry_run=true` hasta estar listo.
- `/_fn/*` es control-plane. En prod, restríngelo (o deshabilita la consola).
- Si expones `telegram-ai-reply` como webhook:
  - agrega verificacion (por ejemplo un header secreto compartido)
  - mantené allowlists de tools bien estrictas
  - ajusta timeouts (en `fn.config.json` puedes subir `timeout_ms` para esta función)

Relacionado:

- [Telegram E2E](../como-hacer/telegram-e2e.md)
- [Funciones de ejemplo](../referencia/funciones-ejemplo.md)

## Diagrama de Flujo

```mermaid
flowchart LR
  A["Request del cliente"] --> B["Discovery de rutas"]
  B --> C["Validación de políticas y método"]
  C --> D["Ejecución del handler runtime"]
  D --> E["Respuesta HTTP + paridad OpenAPI"]
```

## Problema

Qué dolor operativo o de DX resuelve este tema.

## Modelo Mental

Cómo razonar esta feature en entornos similares a producción.

## Decisiones de Diseño

- Por qué existe este comportamiento
- Qué tradeoffs se aceptan
- Cuándo conviene una alternativa

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
