# Capitulo 4 - Meta de la Funcion y Metodos (`fn.config.json`)

Objetivo: controlar metodos, timeout, concurrencia y metadata de invocacion.

## Archivo

`/srv/fn/functions/node/hello-world/fn.config.json`

```json
{
  "timeout_ms": 1500,
  "max_concurrency": 10,
  "max_body_bytes": 262144,
  "invoke": {
    "summary": "Demo capitulo 4",
    "methods": ["GET", "POST"],
    "query": { "name": "World" },
    "body": ""
  }
}
```

## Comportamiento

- si llamas con metodo no permitido: `405`
- Swagger/OpenAPI refleja `invoke.methods`
- `timeout_ms` y `max_concurrency` se aplican por funcion
