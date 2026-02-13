# HTTP API Reference

Formal reference for public and internal endpoints.

## Conventions

- Local base URL: `http://127.0.0.1:8080`
- Common error payload:

```json
{"error":"message"}
```

## Public endpoints

### `GET|POST|PUT|PATCH|DELETE /fn/<name>`

Invokes default function version.

### `GET|POST|PUT|PATCH|DELETE /fn/<name>@<version>`

Invokes an explicit function version.

Key rule:

- allowed methods come from `fn.config.json -> invoke.methods`
- if not allowed: `405` + `Allow` header

### `GET|POST|PUT|PATCH|DELETE /<custom-path>`

Optional mapped endpoints configured per function in `fn.config.json`:

```json
{
  "invoke": {
    "methods": ["GET"],
    "routes": ["/api/node-echo"]
  }
}
```

After reload/discovery, calling `/api/node-echo` invokes that function.

### GET example

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello?name=World'
```

### POST example

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/risk_score?email=user@example.com' \
  -H 'Content-Type: application/json' \
  -d '{"source":"web"}'
```

## Internal platform endpoints (`/_fn/*`)

### Health and discovery

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

### CRUD and configuration

- `GET|POST|DELETE /_fn/function`
- `GET|PUT /_fn/function-config`
- `GET|PUT /_fn/function-env`
- `PUT /_fn/function-code`

### Console operations

- `POST /_fn/invoke`
- `POST /_fn/login`
- `POST /_fn/logout`
- `GET|POST|PUT|PATCH|DELETE /_fn/ui-state`

`/_fn/ui-state` rules:

- `GET` requires Console API access.
- `POST|PUT|PATCH|DELETE` require Console API access **and** write permission (`FN_CONSOLE_WRITE_ENABLED=1` or admin token).

`/_fn/function-env` payload accepts:

- scalar values: `"KEY":"value"`
- secret objects: `"KEY":{"value":"secret","is_secret":true}`
- `null` to delete a key

## `/_fn/invoke` (full payload)

```bash
curl -sS 'http://127.0.0.1:8080/_fn/invoke' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{
    "runtime":"node",
    "name":"node_echo",
    "version":null,
    "method":"POST",
    "query":{"name":"Node"},
    "body":"{\"x\":1}",
    "context":{"trace_id":"abc-123"}
  }'
```

Fields:

- `runtime` optional when name is not ambiguous
  - supported values: `python`, `node`, `php`, `rust`
- `name` required
- `version` optional (`null` for default)
- `method` required
- `query` optional object
- `body` string or JSON-serializable value
- `context` optional object forwarded to `event.context.user`

## OpenAPI and Swagger

- `GET /openapi.json`
- `GET /docs`

OpenAPI is generated dynamically and reflects currently allowed methods per function/version.

## Error table

| Code | Meaning | Typical cause |
|---|---|---|
| `404` | function/version not found | unknown name/version |
| `405` | method not allowed | calling POST on GET-only function |
| `409` | route ambiguity | same function name across runtimes or same mapped route in multiple functions |
| `413` | payload too large | body exceeds `max_body_bytes` |
| `429` | concurrency limit reached | exceeds `max_concurrency` |
| `502` | invalid runtime response | runtime contract violation |
| `503` | runtime down | socket unavailable |
| `504` | timeout | function exceeded `timeout_ms` |
| `500` | internal error | gateway exception |
