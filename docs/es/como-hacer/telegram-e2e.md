# Telegram E2E (Enviar un Mensaje Real)

Esta guia verifica un camino real end-to-end:

`fastfn` -> `telegram-send` -> Telegram Bot API -> tu app de Telegram.

!!! warning "Secretos"
    No commitees tokens reales. Guarda secretos en `fn.env.json` y mantenelos fuera del historial de git.

## 1) Crear un bot token

1. Abrí Telegram y hablá con **@BotFather**
2. Creá un bot nuevo y copiá el token (`TELEGRAM_BOT_TOKEN`)

## 2) Configurar el secreto de la funcion (env de fastfn)

Editá el env de la funcion (Console UI):

- Abrí `http://127.0.0.1:8080/console/explorer/node/telegram-send`
- Seteá `TELEGRAM_BOT_TOKEN` en el editor **Env**
- Marcá `is_secret=true` para que la consola no muestre el valor

El archivo en disco es:

`<FN_FUNCTIONS_ROOT>/node/telegram-send/fn.env.json`

En este repo (corriendo `fastfn dev examples/functions`), ese path es:

`examples/functions/node/telegram-send/fn.env.json`

!!! tip "Consola deshabilitada?"
    La Console UI viene deshabilitada por defecto. Si corrés con Docker Compose, habilitala con:

    - `FN_UI_ENABLED=1`
    - mantené `FN_CONSOLE_LOCAL_ONLY=1` (default) para que no se exponga remoto

## 3) Obtener tu `chat_id`

1. Mandale `/start` al bot (o cualquier mensaje)
2. Pedí updates:

```bash
export TELEGRAM_BOT_TOKEN='...'
curl -sS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
```

Buscá:

`result[].message.chat.id`

Ese es tu `CHAT_ID`.

## 4) Enviar un mensaje real via fastfn

### Opcion A: curl

```bash
export CHAT_ID='123456789'
curl -sS "http://127.0.0.1:8080/fn/telegram-send?chat_id=${CHAT_ID}&text=Hola&dry_run=false"
```

Esperado: el JSON incluye `"sent":true`.

!!! tip "Usar secretos desde docker-compose/.env"
    El demo `telegram-send` prefiere `fn.env.json`, pero también puede hacer fallback a variables de entorno del proceso:

    - `TELEGRAM_BOT_TOKEN`
    - `TELEGRAM_API_BASE` (opcional)

    Esto sirve si guardás secretos en un `.env` local usado por Docker Compose y no querés escribirlos en `fn.env.json`.

    Si corrés `fastfn` con `docker compose`, `docker-compose.yml` ya pasa estas variables al contenedor.

### Opcion B: script manual (recomendado)

Este script llama fastfn y falla si la respuesta indica `dry_run=true` o `sent!=true`.

```bash
CHAT_ID='123456789' TEXT='hola desde fastfn' ./scripts/manual/telegram-e2e.sh
```

### Opcion C: script solo-docker (cuando el loopback del host esta bloqueado)

```bash
CHAT_ID='123456789' TEXT='hola desde fastfn' ./scripts/manual/telegram-e2e-docker.sh
```

## 5) Opcional: AI reply sin configurar webhook

Podés probar el bot con IA sin configurar un webhook usando modo query:

```bash
export CHAT_ID='123456789'
curl -sS "http://127.0.0.1:8080/fn/telegram-ai-reply?mode=reply&dry_run=false&chat_id=${CHAT_ID}&text=Hola"
```

Esto llama a OpenAI y luego responde por Telegram (requiere `OPENAI_API_KEY` y `TELEGRAM_BOT_TOKEN`).

### 5.1 Tools y auto-tools (modo reply)

Tools manuales:

```bash
curl -sS \
"http://127.0.0.1:8080/fn/telegram-ai-reply?mode=reply&dry_run=false&chat_id=${CHAT_ID}&tools=true&text=Usa%20[[http:https://api.ipify.org?format=json]]%20y%20[[fn:request-inspector?key=e2e|GET]]"
```

Auto-tools desde lenguaje natural:

```bash
curl -sS \
"http://127.0.0.1:8080/fn/telegram-ai-reply?mode=reply&dry_run=false&chat_id=${CHAT_ID}&tools=true&auto_tools=true&text=Como%20esta%20el%20clima%20hoy%20y%20cual%20es%20mi%20IP%3F"
```

Env recomendado en `telegram-ai-reply/fn.env.json`:

- `TELEGRAM_TOOLS_ENABLED=true`
- `TELEGRAM_AUTO_TOOLS=true`
- `TELEGRAM_TOOL_ALLOW_FN=request-inspector,telegram-ai-digest`
- `TELEGRAM_TOOL_ALLOW_HTTP_HOSTS=api.ipify.org,wttr.in,ipapi.co`
- `TELEGRAM_TOOL_TIMEOUT_MS=5000`

### Loop E2E completo (todo dentro de `telegram-ai-reply`)

Ahora el loop corre 100% dentro del endpoint. Manda un prompt, espera tu respuesta via `getUpdates` y luego responde con OpenAI.

```bash
curl -sS \
"http://127.0.0.1:8080/fn/telegram-ai-reply?mode=loop&dry_run=false&chat_id=${CHAT_ID}&prompt=fastfn%20loop%20demo&wait_secs=120&max_replies=5&memory=true&force_clear_webhook=true"
```

Para modo scheduler, podés omitir `chat_id` y correr loop como poller multi-chat.

Para forzar un reply único, usá `mode=reply`.

Notas:
- `force_clear_webhook=true` limpia un webhook activo para evitar conflictos `getUpdates` (HTTP 409).
- Si ya tenés otro poller, dejalo en `false` y apagá el otro proceso.
- La memoria conversacional es por chat y se guarda en `<FN_FUNCTIONS_ROOT>/node/telegram-ai-reply/.memory.json`.
- El offset del loop se persiste en `<FN_FUNCTIONS_ROOT>/node/telegram-ai-reply/.loop_state.json`.
- Si hay historial, el prompt le indica al modelo que no responda "no recuerdo" para ese mismo chat.

!!! tip "Timeouts"
    `telegram-ai-reply` hace llamadas reales a la red (OpenAI + Telegram). Asegurate de darle mas timeout en `<FN_FUNCTIONS_ROOT>/node/telegram-ai-reply/fn.config.json`, por ejemplo:

    ```json
    { "timeout_ms": 20000 }
    ```

## Notas

- `dry_run` es **true por defecto** en la mayoria de demos de integracion para evitar envios accidentales.
- Setear `dry_run=false` habilita envios reales, pero solo funciona si `TELEGRAM_BOT_TOKEN` está configurado.

## Limpieza (recomendado)

Después del check E2E, remové secretos del env de la función:

- Consola: dejar el valor vacío (o borrar la key) y guardar.
- O editá `<FN_FUNCTIONS_ROOT>/node/telegram-send/fn.env.json` y borra la entrada.

## 6) Variante Python (reply con IA + tools)

Este repo incluye una version Python del bot:

- Funcion: `telegram-ai-reply-py`
- Ruta: `/fn/telegram-ai-reply-py`

Dry run (seguro):

```bash
export CHAT_ID='123456789'
curl -sS "http://127.0.0.1:8080/fn/telegram-ai-reply-py?mode=reply&dry_run=true&chat_id=${CHAT_ID}&text=Hola%20desde%20python&tools=true&auto_tools=true"
```

Envio real:

```bash
export CHAT_ID='123456789'
curl -sS "http://127.0.0.1:8080/fn/telegram-ai-reply-py?mode=reply&dry_run=false&chat_id=${CHAT_ID}&text=Hola%20desde%20python&tools=true&auto_tools=true"
```

Loop (dry-run):

```bash
curl -sS "http://127.0.0.1:8080/fn/telegram-ai-reply-py?mode=loop&dry_run=true&wait_secs=20"
```

Archivos (se crean en runtime):

- `<FN_FUNCTIONS_ROOT>/python/telegram-ai-reply-py/.memory.json`
- `<FN_FUNCTIONS_ROOT>/python/telegram-ai-reply-py/.loop_state.json`
