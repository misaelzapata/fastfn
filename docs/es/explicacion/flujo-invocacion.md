# Flujo de invocación

## Flujo público (`/<name>`)

1. La petición entra al gateway Lua.
2. Se resuelve runtime/versión por discovery.
3. Se validan método, body, concurrencia y timeout.
4. Se construye `event`.
5. Se envía JSON enmarcado al runtime por socket Unix.
6. El runtime ejecuta el handler.
7. El gateway devuelve la respuesta HTTP final.

## Flujo interno `/_fn/invoke`

`/_fn/invoke` no llama runtimes directamente.

Construye una request interna y la enruta por la misma capa de routing/política que el tráfico público.
Eso garantiza consistencia en métodos, límites, errores y formato de respuesta.

## Context

Si `/_fn/invoke` recibe `context`, lo serializa y lo envía al gateway, que lo expone en `event.context.user` para el handler.
