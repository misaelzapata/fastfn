# Flujo de invocacion y ngx.location.capture

## Flujo publico `/fn/...`

1. request entra al gateway Lua
2. se resuelve runtime/version por discovery
3. se validan metodo, body, concurrencia y timeout
4. se construye `event`
5. se envia JSON enmarcado al runtime por socket Unix
6. runtime ejecuta handler
7. gateway devuelve respuesta HTTP final

## Flujo interno `/_fn/invoke`

`/_fn/invoke` usa subrequest interno:

- `ngx.location.capture('/fn/...')`

Eso garantiza que use exactamente la misma logica del gateway publico: metodos, limites, errores, y formato de respuesta.

## Context

Si `/_fn/invoke` recibe `context`, lo serializa y lo envia al gateway, que lo expone en `event.context.user` para el handler.
