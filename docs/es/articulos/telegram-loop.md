# Telegram Loop Mode (Auto-contenido)

Este articulo explica como `telegram_ai_reply` puede ejecutar un loop E2E completo **dentro de un solo endpoint**. La misma URL puede:

- enviarte un prompt,
- esperar tu respuesta via `getUpdates`,
- llamar a OpenAI,
- y responderte por Telegram.

## Por que existe

Queremos mostrar que fastfn puede manejar un flujo multi-paso sin workers externos ni scripts. Todo pasa dentro de:

`/fn/telegram_ai_reply`

## Un solo comando (modo loop)

```bash
curl -sS -X POST \
"http://127.0.0.1:8080/fn/telegram_ai_reply?mode=loop&dry_run=false&chat_id=TU_CHAT_ID&prompt=fastfn%20loop%20demo&wait_secs=120&max_replies=5&force_clear_webhook=true"
```

Que hace:

1. fastfn envia el prompt a tu chat.
2. Hace polling de `getUpdates` hasta que respondas.
3. Llama OpenAI y te responde.

Si respondes dentro de `wait_secs`, recibis una respuesta con IA.

## Comportamiento por defecto

Si ejecutás loop sin `chat_id`, entra en modo **poller multi-chat** (ideal para scheduler): lee updates entrantes y responde por chat.

Para forzar un reply unico:

```bash
curl -sS -X POST \
"http://127.0.0.1:8080/fn/telegram_ai_reply?mode=reply&dry_run=false&chat_id=TU_CHAT_ID&text=Hola"
```

## Parametros

- `chat_id` (opcional): si está presente, el loop se limita a ese chat. Si falta, escucha todos los chats entrantes.
- `prompt`: texto inicial enviado antes de esperar tu respuesta.
- `wait_secs`: tiempo maximo de espera (default 120).
- `max_replies`: cantidad de respuestas antes de salir (default 5).
- `poll_ms`: intervalo de polling (default 2000).
- `force_clear_webhook`: si `true`, limpia el webhook para evitar 409.
- `dry_run`: si `true`, no hace llamadas externas.
- `memory`: `true|false` (default `true`). Cuando esta activo, usa memoria por chat.
- `memory_max_turns`: cuantos turnos guardar (default 8).
- `memory_ttl_secs`: expira memoria en segundos (default 3600).

## Errores comunes

`409 Conflict`:

Ya tenes un webhook o otro poller activo. Usa:

`force_clear_webhook=true`

o apaga el otro proceso.

## Nota de seguridad

El endpoint usa:

- `TELEGRAM_BOT_TOKEN`
- `OPENAI_API_KEY`

Se pueden cargar via `fn.env.json` de `telegram_ai_reply` o por variables de entorno del contenedor.

La memoria se guarda localmente en `srv/fn/functions/node/telegram_ai_reply/.memory.json`.
El estado de offset del loop se guarda en `srv/fn/functions/node/telegram_ai_reply/.loop_state.json`.
