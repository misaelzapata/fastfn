# Bot de Telegram con IA y Memoria que Sobrevive al Cron

## Por qué existe este artículo
Muchos demos de bot en Telegram funcionan una sola vez y después se rompen.

Esta guía va a la versión práctica:
- loop de polling que se mantiene,
- memoria por chat,
- persistencia de offset para no reprocesar updates viejos,
- configuración estable para scheduler.

Si estás empezando, este es el camino más corto a un bot usable.

## Mapa rápido de documentación
- Arranque de plataforma: [Ejecutar y probar](../como-hacer/ejecutar-y-probar.md)
- Configuración completa Telegram: [Telegram E2E](../como-hacer/telegram-e2e.md)
- Formato de función: [Especificación de funciones](../referencia/especificacion-funciones.md)
- Endpoints internos (`/_fn/reload`, `/_fn/schedules`): [API HTTP](../referencia/api-http.md)
- Contrato runtime y payload: [Contrato runtime](../referencia/contrato-runtime.md)
- Ciclo completo de invocación: [Flujo de invocación](../explicacion/flujo-invocacion.md)

## Qué vas a construir
Una función `telegram_ai_reply` que:
- consulta updates de Telegram por schedule,
- llama a OpenAI,
- responde al mismo chat,
- guarda memoria corta para continuidad.

## Arquitectura en una imagen

```text
Usuario Telegram
  -> Telegram Bot API (getUpdates)
  -> scheduler de fastfn -> /fn/telegram_ai_reply
  -> OpenAI
  -> Telegram Bot API (sendMessage)
  -> Usuario Telegram
```

Archivos de estado local usados:
- `.memory.json` para memoria por chat
- `.loop_state.json` para último offset procesado

## Prerrequisitos
- Docker Desktop activo
- token de bot creado con `@BotFather`
- API key de OpenAI

Opcional recomendado:
- consola habilitada localmente (`FN_UI_ENABLED=1`, `FN_CONSOLE_LOCAL_ONLY=1`)

## Paso 1: Levantar fastfn

```bash
docker compose up -d --build
curl -sS http://127.0.0.1:8080/_fn/health
```

Esperado:
- runtimes `node` y `python` en estado up.

## Paso 2: Configurar secretos y opciones de runtime
Editar `srv/fn/functions/node/telegram_ai_reply/fn.env.json`:

```json
{
  "TELEGRAM_BOT_TOKEN": { "value": "<set-me>", "is_secret": true },
  "OPENAI_API_KEY": { "value": "<set-me>", "is_secret": true },
  "OPENAI_MODEL": { "value": "gpt-4o-mini", "is_secret": false },
  "TELEGRAM_LOOP_ENABLED": { "value": "true", "is_secret": false }
}
```

Notas:
- mantené secretos reales con `is_secret: true`
- valores de función se exponen como `event.env`

## Paso 3: Habilitar scheduler loop en config de función
Editar `srv/fn/functions/node/telegram_ai_reply/fn.config.json`:

```json
{
  "timeout_ms": 200000,
  "max_concurrency": 2,
  "schedule": {
    "enabled": true,
    "every_seconds": 75,
    "method": "GET",
    "query": {
      "loop": "true",
      "dry_run": "false",
      "wait_secs": "45",
      "force_clear_webhook": "true"
    },
    "context": { "type": "cron" }
  }
}
```

Por qué esta combinación:
- `every_seconds` mayor que `wait_secs` reduce solapamiento.
- baja ruido de errores por ejecución concurrente.

## Paso 4: Hot reload en vez de reiniciar

```bash
curl -sS -X POST http://127.0.0.1:8080/_fn/reload
```

Para cambios de función/config/env normalmente no hace falta reiniciar contenedor.

## Paso 5: Verificar estado de scheduler

```bash
curl -sS http://127.0.0.1:8080/_fn/schedules
```

Revisar entrada `telegram_ai_reply`:
- `schedule.enabled=true`
- `state.last_status=200` después de al menos un ciclo

## Paso 6: Verificación dry-run y live
Dry run:

```bash
curl -sS -X POST \
'http://127.0.0.1:8080/fn/telegram_ai_reply?mode=loop&dry_run=true&wait_secs=10'
```

Modo real:
- enviá mensaje al bot,
- esperá un ciclo,
- verificá respuesta en tu teléfono.

Prueba one-shot:

```bash
curl -sS -X POST \
'http://127.0.0.1:8080/fn/telegram_ai_reply?mode=reply&dry_run=false&chat_id=<CHAT_ID>&text=Hola'
```

## Memoria y offset
Ajustes de memoria por query:
- `memory=true|false`
- `memory_max_turns` (default 8)
- `memory_ttl_secs` (default 3600)

Archivo de offset:
- `srv/fn/functions/node/telegram_ai_reply/.loop_state.json`

Archivo de memoria:
- `srv/fn/functions/node/telegram_ai_reply/.memory.json`

Esta combinación estabiliza el modo cron tras reinicios.

## Tabla rápida de troubleshooting

| Síntoma | Significado | Solución |
|---|---|---|
| `last_status=409` | otro poller/webhook activo | usar `force_clear_webhook=true` y apagar poller externo |
| `last_status=502` | falla API externa | validar token/key, red, cuotas |
| `last_status=504` | sin mensajes en la ventana | aceptable en polling; ajustar intervalos |
| responde una sola vez | loop/schedule deshabilitado | activar `TELEGRAM_LOOP_ENABLED` y `schedule.enabled` |
| repite mensajes viejos | offset no persistido | validar permisos de `.loop_state.json` |

## Checklist operativo
1. `/_fn/health` con runtimes activos.
2. `/_fn/schedules` con loop activo y estado saludable.
3. un solo origen de polling activo.
4. secretos en `fn.env.json` con `is_secret=true`.
5. archivos de estado con permisos de escritura.

## Documentación relacionada
- [Telegram E2E](../como-hacer/telegram-e2e.md)
- [Telegram Digest (Cron)](../como-hacer/telegram-digest.md)
- [API HTTP](../referencia/api-http.md)
- [Especificación de funciones](../referencia/especificacion-funciones.md)
- [Arquitectura](../explicacion/arquitectura.md)
