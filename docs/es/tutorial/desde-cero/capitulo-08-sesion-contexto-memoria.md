# Capitulo 8 - Sesion, Contexto y Memoria Basica

Objetivo: agregar contexto de usuario y memoria minima por chat/usuario.

## Contexto en invoke

`POST /_fn/invoke` admite `context`:

```json
{
  "name": "request_inspector",
  "method": "GET",
  "context": { "trace_id": "abc-123", "tenant": "demo" }
}
```

El handler lo recibe en `event.context.user`.

## Memoria basica

Patron simple:

- clave por chat/usuario (`chat_id`, `user_id`)
- guardar ultimos N turnos
- TTL de memoria configurable (`memory_ttl_secs`)

Ejemplo real: `telegram_ai_reply`.
