# Especificación de funciones


> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: FastFN resuelve dependencias y build por función según el runtime: Python usa `requirements.txt`, Node usa `package.json`, PHP instala desde `composer.json` cuando existe, y Rust compila handlers con `cargo`. En `fastfn dev --native` necesitas runtimes y herramientas del host; `fastfn dev` depende de un daemon de Docker activo.
## Nombres y rutas

- nombre (flat): `^[a-zA-Z0-9_-]+$`
- nombre (namespaced): `<segmento>/<segmento>/.../<nombre>` donde cada segmento cumple `^[a-zA-Z0-9_-]+$`
- versión: `^[a-zA-Z0-9_.-]+$`
- rutas públicas (por defecto):
  - `/<name>` (flat)
  - `/<segmento>/<segmento>/.../<nombre>` (namespaced — la estructura de directorios se mapea a rutas, estilo Next.js)
  - `/<name>@<version>`

Los nombres con namespace mapean la estructura de directorios directamente a rutas URL:

| Path en disco (bajo carpeta runtime) | Nombre de función | Ruta |
|---------------------------------------|-------------------|------|
| `hello/handler.py` | `hello` | `/hello` |
| `alice/hello/handler.py` | `alice/hello` | `/alice/hello` |
| `api/v1/users/handler.py` | `api/v1/users` | `/api/v1/users` |

Casos de uso: plataformas multi-tenant (`alice/hello`, `bob/greet`), namespacing de APIs (`api/v1/users`), agrupación organizacional (`team/service/handler`).

## Estado de runtimes

Implementados y ejecutables hoy:

- `python`
- `node`
- `php`
- `lua` (corre in-process dentro de OpenResty — no necesita daemon externo)

Experimentales (opt-in via `FN_RUNTIMES`):

- `rust`
- `go`

## Root de funciones configurable

FastFN descubre funciones escaneando un directorio del filesystem.

Setup común (recomendado):

1. Crear `functions/` en tu repo.
2. Correr `fastfn dev functions` (o setear `"functions-dir": "functions"` en `fastfn.json`).

También puedes controlar discovery con:

- `FN_RUNTIMES` (CSV, ejemplo `python,node,php,rust`)
- `FN_RUNTIME_SOCKETS` (JSON runtime -> socket URI)
- `FN_SOCKET_BASE_DIR` (base de sockets si no hay mapa explícito)

Precedencia de runtime (cuando hay colisiones):

- Si el mismo nombre existe en varios runtimes, `/<name>` usa el primer runtime en `FN_RUNTIMES`.
- Si `FN_RUNTIMES` no está definido, usa orden alfabético de carpetas runtime.

## Cableado de procesos runtime

El cableado global de runtimes vive fuera de `fn.config.json`.

Controles principales:

- `FN_RUNTIMES` para habilitar runtimes
- `runtime-daemons` o `FN_RUNTIME_DAEMONS` para definir counts por runtime externo
- `FN_RUNTIME_SOCKETS` para pasar un mapa explícito de sockets
- `runtime-binaries` o `FN_*_BIN` para elegir el ejecutable del host usado por cada runtime o herramienta

Reglas importantes:

- `lua` corre dentro de OpenResty, así que los counts para `lua` se ignoran.
- `FN_RUNTIME_SOCKETS` acepta string o array por runtime.
- Si defines `FN_RUNTIME_SOCKETS`, gana sobre los sockets generados desde `runtime-daemons`.
- FastFN elige un ejecutable por clave. Si ejecutas tres daemons de Python, los tres usan el mismo `FN_PYTHON_BIN`.

Ejemplo:

```json
{
  "runtime-daemons": {
    "node": 3,
    "python": 3
  },
  "runtime-binaries": {
    "python": "python3.12",
    "node": "node20"
  }
}
```

## Archivos de codigo

Archivos de entrada por runtime (en orden de resolucion):

| Runtime | Candidatos (en orden) |
|---------|----------------------|
| Python  | `handler.py` → `main.py` |
| Node    | `handler.js` → `handler.ts` → `index.js` → `index.ts` |
| PHP     | `handler.php` → `index.php` |
| Lua     | `handler.lua` → `main.lua` → `index.lua` |
| Go      | `handler.go` → `main.go` |
| Rust    | `handler.rs` |

!!! tip "Convencion"
    Usa `handler.<ext>` como default. El nombre coincide con el callable por defecto (`handler(event)`) y mantiene el contrato publico consistente entre runtimes.

### Resolucion de handler (2 pasos)

La resolucion del handler funciona en dos pasos: **seleccion de archivo** y luego **seleccion del callable**.

**Paso 1 — Seleccion de archivo:**

1. `entrypoint` explicito en `fn.config.json` (e.g. `src/my_handler.py`).
2. Rutas por archivo (estilo Next.js): `<method>.<tokens>.<ext>` o `<method>.<ext>`.
3. Archivos de entrada por defecto en orden fijo por runtime (ver tabla arriba).

No existe fallback a "el primer archivo del directorio". Si ninguna regla coincide, la carpeta no expone endpoint.

**Paso 2 — Seleccion del callable:**

- Default: `handler(event)`
- Override con `fn.config.json` → `invoke.handler` (debe ser identificador valido: `^[a-zA-Z_][a-zA-Z0-9_]*$`).
- Python: si el callable `handler` no existe, FastFN busca `main(event)` como fallback.
- Cloudflare Workers adapter: si `invoke.adapter` es `cloudflare-worker`, FastFN busca primero `fetch` antes del nombre configurado.

| Campo | Alcance | Ejemplo | Efecto |
|-------|---------|---------|--------|
| `entrypoint` | Seleccion de archivo | `"src/api.py"` | Carga `src/api.py` en vez de archivos por convencion |
| `invoke.handler` | Seleccion de callable | `"process_request"` | Llama `process_request(event)` en vez de `handler(event)` |

### Inyeccion directa de parametros

Cuando una ruta tiene segmentos dinamicos (e.g. `[id]`, `[...slug]`), los parametros extraidos se inyectan en el handler. El mecanismo varia por runtime:

| Runtime | Metodo de inyeccion | Firma de ejemplo |
|---------|---------------------|------------------|
| Python  | `inspect.signature` → kwargs nombrados | `def handler(event, id):` |
| Node    | Segundo argumento (objeto desestructurado) | `async (event, { id }) =>` |
| PHP     | `ReflectionFunction` → segundo argumento | `function handler($event, $params)` |
| Lua     | Siempre segundo argumento (tabla) | `function handler(event, params)` |
| Go      | Merge en event map bajo clave `params` | `event["params"]["id"]` |
| Rust    | Merge en event Value bajo clave `params` | `event["params"]["id"]` |

Los parametros siempre estan disponibles en `event.params` sin importar el runtime. La inyeccion directa es una conveniencia que evita extraccion manual.

## Modos de discovery

FastFN usa tres modos de discovery de rutas. El modo sale de la estructura real de la carpeta, no de una blacklist ad hoc de nombres.

### 1. Arbol puro de rutas por archivos

Si una carpeta **no** define un entrypoint único, FastFN trata los archivos compatibles como rutas públicas.

Ejemplos:

- `users/index.js` -> `GET /users`
- `users/[id].js` -> `GET /users/:id`
- `admin/post.users.[id].py` -> `POST /admin/users/:id`
- `hello.js` -> `GET /hello`
- Se permite exactamente un prefijo de método por archivo. `get.post.items.js` es ambiguo y FastFN lo ignora con warning.

Los helpers privados en este modo deben usar prefijo `_`:

- `_shared.js`
- `_helpers.py`
- `_csv.php`

Esos archivos quedan privados y no aparecen en OpenAPI ni en el catálogo.

### 2. Single-entry root

Si una carpeta declara un único entrypoint de función, esa carpeta se comporta como una función single-entry, similar a un directorio Lambda.

Una carpeta entra en este modo cuando tiene:

1. `fn.config.json` con `entrypoint` explícito, o
2. un archivo canónico como `handler.*`, `main.*` o `index.*` (ver tabla por runtime arriba)

Ejemplos:

- `payments/handler.js` -> `GET/POST/DELETE /payments`
- `risk-score/main.py` -> `GET /risk-score`

En este modo, los archivos hermanos son módulos internos por defecto:

- `payments/core.js` se puede importar desde `handler.js`, pero **no** se publica como `/payments/core`
- `risk-score/model.py` se puede importar desde `main.py`, pero **no** se publica como `/risk-score/model`

### 3. Subárbol mixto

Dentro de una función single-entry, las subcarpetas todavía pueden exponer subrutas file-based explícitas.

Ejemplos:

- `shop/handler.js` -> `/shop`
- `shop/admin/index.js` -> `/shop/admin`
- `shop/admin/get.health.js` -> `GET /shop/admin/health`

Dentro de un subárbol mixto solo se publican archivos de ruta explícitos:

- `index.*`, `handler.*`, `main.*`
- archivos con prefijo de método como `get.*`, `post.*`, `put.*`, `patch.*`, `delete.*`
- archivos dinámicos como `[id].*`, `[...slug].*`, `[[...slug]].*`

Helpers planos como `core.js`, `shared.py`, `lib.php`, `common.rs` o `utils.go` quedan privados.

## Estructura recomendada (relativa a `FN_FUNCTIONS_ROOT`)

```text
<FN_FUNCTIONS_ROOT>/
  hello/
    handler.py        # GET /hello
  users/
    get.js            # GET /users
    [id]/
      get.py          # GET /users/:id
      delete.py       # DELETE /users/:id
```

!!! info "Categorias de layout"
    - **Recomendado:** Path-neutral (`hello/handler.py`, `users/get.js`). Usado en tutoriales y `fastfn init`.
    - **Soportado (compatibilidad):** Agrupado por runtime (`python/hello/handler.py`, `node/echo/handler.js`). Util para monorepos con muchos runtimes. Discovery usa `FN_NAMESPACE_DEPTH` (default `3`, max `5`).
    - **No recomendado:** Mezclar ambos layouts en el mismo root de funciones. Discovery funciona pero la precedencia de rutas se vuelve dificil de razonar.

FastFN también soporta árboles agrupados por runtime para monorepos y repos mixtos grandes. `fastfn init` ahora genera por defecto directorios path-neutral de función única, así que toma el layout agrupado por runtime como una opción de organización y no como el camino principal que enseña esta documentación.

### Namespaces anidados (estilo Next.js)

Los directorios anidados bajo tu árbol de funciones se mapean directamente a rutas URL:

```text
hello/handler.py                  # GET /hello
api/
  v1/
    users/handler.py              # GET /api/v1/users
    orders/handler.py             # GET /api/v1/orders
alice/
  dashboard/handler.py            # GET /alice/dashboard
```

El discovery recursa en directorios que no contienen un single-entry root, tratándolos como segmentos de namespace. Un directorio que contiene un single-entry root (`handler.py`, `handler.js`, `main.py`, `entrypoint` explícito, etc.) se trata como una función. Las subcarpetas descendientes pueden seguir exponiendo rutas file-based explícitas, pero los módulos helper hermanos quedan privados.

**Límite de profundidad**: `FN_NAMESPACE_DEPTH` controla cuántos niveles profundiza el scanner para árboles agrupados por runtime en modo compatibilidad (default `3`, max `5`). Por ejemplo, con depth 3 el path `python/a/b/c/handler.py` se descubre como función `a/b/c` → ruta `/a/b/c`.

!!! note "Límites de Profundidad"
    El ajuste `FN_NAMESPACE_DEPTH` aplica a directorios agrupados por runtime en modo compatibilidad (por ejemplo `python/`, `node/`).
    Las rutas zero-config basadas en archivos usan un límite de profundidad fijo separado de **6 niveles**.
    Los paths que exceden ese límite fijo zero-config se omiten con warning de discovery, en lugar de fallar silenciosamente.

No existe fallback a "el primer archivo del directorio". Si ninguna regla de entrypoint o ruta explícita coincide, esa carpeta no expone un endpoint público.

Si una carpeta contiene múltiples entry files compatibles entre runtimes, FastFN resuelve de forma determinista en el orden `go`, `lua`, `node`, `php`, `python`, `rust` y emite un warning con los matches ignorados.

El discovery de namespaces y file routes también avisa cuando un segmento cae fuera del set ASCII soportado o cuando la ruta pública normalizada colisiona con prefijos reservados como `/_fn` o `/console`.

Archivos opcionales por funcion/version:

- `fn.config.json`
- `fn.env.json`
- `requirements.txt` (Python)
- `package.json`, `package-lock.json` (Node)
- `composer.json`, `composer.lock` (PHP, opcional)
- `Cargo.toml`, `Cargo.lock` (Rust, opcional)

## Ejemplos minimos de handler (mismo contrato)

Todos consumen `event`. El contrato portable recomendado es devolver `{status, headers, body}`.

### Python

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

### Node

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

### PHP

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

### Rust

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

## Respuesta sencilla (atajos por runtime)

El contrato canonico portable sigue siendo:

- `{ status, headers, body }`
- o binario `{ status, headers, is_base64, body_base64 }`

Soporte de atajos por runtime:

| Runtime | Soporte | Formas aceptadas | Notas |
|---------|---------|------------------|-------|
| Node    | si | dict/object, string, number, array | Valores sin envelope se envuelven como JSON body con status `200` |
| Python  | si | `dict`, `tuple` `(body, status, headers)`, `(body, status)`, `(body,)`, `dict`/`list` plano | Dict sin clave `status` se envuelve como JSON `200`. `statusCode` aceptado como alias de `status`. `bytes` en body se codifica como base64 automaticamente. |
| PHP     | si | array, object, primitivo | Se envuelve como JSON body con status `200` |
| Lua     | si | table, string, number | Se envuelve como JSON body con status `200` |
| Go      | no | — | Requiere envelope explicito `{ "status", "headers", "body" }` |
| Rust    | no | — | Requiere envelope explicito `{ "status", "headers", "body" }` |

Respuestas binarias: usa `is_base64: true` y proporciona el contenido en `body_base64`. Python detecta `bytes` en `body` y codifica como base64 automaticamente.

Validacion de status: todos los runtimes validan codigos de estado en rango `100-599`.

Para paridad entre runtimes, usa respuesta explicita en ejemplos compartidos.

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
- `invoke.handler` (opcional, nombre de función exportada dentro del archivo resuelto; default `handler`)
- `invoke.routes` (mapeo opcional de endpoint publico)
- `invoke.force-url` (opcional, si `true` puede sobrescribir una URL ya mapeada)
- `invoke.adapter` (Beta, Node/Python): modo de compatibilidad (`native`, `aws-lambda`, `cloudflare-worker`)
- `home` (opcional, overlay por carpeta/root):
  - `home.route` o `home.function`: path interno a ejecutar como home.
  - `home.redirect`: URL/path para redirección home (`302`).
- `assets` (opcional, solo en root) para montar una carpeta estática en `/`:
  - `assets.directory`: carpeta relativa a servir, por ejemplo `public` o `dist`.
  - `assets.not_found_handling`: `404` o `single-page-application`.
  - `assets.run_worker_first`: si es `true`, las rutas de funciones ganan antes que los assets.
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
    "adapter": "native",
    "force-url": false,
    "methods": ["GET", "POST"],
    "routes": ["/api/mi-funcion"],
    "summary": "Mi funcion",
    "query": {"name": "World"},
    "body": ""
  },
  "home": {
    "route": "/api/mi-funcion"
  }
}
```

Notas:

- `invoke.handler` permite estilo Lambda con nombre de handler custom (`main`, `run`, etc.).
- `invoke.handler` elige el símbolo a invocar dentro del archivo ya resuelto; no cambia la selección del archivo.
- En runtimes Node y Python, esa función debe existir/exportarse en el mismo archivo.
- Python además acepta `main(req)` cuando no existe `handler`.
- `invoke.routes` es opcional.
- Si existe, cada ruta debe ser absoluta (por ejemplo `/api/mi-funcion`).
- En layout por archivos, `home.route` permite aliasar la raíz de una carpeta (por ejemplo `/portal`) hacia otra ruta detectada en esa carpeta (por ejemplo `/portal/dashboard`).
- En `fn.config.json` raíz, `home.route`/`home.redirect` permite override de `/` sin editar Nginx.
- En `fn.config.json` raíz también puedes definir `assets` para que FastFN sirva una carpeta pública directamente desde el gateway, estilo Cloudflare.
- `assets.directory` debe ser un path relativo seguro dentro del root de funciones y la carpeta debe existir.
- `assets` es root-only en v1; los `fn.config.json` anidados no crean mounts públicos adicionales.
- `/_fn/*` y `/console/*` siguen reservados y nunca se sirven desde `assets`.
- `assets` no expone carpetas hermanas de funciones: solo se sirve el directorio configurado y FastFN bloquea dotfiles e intentos de traversal.
- Prefijos reservados no permitidos (`/_fn`, `/console`, `/docs`).
- Si dos rutas colisionan con la misma prioridad de discovery, FastFN no conserva ninguna de las dos para esa URL, la registra como conflicto y responde `409` hasta que la desambigües.
- Por defecto, FastFN no sobrescribe silenciosamente un mapeo de URL existente.
- Usa `invoke.force-url: true` solo cuando realmente quieres que esta función se quede con una ruta (por ejemplo, durante una migración).
- Los configs por versión (por ejemplo `mi-fn/v2/fn.config.json`) no pueden \"tomar\" una URL existente por sí solos; usa `FN_FORCE_URL=1` si necesitas que una ruta versionada gane.
- Override global: setea `FN_FORCE_URL=1` (o `fastfn dev --force-url`) para tratar todas las rutas config/policy como forced.

### Mapeo de rutas con `fn.routes.json` e `invoke.routes`

FastFN te da tres herramientas para mapear rutas. La regla práctica es:

- usa nombres de archivo cuando la URL puede seguir el árbol de carpetas
- usa `fn.routes.json` cuando una carpeta necesita mapear varios archivos a rutas públicas explícitas
- usa `invoke.routes` cuando una función lógica necesita uno o más aliases públicos

#### `fn.routes.json`

Pon `fn.routes.json` en una carpeta cuando quieras un manifiesto corto que conecte rutas públicas con entry files de esa misma carpeta.

Ejemplo:

```json
{
  "routes": {
    "GET /healthz": "health.py",
    "POST /hooks/rebuild": "rebuild.js",
    "GET,POST /contact": "contact.php",
    "/status": "status.py"
  }
}
```

Reglas:

- Las claves son definiciones de ruta.
- Los valores son archivos relativos a la carpeta que contiene `fn.routes.json`.
- Si omites el prefijo de método HTTP, FastFN trata esa ruta como `GET`.
- Puedes listar más de un método en la clave, por ejemplo `GET,POST /hook`.
- El runtime se infiere a partir de la extensión del archivo target.
- Los prefijos reservados como `/_fn/*` y `/console/*` siguen bloqueados.

Casos típicos:

- una carpeta poliglota donde los nombres de archivo deben quedar cortos, pero las URLs deben ser explícitas
- migrar una API sin renombrar handlers
- mezclar handlers Node/Python/PHP detrás de un mapa de rutas escrito a mano

#### `invoke.routes`

Usa `invoke.routes` dentro del `fn.config.json` de una función cuando la función ya tiene identidad propia y quieres publicarla también en una o más URLs adicionales.

Ejemplo:

```json
{
  "invoke": {
    "methods": ["GET", "POST"],
    "routes": ["/api/forms/contact", "/contact"]
  }
}
```

Esta opción conviene cuando:

- una sola función es dueña de la política de rutas y aliases
- métodos, host rules, summary y otros `invoke.*` deben vivir junto al config de la función
- estás agregando una ruta vanity o un alias de migración a una función existente

#### Precedencia y conflictos

Comportamiento importante:

- Las file routes y `fn.routes.json` se descubren juntas para la misma carpeta.
- Cuando la misma ruta existe en ambos lugares, `fn.routes.json` gana para esa ruta y se salta el duplicado basado en archivo.
- `invoke.routes` registra aliases públicos explícitos después del discovery y puede chocar con otras URLs ya mapeadas.
- Si dos rutas colisionan con la misma prioridad, FastFN registra el conflicto y responde `409` en esa URL hasta que lo resuelvas.
- Usa `invoke.force-url: true` solo cuando quieras reemplazar de forma intencional una URL pública ya tomada.

### Assets públicos en root

Usa `assets` en el `fn.config.json` raíz cuando quieres que FastFN sirva una carpeta desde `/` sin pasar por un handler.

Ejemplo:

```json
{
  "assets": {
    "directory": "public",
    "not_found_handling": "single-page-application",
    "run_worker_first": false
  }
}
```

Comportamiento:

- `GET` y `HEAD` se sirven directo desde el gateway.
- `/` y las URLs de directorio resuelven a `index.html`.
- En modo `single-page-application`, los misses de navegación vuelven a `index.html`.
- Los paths tipo archivo inexistentes, como `/missing.js`, siguen devolviendo `404`.
- Una carpeta de assets vacía no crea una home sintética. Si no hay asset real, ni home explícito, ni rutas descubiertas, `/` devuelve `404`.
- Si `run_worker_first` es `true`, FastFN prueba primero las rutas de funciones y solo cae a assets cuando no hubo match.
- Esto vuelve first-class a carpetas tipo `public/` o `dist/` sin perder handlers normales.
- Mira los demos ejecutables en `examples/functions/assets-static-first`, `examples/functions/assets-spa-fallback` y `examples/functions/assets-worker-first`.

### `keep_warm`

La configuración `keep_warm` indica al scheduler que mantenga la función cargada y lista.

- `enabled`: activa el scheduler de keep-warm.
- `min_warm`: cantidad mínima a mantener caliente.
- `ping_every_seconds`: intervalo entre heartbeats.
- `idle_ttl_seconds`: cuánto tiempo puede quedar ociosa antes de enfriarse.

### `worker_pool`

`worker_pool` es la forma más simple de controlar una función sin cambiar sus rutas.

Detalle importante del modelo:

- `worker_pool` es **por función**.
- `runtime-daemons` es **por runtime** y vive en `fastfn.json` o en variables de entorno, no en `fn.config.json`.
- OpenResty/Lua aplica `worker_pool.max_workers`, `max_queue` y timeouts de cola **antes** de entrar al runtime.
- Después de admitir la request, el gateway elige un socket sano del runtime. Si el runtime tiene más de un socket, la selección es `round_robin`.

Ejemplo:

```json
{
  "worker_pool": {
    "enabled": true,
    "max_workers": 3,
    "max_queue": 6,
    "queue_timeout_ms": 5000,
    "idle_ttl_seconds": 300,
    "overflow_status": 429
  }
}
```

Campos principales:

- `enabled`: activa la ejecución con pool para esa función.
- `max_workers`: máximo de ejecuciones activas admitidas para la función.
- `max_queue`: requests extra permitidas en cola cuando todos los workers están ocupados.
- `queue_timeout_ms`: cuánto puede esperar una request en cola antes de devolver `overflow_status`.
- `idle_ttl_seconds`: cuánto tiempo permanecen vivos los workers ociosos antes de limpiarse.
- `overflow_status`: estado de respuesta al desbordar cola o agotar espera (`429` o `503`).
- `min_warm`: mantiene algunos workers ya creados cuando el runtime lo soporta.
- `queue_poll_ms`: Frecuencia de verificacion de capacidad disponible cuando un request esta en cola (ajuste interno, raramente necesita cambiarse).

Comportamiento actual por runtime:

| Runtime | Routing multi-daemon | Fan-out interno del runtime |
|---|---|---|
| Node | soportado | además usa workers hijos dentro de `node-daemon.js` |
| Python | soportado | la ejecución sigue dependiendo del comportamiento del daemon Python |
| PHP | soportado | el despacho sucede mediante el lanzador PHP |
| Rust | soportado | el despacho sucede mediante el binario compilado |
| Lua | no aplica | corre dentro de OpenResty |

El snapshot de benchmark verificado el **14 de marzo de 2026** mostró resultados dependientes del runtime: algunos mejoraron mucho con más daemons, otros poco, y un path native de PHP llegó a empeorar antes de un fix posterior.

Usa la página canónica de benchmarks para ver los números exactos y los artefactos crudos antes de activar más daemons en todos los runtimes:

- [Benchmarks de rendimiento](../explicacion/benchmarks-rendimiento.md)

### Adaptadores de invocacion

El campo `invoke.adapter` en `fn.config.json` controla la convencion de llamada del handler. Default: `native`.

| Adaptador | Firma del handler | Disponible para |
|-----------|-------------------|-----------------|
| `native` | `handler(event)` | Todos los runtimes |
| `aws-lambda` | `handler(event, context)` | Python, Node |
| `cloudflare-worker` | `fetch(request, env, ctx)` | Python, Node |

**Aliases:** `lambda`, `apigw-v2`, `api-gateway-v2` → `aws-lambda`. `worker`, `workers` → `cloudflare-worker`.

**Adaptador AWS Lambda:**

- `event` se transforma al formato API Gateway v2.
- `context` provee `getRemainingTimeInMillis()`, `done()`, `fail()`, `succeed()`.
- El valor de retorno se normaliza de vuelta al envelope FastFN.

**Adaptador Cloudflare Workers:**

- Busqueda de handler: FastFN busca primero un export `fetch`, luego cae al nombre configurado.
- `request` provee `.text()`, `.json()`, `.url`, `.method`, `.headers`.
- `env` contiene las variables de entorno de la funcion desde `fn.env.json`.
- `ctx` provee `waitUntil()` y `passThroughOnException()`.
- `ctx.waitUntil()` corre como trabajo best-effort en background: no retrasa la respuesta HTTP y los awaitables rechazados quedan logueados como eventos de runtime.

Nota Node + Lambda callback:

- En modo `aws-lambda`, Node soporta tanto handlers async como handlers con callback (`event, context, callback`).

```json
{
  "invoke": {
    "adapter": "aws-lambda",
    "handler": "handler"
  }
}
```

## Config edge passthrough (`edge`)

Si quieres un comportamiento estilo Cloudflare Workers (el handler devuelve un `proxy` y el gateway hace el request saliente), habilítalo por función en `fn.config.json`:

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

Después el handler puede devolver `{ "proxy": { ... } }`. Ver el contrato completo en: **Contrato Runtime**.

## Gestion de dependencias (auto-install + inferencia)

FastFN resuelve dependencias o build por carpeta de función y agrega inferencia autónoma para Python/Node.

Modelo de resolucion:

- Python, Node y PHP usan manifiestos locales por función (`requirements.txt`, `package.json`, `composer.json`).
- Los handlers Rust se compilan con `cargo` dentro de un workspace `.rust-build/` por función.
- FastFN no busca automaticamente dependencias en la raiz del repo.
- Para reutilizacion entre muchas funciones, usa `shared_deps`.
- Python y Node dejan trazabilidad de resolucion en `<function_dir>/.fastfn-deps-state.json`.
- PHP y Rust hoy resuelven/installan/build-ean directo sin ese archivo de estado por funcion.

### Archivos que FastFN escribe por runtime

| Runtime | Archivo de estado | Lock/snapshot | Directorio de deps | Directorio de build |
|---------|------------------|---------------|--------------------|--------------------|
| Python  | `.fastfn-deps-state.json` | `requirements.lock.txt` (informativo, output de `pip freeze`) | `.deps/` | — |
| Node    | `.fastfn-deps-state.json` | `package-lock.json` (funcional, lo usa `npm ci`) | `node_modules/` | — |
| PHP     | — | — | `vendor/` | — |
| Rust    | — | — | — | `.rust-build/` |
| Go      | — | — | — | `.go-build/` |
| Lua     | — | — | — | — (in-process, sin deps externas) |

`requirements.lock.txt` es un snapshot informativo generado por `pip freeze`. NO se usa para instalacion — solo para auditar lo que se instalo. `package-lock.json` es funcional — `npm ci` lo usa para instalaciones deterministas.

Cuando corre la inferencia en Python o Node, FastFN tambien guarda:

- `infer_backend`
- `inference_duration_ms`

### Python (manifiesto + inferencia)

Entradas soportadas:

- `requirements.txt`
- hints inline `#@requirements ...`
- inferencia de imports cuando falta o esta incompleto el manifiesto

Hints inline: FastFN escanea las primeras 30 lineas del handler buscando comentarios `#@requirements <paquete> [<paquete>...]`. Se combinan con las entradas de `requirements.txt`.

Comportamiento:

- Si falta `requirements.txt` y la inferencia resuelve imports, FastFN lo crea automaticamente.
- Si `requirements.txt` existe, agrega paquetes faltantes inferidos sin borrar tus pins.
- Tras una instalacion exitosa, escribe `requirements.lock.txt` (lock informativo en v1).

Toggles:

- `FN_AUTO_REQUIREMENTS=0` desactiva auto-install de Python.
- `FN_AUTO_INFER_PY_DEPS=0` desactiva inferencia Python.
- `FN_PY_INFER_BACKEND=native|pipreqs` elige el backend de inferencia Python.
- `FN_AUTO_INFER_WRITE_MANIFEST=0` evita escribir manifiestos desde inferencia.
- `FN_AUTO_INFER_STRICT=1` falla si hay imports no resolubles.
- `FN_PREINSTALL_PY_DEPS_ON_START=1` preinstala deps al iniciar runtime.

Invalidacion de cache: FastFN calcula una firma con el mtime del handler, mtime del manifiesto e inline requirements. Si la firma coincide con la instalacion previa y `.deps/` no esta vacio, reutiliza las dependencias. Timeout de instalacion: 180 segundos.

La inferencia es opcional y normalmente mas lenta que usar un manifiesto explicito porque FastFN puede tener que analizar imports o invocar una herramienta externa.
Para el loop mas rapido y para produccion, prefiere `requirements.txt` o `#@requirements`.

La inferencia solo auto-agrega nombres directos de paquete, por ejemplo `requests -> requests`.
FastFN no mantiene una tabla interna de aliases de imports Python.
Si el nombre del import no coincide con el paquete que instalas (`PIL`/`Pillow`, `yaml`/`PyYAML`, `jwt`/`PyJWT`, etc.), decláralo explícitamente en `requirements.txt` o con `#@requirements`.
Cuando lo declaras explícitamente, ese manifiesto pasa a ser la fuente de verdad y los imports alias no resueltos quedan como información, no como bloqueo de instalación.

Notas de backend:

- `native` es el default y es intencionalmente conservador.
- `pipreqs` es opt-in y requiere que `pipreqs` exista en el entorno donde corre el daemon Python.

### Node (manifiesto + inferencia)

Entradas soportadas:

- `package.json`
- inferencia de `import/require` para dependencias faltantes

Comportamiento:

- Si falta `package.json` y hay imports resolubles, FastFN crea `package.json`.
- Si existe `package.json`, agrega dependencias faltantes inferidas.
- Con lockfile usa `npm ci`; sin lockfile usa `npm install`.

Si `npm ci` falla con lockfile presente, FastFN reintenta con `npm install`. Timeout de instalacion: 180 segundos.

Toggles:

- `FN_AUTO_NODE_DEPS=0` desactiva auto-install de Node.
- `FN_AUTO_INFER_NODE_DEPS=0` desactiva inferencia Node.
- `FN_NODE_INFER_BACKEND=native|detective|require-analyzer` elige el backend de inferencia Node.
- `FN_AUTO_INFER_WRITE_MANIFEST=0` evita escritura de manifiesto inferido.
- `FN_AUTO_INFER_STRICT=1` activa fail-fast en imports no resolubles.
- `FN_PREINSTALL_NODE_DEPS_ON_START=1` preinstala deps al iniciar.
- `FN_PREINSTALL_NODE_DEPS_CONCURRENCY=4` controla concurrencia de preinstall.

Invalidacion de cache: FastFN calcula una firma con el mtime de `package.json` y de `package-lock.json` (o `"no-lock"` si no existe). Si la firma coincide y `node_modules/` existe, reutiliza las dependencias.

La inferencia de Node excluye paquetes que coincidan con nombres de `shared_deps` para evitar duplicar dependencias compartidas.

La inferencia de Node tambien es opcional y normalmente mas lenta que declarar `package.json` desde el inicio.
Usa manifiestos explicitos cuando ya conoces las dependencias o cuando quieres el arranque mas corto posible.

Notas de backend:

- `native` es el default.
- `detective` es opt-in y funciona mejor con `require(...)` estatico.
- `require-analyzer` es opt-in y sirve como ayuda de bootstrap mas amplia, pero no reemplaza un `package.json` explicito.

### PHP (solo manifiesto en esta fase)

- Usa `composer.json` (y opcionalmente `composer.lock`) por funcion.
- FastFN ejecuta `composer install` por funcion cuando corresponde.
- No hay inferencia por imports en PHP en esta fase.
- `FN_AUTO_PHP_DEPS=0` desactiva auto-install de Composer.
- PHP hoy no emite `metadata.dependency_resolution`.

### Rust (build en esta fase)

Comportamiento:

- FastFN compila handlers Rust con `cargo build --release`.
- El runtime prepara un workspace `.rust-build/` por función y compila el handler allí.
- No hay inferencia por imports para Rust en esta fase.
- El modo native requiere `cargo` en `PATH`.
- Rust hoy no emite `metadata.dependency_resolution`.

### Go (build)

- FastFN compila handlers Go con `go build` dentro de un workspace `.go-build/` por funcion.
- Si `go.mod` y `go.sum` existen en el directorio de la funcion, se usan para resolucion de modulos.
- Timeout de build controlado por `GO_BUILD_TIMEOUT_S` (default: `180` segundos).
- El modo native requiere `go` en `PATH`.
- Go es experimental y debe habilitarse via `FN_RUNTIMES`.

### Lua (in-process)

Los handlers Lua corren dentro del proceso OpenResty. No hay daemon externo, no hay instalacion de dependencias ni archivos de estado. Los modulos disponibles en el entorno OpenResty (`cjson`, `resty.*`) se pueden usar directamente.

### Errores estrictos y transparencia

- Si la inferencia no resuelve imports (con strict activo), la invocacion falla con error accionable.
- Los fallos de install o build muestran un tail corto de pip/npm/composer/cargo para debug rapido.
- `GET /_fn/function` expone `metadata.dependency_resolution` cuando el runtime escribe ese estado (hoy sobre todo Python/Node).

Flujo resumido:

1. FastFN lee el manifiesto local de la funcion.
2. Si el manifiesto ya alcanza, instala desde ahi.
3. Si falta o esta incompleto, Python y Node pueden inferir imports y escribir el manifiesto.
4. Luego el runtime guarda estado de resolucion y lock info cuando aplica.
5. Finalmente ejecuta el handler o compila el binario Rust.

## Packs de dependencias compartidas (`shared_deps`)

Si quieres que varias funciones reutilicen la misma instalación de dependencias (por ejemplo un `node_modules` compartido para Node, o una carpeta de pip compartida para Python), puedes usar packs compartidos.

Los nombres de pack los defines tú, y una función puede combinar sus dependencias locales con uno o más packs compartidos.

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

Si tu functions root es runtime-scoped (por ejemplo `<root>/python` o `<root>/node`), FastFN también revisa un nivel arriba buscando el mismo layout `.fastfn/packs/<runtime>/...` para mantener compatibilidad con esa variante.

Ejemplos:

- Pack Python: `<FN_FUNCTIONS_ROOT>/.fastfn/packs/python/qrcode_pack/requirements.txt`
- Pack Node: `<FN_FUNCTIONS_ROOT>/.fastfn/packs/node/qrcode_pack/package.json`
- Pack Node TypeScript (esbuild): `<FN_FUNCTIONS_ROOT>/.fastfn/packs/node/ts_pack/package.json`

En Node, el pack también puede traer un `node_modules/` ya resuelto dentro del propio pack. Si existe `package.json`, FastFN puede instalar ahí las dependencias del pack.

En runtime:

- la función conserva sus dependencias locales si las tiene
- `shared_deps` suma uno o más roots reutilizables por encima de eso
- Python instala en `<pack>/.deps` y lo agrega a `sys.path`
- Node instala en `<pack>/node_modules` y lo agrega a la resolucion de modulos para esa invocacion
- si falta un pack configurado, FastFN falla rápido con un error accionable

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
- macros: `@hourly`, `@daily`, `@midnight`, `@weekly`, `@monthly`, `@yearly`, `@annually`
- aliases de mes/dia: `JAN..DEC`, `SUN..SAT`
- day-of-week acepta `0..6` y tambien `7` para domingo

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
- offsets fijos como `+02:00`, `-05:00`, `+0200` o `-0500`

- El scheduler corre dentro de OpenResty (worker 0).
- Invoca el runtime por unix socket.
- La policy aplica igual (metodos, body, concurrencia, timeout).
- Para correr cada **X minutos**, usa `every_seconds = X * 60` (ejemplo: 15 minutos => `900`).
- Cuando day-of-month y day-of-week estan restringidos a la vez, el match sigue semantica tipo Vixie (`OR`).
- Estado del scheduler: `GET /_fn/schedules` (`next`, `last`, `last_status`, `last_error`).
- Cuando hay retries pendientes, el snapshot tambien expone `retry_due` y `retry_attempt`.
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
  - El runtime clamp-ea: `max_attempts` `1..10`, delays `0..3600`, `jitter` `0..0.5`.
  - Retries aplican a status `0`, `429`, `503` y `>=500`. El scheduler actualiza `last_error` con `retrying ...`.
- Consola: `GET /console/scheduler` muestra schedules + keep_warm (requiere `FN_UI_ENABLED=1`).
- Toggles globales:
  - `FN_SCHEDULER_ENABLED=0` deshabilita el scheduler.
  - `FN_SCHEDULER_INTERVAL` controla el tick (default `1` segundo, minimo efectivo `1`).
  - `FN_SCHEDULER_PERSIST_ENABLED=0` deshabilita persistencia de estado.
  - `FN_SCHEDULER_PERSIST_INTERVAL` controla cada cuánto se escribe el estado (segundos, clamp `5..3600`).
  - `FN_SCHEDULER_STATE_PATH` permite override del path del archivo.

## `fn.env.json` y secretos

- `fn.env.json`: valores inyectados en `event.env`
- los secretos se marcan en el mismo archivo con `is_secret`

Ejemplo:

```json
{
  "API_KEY": {"value": "secret-value", "is_secret": true},
  "PUBLIC_FLAG": {"value": "on", "is_secret": false}
}
```

## Diagrama de Flujo de Ejecución

```mermaid
flowchart LR
  A["Request HTTP entrante"] --> B["Resolución de ruta"]
  B --> C["Evaluación de política fn.config"]
  C --> D["Adaptador de runtime"]
  D --> E["Normalización de respuesta del handler"]
  E --> F["Salida consistente con OpenAPI"]
```

## Contrato

Define la forma esperada de request/response, campos de configuración y garantías de comportamiento.

## Ejemplo End-to-End

Usa los ejemplos de esta página como plantillas canónicas para implementación y testing.

## Casos Límite

- Fallbacks ante configuración faltante
- Conflictos de rutas y precedencia
- Matices por runtime

## Ver también

- [Referencia API HTTP](api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
- [Arquitectura](../explicacion/arquitectura.md)
