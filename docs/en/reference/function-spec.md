# Function Specification


> Verified status as of **March 13, 2026**.
> Runtime note: FastFN resolves dependencies and build steps per function: Python uses `requirements.txt`, Node uses `package.json`, PHP installs from `composer.json` when present, and Rust handlers are built with `cargo`. Host runtimes/tools are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
## Quick Start

The easiest way to conform to this spec is using the CLI:

```bash
fastfn init <name> -t <runtime>
```

This generates the correct folder structure and configuration file.

## Naming and routing

- Function name (flat): `^[a-zA-Z0-9_-]+$`
- Function name (namespaced): `<segment>/<segment>/.../<name>` where each segment matches `^[a-zA-Z0-9_-]+$`
- Version: `^[a-zA-Z0-9_.-]+$`
- Public routes (default):
  - `/<name>` (flat)
  - `/<segment>/<segment>/.../<name>` (namespaced — directory structure maps to routes, Next.js-style)
  - `/<name>@<version>`

Namespaced names map directory structure directly to URL paths. Examples:

| Disk path (under runtime dir) | Function name | Route |
|-------------------------------|---------------|-------|
| `hello/handler.py` | `hello` | `/hello` |
| `alice/hello/handler.py` | `alice/hello` | `/alice/hello` |
| `api/v1/users/handler.py` | `api/v1/users` | `/api/v1/users` |

Use cases: multi-tenant platforms (`alice/hello`, `bob/greet`), API namespacing (`api/v1/users`), organizational grouping (`team/service/handler`).

## Runtime support status

Implemented and runnable now:

- `python`
- `node`
- `php`
- `lua` (runs in-process inside OpenResty — no external daemon needed)

Experimental (opt-in via `FN_RUNTIMES`):

- `rust`
- `go`

## Functions root (`FN_FUNCTIONS_ROOT`)

FastFN discovers functions by scanning a directory tree on disk. That directory is called `FN_FUNCTIONS_ROOT`.

Common setup:

1. Create a `functions/` directory in your repo.
2. Run `fastfn dev functions` (or set `"functions-dir": "functions"` in `fastfn.json`).

In portable (Docker) mode, FastFN mounts your functions directory into the container.
That internal container path is not part of the public API surface and is usually not needed.

## Runtime process wiring

Global runtime wiring lives outside `fn.config.json`.

The main controls are:

- `FN_RUNTIMES` to enable runtimes
- `runtime-daemons` or `FN_RUNTIME_DAEMONS` to choose daemon counts per external runtime
- `FN_RUNTIME_SOCKETS` to pass an explicit socket map
- `runtime-binaries` or `FN_*_BIN` to choose the host executable used for each runtime or tool

Important rules:

- `lua` runs in-process, so daemon counts for `lua` are ignored.
- `FN_RUNTIME_SOCKETS` can use either a string or an array per runtime.
- If `FN_RUNTIME_SOCKETS` is set, it wins over generated sockets from `runtime-daemons`.
- FastFN chooses one executable per binary key. If you run three Python daemons, all three use the same configured `FN_PYTHON_BIN`.

Example:

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

## Recommended layout (file routes)

Inside `FN_FUNCTIONS_ROOT`, routes come from paths and filenames (Next.js-style).

Recommended:

```text
hello/
  get.py          # GET /hello
users/
  get.js          # GET /users
  [id]/
    get.py        # GET /users/:id
    delete.py     # DELETE /users/:id
```

Filenames supported:

- Method-only: `get.py`, `post.js` (maps to the directory root).
- Method + tokens: `get.items.py`, `post.users.[id].js`.
- Exactly one method prefix is allowed per filename. `get.post.items.js` is ambiguous and is ignored with a warning.
- Canonical single-entry files such as `handler.*`, `main.*`, and `index.*` are treated as "directory root" files (default method: `GET`). Not all names exist for all runtimes; see the [resolution order table](#entry-files-and-handler-functions) below.

Reserved route prefixes are blocked: `/_fn`, `/console`.

!!! info "Layout categories"
    - **Recommended:** Path-neutral (`hello/handler.py`, `users/get.js`). Used in tutorials and `fastfn init`.
    - **Supported (compatibility):** Runtime-grouped (`python/hello/handler.py`, `node/echo/handler.js`). Useful for monorepos with many runtimes. Discovery uses `FN_NAMESPACE_DEPTH` (default `3`, max `5`).
    - **Not recommended:** Mixing both layouts in the same functions root. Discovery still works but routing precedence becomes harder to reason about.

## Discovery modes

FastFN uses three route-discovery modes. The mode is determined by what exists in each directory, not by a hardcoded filename blacklist.

### 1. Pure file tree

If a directory does **not** define a single entrypoint, FastFN treats matching files as public routes.

Examples:

- `users/index.js` -> `GET /users`
- `users/[id].js` -> `GET /users/:id`
- `admin/post.users.[id].py` -> `POST /admin/users/:id`
- `hello.js` -> `GET /hello`

Private helpers in a pure file tree should be prefixed with `_`:

- `_shared.js`
- `_helpers.py`
- `_csv.php`

Those files stay private and are excluded from OpenAPI/catalog discovery.

### 2. Single-entry root

If a directory declares one function entrypoint, that directory becomes a single function, similar to a Lambda handler directory.

A directory is treated as single-entry when it has:

1. `fn.config.json` with an explicit `entrypoint`, or
2. a canonical entry file such as `handler.*`, `main.*`, or `index.*` (see per-runtime table below)

Examples:

- `payments/handler.js` -> `GET/POST/DELETE /payments`
- `risk-score/main.py` -> `GET /risk-score`

In this mode, sibling files are private implementation modules by default:

- `payments/core.js` is importable from `handler.js`, but it is **not** published as `/payments/core`
- `risk-score/model.py` is importable from `main.py`, but it is **not** published as `/risk-score/model`

### 3. Mixed subtree

Inside a single-entry function, subdirectories can still expose explicit file-based routes.

Examples:

- `shop/handler.js` -> `/shop`
- `shop/admin/index.js` -> `/shop/admin`
- `shop/admin/get.health.js` -> `GET /shop/admin/health`

Inside a mixed subtree, only explicit route files become public:

- `index.*`, `handler.*`, `main.*`
- method-prefixed files such as `get.*`, `post.*`, `put.*`, `patch.*`, `delete.*`
- dynamic files such as `[id].*`, `[...slug].*`, `[[...slug]].*`

Plain helper files like `core.js`, `shared.py`, `lib.php`, `common.rs`, or `utils.go` stay private.

## Advanced layout (runtime-grouped compatibility)

FastFN still supports runtime-grouped trees for monorepos and large mixed-runtime repos. `fastfn init` now scaffolds path-neutral single-function directories by default, so treat runtime-grouped layout as an organizational option rather than the primary teaching path in these docs.

<!-- runtime-paths-ok:start -->
```text
node/hello/handler.js
python/risk-score/main.py
php/export-report/handler.php
lua/quick-hook/handler.lua
```
<!-- runtime-paths-ok:end -->

When `fn.config.json` declares a function identity (for example by setting `runtime`, `name`, or `entrypoint`), that directory is treated as a single function root.

### Nested namespaces (Next.js-style)

Directory nesting under a runtime folder still maps directly to URL paths:

<!-- runtime-paths-ok:start -->
```text
python/
  hello/handler.py                # GET /hello
  api/
    v1/
      users/handler.py            # GET /api/v1/users
      orders/handler.py           # GET /api/v1/orders
  alice/
    dashboard/handler.py          # GET /alice/dashboard
```
<!-- runtime-paths-ok:end -->

Discovery recurses into directories that don't contain a single-entry root, treating them as namespace segments. A directory that contains a single-entry root (`handler.py`, `handler.js`, `main.py`, explicit `entrypoint`, etc.) is treated as one function. Descendant folders under that function can still expose explicit file-based routes, but sibling helper modules remain private.

**Depth limit**: `FN_NAMESPACE_DEPTH` controls how many levels deep the scanner recurses for runtime-grouped compatibility trees (default `3`, max `5`). For example, with depth 3 the path `python/a/b/c/handler.py` is discovered as function `a/b/c` → route `/a/b/c`.

!!! note "Depth Limits"
    The `FN_NAMESPACE_DEPTH` setting applies to runtime-grouped compatibility directories (for example `python/`, `node/`).
    Zero-config file-based routes use a separate, fixed depth limit of **6 levels**.
    Paths deeper than that fixed zero-config limit are skipped with a discovery warning instead of failing silently.

## Entry files and handler functions

Handler resolution works in two steps: **file selection** then **callable selection**.

### Step 1 — File selection

The runtime resolves the handler file in the following order:

1. Explicit `entrypoint` in `fn.config.json` (e.g. `src/my_handler.py`).
2. File routes (Next.js-style): `<method>.<tokens>.<ext>` or method-only `<method>.<ext>` (for example `get.py`, `post.users.[id].js`).
3. Default entry files in a fixed per-runtime order (see table below).

There is no fallback to "the first file in the directory". If none of the rules above match, the directory does not expose a public endpoint.

**Default entry files by runtime (resolution order):**

| Runtime | Candidates (checked in order) |
|---------|-------------------------------|
| Python  | `handler.py` → `main.py` |
| Node    | `handler.js` → `handler.ts` → `index.js` → `index.ts` |
| PHP     | `handler.php` → `index.php` |
| Lua     | `handler.lua` → `main.lua` → `index.lua` |
| Go      | `handler.go` → `main.go` |
| Rust    | `handler.rs` |

!!! tip "Convention"
    Use `handler.<ext>` by default. The name matches the default callable (`handler(event)`) and keeps the public contract consistent across runtimes.

If a directory contains multiple compatible default entry files across runtimes, FastFN resolves them deterministically in the order above and emits a discovery warning listing the ignored matches.

Namespace and file-route discovery also warn when a segment falls outside the supported ASCII set or when the normalized public route would collide with reserved prefixes such as `/_fn` or `/console`.

### Step 2 — Callable selection

Once the file is loaded, FastFN calls a specific exported symbol inside it.

- Default callable: `handler(event)`
- Override with `fn.config.json` → `invoke.handler` (must be a valid identifier matching `^[a-zA-Z_][a-zA-Z0-9_]*$`).
- Python convenience: if the default `handler` symbol is missing, FastFN falls back to `main(event)`.
- Cloudflare Workers adapter: if `invoke.adapter` is `cloudflare-worker`, FastFN first looks for a `fetch` export before falling back to the configured handler name.

| Field | Scope | Example | Effect |
|-------|-------|---------|--------|
| `entrypoint` | File selection | `"src/api.py"` | Loads `src/api.py` instead of convention files |
| `invoke.handler` | Callable selection | `"process_request"` | Calls `process_request(event)` instead of `handler(event)` |

### Direct parameter injection

When a route contains dynamic segments (e.g. `[id]`, `[...slug]`), extracted parameters are injected into the handler. The injection mechanism varies by runtime:

| Runtime | Injection method | Example signature |
|---------|-----------------|-------------------|
| Python  | `inspect.signature` → named kwargs | `def handler(event, id):` |
| Node    | Second argument (destructured object) | `async (event, { id }) =>` |
| PHP     | `ReflectionFunction` → second argument | `function handler($event, $params)` |
| Lua     | Always second argument (table) | `function handler(event, params)` |
| Go      | Merged into event map under `params` key | `event["params"]["id"]` |
| Rust    | Merged into event Value under `params` key | `event["params"]["id"]` |

Parameters are always available in `event.params` regardless of runtime. Direct injection is a convenience that avoids manual extraction.

### Python

```python
import json

def handler(event):
    return {
        "status": 200,
        "body": json.dumps({"hello": "world"}),
    }
```

#### Optional: Python Extras (validation)

This repository includes a small optional helper at `sdk/python/fastfn/extras.py`:

- `json_response(body, status=200, headers=None)`
- `validate(Model, data)` (requires `pydantic`)

### Node

```js
exports.handler = async (event) => {
  return {
    status: 200,
    body: JSON.stringify({ hello: 'world' }),
  };
};
```

### Go

```go
package main

import "encoding/json"

func handler(event map[string]interface{}) map[string]interface{} {
    body, _ := json.Marshal(map[string]interface{}{"hello": "world"})
    return map[string]interface{}{
        "status": 200,
        "headers": map[string]interface{}{"Content-Type": "application/json"},
        "body": string(body),
    }
}
```

### Lua

```lua
local cjson = require("cjson.safe")

function handler(event)
  return {
    status = 200,
    headers = { ["Content-Type"] = "application/json" },
    body = cjson.encode({ hello = "world" }),
  }
end
```

### Simple response shorthand (quick reference)

FastFN's canonical portable response remains:

- `{ status, headers, body }`
- or binary `{ status, headers, is_base64, body_base64 }`

Runtime shorthand support:

| Runtime | Shorthand support | Accepted forms | Notes |
|---------|-------------------|----------------|-------|
| Node    | yes | dict/object, string, number, array | Non-envelope values wrapped as JSON body with status `200` |
| Python  | yes | `dict`, `tuple` `(body, status, headers)`, `(body, status)`, `(body,)`, plain `dict`/`list` | Dict without `status` key wrapped as JSON `200`. `statusCode` accepted as alias for `status`. `bytes` in body auto-encoded as base64. |
| PHP     | yes | array, object, primitive | Wrapped as JSON body with status `200` |
| Lua     | yes | table, string, number | Wrapped as JSON body with status `200` |
| Go      | no | — | Explicit `{ "status", "headers", "body" }` envelope required |
| Rust    | no | — | Explicit `{ "status", "headers", "body" }` envelope required |

Binary responses: set `is_base64: true` and provide the content in `body_base64`. Python auto-detects `bytes` in `body` and encodes as base64 automatically.

Status validation: all runtimes validate status codes in range `100-599`.

For cross-runtime parity, prefer explicit envelope responses in shared examples.

## Dependency management (auto-install)

FastFN resolves dependencies or build steps **per function directory** by default, with autonomous inference for Python/Node.

Resolution model:

- Python/Node/PHP use function-local dependency files (`requirements.txt`, `package.json`, `composer.json`).
- Rust handlers are built with `cargo` inside a per-function `.rust-build/` workspace.
- FastFN does **not** scan repo root dependency files automatically.
- A function can combine local dependency files with reusable shared packs via `shared_deps`.
- Python and Node write transparent resolution state to `<function_dir>/.fastfn-deps-state.json`.
- PHP and Rust currently install/build directly without a per-function `.fastfn-deps-state.json` file.

### Files written by FastFN

| Runtime | State file | Lock/snapshot | Deps directory | Build directory |
|---------|-----------|---------------|----------------|-----------------|
| Python  | `.fastfn-deps-state.json` | `requirements.lock.txt` (informational, output of `pip freeze`) | `.deps/` | — |
| Node    | `.fastfn-deps-state.json` | `package-lock.json` (functional, used by `npm ci`) | `node_modules/` | — |
| PHP     | — | — | `vendor/` | — |
| Rust    | — | — | — | `.rust-build/` |
| Go      | — | — | — | `.go-build/` |
| Lua     | — | — | — | — (in-process, no external deps) |

`requirements.lock.txt` is an informational snapshot generated by `pip freeze`. It is NOT used for installation — only for auditing what was installed. `package-lock.json` is functional — `npm ci` uses it for deterministic installs.

When Python or Node inference runs, FastFN also records:

- `infer_backend`
- `inference_duration_ms`

### Python (manifest + inference)

Supported inputs:

- `requirements.txt` (explicit manifest).
- inline `#@requirements ...` hints.
- import inference when manifest is missing or incomplete.

Inline hints: FastFN scans the first 30 lines of the handler file for comments matching `#@requirements <package> [<package>...]`. These are merged with `requirements.txt` entries.

Behavior:

- If `requirements.txt` is missing and inference resolves imports, FastFN generates it automatically.
- If `requirements.txt` exists, FastFN appends missing inferred packages without removing your existing pins.
- After successful install, FastFN writes `requirements.lock.txt` (informational lock snapshot).

Toggles:

- `FN_AUTO_REQUIREMENTS=0` disables Python auto-install.
- `FN_AUTO_INFER_PY_DEPS=0` disables Python inference.
- `FN_PY_INFER_BACKEND=native|pipreqs` selects the Python inference backend.
- `FN_AUTO_INFER_WRITE_MANIFEST=0` keeps inference in-memory only (no manifest writes).
- `FN_AUTO_INFER_STRICT=1` fails fast on unresolved imports.
- `FN_PREINSTALL_PY_DEPS_ON_START=1` preinstalls discovered handlers during runtime startup.

Cache invalidation: FastFN computes a signature from the handler file mtime, manifest file mtime, and inline requirement comments. If the signature matches the previous install and `.deps/` is non-empty, cached dependencies are reused. Installation timeout: 180 seconds.

Inference is optional and usually slower than an explicit manifest because FastFN may need to parse imports or invoke an external tool.
Use `requirements.txt` or `#@requirements` for the tightest dev loop and for production-grade repeatability.

Inference only auto-adds direct package names such as `requests -> requests`.
FastFN does not ship a built-in import alias table for Python packages.
If the import name differs from the package you install (`PIL`/`Pillow`, `yaml`/`PyYAML`, `jwt`/`PyJWT`, etc.), declare it explicitly in `requirements.txt` or with `#@requirements`.
When you do declare it explicitly, that explicit manifest stays authoritative and unresolved alias-style imports remain informational instead of blocking install.

Backend notes:

- `native` is the default and intentionally conservative.
- `pipreqs` is opt-in and requires `pipreqs` to be available in the environment that runs the Python daemon.

### Node.js (manifest + inference)

Supported inputs:

- `package.json` (explicit manifest).
- import/require inference for missing dependencies.

Behavior:

- If `package.json` is missing and imports are inferred, FastFN creates `package.json`.
- If `package.json` exists, FastFN appends inferred missing dependencies.
- If lockfile exists, FastFN prefers `npm ci`; otherwise uses `npm install`.
- If `npm ci` fails with a lockfile present, FastFN retries with `npm install`. Installation timeout: 180 seconds.

Toggles:

- `FN_AUTO_NODE_DEPS=0` disables Node auto-install.
- `FN_AUTO_INFER_NODE_DEPS=0` disables Node inference.
- `FN_NODE_INFER_BACKEND=native|detective|require-analyzer` selects the Node inference backend.
- `FN_AUTO_INFER_WRITE_MANIFEST=0` disables manifest writes from inference.
- `FN_AUTO_INFER_STRICT=1` fails fast on unresolved imports.
- `FN_PREINSTALL_NODE_DEPS_ON_START=1` preinstalls discovered handlers on startup.
- `FN_PREINSTALL_NODE_DEPS_CONCURRENCY=4` controls startup preinstall concurrency.

Cache invalidation: FastFN computes a signature from `package.json` mtime and `package-lock.json` mtime (or `"no-lock"` if missing). If the signature matches and `node_modules/` exists, cached dependencies are reused.

Node inference excludes packages that match `shared_deps` pack names to avoid duplicating shared dependencies.

Node inference is also optional and generally slower than committing `package.json` up front.
Use explicit manifests when you already know the dependencies or when you want the shortest repeated startup time.

Backend notes:

- `native` is the default.
- `detective` is opt-in and works best for static `require(...)` usage.
- `require-analyzer` is opt-in and can be useful as a broader bootstrap aid, but it still does not replace an explicit `package.json`.

### PHP (manifest only in this phase)

Supported inputs:

- `composer.json` (plus optional `composer.lock`).

Behavior:

- FastFN runs `composer install` per function when `composer.json` is present.
- No import-based inference is performed for PHP in this phase.
- PHP currently does not emit `metadata.dependency_resolution` state.

Toggle:

- `FN_AUTO_PHP_DEPS=0` disables Composer auto-install.

### Rust (build step in this phase)

Behavior:

- FastFN builds Rust handlers with `cargo build --release`.
- The runtime prepares a per-function `.rust-build/` workspace and compiles the handler there.
- No import-based inference is performed for Rust in this phase.
- Native mode requires `cargo` in `PATH`.
- Rust currently does not emit `metadata.dependency_resolution` state.

### Go (build step)

Behavior:

- FastFN builds Go handlers with `go build` inside a per-function `.go-build/` workspace.
- If `go.mod` and `go.sum` exist in the function directory, they are used for module resolution.
- Build timeout controlled by `GO_BUILD_TIMEOUT_S` (default: `180` seconds).
- Native mode requires `go` in `PATH`.
- Go is experimental and must be enabled via `FN_RUNTIMES`.

### Lua (in-process)

Lua handlers run inside the OpenResty process. There is no external daemon, no dependency installation, and no state files. Lua modules available in the OpenResty environment (such as `cjson`, `resty.*`) can be used directly.

### Strict errors and transparency

- Unresolved inferred imports (when strict mode is on) return actionable runtime errors.
- Install or build failures include short actionable tails from pip/npm/composer/cargo output.
- Console API `GET /_fn/function` exposes `metadata.dependency_resolution` when the runtime writes that state (today mainly Python/Node).

Short flow:

1. FastFN loads the function-local manifest.
2. If that manifest is enough, it installs from there.
3. If it is missing or incomplete, Python and Node can infer imports and write the manifest.
4. The runtime then writes dependency-resolution state and lock info when supported.
5. Finally FastFN invokes the handler or builds the Rust binary.

### Shared dependency packs (`shared_deps`)

Shared packs live under your functions root, and the pack names are user-defined identifiers:

```text
<FN_FUNCTIONS_ROOT>/.fastfn/packs/python/<pack>/requirements.txt
<FN_FUNCTIONS_ROOT>/.fastfn/packs/node/<pack>/package.json
```

If your functions root is runtime-scoped (for example `<root>/python` or `<root>/node`), FastFN also checks one level up for the same `.fastfn/packs/<runtime>/...` layout for compatibility with that layout.

Node packs can also bring a preinstalled `node_modules/` tree in the pack directory; if a `package.json` is present, FastFN can install the pack dependencies there as well.

Then reference them from `fn.config.json`:

```json
{ "shared_deps": ["<pack>"] }
```

Behavior:

- the function keeps its own local dependencies if it has them
- `shared_deps` adds one or more reusable pack roots on top
- Python adds the pack `.deps` directories to import resolution
- Node adds the pack `node_modules` directories to module resolution
- missing pack names fail fast with an actionable runtime error

### Cold starts

The first request after adding or changing dependencies may be slower because the runtime installs packages before executing your handler.

## Function config (`fn.config.json`)

Main fields:

- `timeout_ms`: Maximum execution time.
- `max_concurrency`: Max simultaneous requests (semaphor).
- `max_body_bytes`: Request body limit.
- `entrypoint`: (Optional) Explicit file path to the handler script relative to function root.
- `keep_warm`: (Optional) Periodic ping settings to keep the function hot.
- `worker_pool`: (Optional) Advanced runtime worker pool settings.
- `response.include_debug_headers`: Whether to include `X-Fn-Runtime` headers.
- `invoke.routes`: (Optional) Public URLs for the function (array). Defaults to `/<name>` and `/<name>/*`.
- `invoke.allow_hosts`: (Optional) Host allowlist for those routes (array).
- `invoke.force-url`: (Optional) If `true`, this function is allowed to override an already-mapped URL.
- `invoke.adapter`: (Beta, Node/Python) compatibility mode for external handler styles (`native`, `aws-lambda`, `cloudflare-worker`).
- `home`: (Optional, directory overlay) Home mapping for folder/root:
  - `home.route` or `home.function`: internal path to execute as home.
  - `home.redirect`: URL/path to redirect as home (`302`).
- `assets`: (Optional, root-only) Mount a static directory at `/`:
  - `assets.directory`: relative folder to serve, such as `public` or `dist`.
  - `assets.not_found_handling`: `404` or `single-page-application`.
  - `assets.run_worker_first`: if `true`, route handlers win before static assets.

Notes:
- By default, FastFN does not silently override an existing URL mapping.
- In file-routes layout, a `fn.config.json` that does not declare a function identity (`runtime`/`name`/`entrypoint`) is treated as a **policy overlay** for all file routes under that folder (and nested folders). This is the recommended way to set `timeout_ms`, `max_concurrency`, `invoke.allow_hosts`, etc.
- In file-routes layout, folder overlays can define `home.route` to alias folder root (for example `/portal`) to another discovered route in that folder (for example `/portal/dashboard`).
- Root-level `fn.config.json` can define `home.route`/`home.redirect` to override `/` without editing Nginx.
- Root-level `fn.config.json` can also define `assets` to mount a static folder directly from the gateway, similar to Cloudflare static assets.
- `assets.directory` must be a safe relative path under the functions root and the directory must exist.
- `assets` is root-only in v1; nested `fn.config.json` files do not create additional public mounts.
- `/_fn/*` and `/console/*` stay reserved and are never served from `assets`.
- `assets` only serves the configured directory. Sibling function folders, dotfiles, and traversal attempts are not exposed as public files.
- If two routes collide at the same discovery priority, FastFN keeps neither mapping for that URL, records it as a conflict, and returns `409` for requests to that path until you disambiguate it.
- Use `invoke.force-url: true` only when you intentionally want this function to take a route from another function (for example during a migration).
- Version-scoped configs (for example `my-fn/v2/fn.config.json`) never take over an existing URL by themselves; use `FN_FORCE_URL=1` if you need a version route to win.
- Global override: set `FN_FORCE_URL=1` (or `fastfn dev --force-url`) to treat all config/policy routes as forced.

### Route mapping with `fn.routes.json` and `invoke.routes`

FastFN gives you three route-mapping tools. The simplest rule is:

- use file names when the URL can follow the folder tree
- use `fn.routes.json` when one folder needs to map several files to explicit public routes
- use `invoke.routes` when one logical function needs one or more public aliases

#### `fn.routes.json`

Place `fn.routes.json` in a folder when you want a small manifest that maps public routes to entry files in that same folder.

Example:

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

Rules:

- Keys are route definitions.
- Values are entry files relative to the folder that contains `fn.routes.json`.
- If you omit the HTTP method prefix, FastFN treats that route as `GET`.
- You can list more than one method in the key, such as `GET,POST /hook`.
- Runtime is inferred from the target file extension.
- Reserved prefixes like `/_fn/*` and `/console/*` still cannot be claimed.

Typical use cases:

- a polyglot folder where file names should stay short, but URLs should be explicit
- migrating an API without renaming handler files
- mixing Node/Python/PHP handlers behind a hand-written route map

#### `invoke.routes`

Use `invoke.routes` inside one function's `fn.config.json` when the function already has an identity and you want to publish one or more extra URLs for it.

Example:

```json
{
  "invoke": {
    "methods": ["GET", "POST"],
    "routes": ["/api/forms/contact", "/contact"]
  }
}
```

This is the better choice when:

- one function owns the route policy and aliases
- methods, host rules, summary, and other `invoke.*` settings should live with the function config
- you are adding vanity paths or a migration alias to an existing function

#### Precedence and conflict behavior

Important behavior:

- File routes and `fn.routes.json` are discovered together for the same folder.
- When the same route exists in both, `fn.routes.json` wins for that route and the file-based duplicate is skipped.
- `invoke.routes` registers explicit public aliases after discovery and can collide with other mapped URLs.
- If two routes collide at the same discovery priority, FastFN records a conflict and serves `409` for that URL until you disambiguate it.
- Use `invoke.force-url: true` only when you intentionally want one function to replace an already mapped public URL.

Example with advanced fields:

```json
{
  "group": "demos",
  "timeout_ms": 1500,
  "max_concurrency": 10,
  "max_body_bytes": 1048576,
  "entrypoint": "src/api.py",
  "invoke": {
    "handler": "main",
    "adapter": "native",
    "force-url": false,
    "routes": ["/my-api", "/my-api/*"],
    "allow_hosts": ["api.example.com"]
  },
  "home": {
    "route": "/my-api"
  },
  "keep_warm": {
    "enabled": true,
    "min_warm": 1,
    "ping_every_seconds": 60,
    "idle_ttl_seconds": 300
  },
  "worker_pool": {
    "enabled": true,
    "min_warm": 0,
    "max_workers": 5,
    "idle_ttl_seconds": 600,
    "queue_timeout_ms": 2000,
    "overflow_status": 429
  },
  "response": {
    "include_debug_headers": true
  }
}
```

### Root public assets

Use `assets` in the root `fn.config.json` when you want FastFN itself to serve a folder from `/` without going through a handler.

Example:

```json
{
  "assets": {
    "directory": "public",
    "not_found_handling": "single-page-application",
    "run_worker_first": false
  }
}
```

Behavior:

- `GET` and `HEAD` are served directly from the gateway.
- `/` and directory URLs resolve to `index.html`.
- In `single-page-application` mode, navigation misses fall back to `index.html`.
- Requests for missing file-like paths such as `/missing.js` still return `404`.
- An empty assets folder does not create a synthetic home route. With no real asset, no explicit home action, and no discovered function route, `/` returns `404`.
- If `run_worker_first` is `true`, FastFN checks mapped routes first and only falls back to static assets when no function route matches.
- This makes `dist/` or framework build folders first-class without giving up normal runtime handlers.
- Public assets do not weaken function isolation: FastFN serves only the configured folder and keeps adjacent handler directories private.
- See the runnable demos in `examples/functions/assets-static-first`, `examples/functions/assets-spa-fallback`, and `examples/functions/assets-worker-first`.

### Keep Warm

The `keep_warm` configuration instructs the runtime scheduler to periodically verify the function is loaded and ready.

- `enabled`: Activate the keep-warm scheduler.
- `min_warm`: Minimum number of instances (not fully implemented in all runtimes, usually 1).
- `ping_every_seconds`: Interval between heartbeats.
- `idle_ttl_seconds`: How long allowed to remain idle before scale-down.

### Worker Pool

`worker_pool` is the simplest way to control one function without changing routes.

Important model detail:

- `worker_pool` is **per function**.
- `runtime-daemons` is **per runtime** and lives in `fastfn.json` or environment variables, not in `fn.config.json`.
- OpenResty/Lua enforces `worker_pool.max_workers`, `max_queue`, and queue timeouts **before** the request enters the runtime.
- After the request is admitted, the gateway selects a healthy runtime socket. If the runtime has more than one socket, selection is `round_robin`.

Example:

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

Core fields:

- `enabled`: Turn pool-based execution on for this function.
- `max_workers`: Maximum active executions admitted for this function.
- `max_queue`: Extra queued requests allowed after all workers are busy.
- `queue_timeout_ms`: How long a queued request can wait before returning `overflow_status`.
- `idle_ttl_seconds`: How long idle workers stay around before cleanup.
- `overflow_status`: Status to return on queue overflow or timeout (`429` or `503`).
- `min_warm`: Keep some runtime workers pre-created when the runtime supports it.
- `queue_poll_ms`: How often to check for available capacity when a request is queued (internal tuning, rarely needs changing).

Current runtime behavior:

| Runtime | Multi-daemon routing | Runtime-internal fan-out |
|---|---|---|
| Node | supported | also uses child workers inside `node-daemon.js` |
| Python | supported | request handling still depends on the Python daemon behavior |
| PHP | supported | runtime dispatch happens through the PHP launcher |
| Rust | supported | runtime dispatch happens through the compiled binary launcher |
| Lua | not applicable | runs in-process inside OpenResty |

The benchmark snapshot verified on **March 14, 2026** showed runtime-dependent results: some runtimes improved a lot with extra daemons, some only a little, and one earlier native PHP path regressed before a later fix.

Use the canonical benchmark page for exact numbers and raw artifacts before enabling extra daemons everywhere:

- [Performance benchmarks](../explanation/performance-benchmarks.md)

### Invoke adapters

The `invoke.adapter` field in `fn.config.json` controls the handler calling convention. Default: `native`.

| Adapter | Handler signature | Available for |
|---------|-------------------|---------------|
| `native` | `handler(event)` | All runtimes |
| `aws-lambda` | `handler(event, context)` | Python, Node |
| `cloudflare-worker` | `fetch(request, env, ctx)` | Python, Node |

**Aliases:** `lambda`, `apigw-v2`, `api-gateway-v2` → `aws-lambda`. `worker`, `workers` → `cloudflare-worker`.

**AWS Lambda adapter:**

- `event` is transformed to match API Gateway v2 format.
- `context` provides `getRemainingTimeInMillis()`, `done()`, `fail()`, `succeed()`.
- Return value is normalized back to FastFN envelope.

**Cloudflare Workers adapter:**

- Handler name lookup: FastFN first looks for a `fetch` export, then falls back to the configured handler name.
- `request` provides `.text()`, `.json()`, `.url`, `.method`, `.headers`.
- `env` contains the function's environment variables from `fn.env.json`.
- `ctx` provides `waitUntil()` and `passThroughOnException()`.
- `ctx.waitUntil()` is best-effort background work: it does not delay the HTTP response, and rejected awaitables are logged as runtime events.

Node + Lambda callback note:

- In `aws-lambda` mode, Node supports both async handlers and callback-based handlers (`event, context, callback`).

```json
{
  "invoke": {
    "adapter": "aws-lambda",
    "handler": "handler"
  }
}
```

## Edge passthrough config (`edge`)

If you want Cloudflare-Workers-style behavior (handler returns a `proxy` directive and the gateway performs the outbound request), enable it per function in `fn.config.json`:

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

Then your handler can return `{ "proxy": { "path": "/foo" } }`.

## Schedule (cron or interval)

You can attach a schedule to a function using either:

- `every_seconds` (simple interval)
- `cron` (cron expression)

### Interval schedule (`every_seconds`)

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

### Cron schedule (`cron`)

Cron supports:

- 5 fields: `min hour dom mon dow`
- 6 fields: `sec min hour dom mon dow`
- macros: `@hourly`, `@daily`, `@midnight`, `@weekly`, `@monthly`, `@yearly`, `@annually`
- month/day aliases: `JAN..DEC`, `SUN..SAT`
- day-of-week accepts `0..6` and also `7` for Sunday

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

Timezone values:

- `UTC`, `Z`
- `local` (default if omitted)
- fixed offsets like `+02:00`, `-05:00`, `+0200`, or `-0500`

Notes:

- This runs inside OpenResty (worker 0) and calls your function through the same gateway/runtime policy as normal traffic.
- To run a function every **X minutes**, set `every_seconds = X * 60` (example: every 15 minutes => `900`).
- When both day-of-month and day-of-week are restricted, cron matching follows Vixie-style `OR` semantics.
- Scheduler state is visible at `GET /_fn/schedules` (`next`, `last`, `last_status`, `last_error`).
- When retries are pending, the scheduler snapshot also exposes `retry_due` and `retry_attempt`.
- Schedules are stored in `fn.config.json` (so schedule definitions persist across restarts).
- Scheduler state is persisted to `<FN_FUNCTIONS_ROOT>/.fastfn/scheduler-state.json` by default (so `last/next/status/error` survives restarts).
- Common failure modes (`last_status` / `last_error`):
  - `405`: schedule `method` not allowed by function policy.
  - `413`: schedule `body` exceeded `max_body_bytes`.
  - `429`: function was busy (concurrency gate).
  - `503`: runtime down/unhealthy.
- Retry/backoff (optional):
  - Set `schedule.retry=true` for defaults, or provide an object:
  - `max_attempts` (default `3`), `base_delay_seconds` (default `1`), `max_delay_seconds` (default `30`), `jitter` (default `0.2`).
  - Runtime clamps: `max_attempts` `1..10`, delays `0..3600`, `jitter` `0..0.5`.
  - Retries apply to status `0`, `429`, `503`, and `>=500`. The scheduler updates `last_error` with a `retrying ...` message.
- Console UI: `GET /console/scheduler` shows schedules + keep_warm (requires `FN_UI_ENABLED=1`).
- Global toggles:
  - `FN_SCHEDULER_ENABLED=0` disables the scheduler entirely.
  - `FN_SCHEDULER_INTERVAL` controls the scheduler tick loop (default `1` second, minimum effective value `1`).
  - `FN_SCHEDULER_PERSIST_ENABLED=0` disables scheduler state persistence.
  - `FN_SCHEDULER_PERSIST_INTERVAL` controls how often scheduler state is flushed (seconds, clamped to `5..3600`).
  - `FN_SCHEDULER_STATE_PATH` overrides the state file path.

## Function env and secrets

- `fn.env.json`: values injected into `event.env`
- secret masking is defined per key in the same file with `is_secret`

Example:

```json
{
  "API_KEY": {"value": "secret-value", "is_secret": true},
  "PUBLIC_FLAG": {"value": "on", "is_secret": false}
}
```

## Execution Flow Diagram

```mermaid
flowchart LR
  A["Incoming HTTP request"] --> B["Route resolution"]
  B --> C["fn.config policy evaluation"]
  C --> D["Runtime adapter"]
  D --> E["Handler response normalization"]
  E --> F["OpenAPI-consistent output"]
```

## Contract

Defines expected request/response shape, configuration fields, and behavioral guarantees.

## End-to-End Example

Use the examples in this page as canonical templates for implementation and testing.

## Edge Cases

- Missing configuration fallbacks
- Route conflicts and precedence
- Runtime-specific nuances

## See also

- [HTTP API Reference](http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
- [Architecture Overview](../explanation/architecture.md)
