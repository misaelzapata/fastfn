# Telegram Loop Mode: qué cambió y qué usar ahora


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
Notas y capturas viejas pueden mencionar un loop auto-contenido de Telegram que hacía polling y respuesta dentro de un solo endpoint. Ese ya no es el ejemplo por defecto del repo.

Hoy el punto de partida recomendado es más chico y más fácil de seguir:

1. Telegram manda un webhook POST a `/telegram-ai-reply`.
2. El handler lee el texto entrante.
3. La función le pide una respuesta a OpenAI.
4. La función devuelve esa respuesta con Telegram `sendMessage`.

El ejemplo funcional está en `examples/functions/node/telegram-ai-reply/handler.js`.

## Prueba local rápida

Levantá el catálogo de ejemplos:

```bash
bin/fastfn dev examples/functions
```

Luego mandá una request de prueba:

```bash
curl -sS 'http://127.0.0.1:8080/telegram-ai-reply' \
  -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message":{"chat":{"id":123},"text":"Hola desde Telegram"}}'
```

Si la función está configurada correctamente, va a llamar a OpenAI y devolver un resumen JSON de la respuesta que envió a Telegram.

## Si necesitás polling o trabajo programado

Conviene usar una función programada en vez de volver a meter el loop viejo dentro del handler de webhook.

El repo ya trae `examples/functions/node/telegram-ai-digest`, que es un mejor punto de partida para trabajo de Telegram por intervalo. Su schedule se ve así:

```json
"schedule": {
  "enabled": true,
  "every_seconds": 3600,
  "method": "GET"
}
```

Ese patrón encaja mejor para:

- digests periódicos,
- polling con `getUpdates`,
- tareas de limpieza,
- resúmenes que deben correr aunque nadie esté esperando una respuesta HTTP.

## Qué camino conviene elegir

- Usá webhook cuando cada mensaje tenga que disparar una respuesta inmediata.
- Usá schedule cuando el trabajo tenga que correr por intervalo o cuando polling sea más simple que exponer un webhook público.
- Guardá memoria fuera de la request si el bot necesita recordar algo entre corridas o mensajes.

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
