# QA Report: FastFN Cloud Dashboard

**Date:** 2026-03-01
**Scope:** Full dashboard QA — all pages, new features, edge cases
**Test suite:** 83 Django tests (all passing)

---

## Pages Verified

### 1. Dashboard Home

**URL:** `/dashboard/`

**What it shows:**
- Navigation bar: Dashboard, Schedules, Logs, Secrets, API Docs, Settings
- User info: namespace (`/demo-user/`), functions URL
- Connection status badge (green "FastFN connected")
- "New function" button

**Metrics (two groups, clearly separated):**

| Group | Metric | Value | Description |
|-------|--------|-------|-------------|
| YOUR NAMESPACE | Functions | 6 | Functions owned by this user |
| YOUR NAMESPACE | Routes | 11 | Total routes across user's functions |
| YOUR NAMESPACE | Scheduled | 1 | Functions with cron schedules |
| INSTANCE HEALTH (all users) | Warm | 11 | Loaded workers across all users |
| INSTANCE HEALTH (all users) | Cold | 1 | Not yet loaded |
| INSTANCE HEALTH (all users) | Stale | 0 | Marked for reload |

**Runtime Health:** Shows green dots for php, lua, node, python.

**Functions Table:**

| Column | Description |
|--------|-------------|
| NAME | Function short name |
| RUNTIME | Color-coded runtime badge (lua, node, php, python) |
| URL | Clickable link to function's public URL |
| ROUTES / METHODS | Per-route method badges with color coding |
| SCHEDULE | Cron label if scheduled, "none" otherwise |
| Actions | Edit link + Delete button |

**Route/Method color coding:**
- GET = green (`bg-emerald-50`)
- POST = teal (`bg-teal-50`)
- PUT = amber (`bg-amber-50`)
- DELETE = red (`bg-red-50`)
- Fallback (no route_methods) = gray (`bg-gray-100`)

**Functions verified:**
1. `hello-lua` — lua, 2 routes (base + wildcard), GET only, cron schedule
2. `hello-node` — node, 2 routes, GET only
3. `hello-php` — php, 2 routes, DELETE/GET/POST/PUT on each
4. `api` — python, deep nested route (`/api/v1/products`), GET + POST
5. `hello-python` — python, 2 routes, GET + POST
6. `users` — python, 2 routes (`/users` GET+POST, `/users/{id}` DELETE+PUT)

---

### 2. Edit Function

**URL:** `/dashboard/functions/<name>/`

**Layout:** Three-panel — file explorer (left), code editor (center), side panel (right)

**File Explorer (EXPLORER):**
- Collapsible tree with file icons
- Shows file sizes
- Supports bracket filenames: `delete.[id].py`, `put.[id].py`
- CRUD buttons: new file (+), new folder, rename, delete
- Click to open file in editor

**Code Editor:**
- Syntax-highlighted (CodeMirror)
- Line numbers
- Tab shows current filename
- "Saved" indicator in top bar

**Verified: Bracket `[id]` files**
- `delete.[id].py` opens correctly, shows handler code
- `put.[id].py` opens correctly
- `get.py`, `post.py` open normally
- File path shows in tab: `users/delete.[id].py`

---

### 3. Side Panel Tabs

#### Test Tab
- Event Template dropdown with Load button
- Event JSON editor (pre-populated with method, context, path)
- "Advanced HTTP Options" expandable
- "Invoke Payload Preview" expandable
- Green "Test" button to invoke

#### Preview Tab
- iframe showing live function output
- Refresh and Open buttons
- Shows rendered HTML from function (e.g., "Hola, World!")
- Session info: session ID, visit count, secret key (masked), theme
- Form submission for POST testing

#### Env Tab
- List of environment variables with key/value fields
- "Secret" checkbox to mask values (shown as dots)
- "Show" button to reveal masked values
- "Remove" button per variable
- "+ Add variable" button
- Green "Save" button
- Verified variables: SECRET_KEY (masked), APP_ENV, GREETING

#### Config Tab
- Timeout (ms): editable, default 2500
- Max Concurrency: editable, default 20
- Max Body (bytes): editable, default 1048576
- **Detected Routes (from files):** read-only, auto-detected
  - Shows route paths with color-coded method badges
  - Example: `/demo-user/users` GET POST, `/demo-user/users/{id}` DELETE PUT
  - Label: "Auto-detected from method files (e.g. get.py, post.py). These are your function's active endpoints."
- **Allowed Methods (config override):** clickable method badges (GET, POST, PUT, DELETE, PATCH)
- **Routes:** namespace/path with add/remove, preset buttons (+base, +/{id}, +/{slug})
- Keep-warm & Workers expandable

#### Schedule Tab
- Cron expression field
- Enable/disable toggle

#### Deps Tab
- Shows runtime-specific dependency file (requirements.txt for Python, package.json for Node, etc.)

#### Info Tab
- Function metadata

---

### 4. Schedules & Jobs

**URL:** `/dashboard/schedules/`

**Schedules tab:**
- Table: FUNCTION, RUNTIME, SCHEDULE, LAST RUN, NEXT RUN
- Shows `hello-lua` with `cron` badge, lua runtime
- Edit link per schedule

**Jobs tab:**
- Async background jobs listing

---

### 5. Logs

**URL:** `/dashboard/logs/`

- Two tabs: Error Log, Access Log
- Auto-refresh checkbox
- Line count dropdown (200 lines default)
- Refresh button
- Dark terminal-style output area
- "No log entries found." when empty

---

### 6. Secrets Vault

**URL:** `/dashboard/secrets/`

- "Add / Update Secret" form: SECRET_KEY input + Value input + Save button
- Values are write-only (hidden after save)
- "No secrets stored" empty state with lock icon
- List of stored secrets with delete buttons

---

### 7. API Docs

**URL:** `/dashboard/openapi/`

- "Download JSON" button + "Refresh" button
- Swagger UI rendering of auto-generated OpenAPI 3.1 spec
- Server selector dropdown
- Grouped by "functions — Invocable functions"
- Each endpoint shows: method badge (GET/POST), path, summary
- Expandable for details
- Verified endpoints visible: hello-lua, hello-python, hello-node, users (GET + POST)

---

### 8. Instance Settings

**URL:** `/dashboard/instance/`

- Feature flag toggles:
  - Console UI: ON (enable web console interface)
  - API Access: ON (enable /_fn/* management API endpoints)
  - Write Operations: ON (allow create, update, and delete operations)
  - Local Only: ON (restrict access to localhost requests)
  - Login Required: OFF (require session login for console access)
- "Reset to Defaults" button

---

### 9. Create Function

**URL:** `/dashboard/functions/new/`

- Function name input field
- Runtime selector: **python**, node, php, lua, rust, go (6 runtimes)
- Template selector: **Blank**, Hello World, REST API, Form Handler, Scheduled Task (5 templates)
- Code preview showing template content
- "Create function" button

---

## New Features Verified

### A. Route/Methods Distinction (Functions vs Methods)
- Dashboard home shows per-route method breakdown instead of flat method list
- Config tab shows "Detected Routes (from files)" section
- Color-coded method badges throughout

### B. Bracket `[id]` File Support
- File browser displays `delete.[id].py`, `put.[id].py` correctly
- Files can be opened, read, and edited
- Path validation allows brackets but still rejects traversal (`../`), null bytes, absolute paths

### C. URL Simplification
- Edit URLs use `/functions/<name>/` (no runtime in URL)
- Runtime resolved from catalog automatically
- Unknown names redirect to dashboard home

### D. Metrics Clarity
- "YOUR NAMESPACE" group: user-scoped (Functions, Routes, Scheduled)
- "INSTANCE HEALTH (all users)" group: instance-scoped (Warm, Cold, Stale)
- No more confusing mixed metrics

---

## Test Coverage

### Existing Tests (50 — `dashboard/tests.py`)
- DashboardTests: login, connected/unhealthy states, functions list, CRUD
- CreateFunctionPerRuntimeTests: all 6 runtimes, all 5 templates, error cases
- FileOperationTests: read/write/delete/upload, path validation

### New Tests (33 — `dashboard/test_session_changes.py`)

| Test Class | Tests | What it covers |
|-----------|-------|----------------|
| EditFunctionURLTests | 4 | URL without runtime, runtime from catalog, unknown redirect, create redirect |
| RouteMethodsTests | 3 | Color badges, fallback when empty, JSON in edit page |
| BracketFilePathTests | 6 | Read/write brackets, catchall, traversal/null/absolute rejection |
| FastFNClientRouteMethodsTests | 3 | OpenAPI extraction, multi-route grouping, empty methods |
| EdgeCaseAndErrorTests | 17 | Slug-for-id, special chars, missing args, invalid JSON, traversal variants, malformed data, empty state |

**Total: 83 tests, all passing.**

### Edge Cases Specifically Tested
- Slug sent where ID expected → redirect (no crash)
- URL-encoded special characters in function name → handled
- Empty catalog → graceful redirect
- Missing name/runtime/body in create → no 500
- Missing or empty file path → 400
- Invalid JSON in write body → 400
- Path traversal hidden in brackets (`[..]/hack.py`) → rejected
- Deeply nested traversal (`a/b/../../etc/passwd`) → rejected
- Missing `route_methods` key in function dict → fallback UI
- Empty functions list → renders fine
- Empty methods list → renders fine
- Dynamic `{id}` routes grouped correctly under same function
- Deep nested versioned routes (`/api/v1/products/{id}`) → grouped correctly

---

### E. Direct Route Params Injection

Route params from bracket filenames (`[id]`, `[slug]`, `[...path]`) are automatically injected as **direct function arguments** — no need to access `event.params`.

**How each runtime injects params:**

| Runtime | Mechanism | Handler Signature |
|---------|-----------|-------------------|
| Python | `inspect.signature` → kwargs | `def handler(event, id):` |
| Node.js | Second arg when `handler.length > 1` | `async (event, { id }) =>` |
| PHP | `ReflectionFunction` → second arg | `function handler($event, $params)` |
| Lua | Always passed as second arg | `function handler(event, params)` |
| Go | Params merged into event map | `event["id"].(string)` |
| Rust | Params merged into event value | `event["id"].as_str()` |

**Param types supported:**

| Pattern | Example File | Handler gets |
|---------|-------------|--------------|
| `[id]` | `products/[id]/get.py` | `id="42"` |
| `[slug]` | `posts/[slug]/get.py` | `slug="hello-world"` |
| `[cat]/[slug]` | `posts/[cat]/[slug]/get.py` | `category="tech", slug="hello"` |
| `[...path]` | `files/[...path]/get.py` | `path="docs/2024/report.pdf"` |

**Backward compatible:** Existing `handler(event)` signatures work unchanged. Extra params are only injected when the handler signature declares them.

**Test coverage:**

| Test File | Tests | What |
|-----------|-------|------|
| `test-python-handlers.py` | 15 | Example handlers (all param types) + worker `_call_handler` injection logic |
| `test-node-daemon-adapters.js` | 4 | Node param injection (id, multi, single-arg, wildcard) |

---

## Documentation & Examples Updated

### Examples (all 6 runtimes)
- `examples/functions/rest-api-methods/products/` — CRUD: get, post, [id]/get, [id]/put, [id]/delete (30 files)
- `examples/functions/rest-api-methods/posts/[slug]/` — Single named param (6 files)
- `examples/functions/rest-api-methods/posts/[category]/[slug]/` — Multi-param (6 files)
- `examples/functions/rest-api-methods/files/[...path]/` — Catch-all wildcard (6 files)
- `examples/functions/versioned-api/` — API versioning with deep nesting
- All handlers use **direct params injection** (not `event.params`)

### Articles
- `docs/en/articles/file-based-method-routing.md` — all 6 runtimes with GET, POST+validation, reference table
- `docs/es/articulos/enrutamiento-metodos-por-archivos.md` — Spanish mirror

### Tutorials Updated
- `docs/en/tutorial/routing.md` — all 6 runtimes in params access + method dispatch tabs
- `docs/es/tutorial/routing.md` — Spanish mirror

### Reference Updated
- `docs/en/how-to/zero-config-routing.md` — depth-6 note, runtime dir skip, method files
- `docs/es/como-hacer/zero-config-routing.md` — Spanish mirror
- `docs/en/reference/function-spec.md` — depth limits clarification
- `docs/es/referencia/especificacion-funciones.md` — Spanish mirror
- `docs/en/tutorial/from-zero/2-routing-and-data.md` — method files tip
- `docs/es/tutorial/desde-cero/2-enrutamiento-y-datos.md` — Spanish mirror

### Test Fixtures
- `tests/fixtures/deep-routes/` — 8 handler files at depths 1-4 with method-specific routing
