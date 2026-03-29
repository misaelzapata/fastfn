# Enrutamiento Zero-Config (estilo Next.js / rutas dinámicas por archivos)


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
## Vista Rápida

- Complejidad: Intermedio
- Tiempo típico: 15-25 minutos
- Úsalo cuando: quieres rutas por filesystem con precedencia predecible
- Resultado: el descubrimiento de rutas y los conflictos son deterministas

FastFN soporta enrutamiento basado en archivos con detección automática de runtime. Puedes publicar endpoints sin escribir `fn.config.json` por función.

## 1. Auto-descubrimiento de Runtime

El runtime se infiere por extensión de archivo:

- `.js`, `.ts` -> `node`
- `.py` -> `python`
- `.php` -> `php`
- `.rs` -> `rust`
- `.go` -> `go`

## 2. Reglas de Rutas Basadas en Archivos

Dado un root de proyecto:

```text
my-project/
  users/
    index.js
    [id].js
  blog/
    [...slug].py
  admin/
    post.users.[id].py
```

Rutas descubiertas:

- `users/index.js` -> `GET /users`
- `users/[id].js` -> `GET /users/:id`
- `blog/[...slug].py` -> `GET /blog/:slug*`
- `admin/post.users.[id].py` -> `POST /admin/users/:id`

!!! info "Profundidad de Anidamiento"
    El descubrimiento zero-config soporta hasta **6 niveles** de anidamiento de directorios.
    Por ejemplo, `api/v1/admin/users/settings/profile/index.py` se mapea a
    `GET /api/v1/admin/users/settings/profile`.
    Los directorios con más de 6 niveles se ignoran y ahora emiten un warning de discovery.

Convenciones:

- `index`, `handler` y `main` apuntan a la raíz de la carpeta.
- `[id]` mapea a un segmento dinámico (`:id`).
- `[...slug]` mapea a catch-all (`:slug*`).
- Prefijo opcional de método en nombre de archivo: `get.`, `post.`, `put.`, `patch.`, `delete.`.
- Se permite exactamente un prefijo de método por archivo. `get.post.items.js` es ambiguo, así que FastFN avisa y lo ignora.
- Archivos ignorados: `_*.ext`, `*.test.*`, `*.spec.*`.
- Catch-all opcional `[[...opt]]` mapea tanto `/base` como `/base/:opt*`.
- Prefijos reservados bloqueados: `/_fn`, `/console`.
- Los segmentos de namespace invalidos fuera del set ASCII soportado se omiten con warning.
- `/docs` está disponible para rutas públicas.
- El scanner zero-config respeta `zero_config.ignore_dirs`, `zero_config_ignore_dirs` y `FN_ZERO_CONFIG_IGNORE_DIRS` definidos en la raíz.
- El CLI avisa cuando dos file routes de la misma prioridad resuelven la misma URL y elimina esa URL del resultado de discovery, alineado con el modelo de conflictos del gateway.
- Si una carpeta contiene multiples handlers single-entry compatibles, FastFN elige uno de forma determinista usando el orden `go`, `lua`, `node`, `php`, `python`, `rust` y avisa cuáles fueron ignorados.

### Helpers privados vs endpoints públicos

FastFN distingue tres formas de discovery:

1. `pure_file_tree`: una carpeta sin entrypoint único; los archivos compatibles se publican como rutas.
2. `single_entry_root`: una carpeta con `entrypoint` en `fn.config.json` o con archivo canónico `handler.*`, `index.*`, `main.*`; la carpeta se trata como una sola función.
3. `mixed_subtree`: rutas file-based explícitas dentro de una función single-entry.

Ejemplo:

```text
users/
  index.js
  [id].js
  _shared.js
shop/
  handler.js
  core.js
  admin/
    index.js
    get.health.js
    helpers.js
```

Resultado:

- `users/index.js` -> `GET /users`
- `users/[id].js` -> `GET /users/:id`
- `users/_shared.js` -> helper privado, no ruta
- `shop/handler.js` -> `/shop`
- `shop/core.js` -> helper privado, no `/shop/core`
- `shop/admin/index.js` -> `/shop/admin`
- `shop/admin/get.health.js` -> `GET /shop/admin/health`
- `shop/admin/helpers.js` -> helper privado, no ruta

Reglas prácticas:

- En un pure file tree, prefija los helpers privados con `_`.
- En single-entry root o mixed subtree, los archivos hermanos no explícitos quedan privados por defecto.
- Los helpers privados nunca aparecen en `/_fn/openapi.json` ni en `/_fn/catalog`.
- Si el scanner omite una carpeta por profundidad, segmentos inválidos, prefijos reservados o múltiples handlers compatibles, los logs de discovery ahora explican el motivo.

Configurar carpetas ignoradas (scanner zero-config):

- Directorios ignorados por defecto: `node_modules`, `vendor`, `__pycache__`, `.fastfn`, `.deps`, `.rust-build`, `target`, `src`.
- Si defines `assets.directory` en el `fn.config.json` root, esa carpeta pública también se excluye del scanner zero-config para que no se trate como función.

!!! note "`src/` se ignora por defecto"
    El directorio `src` esta en la lista de ignorados por defecto. Si usas `entrypoint: "src/api.py"` en `fn.config.json`, el entrypoint explicito funciona — solo el discovery zero-config de rutas por archivo salta `src/`.

- Para agregar más de forma global, usa:

```bash
FN_ZERO_CONFIG_IGNORE_DIRS="build,dist,tmp" fastfn dev .
```

- O configúralo en la raíz de funciones con `fn.config.json`:

```json
{
  "zero_config": {
    "ignore_dirs": ["build", "dist", "tmp"]
  }
}
```

### Home por carpeta (`fn.config.json`)

Puedes definir un "home" de carpeta sin crear `index.*`.

Ejemplo:

```text
portal/
  fn.config.json
  get.dashboard.js
```

`portal/fn.config.json`:

```json
{
  "home": {
    "route": "dashboard"
  }
}
```

Resultado:

- `GET /portal/dashboard` -> manejado por `portal/get.dashboard.js`
- `GET /portal` -> mismo handler (alias home de carpeta)

Notas:

- `home.route` puede ser absoluto (`/portal/dashboard`) o relativo (`dashboard`).
- Para alias de carpeta, FastFN resuelve `home.route` contra rutas detectadas en esa misma carpeta.

### Comportamiento de home raíz (`/`)

Por defecto, FastFN mantiene una landing interna en `/`. Puedes overridearla:

```bash
# Dispatch interno (sin 302): ejecuta handler mapeado en /showcase
FN_HOME_FUNCTION=/showcase fastfn dev .

# Redirect (302)
FN_HOME_REDIRECT=/_fn/docs fastfn dev .
```

O desde `fn.config.json` en el root (cuando ese archivo existe en el `FN_FUNCTIONS_ROOT` efectivo):

```json
{
  "home": {
    "route": "/showcase"
  }
}
```

`home` soporta:

- `route` (o `function`): path interno para ejecutar en `/`
- `redirect`: URL/path para redirigir desde `/` (302)

Precedencia (de mayor a menor):

1. `FN_HOME_FUNCTION`
2. `FN_HOME_REDIRECT`
3. `home` en `fn.config.json` raíz
4. landing interna por defecto

### Assets públicos en root

También puedes declarar una carpeta pública completa en el `fn.config.json` root:

```json
{
  "assets": {
    "directory": "public",
    "not_found_handling": "single-page-application",
    "run_worker_first": false
  }
}
```

Reglas:

- La carpeta se monta en `/`.
- `public/` o `dist/` son ejemplos típicos, pero el nombre es configurable.
- El scanner zero-config ignora esa carpeta para no publicarla como función.
- Solo se publica la carpeta configurada. Las carpetas vecinas de funciones, los dotfiles y los intentos de traversal quedan bloqueados.
- En `single-page-application`, el fallback SPA corre para requests sin extensión que parecen navegación. FastFN toma `Accept: text/html`, `Accept: */*`, `Sec-Fetch-Mode: navigate` o `Sec-Fetch-Dest: document` como señales de navegación.
- Eso significa que `curl` sobre un path tipo `/dashboard` puede recibir el shell SPA, mientras que paths con pinta de archivo como `/app.missing.js` y paths con pinta de API como `/api/unknown` siguen devolviendo `404`.
- Los paths con pinta de archivo, como `/app.missing.js`, siguen devolviendo `404`.
- Si no existe un asset real y tampoco una ruta de función, FastFN devuelve `404` o el shell SPA según la config.
- Una carpeta de assets vacía no inventa `/` por sí sola. Si no hay asset real, ni home explícito, ni rutas de función, `/` devuelve `404`.
- `fastfn dev` monta el root completo de apps no-leaf, así que assets, rutas y carpetas nuevas se ven sin reiniciar la stack.
- Cuando una carpeta root-level ya es una función explícita, `handler.*` conserva esa identidad y no la degrada a un alias falso de file route.
- Ejemplos ejecutables: `examples/functions/assets-static-first`, `examples/functions/assets-spa-fallback`, `examples/functions/assets-worker-first`.

Tip de verificación manual:

```bash
curl -H 'Accept: text/html' http://127.0.0.1:8080/dashboard/team
curl -H 'Accept: */*' http://127.0.0.1:8080/dashboard/team
curl -H 'Accept: */*' http://127.0.0.1:8080/api/unknown
```

Las primeras dos requests deben devolver el shell SPA. La tercera debe quedarse en `404`, salvo que exista un asset real o una ruta de función.

## 3. Precedencia (Importante)

FastFN fusiona rutas desde múltiples fuentes:

1. Enrutamiento por archivos (estilo Next.js)
2. `fn.routes.json` (mapa explícito de rutas)
3. `fn.config.json` (política por función)

Comportamiento importante:

- `fn.routes.json` puede sobrescribir rutas basadas en archivos.
- Las rutas de `fn.config.json` **no sobrescriben silenciosamente** una URL ya mapeada por defecto.
  - Usa `invoke.force-url: true` para migrar una función específica.
  - O configura `FN_FORCE_URL=1` (o `fastfn dev --force-url`) para forzar todas las rutas de policy globalmente.
- Si dos rutas colisionan con la misma prioridad, FastFN lo trata como conflicto real y responde `409`.

## 4. Logs de Descubrimiento

Ejecuta:

```bash
fastfn dev .
```

Busca logs `[Discovery]` para verificar runtime, entry file y mapping generado.

`fastfn dev` ahora monta el root completo del proyecto en desarrollo para que hot reload detecte archivos/carpetas nuevas sin reiniciar.

Comportamiento de hot reload:

- `fastfn dev` dispara reload inmediato ante cambios usando `/_fn/reload`.
- `/_fn/reload` acepta `GET` y `POST`.
- OpenResty usa watchdog inotify no bloqueante en Linux por defecto.
- Si watchdog no está disponible, hace fallback a escaneo por intervalo (`FN_HOT_RELOAD_INTERVAL`, default `2s`).
- Variables opcionales de tuning:
  - `FN_HOT_RELOAD_WATCHDOG=0|1`
  - `FN_HOT_RELOAD_WATCHDOG_POLL`
  - `FN_HOT_RELOAD_DEBOUNCE_MS`

!!! note "Manejo de Directorios de Runtime"
    Los directorios con nombre de runtime (`python/`, `node/`, `php/`, `lua/`, `rust/`, `go/`)
    en el nivel raíz son escaneados por el scanner específico de runtime, no por el scanner zero-config.
    Esto previene el doble registro de árboles agrupados por runtime en modo compatibilidad.
    Ese layout sigue soportado, pero no es el layout por defecto que recomienda esta documentación para proyectos nuevos.

## 5. Comportamiento Multi-Directorio / Multi-App

Cuando ejecutas `fastfn dev <root>`, los prefijos de ruta siguen la estructura de carpetas. Esto te deja correr varias apps desde un mismo root sin colisiones.

Root de ejemplo:

```text
tests/fixtures/
  nextstyle-clean/
    users/index.js
  polyglot-demo/
    fn.routes.json
```

Rutas:

- `nextstyle-clean/users/index.js` -> `GET /nextstyle-clean/users`
- `polyglot-demo/fn.routes.json` route `GET /items` -> `GET /items`

## 6. Endpoints HTML + CSS

Las rutas por archivos también pueden devolver HTML.

Archivos de ejemplo:

- `html/index.js` -> `GET /html`
- `showcase/index.js` -> `GET /showcase`
- `showcase/get.form.js` -> `GET /showcase/form`
- `showcase/post.form.js` -> `POST /showcase/form`
- `showcase/put.form.js` -> `PUT /showcase/form`

Cada handler necesita:

- `status: 200`
- `headers: { "Content-Type": "text/html; charset=utf-8" }`
- `body` con HTML (y opcional CSS inline en `<style>`)

## 7. Enrutamiento por Archivo de Método

Crea archivos handler separados por método HTTP usando el nombre del método como nombre de archivo:

```text
orders/
  get.py       # GET /orders
  post.py      # POST /orders
  [id]/
    get.py     # GET /orders/:id
    put.py     # PUT /orders/:id
    delete.py  # DELETE /orders/:id
```

Cada archivo maneja exactamente un método HTTP, evitando ramificaciones `if method == "POST"`.
FastFN infiere el método del prefijo del nombre de archivo (`get.`, `post.`, `put.`, `patch.`, `delete.`).
Usa un solo prefijo de método por archivo. Nombres como `get.post.items.js` se rechazan por ambiguos y no se publican.

Combinado con segmentos dinámicos `[id]`, esto te da una estructura REST API completa
con un archivo por endpoint, similar a cómo Next.js maneja las rutas de API.

### Imports de helpers compartidos

Los helpers están permitidos y son recomendables. La clave es mantenerlos privados según el modo de discovery:

- Pure file tree: usa `_shared.js`, `_shared.py`, `_shared.php`, etc.
- Single-entry / mixed subtree: usa módulos hermanos normales como `core.js`, `service.py`, `lib.php`, `common.rs`

Ejemplos reales del repo:

- `examples/functions/next-style/users/index.js` y `users/[id].js` hacen `require("./_shared")`
- `examples/functions/next-style/blog/index.py` y `blog/[...slug].py` importan `_shared.py`
- `examples/functions/node/whatsapp/handler.js` delega a `./core.js`

Esos imports son dependencias ejecutables reales, pero los archivos helper siguen privados y no se publican como endpoints.

## 8. Señales Warm/Cold del Runtime

Las respuestas del gateway incluyen headers de ciclo de vida:

- `X-FastFN-Function-State: cold|warm`
- `X-FastFN-Warmed: true` en la primera respuesta exitosa tras warm-up
- `X-FastFN-Warming: true` con `Retry-After: 1` cuando el primer hit sigue calentando

El build de Rust en primer arranque se puede ajustar con:

- `FN_RUST_BUILD_TIMEOUT_S` (default: `20`)

## 9. Toggles de Docs Internas y API Admin

- Swagger UI interna: `/_fn/docs`
- OpenAPI JSON interna: `/_fn/openapi.json`
- Deshabilitar endpoints de docs internas:
  - `FN_DOCS_ENABLED=0`
- Deshabilitar endpoints admin/console (`/_fn/*` write/admin handlers):
  - `FN_ADMIN_API_ENABLED=0`

Para un racional más profundo y resultados validados, consulta:

- `docs/es/articulos/apis-poliglotas-next-style.md`

## 10. Nombre de operación, summary y IDs OpenAPI

En routing por archivos, el nombre de operación se deriva; no se define por decorador.

Mapeo práctico:

- Nombre de path: se deriva de carpeta/archivo (`users/[id].js` -> `/users/{id}`)
- Método HTTP: se deriva del prefijo (`get.`, `post.`...) o política de métodos permitidos
- Summary: se puede ajustar con `invoke.summary` en `fn.config.json` o hint `@summary`
- `operationId`: se genera como `<method>_<runtime>_<name>_<version>`
- Tags: las genera el gateway (`functions` para rutas públicas)

Ejemplo de summary en `fn.config.json`:

```json
{
  "invoke": {
    "methods": ["GET"],
    "summary": "Obtener perfil de cliente"
  }
}
```

Ejemplo de hint en handler:

```js
// @summary Obtener suscripciones activas
exports.handler = async () => ({ status: 200, body: [] });
```

## 11. Sanity Check de Swagger/OpenAPI

Con `fastfn dev examples/functions/next-style` corriendo:

```bash
curl -sS http://127.0.0.1:8080/_fn/openapi.json | jq '.paths | keys | length'
```

Expectativas rápidas:

- Existen endpoints internos bajo `/_fn/*` (por ejemplo `/_fn/invoke`, `/_fn/catalog`).
- Existen rutas públicas como paths OpenAPI mapeados (`/users`, `/users/{id}`, `/blog`, `/blog/{slug}`, `/php/profile/{id}`, `/rust/health`, `/rust/version`).
- No deben aparecer módulos helper privados como `/users/_shared`, `/blog/_shared`, `/php/_shared`, `/rust/_shared` o `/whatsapp/core`.
- No se emiten operation summaries `unknown/unknown`.

## Diagrama de Flujo

```mermaid
flowchart LR
  A["Request del cliente"] --> B["Discovery de rutas"]
  B --> C["Validación de políticas y método"]
  C --> D["Ejecución del handler runtime"]
  D --> E["Respuesta HTTP + paridad OpenAPI"]
```

## Objetivo

Alcance claro, resultado esperado y público al que aplica esta guía.

## Prerrequisitos

- CLI de FastFN disponible
- Dependencias por modo verificadas (Docker para `fastfn dev`, OpenResty+runtimes para `fastfn dev --native`)

## Checklist de Validación

- Los comandos de ejemplo devuelven estados esperados
- Las rutas aparecen en OpenAPI cuando aplica
- Las referencias del final son navegables

## Solución de Problemas

- Si un runtime cae, valida dependencias de host y endpoint de health
- Si faltan rutas, vuelve a ejecutar discovery y revisa layout de carpetas

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](ejecutar-y-probar.md)
