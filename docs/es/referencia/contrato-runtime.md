# Contrato runtime (event/context)

Este documento define exactamente que envia OpenResty al handler y que debe devolver el runtime.

## 1) Transporte interno

- Protocolo: socket Unix por runtime (`python`, `node`, `php`, `rust`).
- Framing: `4-byte big-endian length + JSON`.
- Request interno: `{ fn, version, event }`.
- Response interno: `{ status, headers, body }` o binario base64.

## 2) Que envia el cliente HTTP y como llega al handler

### Request publico (cliente -> gateway)

```bash
curl -sS 'http://127.0.0.1:8080/risk-score?email=user@example.com' \
  -H 'x-user-email: user@example.com' \
  -H 'x-api-key: my-key' \
  -H 'Cookie: session_id=abc123; theme=dark' \
  -H 'Content-Type: application/json' \
  -d '{"extra":"value"}'
```

### Mapeo en `event`

- query string -> `event.query`
- headers -> `event.headers`
- body raw (string) -> `event.body`
- IP/UA cliente -> `event.client`
- metadata de gateway/politica -> `event.context`
- env por funcion -> `event.env`

## 3) Payload interno completo (gateway -> runtime)

```json
{
  "fn": "hello",
  "version": "v2",
  "event": {
    "id": "req-1770795478241-13-311866",
    "ts": 1770795478241,
    "method": "GET",
    "path": "/hello@v2",
    "raw_path": "/hello@v2?name=NodeWay",
    "query": {"name": "NodeWay"},
    "headers": {
      "host": "127.0.0.1:8080",
      "user-agent": "curl/8.7.1",
      "accept": "*/*",
      "x-api-key": "my-key",
      "cookie": "session_id=abc123"
    },
    "body": "",
    "client": {"ip": "127.0.0.1", "ua": "curl/8.7.1"},
    "context": {
      "request_id": "req-1770795478241-13-311866",
      "runtime": "node",
      "function_name": "hello",
      "version": "v2",
      "timeout_ms": 1500,
      "max_concurrency": 15,
      "max_body_bytes": 1048576,
      "gateway": {"worker_pid": 12345},
      "debug": {"enabled": false},
      "user": null
    },
    "env": {
      "NODE_GREETING": "v2"
    }
  }
}
```

## 4) Referencia de campos `event`

| Campo | Tipo | Origen | Notas |
|---|---|---|---|
| `id` | `string` | gateway | request id unico |
| `ts` | `number` | gateway | epoch ms |
| `method` | `string` | HTTP request | `GET/POST/PUT/PATCH/DELETE` |
| `path` | `string` | gateway | ruta normalizada sin query |
| `raw_path` | `string` | gateway | URI original con query |
| `query` | `object` | query string | valores de URL |
| `headers` | `object` | headers request | incluye auth/cookies si cliente envia |
| `body` | `string` o `null` | request body | cuerpo raw, no parseado por gateway |
| `client.ip` | `string` | gateway | IP remota |
| `client.ua` | `string` o `null` | header | User-Agent |
| `context.request_id` | `string` | gateway | mismo `id` |
| `context.runtime` | `string` | discovery | runtime resuelto |
| `context.function_name` | `string` | routing | nombre funcion |
| `context.version` | `string` | routing | version efectiva |
| `context.timeout_ms` | `number` | politica | timeout aplicado |
| `context.max_concurrency` | `number` | politica | limite aplicado |
| `context.max_body_bytes` | `number` | politica | limite body aplicado |
| `context.gateway.worker_pid` | `number` | OpenResty | pid worker |
| `context.debug.enabled` | `boolean` | politica | debug headers habilitados |
| `context.user` | `object` o `null` | `/_fn/invoke` | contexto custom inyectado |
| `env` | `object` | `fn.env.json` | variables por funcion/version |

## 5) Inyeccion de `context.user` desde `/_fn/invoke`

```bash
curl -sS 'http://127.0.0.1:8080/_fn/invoke' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{
    "name":"hello",
    "method":"GET",
    "query":{"name":"Ctx"},
    "context":{"trace_id":"abc-123","tenant":"demo"}
  }'
```

El handler lo recibe en:

- `event.context.user.trace_id`
- `event.context.user.tenant`

## 6) Response del runtime (obligatorio)

### Texto/JSON

```json
{
  "status": 200,
  "headers": {"Content-Type": "application/json"},
  "body": "{\"ok\":true}"
}
```

### Binario

```json
{
  "status": 200,
  "headers": {"Content-Type": "image/png"},
  "is_base64": true,
  "body_base64": "iVBORw0KGgo..."
}
```

### Passthrough estilo edge (proxy)

Una funcion puede devolver un campo `proxy`. Esto se parece a Cloudflare Workers `return fetch(request)`:

- tu handler devuelve un request “declarativo”
- fastfn hace el request saliente dentro del gateway
- fastfn devuelve status/headers/body del upstream al cliente
- si `proxy` está presente, manda la respuesta del upstream (los `status/headers/body` de arriba quedan como fallback)

Ejemplo (Node):

```js
exports.handler = async (event) => {
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    proxy: {
      path: "/hello?name=edge",
      method: event.method || "GET",
      headers: { "x-fastfn-edge": "1" },
      body: event.body || "",
      timeout_ms: (event.context || {}).timeout_ms || 2000
    }
  };
};
```

### Ejemplo de filtro + rewrite (auth + passthrough)

Este patrón es lo más parecido al caso típico en Workers: validar la request entrante y luego reescribir/passthrough.

```js
function header(event, name) {
  const h = event.headers || {};
  return h[name] || h[name.toLowerCase()] || h[name.toUpperCase()] || null;
}

exports.handler = async (event) => {
  const env = event.env || {};

  // Filtro: requiere API key
  const expected = String(env.EDGE_FILTER_API_KEY || "");
  const provided = String(header(event, "x-api-key") || "");
  if (!expected || provided !== expected) {
    return { status: 401, headers: { "Content-Type": "application/json" }, body: "{\"error\":\"unauthorized\"}" };
  }

  // Rewrite + passthrough
  const userId = String((event.query || {}).user_id || "");
  return {
    proxy: {
      path: "/v1/users/" + encodeURIComponent(userId),
      method: "GET",
      headers: { "x-edge": "1" },
      timeout_ms: (event.context || {}).timeout_ms || 2000
    }
  };
};
```

Para permitir esto, habilitá `edge` en el `fn.config.json` de esa función (proxy viene deshabilitado por defecto).

Campos soportados (minimo):

- `url`: URL absoluta `http(s)://...` (o)
- `path`: path que empieza con `/` (requiere `edge.base_url` en `fn.config.json`)
- `method`: `GET|POST|PUT|PATCH|DELETE`
- `headers`: objeto de headers hacia upstream
- `body`: body string
- `timeout_ms`: timeout del request (ms)
- `max_response_bytes`: limite de bytes del response
- `is_base64` + `body_base64`: body de request en base64 (opcional)

Seguridad:

- el proxy está **deshabilitado por defecto** por funcion
- se habilita con `edge` en `fn.config.json`
- proxyear a paths del control-plane (`/_fn/*`, `/console/*`) está bloqueado

```json
{
  "edge": {
    "base_url": "https://api.example.com",
    "allow_hosts": ["api.example.com"],
    "allow_private": false,
    "max_response_bytes": 1048576
  }
}
```

## 7) Tipos de respuesta soportados

- `application/json`
- `text/html`
- `text/csv`
- binarios como `image/png`

`/_fn/invoke` envuelve respuestas no-texto en base64 para mantener salida JSON estable.

## 8) Modo estricto de filesystem (por defecto)

`fastfn` ejecuta handlers con modo estricto de filesystem habilitado por defecto:

- `FN_STRICT_FS=1` (default)
- `FN_STRICT_FS_ALLOW=/ruta/a/permitir,/otra/ruta` (opcional)

Reglas:

- la funcion puede leer/escribir dentro de su propio directorio
- no puede leer rutas arbitrarias fuera de su sandbox
- no puede leer archivos protegidos de plataforma:
  - `fn.config.json`
  - `fn.env.json`
- no se permite spawn de subprocess desde handlers en modo estricto

Nota de implementacion:

- Python y Node aplican bloqueo estricto de filesystem a nivel runtime.
- PHP y Rust corren en procesos aislados con validacion de rutas y ejecucion acotada, pero hoy no interceptan por archivo la lista protegida.

Importante:

- es un sandbox a nivel runtime (lenguaje), no un aislamiento kernel (cgroups/seccomp/chroot).
