# Referencia HTTP

Referencia formal de endpoints publicos e internos.

## Convenciones

- Base URL local: `http://127.0.0.1:8080`
- Formato de error comun:

```json
{"error":"message"}
```

## Endpoints publicos

### `GET|POST|PUT|PATCH|DELETE /fn/<name>`

Invoca version default de una funcion.

### `GET|POST|PUT|PATCH|DELETE /fn/<name>@<version>`

Invoca version explicita.

Regla clave:

- Los metodos permitidos salen de `fn.config.json -> invoke.methods`.
- Si el metodo no esta permitido: `405` + header `Allow`.

### `GET|POST|PUT|PATCH|DELETE /<ruta-personalizada>`

Endpoints mapeados opcionales por funcion desde `fn.config.json`:

```json
{
  "invoke": {
    "methods": ["GET"],
    "routes": ["/api/node-echo"]
  }
}
```

Despues de recargar/discovery, llamar `/api/node-echo` invoca esa funcion.

### Ejemplo GET

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello?name=World'
```

### Ejemplo POST

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/risk-score?email=user@example.com' \
  -H 'Content-Type: application/json' \
  -d '{"source":"web"}'
```

## Endpoints internos de plataforma (`/_fn/*`)

### Salud y discovery

- `GET /_fn/health`
- `POST /_fn/reload`
- `GET /_fn/catalog`
- `GET /_fn/packs`
- `GET /_fn/schedules`
- `GET /_fn/jobs`
- `POST /_fn/jobs`
- `GET /_fn/jobs/<id>`
- `DELETE /_fn/jobs/<id>`
- `GET /_fn/jobs/<id>/result`

### CRUD y configuracion

- `GET|POST|DELETE /_fn/function`
- `GET|PUT /_fn/function-config`
- `GET|PUT /_fn/function-env`
- `PUT /_fn/function-code`

### Operacion de consola

- `POST /_fn/invoke`
- `POST /_fn/login`
- `POST /_fn/logout`
- `GET|POST|PUT|PATCH|DELETE /_fn/ui-state`

Reglas de `/_fn/ui-state`:

- `GET` requiere acceso a Console API.
- `POST|PUT|PATCH|DELETE` requieren acceso a Console API **y** permiso de escritura (`FN_CONSOLE_WRITE_ENABLED=1` o token admin).

El payload de `/_fn/function-env` acepta:

- valores escalares: `"KEY":"value"`
- objetos secretos: `"KEY":{"value":"secret","is_secret":true}`
- `null` para eliminar una clave

## `/_fn/invoke` (payload completo)

```bash
curl -sS 'http://127.0.0.1:8080/_fn/invoke' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{
    "runtime":"node",
    "name":"node-echo",
    "version":null,
    "method":"POST",
    "query":{"name":"Node"},
    "body":"{\"x\":1}",
    "context":{"trace_id":"abc-123"}
  }'
```

Campos:

- `runtime` opcional cuando nombre no es ambiguo
  - valores soportados: `python`, `node`, `php`, `rust`
- `name` obligatorio
- `version` opcional (`null` para default)
- `method` obligatorio
- `query` objeto opcional
- `body` string o JSON serializable
- `context` objeto opcional inyectado a `event.context.user`

## OpenAPI y Swagger

- `GET /openapi.json`
- `GET /docs`

OpenAPI es dinamico y refleja metodos permitidos por funcion/version en tiempo real.

## Tabla de errores

| Codigo | Significado | Caso tipico |
|---|---|---|
| `404` | funcion/version no encontrada | nombre o version inexistente |
| `405` | metodo no permitido | `POST` a funcion solo `GET` |
| `409` | ambiguedad de ruta | mismo nombre en runtimes distintos o misma ruta mapeada en multiples funciones |
| `413` | payload demasiado grande | body > `max_body_bytes` |
| `429` | concurrencia excedida | supera `max_concurrency` |
| `502` | respuesta runtime invalida | contrato runtime roto |
| `503` | runtime caido | socket no disponible |
| `504` | timeout | funcion excede `timeout_ms` |
| `500` | error interno | excepcion gateway |
