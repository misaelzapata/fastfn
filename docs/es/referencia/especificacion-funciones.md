# Especificacion de funciones

## Nombres y rutas

- nombre: `^[a-zA-Z0-9_-]+$`
- version: `^[a-zA-Z0-9_.-]+$`
- rutas publicas:
  - `/fn/<name>`
  - `/fn/<name>@<version>`

## Estado de runtimes

Implementados y ejecutables hoy:

- `python`
- `node`
- `php`
- `rust`

## Root de funciones configurable

El discovery es por filesystem y el root se puede configurar.

Orden de resolucion:

1. `FN_FUNCTIONS_ROOT` (si existe)
2. `/app/srv/fn/functions` (default contenedor)
3. `$PWD/srv/fn/functions` (default local)
4. `/srv/fn/functions`

Tambien puedes controlar discovery con:

- `FN_RUNTIMES` (CSV, ejemplo `python,node,php,rust`)
- `FN_RUNTIME_SOCKETS` (JSON runtime -> socket URI)
- `FN_SOCKET_BASE_DIR` (base de sockets si no hay mapa explicito)

Precedencia de runtime para rutas legacy:

- Si el mismo nombre existe en varios runtimes, `/fn/<name>` usa el primer runtime en `FN_RUNTIMES`.
- Si `FN_RUNTIMES` no esta definido, usa orden alfabetico de carpetas runtime.

## Archivos de codigo

Runtime implementado:

- Python: `app.py` o `handler.py`
- Node: `app.js` o `handler.js`
- PHP: `app.php` o `handler.php`
- Rust: `app.rs` o `handler.rs`

## Estructura (relativa a `FN_FUNCTIONS_ROOT`)

```text
<FN_FUNCTIONS_ROOT>/
  python/<name>[/<version>]/app.py|handler.py
  node/<name>[/<version>]/app.js|handler.js
  php/<name>[/<version>]/app.php|handler.php
  rust/<name>[/<version>]/app.rs|handler.rs
```

Archivos opcionales por funcion/version:

- `fn.config.json`
- `fn.env.json`
- `requirements.txt` (Python)
- `package.json`, `package-lock.json` (Node)
- `composer.json`, `composer.lock` (PHP, opcional)
- `Cargo.toml`, `Cargo.lock` (Rust, opcional)

## Ejemplos minimos de handler (mismo contrato)

Todos consumen `event` y devuelven `{status, headers, body}`.

=== "Python"

    ```python
    import json

    def handler(event):
        name = (event.get("query") or {}).get("name", "world")
        return {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"hello": name}),
        }
    ```

=== "Node"

    ```js
    exports.handler = async (event) => {
      const query = event.query || {};
      const name = query.name || 'world';
      return {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ hello: name }),
      };
    };
    ```

=== "PHP"

    ```php
    <?php
    function handler($event) {
        $query = $event['query'] ?? [];
        $name = $query['name'] ?? 'world';

        return [
            'status' => 200,
            'headers' => ['Content-Type' => 'application/json'],
            'body' => json_encode(['hello' => $name]),
        ];
    }
    ```

=== "Rust"

    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let name = event
            .get("query")
            .and_then(|q| q.get("name"))
            .and_then(|n| n.as_str())
            .unwrap_or("mundo");

        json!({
            "status": 200,
            "headers": { "Content-Type": "application/json" },
            "body": json!({ "hello": name }).to_string()
        })
    }
    ```

## `fn.config.json`

Campos clave:

- `timeout_ms`
- `max_concurrency`
- `max_body_bytes`
- `group` (opcional)
- `shared_deps` (opcional)
- `edge` (opcional, passthrough tipo edge)
- `include_debug_headers`
- `schedule` (cron simple por intervalo, opcional)
- `invoke.methods`
- `invoke.handler` (opcional, nombre de funcion exportada; default `handler`)
- `invoke.routes` (mapeo opcional de endpoint publico)
- `invoke.force-url` (opcional, si `true` puede sobrescribir una URL ya mapeada)
- `invoke.summary`
- `invoke.query`
- `invoke.body`

Ejemplo:

```json
{
  "group": "demos",
  "shared_deps": ["common_http"],
  "timeout_ms": 1500,
  "max_concurrency": 10,
  "max_body_bytes": 1048576,
  "include_debug_headers": false,
  "invoke": {
    "handler": "main",
    "force-url": false,
    "methods": ["GET", "POST"],
    "routes": ["/api/mi-funcion"],
    "summary": "Mi funcion",
    "query": {"name": "World"},
    "body": ""
  }
}
```

Notas:

- `invoke.handler` permite estilo Lambda con nombre de handler custom (`main`, `run`, etc.).
- En runtimes Node y Python, esa funcion debe existir/exportarse en el mismo archivo.
- `invoke.routes` es opcional.
- Si existe, cada ruta debe ser absoluta (por ejemplo `/api/mi-funcion`).
- Prefijos reservados no permitidos (`/fn`, `/_fn`, `/console`, `/docs`).
- Conflictos de rutas devuelven `409`.
- Por defecto, FastFN no sobrescribe silenciosamente un mapeo de URL existente.
- Usa `invoke.force-url: true` solo cuando realmente queres que esta funcion se quede con una ruta (por ejemplo, durante una migracion).
- Los configs por version (por ejemplo `node/mi-fn/v2/fn.config.json`) no pueden "tomar" una URL existente por si solos; usa `FN_FORCE_URL=1` si necesitas que una ruta versionada gane.
- Override global: setea `FN_FORCE_URL=1` (o `fastfn dev --force-url`) para tratar todas las rutas config/policy como forced.

## Config edge passthrough (`edge`)

Si queres un comportamiento estilo Cloudflare Workers (el handler devuelve un `proxy` y el gateway hace el request saliente), habilitalo por funcion en `fn.config.json`:

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

Despues el handler puede devolver `{ "proxy": { ... } }`. Ver el contrato completo en: **Contrato Runtime**.

## Packs de dependencias compartidas (`shared_deps`)

Si queres que varias funciones reutilicen la misma instalacion de dependencias (por ejemplo: un `node_modules` compartido para Node, o una carpeta de pip compartida para Python), podes usar packs compartidos.

En `fn.config.json`:

```json
{
  "shared_deps": ["qrcode_pack"]
}
```

Los packs viven dentro del root de funciones (funciona con el volumen default de Docker):

```text
<FN_FUNCTIONS_ROOT>/.fastfn/packs/<runtime>/<pack>/
```

Ejemplos:

- Pack Python: `<FN_FUNCTIONS_ROOT>/.fastfn/packs/python/qrcode_pack/requirements.txt`
- Pack Node: `<FN_FUNCTIONS_ROOT>/.fastfn/packs/node/qrcode_pack/package.json`
- Pack Node TypeScript (esbuild): `<FN_FUNCTIONS_ROOT>/.fastfn/packs/node/ts_pack/package.json`

En runtime:

- Python instala en `<pack>/.deps` y lo agrega a `sys.path`
- Node instala en `<pack>/node_modules` y lo agrega a la resolucion de modulos para esa invocacion

Esto no es aislamiento nivel kernel (virtualenv/cargo completo), pero sirve para deduplicar instalaciones de forma simple.

## Schedule (cron o intervalo)

Puedes adjuntar un schedule a una funcion usando:

- `every_seconds` (intervalo)
- `cron` (expresion cron)

### Schedule por intervalo (`every_seconds`)

```json
{
  "schedule": {
    "enabled": true,
    "every_seconds": 60,
    "method": "GET",
    "query": {},
    "headers": {},
    "body": "",
    "context": {}
  }
}
```

### Schedule cron (`cron`)

Cron soporta:

- 5 campos: `min hour dom mon dow`
- 6 campos: `sec min hour dom mon dow`
- macros: `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`

```json
{
  "schedule": {
    "enabled": true,
    "cron": "*/5 * * * *",
    "timezone": "UTC",
    "method": "GET",
    "query": {},
    "headers": {},
    "body": "",
    "context": {}
  }
}
```

Timezones:

- `UTC`, `Z`
- `local` (default si se omite)
- offsets fijos como `+02:00` o `-05:00`

- El scheduler corre dentro de OpenResty (worker 0).
- Invoca el runtime por unix socket.
- La policy aplica igual (metodos, body, concurrencia, timeout).
- Para correr cada **X minutos**, usa `every_seconds = X * 60` (ejemplo: 15 minutos => `900`).
- Estado del scheduler: `GET /_fn/schedules` (`next`, `last`, `last_status`, `last_error`).
- Los schedules se guardan en `fn.config.json` (la definicion persiste entre restarts).
- El estado del scheduler se persiste por defecto en `<FN_FUNCTIONS_ROOT>/.fastfn/scheduler-state.json` (para mantener `last/next/status/error` entre restarts).
- Fallos comunes (`last_status` / `last_error`):
  - `405`: el `method` del schedule no esta permitido por la policy de la funcion.
  - `413`: el `body` excedio `max_body_bytes`.
  - `429`: la funcion estaba ocupada (gate de concurrencia).
  - `503`: runtime caido/no saludable.
- Retry/backoff (opcional):
  - Setea `schedule.retry=true` para defaults, o un objeto:
  - `max_attempts` (default `3`), `base_delay_seconds` (default `1`), `max_delay_seconds` (default `30`), `jitter` (default `0.2`).
  - Retries aplican a status `0`, `429`, `503` y `>=500`. El scheduler actualiza `last_error` con `retrying ...`.
- Consola: `GET /console/scheduler` muestra schedules + keep_warm (requiere `FN_UI_ENABLED=1`).
- Toggles globales:
  - `FN_SCHEDULER_ENABLED=0` deshabilita el scheduler.
  - `FN_SCHEDULER_INTERVAL` controla el tick (default `1` segundo).
  - `FN_SCHEDULER_PERSIST_ENABLED=0` deshabilita persistencia de estado.
  - `FN_SCHEDULER_PERSIST_INTERVAL` controla cada cuánto se escribe el estado (segundos).
  - `FN_SCHEDULER_STATE_PATH` permite override del path del archivo.

## `fn.env.json` y secretos

- `fn.env.json`: valores inyectados en `event.env`
- los secretos se marcan en el mismo archivo con `is_secret`

Ejemplo:

```json
{
  "API_KEY": {"value": "secret-value", "is_secret": true},
  "PUBLIC_FLAG": {"value": "on", "is_secret": false},
  "LEGACY_VALUE": "compatible"
}
```
