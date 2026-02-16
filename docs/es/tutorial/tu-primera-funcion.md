# Tu primera funcion (Python, Node, PHP, Lua, Rust)

En este tutorial crearas una funcion usando el mismo contrato en cinco lenguajes.

!!! info "Estado actual de runtimes"
    Estables hoy: `python`, `node`, `php`, `lua`. Experimentales opt-in: `rust`, `go`.

## 0) (Camino para principiantes) Usa el Wizard de la Consola

Si estas empezando a programar, esto es lo mas simple:

1. Habilita la UI de consola:

```bash
export FN_UI_ENABLED=1
docker compose up -d --build
```

2. Abre el wizard:

- `http://127.0.0.1:8080/console/wizard`

3. Elige runtime + template y toca **Create and open**.

Despues podes seguir el resto del tutorial para entender los archivos que fastfn creo dentro de `FN_FUNCTIONS_ROOT`.

## 1) Elegir root de funciones

El root de discovery se configura con `FN_FUNCTIONS_ROOT`.

Defaults:

- Docker: `/app/srv/fn/functions`
- local repo: `$PWD/srv/fn/functions`

Ejemplo local:

```bash
export FN_FUNCTIONS_ROOT="$PWD/srv/fn/functions"
```

## 2) Crear carpeta de funcion

Ejemplos (relativos a `FN_FUNCTIONS_ROOT`):

- `python/mi-perfil/`
- `node/mi-perfil/`
- `php/mi-perfil/`
- `rust/mi-perfil/`

## 3) Agregar handler (mismo comportamiento en 4 lenguajes)

La funcion lee query/header/context y devuelve JSON.

=== "Python (`app.py`)"

    ```python title="$FN_FUNCTIONS_ROOT/python/mi-perfil/app.py"
    import json

    def handler(event):
        query = event.get("query") or {}
        headers = event.get("headers") or {}
        ctx = event.get("context") or {}

        perfil = {
            "name": query.get("name", "anonimo"),
            "role": query.get("role", "invitado"),
            "trace": ctx.get("request_id"),
            "auth_header_seen": bool(headers.get("authorization")),
        }

        return {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(perfil),
        }
    ```

=== "Node (`app.js`)"

    ```js title="$FN_FUNCTIONS_ROOT/node/mi-perfil/app.js"
    exports.handler = async (event) => {
      const query = event.query || {};
      const headers = event.headers || {};
      const ctx = event.context || {};

      const perfil = {
        name: query.name || 'anonimo',
        role: query.role || 'invitado',
        trace: ctx.request_id || null,
        auth_header_seen: Boolean(headers.authorization),
      };

      return {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(perfil),
      };
    };
    ```

=== "PHP (`app.php`)"

    ```php title="$FN_FUNCTIONS_ROOT/php/mi-perfil/app.php"
    <?php
    function handler($event) {
        $query = $event['query'] ?? [];
        $headers = $event['headers'] ?? [];
        $ctx = $event['context'] ?? [];

        $perfil = [
            'name' => $query['name'] ?? 'anonimo',
            'role' => $query['role'] ?? 'invitado',
            'trace' => $ctx['request_id'] ?? null,
            'auth_header_seen' => !empty($headers['authorization']),
        ];

        return [
            'status' => 200,
            'headers' => ['Content-Type' => 'application/json'],
            'body' => json_encode($perfil),
        ];
    }
    ```

=== "Rust (`app.rs`)"

    ```rust title="$FN_FUNCTIONS_ROOT/rust/mi-perfil/app.rs"
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let query = event.get("query").cloned().unwrap_or_else(|| json!({}));
        let headers = event.get("headers").cloned().unwrap_or_else(|| json!({}));
        let ctx = event.get("context").cloned().unwrap_or_else(|| json!({}));

        let name = query.get("name").and_then(|v| v.as_str()).unwrap_or("anonimo");
        let role = query.get("role").and_then(|v| v.as_str()).unwrap_or("invitado");
        let trace = ctx.get("request_id").cloned().unwrap_or(Value::Null);
        let auth_seen = headers.get("authorization").is_some();

        json!({
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json!({
                "name": name,
                "role": role,
                "trace": trace,
                "auth_header_seen": auth_seen
            }).to_string()
        })
    }
    ```

## 4) Configurar politica (`fn.config.json`)

Crear `fn.config.json` en la misma carpeta de la funcion:

```json title="$FN_FUNCTIONS_ROOT/<runtime>/mi-perfil/fn.config.json"
{
  "timeout_ms": 1500,
  "max_concurrency": 5,
  "max_body_bytes": 262144,
  "invoke": {
    "methods": ["GET", "POST"],
    "summary": "Retornar payload de perfil",
    "query": {"name": "Ada", "role": "admin"},
    "body": ""
  }
}
```

## 5) Recargar discovery

```bash
curl -sS -X POST 'http://127.0.0.1:8080/_fn/reload'
# opcional (mismo efecto, POST sigue siendo preferido para tooling)
curl -sS 'http://127.0.0.1:8080/_fn/reload'
```

## 6) Probar endpoint

```bash
curl -sS 'http://127.0.0.1:8080/fn/mi-perfil?name=Ada&role=admin' \
  -H 'Authorization: Bearer demo-token'
```

POST:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/fn/mi-perfil?name=Bob' \
  -H 'Content-Type: application/json' \
  -d '{"nota":"event.body contiene el input raw"}'
```

## 7) Variables de entorno opcionales

Crear `fn.env.json` en la misma carpeta de la funcion:

```json
{
  "PROFILE_SOURCE": "base-local"
}
```

Lectura en runtime:

- Python: `event.get("env", {}).get("PROFILE_SOURCE")`
- Node: `(event.env || {}).PROFILE_SOURCE`
- PHP: `$event['env']['PROFILE_SOURCE'] ?? null`
- Rust: `event.get("env").and_then(|e| e.get("PROFILE_SOURCE"))`

## 8) Ejecutar en modo nativo para produccion

Cuando quieras correr con defaults de produccion (sin hot reload), usa:

```bash
FN_HOST_PORT=8080 \
FN_UI_ENABLED=0 \
FN_CONSOLE_API_ENABLED=0 \
FN_CONSOLE_WRITE_ENABLED=0 \
FN_PUBLIC_BASE_URL=https://api.midominio.com \
bin/fastfn run --native "$FN_FUNCTIONS_ROOT"
```

Validacion rapida desde otra terminal:

```bash
curl -sS 'http://127.0.0.1:8080/fn/mi-perfil?name=Ada'
curl -sS 'http://127.0.0.1:8080/openapi.json'
curl -sS 'http://127.0.0.1:8080/_fn/openapi.json' | jq -r '.servers[0].url'
# https://api.midominio.com
```

## 9) Usar el SDK de FastFN en Node

Si queres helpers de request/response en handlers Node:

```bash
npm install ./sdk/js
```

Ejemplo de handler:

```js
const { Request, toResponse } = require('@fastfn/runtime');

exports.handler = async (event) => {
  const req = new Request(event);
  return toResponse({
    ok: true,
    method: req.method,
    path: req.path,
  });
};
```

Este handler funciona igual en `fastfn dev` y `fastfn run --native`.

Ejemplo de app cliente consumiendo la API en native:

```js
const baseUrl = process.env.FASTFN_BASE_URL || 'http://127.0.0.1:8080';

async function main() {
  const res = await fetch(`${baseUrl}/fn/mi-perfil?name=Ada`);
  const body = await res.json();
  console.log({ status: res.status, body });
}

main().catch(console.error);
```
