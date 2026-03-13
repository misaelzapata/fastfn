# Zero-Config Routing (Next.js Style / File-Based Dynamic Routing)


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
## Quick View

- Complexity: Intermediate
- Typical time: 15-25 minutes
- Use this when: you want filesystem routes with predictable precedence
- Outcome: route discovery and conflict behavior are deterministic


FastFN supports file-based routing with automatic runtime detection. You can ship endpoints without writing `fn.config.json` for each function.

## 1. Runtime Auto-Discovery

Runtime is inferred from file extension:

- `.js`, `.ts` -> `node`
- `.py` -> `python`
- `.php` -> `php`
- `.rs` -> `rust`
- `.go` -> `go`

## 2. File-Based Route Rules

Given a project root:

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

Discovered routes:

- `users/index.js` -> `GET /users`
- `users/[id].js` -> `GET /users/:id`
- `blog/[...slug].py` -> `GET /blog/:slug*`
- `admin/post.users.[id].py` -> `POST /admin/users/:id`

!!! tip "Zero-Config Magic"
    Notice how you didn't have to register any of these routes in a central file? FastFN automatically maps `users/[id].js` to `/users/:id`. Just drop the file and the route is live.

!!! info "Nesting Depth"
    Zero-config discovery supports up to **6 levels** of directory nesting.
    For example, `api/v1/admin/users/settings/profile/index.py` maps to
    `GET /api/v1/admin/users/settings/profile`.
    Directories deeper than 6 levels are silently ignored.

Conventions:

- `index`, `handler`, `app`, `main` map to folder root.
- `[id]` maps to a dynamic segment (`:id`).
- `[...slug]` maps to catch-all (`:slug*`).
- Optional method prefix in filename: `get.`, `post.`, `put.`, `patch.`, `delete.`.
- Ignored files: `_*.ext`, `*.test.*`, `*.spec.*`.
- Optional catch-all `[[...opt]]` maps both `/base` and `/base/:opt*`.
- Reserved prefixes are blocked (`/_fn`, `/console`).
- `/docs` is available for user routes.

Configure ignored folders (zero-config scanner):

- Default ignored directories include: `node_modules`, `vendor`, `__pycache__`, `.fastfn`, `.deps`, `.rust-build`, `target`, `src`.
- Add more globally with env var:

```bash
FN_ZERO_CONFIG_IGNORE_DIRS="build,dist,tmp" fastfn dev .
```

- Or configure at functions root with `fn.config.json`:

```json
{
  "zero_config": {
    "ignore_dirs": ["build", "dist", "tmp"]
  }
}
```

### Folder-defined home alias (`fn.config.json`)

You can define a folder "home route" without creating `index.*`.

Example:

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

Result:

- `GET /portal/dashboard` -> handled by `portal/get.dashboard.js`
- `GET /portal` -> same handler (folder home alias)

Notes:

- `home.route` can be absolute (`/portal/dashboard`) or relative (`dashboard`).
- For folder aliases, FastFN resolves `home.route` against routes discovered in that same folder.

### Root home behavior (`/`)

FastFN keeps a built-in landing page at `/` by default. You can override it:

```bash
# Internal dispatch (no 302): executes mapped handler at /showcase
FN_HOME_FUNCTION=/showcase fastfn dev .

# Redirect (302)
FN_HOME_REDIRECT=/_fn/docs fastfn dev .
```

Or from root `fn.config.json` (when that file exists in the effective `FN_FUNCTIONS_ROOT`):

```json
{
  "home": {
    "route": "/showcase"
  }
}
```

`home` object supports:

- `route` (or `function`): internal path to execute for `/`
- `redirect`: URL/path to redirect from `/` (302)

Env vars have precedence over `fn.config.json`:

1. `FN_HOME_FUNCTION`
2. `FN_HOME_REDIRECT`
3. root `fn.config.json` `home`
4. built-in landing page

## 3. Precedence (Important)

FastFN merges routes from multiple sources:

1. File-based routing (Next.js style)
2. `fn.routes.json` (explicit route map)
3. `fn.config.json` (per-function policy)

!!! warning "Route Conflict Behavior"
    - `fn.routes.json` can override file-based routes.
    - `fn.config.json` routes **do not silently override** an already-mapped URL by default.
        - Use `invoke.force-url: true` for a single function migration.
        - Or set `FN_FORCE_URL=1` (or `fastfn dev --force-url`) to force all policy routes globally.
    - If two routes collide at the same priority, FastFN treats it as a real conflict and returns `409`.

## 4. Discovery Logs

Run:

```bash
fastfn dev .
```

Look for `[Discovery]` logs to verify runtime, entry file, and generated route mapping.

`fastfn dev` now mounts the full project root in development so hot reload works for new files/folders without restarting.

Hot reload behavior:

- `fastfn dev` triggers immediate reloads on file changes via `/_fn/reload`.
- `/_fn/reload` accepts both `GET` and `POST`.
- OpenResty uses a non-blocking inotify watchdog on Linux by default.
- If watchdog is unavailable, it falls back to interval scan (`FN_HOT_RELOAD_INTERVAL`, default `2s`).
- Optional tuning env vars:
  - `FN_HOT_RELOAD_WATCHDOG=0|1`
  - `FN_HOT_RELOAD_WATCHDOG_POLL`
  - `FN_HOT_RELOAD_DEBOUNCE_MS`

!!! note "Runtime Directory Handling"
    Directories named after runtimes (`python/`, `node/`, `php/`, `lua/`, `rust/`, `go/`)
    at the root level are scanned by the runtime-specific scanner, not the zero-config scanner.
    This prevents double-registration of runtime-grouped functions.

## 5. Multi-Directory / Multi-App Behavior

When you run `fastfn dev <root>`, route prefixes follow folder structure. This lets you run many apps from one root without collisions.

Example root:

```text
tests/fixtures/
  nextstyle-clean/
    users/index.js
  polyglot-demo/
    fn.routes.json
```

Routes:

- `nextstyle-clean/users/index.js` -> `GET /nextstyle-clean/users`
- `polyglot-demo/fn.routes.json` route `GET /items` -> `GET /items`

## 6. HTML + CSS Endpoints

File-based routes can return HTML pages too.

Example files:

- `html/index.js` -> `GET /html`
- `showcase/index.js` -> `GET /showcase`
- `showcase/get.form.js` -> `GET /showcase/form`
- `showcase/post.form.js` -> `POST /showcase/form`
- `showcase/put.form.js` -> `PUT /showcase/form`

Each handler just needs:

- `status: 200`
- `headers: { "Content-Type": "text/html; charset=utf-8" }`
- `body` with HTML (and optional inline CSS in `<style>`)

## 7. Method-Specific File Routing

Create separate handler files per HTTP method using the method name as filename:

```text
orders/
  get.py       # GET /orders
  post.py      # POST /orders
  [id]/
    get.py     # GET /orders/:id
    put.py     # PUT /orders/:id
    delete.py  # DELETE /orders/:id
```

Each file handles exactly one HTTP method, avoiding `if method == "POST"` branching.
FastFN infers the method from the filename prefix (`get.`, `post.`, `put.`, `patch.`, `delete.`).

Combined with `[id]` dynamic segments, this gives you a complete REST API structure
with one file per endpoint — similar to how Next.js handles API routes.

## 8. Warm/Cold Runtime Signals

Gateway responses include runtime lifecycle headers:

- `X-FastFN-Function-State: cold|warm`
- `X-FastFN-Warmed: true` on first successful warm-up response
- `X-FastFN-Warming: true` with `Retry-After: 1` when the first hit is still warming

Rust first-run compile can be tuned with:

- `FN_RUST_BUILD_TIMEOUT_S` (default: `20`)

## 9. Internal Docs & Admin API Toggles

- Internal Swagger UI: `/_fn/docs`
- Internal OpenAPI JSON: `/_fn/openapi.json`
- Disable internal docs endpoints:
  - `FN_DOCS_ENABLED=0`
- Disable admin/console API endpoints (`/_fn/*` write/admin handlers):
  - `FN_ADMIN_API_ENABLED=0`

For a deeper rationale and validated outcomes, see:

- `docs/en/explanation/nextjs-style-routing-benefits.md`

## 10. Operation naming, summaries, and OpenAPI IDs

In file-based routing, operation naming is derived, not manually declared per decorator.

Practical mapping:

- Path name: derived from folder/file route (`users/[id].js` -> `/users/{id}`)
- HTTP method: derived from method prefix (`get.`, `post.`...) or allowed methods policy
- Summary: can be influenced with `invoke.summary` in `fn.config.json` or handler hint `@summary`
- `operationId`: generated automatically as `<method>_<runtime>_<name>_<version>`
- Tags: generated by gateway (`functions` for public routes)

`fn.config.json` summary example:

```json
{
  "invoke": {
    "methods": ["GET"],
    "summary": "Fetch one customer profile"
  }
}
```

Handler hint example:

```js
// @summary Fetch active subscriptions
exports.handler = async () => ({ status: 200, body: [] });
```

## 11. Swagger/OpenAPI Sanity Check

With `fastfn dev examples/functions/next-style` running:

```bash
curl -sS http://127.0.0.1:8080/_fn/openapi.json | jq '.paths | keys | length'
```

Quick expectations:

- Internal endpoints exist under `/_fn/*` (for example `/_fn/invoke`, `/_fn/catalog`).
- Public routes exist as mapped OpenAPI paths (`/users`, `/users/{id}`, `/blog/{slug}`, `/php/profile/{id}`, `/rust/health`).
- No `unknown/unknown` operation summaries are emitted.

## Flow Diagram

```mermaid
flowchart LR
  A["Client request"] --> B["Route discovery"]
  B --> C["Policy and method validation"]
  C --> D["Runtime handler execution"]
  D --> E["HTTP response + OpenAPI parity"]
```

## Objective

Clear scope, expected outcome, and who should use this page.

## Prerequisites

- FastFN CLI available
- Runtime dependencies by mode verified (Docker for `fastfn dev`, OpenResty+runtimes for `fastfn dev --native`)

## Validation Checklist

- Command examples execute with expected status codes
- Routes appear in OpenAPI where applicable
- References at the end are reachable

## Troubleshooting

- If runtime is down, verify host dependencies and health endpoint
- If routes are missing, re-run discovery and check folder layout

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](run-and-test.md)
