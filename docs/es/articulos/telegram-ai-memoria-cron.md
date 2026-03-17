# Bots de Telegram Programados con FastFN


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
## Por qué existe este artículo

Usá una función programada de Telegram cuando el trabajo tenga que correr por intervalo: hacer polling, enviar digests o generar resúmenes para un chat. El repo ya incluye `telegram-ai-digest`, un ejemplo funcional que lee mensajes recientes, le pide un resumen a OpenAI y publica el resultado en Telegram.

Si necesitás una respuesta inmediata por cada mensaje entrante, mirá [Cómo funciona `telegram-ai-reply`](telegram-ai-reply-como-funciona.md).

## Mapa rápido de documentación
- Arranque de plataforma: [Ejecutar y probar](../como-hacer/ejecutar-y-probar.md)
- Configuración completa Telegram: [Telegram E2E](../como-hacer/telegram-e2e.md)
- Formato de función: [Especificación de funciones](../referencia/especificacion-funciones.md)
- Endpoints internos (`/_fn/reload`, `/_fn/schedules`): [API HTTP](../referencia/api-http.md)
- Contrato runtime y payload: [Contrato runtime](../referencia/contrato-runtime.md)
- Ciclo completo de invocación: [Flujo de invocación](../explicacion/flujo-invocacion.md)

## Arquitectura

```text
Chat de Telegram
  -> Telegram Bot API (getUpdates)
  -> schedule de FastFN
  -> telegram-ai-digest
  -> OpenAI
  -> Telegram Bot API (sendMessage)
  -> Chat de Telegram
```

## Prerrequisitos
- Docker Desktop activo
- token de bot creado con `@BotFather`
- chat ID del chat de destino
- API key de OpenAI

Opcional recomendado:
- consola habilitada localmente (`FN_UI_ENABLED=1`, `FN_CONSOLE_LOCAL_ONLY=1`)

## Paso 1: Levantar FastFN

```bash
docker compose up -d --build
curl -sS http://127.0.0.1:8080/_fn/health
```

Esperado:
- runtimes `node` y `python` en estado up.

## Paso 2: Configurar secretos
Editar `<FN_FUNCTIONS_ROOT>/telegram-ai-digest/fn.env.json`:

```json
{
  "TELEGRAM_BOT_TOKEN": { "value": "<set-me>", "is_secret": true },
  "TELEGRAM_CHAT_ID": { "value": "<set-me>", "is_secret": false },
  "OPENAI_API_KEY": { "value": "<set-me>", "is_secret": true }
}
```

Notas:
- mantené secretos reales con `is_secret: true`
- valores de función se exponen como `event.env`

## Paso 3: Revisar el schedule

El ejemplo corre por intervalo desde `telegram-ai-digest/fn.config.json`:

```json
"schedule": {
  "enabled": true,
  "every_seconds": 3600,
  "method": "GET"
}
```

Ajustá el intervalo según tu caso y luego recargá.

## Paso 4: Ejecutar la función una vez a mano

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-digest'
```

Ejemplo de respuesta:

```json
{
  "ok": true,
  "message_count": 42,
  "digest": "Daily Digest (2026-03-17T12:00 UTC)\n\n..."
}
```

## Paso 5: Hot reload en vez de reiniciar

```bash
curl -sS -X POST http://127.0.0.1:8080/_fn/reload
```

Para cambios de función/config/env normalmente no hace falta reiniciar contenedor.

## Paso 6: Verificar estado del scheduler

```bash
curl -sS http://127.0.0.1:8080/_fn/schedules
```

## Checklist operativo
1. `/_fn/health` con runtimes activos.
2. secretos en `fn.env.json` con `is_secret=true`.
3. un solo origen de polling activo para el mismo bot token.
4. si necesitás memoria entre corridas, guardala fuera de la request en base de datos, archivo u otro storage durable.

## Documentación relacionada
- [Telegram E2E](../como-hacer/telegram-e2e.md)
- [Telegram Digest (Cron)](../como-hacer/telegram-digest.md)
- [API HTTP](../referencia/api-http.md)
- [Especificación de funciones](../referencia/especificacion-funciones.md)
- [Arquitectura](../explicacion/arquitectura.md)

## Idea clave

El trabajo programado en Telegram tiene una forma distinta a la de los webhooks. Usalo cuando el bot tenga que despertarse por intervalo, leer actividad reciente y publicar un resultado sin esperar una request entrante.

## Qué conviene tener en cuenta

- Los jobs programados sirven bien para digests, polling, limpieza y otras tareas en segundo plano.
- Conviene dejar explícitos el polling, la deduplicación y el almacenamiento, en vez de esconderlos dentro de un handler de webhook.
- Si el bot tiene que recordar algo entre corridas, guardá ese estado fuera de la request.

## Cuándo conviene el camino de webhook

- Usá la guía de webhook cuando cada mensaje entrante tenga que disparar una respuesta inmediata.
- Usá el camino programado cuando el trabajo sea periódico o cuando polling sea más simple que exponer un webhook público.
- Combiná ambos solo si cada uno tiene una responsabilidad bien separada.

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
