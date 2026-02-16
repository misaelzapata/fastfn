# Status Update: 2026-02-15

## Update: 2026-02-16 (Routing + Edge Security)

- [x] `FN_FORCE_URL` now affects routing inside OpenResty:
  - added `env FN_FORCE_URL;` to:
    - `openresty/nginx.conf`
    - `cli/embed/runtime/openresty/nginx.conf`
  - validated by integration: `bash tests/integration/test-openapi-system.sh` (policy override works when `FN_FORCE_URL=1`)
- [x] Edge proxy SSRF hardening:
  - deny edge proxy to control-plane surfaces (`/_fn/*`, `/console/*`):
    - `openresty/lua/fastfn/http/gateway.lua`
    - `cli/embed/runtime/openresty/lua/fastfn/http/gateway.lua`
  - validated by integration assertion: `assert_edge-proxy_denies_control_plane_paths` (`tests/integration/test-openapi-system.sh`)
- [x] Deterministic dynamic route matching by specificity (catch-all cannot steal more specific routes):
  - `openresty/lua/fastfn/core/routes.lua` (+ embedded parity copy)
  - unit coverage: `test_routes_dynamic_order_is_deterministic_and_specific` (`tests/unit/lua-runner.lua`)
- [x] Docker stack parity for env passthrough (fixes config-driven OpenAPI toggles and server URL override in Docker dev mode):
  - `docker-compose.yml`: added `FN_OPENAPI_INCLUDE_INTERNAL`, `FN_PUBLIC_BASE_URL`, `FN_RUNTIME_SOCKETS`
  - `cli/cmd/dev.go`: apply `openapi-include-internal` config to `FN_OPENAPI_INCLUDE_INTERNAL` for `fastfn dev`
- [x] Docker `start.sh` now starts only requested runtimes via `FN_RUNTIMES` and includes Go daemon:
  - `docker/openresty/start.sh`
  - `cli/embed/runtime/docker/openresty/start.sh`
  - validated: `FN_RUNTIMES=python,node,php,go` integration block in `tests/integration/test-openapi-system.sh`
- [x] Docker build iteration speed improved:
  - reordered installs before code copies:
    - `docker/openresty/Dockerfile`
    - `cli/embed/runtime/Dockerfile`
- [x] Integration tests no longer mutate repo fixtures and avoid docker container-name conflicts:
  - `tests/integration/test-openapi-system.sh` now:
    - runs against a temp copy under `tests/results/`
    - sets `COMPOSE_PROJECT_NAME` for the whole run
  - validated: `bash tests/integration/test-openapi-system.sh`

## Runtime/Lua Immediate Queue (user-requested)

- [x] Portable mode now respects runtime toggles and host port overrides:
  - `cli/embed/runtime/docker-compose.yml`
  - added `${FN_HOST_PORT:-8080}` and env passthrough for `FN_RUNTIMES` / `FN_RUNTIME_SOCKETS`
- [x] Docker stack env passthrough aligned for runtime toggles:
  - `docker-compose.yml`
  - added env passthrough for `FN_RUNTIMES` / `FN_RUNTIME_SOCKETS`
- [x] Rust/Go first-hit timeout hardening (fix 504 on cold compile):
  - timeout floor raised in route policy for compile runtimes (`rust`/`go`) to `180000ms`:
    - `openresty/lua/fastfn/core/routes.lua`
    - `cli/embed/runtime/openresty/lua/fastfn/core/routes.lua`
  - build timeout defaults raised to `180s`:
    - `srv/fn/runtimes/rust_daemon.py`
    - `srv/fn/runtimes/go_daemon.py`
    - `cli/embed/runtime/srv/fn/runtimes/rust_daemon.py`
    - `cli/embed/runtime/srv/fn/runtimes/go_daemon.py`
- [x] Lua test block validated directly:
  - command: `FASTFN_REPO_ROOT=/Users/misaelzapata/Downloads/simpleroute /opt/homebrew/bin/resty tests/unit/lua-runner.lua`
  - result: `console security unit tests passed` + `lua unit tests passed`
- [x] Runtime-off behavior validated (no rust/go):
  - `FN_RUNTIMES=python,node,php,lua` hides `rust`/`go` from `/_fn/health` + `/_fn/catalog`
  - OpenAPI excludes `/rust_live` and `/go_live`
  - disabled runtime routes return `404`
- [x] Marked `rust`/`go` as experimental and off-by-default:
  - CLI surface/docs updated:
    - `cli/cmd/root.go`
    - `cli/cmd/init.go`
    - `docs/en/reference/function-spec.md`
    - `docs/es/referencia/especificacion-funciones.md`
    - `docs/en/explanation/architecture.md`
    - `docs/es/explicacion/arquitectura.md`
  - Docker defaults now stable-only (`python,node,php,lua`):
    - `docker-compose.yml`
    - `cli/embed/runtime/docker-compose.yml`
    - `docker/openresty/Dockerfile`
    - `cli/embed/runtime/Dockerfile`
  - Docker runtime bootstrap now starts only requested runtimes from `FN_RUNTIMES`:
    - `docker/openresty/start.sh`
    - `cli/embed/runtime/docker/openresty/start.sh`
  - Native runtime selection now enforces requested+available runtimes only:
    - `cli/internal/process/runner.go`
    - selection logic extracted/tested for edge cases (defaults, unknown runtimes, unavailable deps, experimental opt-in):
      - `cli/internal/process/runner_test.go`
- [x] Added explicit automated `shared_deps` check in active integration suite:
  - `tests/integration/test-openapi-system.sh`
  - new assertion `assert_shared_deps_node_pack_runtime`
  - validates node shared pack resolution through `.fastfn/packs/node/<pack>/node_modules`
- [x] Lua integrated as first-class in-process runtime (no daemon/proxy hop):
  - runtime core + dispatch:
    - `openresty/lua/fastfn/core/lua_runtime.lua`
    - `openresty/lua/fastfn/core/routes.lua`
    - `openresty/lua/fastfn/http/gateway.lua`
    - `openresty/lua/fastfn/core/jobs.lua`
    - `openresty/lua/fastfn/core/scheduler.lua`
    - `openresty/lua/fastfn/console/invoke_endpoint.lua`
  - discovery + console/runtime metadata:
    - `openresty/lua/fastfn/console/data.lua`
    - `openresty/console/index.html`
    - `openresty/console/wizard.js`
    - `openresty/console/console.js`
    - `cli/internal/discovery/scan.go`
  - native+portable defaults aligned (`python,node,php,lua`; `rust/go` remain experimental):
    - `cli/internal/process/runner.go`
    - `docker-compose.yml`
    - `cli/embed/runtime/docker-compose.yml`
    - `docker/openresty/Dockerfile`
    - `cli/embed/runtime/Dockerfile`
    - `docker/openresty/start.sh`
    - `cli/embed/runtime/docker/openresty/start.sh`
  - embed/runtime parity synced under `cli/embed/runtime/openresty/...` for all files above.
  - validation:
    - `go test ./internal/process/... ./internal/discovery/... ./cmd/...`
    - `FASTFN_REPO_ROOT=/Users/misaelzapata/Downloads/simpleroute /opt/homebrew/bin/resty tests/unit/lua-runner.lua`
    - `bash tests/integration/test-openapi-system.sh`
    - `bash tests/integration/test-openapi-native.sh`

## Latest Execution Update (OpenAPI + Native Parity)

- [x] Home `Quick Invoke` now uses live OpenAPI instead of a stale hardcoded demo list:
  - `openresty/lua/fastfn/http/home.lua`
  - `cli/embed/runtime/openresty/lua/fastfn/http/home.lua`
  - sources commands from `/_fn/openapi.json` and shows only live public function routes
- [x] Added config-level OpenAPI admin/internal visibility toggle (without disabling admin functionality):
  - new `fastfn.json` key: `openapi-include-internal` (alias support includes `swagger-include-admin`)
  - wired in CLI startup to set `FN_OPENAPI_INCLUDE_INTERNAL` from config:
    - `cli/cmd/root.go`
    - `cli/cmd/dev.go`
    - `cli/cmd/run.go`
  - docs updated:
    - `docs/en/reference/fastfn-config.md`
    - `docs/es/referencia/config-fastfn.md`
    - `docs/en/reference/http-api.md`
    - `docs/es/referencia/api-http.md`
- [x] Expanded integration coverage for these behaviors (Docker + Native):
  - `tests/integration/test-openapi-system.sh`
  - `tests/integration/test-openapi-native.sh`
  - verifies home quick-invoke text no longer uses stale static demo paragraph
  - verifies `fastfn.json` config can opt-in internal/admin endpoints in OpenAPI
- [x] Hardened Docker integration startup checks:
  - `tests/integration/test-openapi-system.sh` now fails fast if the launched `fastfn` process exits before health is reachable
  - avoids false positives from stale processes already bound to `127.0.0.1:8080`
- [x] Fixed config-toggle coverage reliability for Docker OpenAPI integration:
  - `tests/integration/test-openapi-system.sh` now writes the temporary config to a real `.json` file path
  - this ensures `--config` is parsed as JSON by Viper in all runs
- [x] CLI config loading now fails fast when `--config` is invalid/unreadable:
  - `cli/cmd/root.go` exits with an explicit error for malformed or unsupported explicit config files
- [x] SDK parity alignment with runtime method contract:
  - removed `OPTIONS` / `HEAD` from SDK request method types:
    - `sdk/js/index.d.ts`
    - `sdk/python/fastfn/types.py`
  - standardized PHP proxy helper as `Response::proxy(...)`:
    - `sdk/php/FastFN.php`
- [x] Added targeted tests for previously uncovered CLI/runtime config paths:
  - `cli/cmd/run_test.go` (run target-dir resolution)
  - `cli/cmd/dev_native_test.go` (native defaults passed by wrapper)
  - `cli/internal/process/check_test.go` (docker/dependency checks)
  - `cli/internal/process/config_test.go` (native nginx config generation)
- [x] CONTRIBUTING/Go docs mismatch fixed:
  - `CONTRIBUTING.md` now matches module reality (`Go 1.20+`, `cd cli && go test ./...`)
- [x] Go runtime implemented end-to-end (system + native parity):
  - new runtime daemon:
    - `srv/fn/runtimes/go_daemon.py`
    - `cli/embed/runtime/srv/fn/runtimes/go_daemon.py`
  - runtime process wiring:
    - `cli/internal/process/runner.go`
    - `cli/internal/process/check.go`
    - `docker/openresty/start.sh`
    - `cli/embed/runtime/docker/openresty/start.sh`
  - runtime/container defaults:
    - `docker/openresty/Dockerfile`
    - `cli/embed/runtime/Dockerfile`
  - route/policy parity for first-hit compile timeout:
    - `openresty/lua/fastfn/core/routes.lua`
    - `cli/embed/runtime/openresty/lua/fastfn/core/routes.lua`
  - console/editor create/delete parity for Go function files:
    - `openresty/lua/fastfn/console/data.lua`
    - `cli/embed/runtime/openresty/lua/fastfn/console/data.lua`
  - integration coverage:
    - `tests/integration/test-openapi-system.sh` now validates ad-hoc Go endpoint creation/invoke/host-allowlist/OpenAPI export
    - `tests/integration/test-openapi-native.sh` adds equivalent native ad-hoc Go check (auto-skip if runtime unavailable)
- [x] Next-style `hello_demo` wildcard/underscore cleanup completed:
  - explicit route moved to `GET /hello-demo/:name` (no default catch-all wildcard route for this demo)
  - demo now returns dynamic payload from path params (`name`) and query (`lang`), default greeting is `Hello`
  - files:
    - `examples/functions/next-style/python/hello-demo/fn.config.json`
    - `examples/functions/next-style/python/hello-demo/app.py`
- [x] OpenAPI E2E parity validation hardened for all mapped functions:
  - now enforces exact catalog ↔ OpenAPI parity (no extra paths, no missing paths, exact method set per path)
  - applied in:
    - `tests/integration/test-api.sh`
    - `tests/integration/test-openapi-system.sh`
    - `tests/integration/test-openapi-native.sh`
- [x] Next.js-in-function adapter delivered (without adding a new runtime):
  - new function example mounts a full Next app from a standard Node handler:
    - `examples/functions/node/next_app/app.js`
    - `examples/functions/node/next_app/fn.config.json`
    - `examples/functions/node/next_app/package.json`
    - `examples/functions/node/next_app/pages/index.js`
  - adapter contract unit coverage:
    - `tests/unit/test-node-handler.js` (`testNextAppAdapterMountRewrite`)
- [x] SDK 4.2 surface parity aligned to common API (`json` / `text` / `proxy`) without runtime changes:
  - Python now includes runtime helpers:
    - `sdk/python/fastfn/response.py`
    - `sdk/python/fastfn/__init__.py`
  - PHP includes `Response::text(...)`:
    - `sdk/php/FastFN.php`
  - Rust includes `Response::text(...)` and proxy headers support:
    - `sdk/rust/src/lib.rs`
  - SDK contract checks expanded:
    - `tests/unit/test-sdks.sh`
    - `sdk/js/smoke.test.cjs`
- [x] Added long-form docs (EN/ES) for running Next.js inside a FastFN function:
  - `docs/en/articles/nextjs-inside-fastfn-function.md`
  - `docs/es/articulos/nextjs-dentro-de-funcion-fastfn.md`
  - linked in nav:
    - `mkdocs.yml`
- [x] Go daemon framing hardened for malformed payloads and noisy write failures:
  - clearer `400` errors for invalid UTF-8 / invalid JSON frames
  - max response frame size guard with explicit fallback error payload
  - ignores client disconnects during frame write (no thread traceback spam)
  - files:
    - `srv/fn/runtimes/go_daemon.py`
    - `cli/embed/runtime/srv/fn/runtimes/go_daemon.py`
- [x] Added targeted Go daemon unit coverage for frame edge cases:
  - covers invalid UTF-8, invalid JSON, non-object JSON, oversized frame length, oversized response fallback, and disconnect-on-write
  - files:
    - `tests/unit/test-go-handler.py`
    - `cli/test-all.sh`
    - `scripts/ci/test-pipeline.sh`
- [x] Next.js demo upgraded with live background clock via ping polling:
  - visual clock page: `GET /next-app/api/clock` (HTML + CSS + live updates)
  - data endpoint for ticks/time: `GET /next-app/api/clock-data`
  - client pages poll every second and render live status/ticks
  - fixes adapter defaults for strict sandbox + mount path behavior
  - files:
    - `examples/functions/node/next_app/app.js`
    - `examples/functions/node/next_app/pages/index.js`
    - `examples/functions/node/next_app/pages/api/clock.js`
    - `examples/functions/node/next_app/pages/api/clock-data.js`
    - `tests/unit/test-node-handler.js`
- [x] Console Test tab now includes richer runnable templates (beyond empty/hello):
  - added templates: `Route + Query`, `POST JSON Body`, `Context + Body`
  - `POST JSON Body` now auto-falls back to an allowed method when function does not permit `POST` (prevents template-induced `405`)
  - files:
    - `openresty/console/index.html`
    - `cli/embed/runtime/openresty/console/index.html`
    - `openresty/console/console.js`
    - `cli/embed/runtime/openresty/console/console.js`
  - E2E coverage:
    - `tests/e2e/console-gateway.spec.js` (`test templates generate runnable payloads with dynamic values`)
    - `tests/e2e/console-gateway.spec.js` (`post-json template does not force unsupported POST method`)
- [x] AI chat panel scrollability validated with UI automation:
  - verifies overflow + autoscroll-to-bottom behavior under long chat history
  - files:
    - `tests/e2e/console-wizard.spec.js` (`AI chat panel is scrollable and auto-scrolls to latest message`)
- [x] Added live-provider assistant smoke test (real key path) with optional CLI hook:
  - new script:
    - `tests/integration/test-assistant-live-provider.sh`
  - optional suite hook:
    - `cli/test-all.sh` (`RUN_ASSISTANT_LIVE_TEST=1`)
  - E2E webserver now supports provider override for real-model runs:
    - `tests/e2e/start-fastfn-webserver.sh`
- [ ] Live provider outbound connectivity from this local environment:
  - **FAIL** for both OpenAI and Claude in native smoke
  - error evidence:
    - `connect_error:api.openai.com could not be resolved (60: Operation timed out)`
    - `connect_error:api.anthropic.com could not be resolved (60: Operation timed out)`
  - commands executed (outside sandbox):
    - `ASSISTANT_LIVE_MODE=native ASSISTANT_LIVE_PORT=18133 WAIT_SECS=180 bash tests/integration/test-assistant-live-provider.sh openai`
    - `ASSISTANT_LIVE_MODE=native ASSISTANT_LIVE_PORT=18132 WAIT_SECS=180 bash tests/integration/test-assistant-live-provider.sh claude`

## Coverage Uplift Sprint (2026-02-15)

- [x] Started polyglot coverage uplift campaign with runtime-focused tests.
- [x] Added high-coverage test branches for Python Gmail handler:
  - `tests/unit/test-python-handlers.py`
  - added: required-param errors, forced dry-run path, mocked SMTP success path, mocked SMTP failure path.
- [x] Added high-coverage action-path tests for Node WhatsApp handler:
  - `tests/unit/test-node-handler.js`
  - added: action/method guards, inbox/outbox limits, QR raw mode, send/body validation paths, chat error/no-recipient paths.
- [x] Re-ran coverage pipeline and recorded uplift:
  - command: `bash cli/coverage.sh`
  - **Before**
    - Python lines: `62.88%` (`70/102`)
    - Node lines: `68.91%` (`2332/3384`)
    - Combined (`python+node`): `68.90%` (`2402/3486`)
  - **After**
    - Python lines: `81.06%` (`88/102`)
    - Node lines: `73.40%` (`2487/3388`)
    - Combined (`python+node`): `73.78%` (`2575/3490`)
    - Lua lines: `49.19%` (`1831/3722`) (unchanged in this pass)
- [x] Verified non-Python/Node runtime unit suites still passing:
  - `python3 tests/unit/test-rust-handler.py` ✅
  - `python3 tests/unit/test-go-handler.py` ✅
  - `php tests/unit/test-php-handler.php` skipped locally (`php` binary unavailable), still covered via Docker fallback in full suite.

### Coverage Uplift Sprint (Pass 2)

- [x] Added Python branch-coverage tests for `risk-score` low/medium paths:
  - `tests/unit/test-python-handlers.py`
  - covers: missing email/IP defaults and public-IP/public-email low-risk path.
- [x] Added substantial Lua unit coverage for routing + console CRUD contracts:
  - `tests/unit/lua-runner.lua`
  - new suites:
    - route discovery + host allowlist + conflict resolution + dynamic params + worker-pool metrics snapshot
    - console data CRUD (`create_function`, `set_function_config/env/code`, file-target detail, delete, secrets, dashboard metrics)
    - watchdog guardrail validation (`root`/`on_change` required)
- [x] Made Lua unit runner portable for local + container execution:
  - `tests/unit/lua-runner.lua`
  - `tests/unit/test-console-security.lua`
  - supports `FASTFN_REPO_ROOT` (fallback `/app`) for package/dofile paths.
- [x] Re-ran line coverage (without Docker daemon; Lua line report unavailable in this environment):
  - command: `PATH="/Users/misaelzapata/brew/bin:/opt/homebrew/bin:/usr/bin:/bin" bash cli/coverage.sh`
  - Python lines: `87.12%` (`92/102`)
  - Node lines: `74.49%` (`2669/3583`)
  - Combined (`python+node`): `74.93%` (`2761/3685`)
  - Lua lines: `n/a` in this local run (no Docker + no local `luacov` module for OpenResty runner).
- [x] Verified Lua suite correctness with local OpenResty runner:
  - `FASTFN_REPO_ROOT=/Users/misaelzapata/Downloads/simpleroute resty tests/unit/lua-runner.lua` ✅

- [x] Reduced strict-sandbox Next.js cache noise (warning cleanup):
  - `examples/functions/node/next_app/app.js`
  - under strict FS, default Next webpack filesystem cache is disabled unless user provides explicit webpack config.

### Coverage Next Queue (in progress)

1. Complete Lua line coverage pass in Docker CI (`cli/test-lua.sh`/`cli/coverage.sh`) to quantify the new Lua tests in `luacov.report.out`.
2. Add a dedicated “polyglot runtime unit matrix” step to CI summary output (Rust/Go/PHP pass/fail + skip reason) alongside line-coverage metrics.
3. Increase Node branch coverage in large handlers (`whatsapp`, `telegram-ai-reply`) with targeted edge-case tests (timeouts, method guards, fallback code paths).

### COSAW_TODO_QUEUE_2026-02-15

- [x] Hardening Go daemon frame handling (`invalid payload`, `utf`, `max size`, disconnected client write).
- [x] Add explicit unit coverage for these edge cases.
- [x] Validate Next.js route is serving correctly at `/next-app`.
- [x] Add background-updating clock demo (ping polling).
- [ ] Optional follow-up: add WebSocket push variant for the clock demo in addition to ping polling.

### DEMO_VALIDATION_MATRIX_2026-02-15 (OK/FAIL)

| Scope | Validation | Result | Evidence |
|------|------------|--------|----------|
| `hello_demo` public route contract | Swagger/OpenAPI exports `/hello-demo/{name}` and does not export legacy `/hello_demo/{wildcard}` | **OK** | `tests/integration/test-api.sh` (`assert_openapi_paths`) |
| `hello_demo` interactive behavior | `GET /hello-demo/Juan` returns dynamic response with `"name":"Juan"` and `"message":"Hello Juan"` | **OK** | `tests/integration/test-api.sh` Phase 1 assertions |
| Docker OpenAPI completeness | Every mapped catalog route is present in OpenAPI | **OK** | `bash tests/integration/test-api.sh`, `bash tests/integration/test-openapi-system.sh` |
| Docker OpenAPI exactness | OpenAPI has no extra public paths beyond mapped catalog routes | **OK** | strict parity assertions added in `test-api.sh` + `test-openapi-system.sh` |
| Docker OpenAPI method exactness | OpenAPI methods exactly match mapped route method unions | **OK** | strict parity assertions added in `test-api.sh` + `test-openapi-system.sh` |
| Native OpenAPI completeness | Every mapped native route is present in OpenAPI | **OK** | `bash tests/integration/test-openapi-native.sh` |
| Native OpenAPI exactness | OpenAPI has no extra public paths and no missing mapped paths | **OK** | strict parity assertions added in `test-openapi-native.sh` |
| Native OpenAPI method exactness | OpenAPI methods exactly match mapped route method unions | **OK** | strict parity assertions added in `test-openapi-native.sh` |
| OpenAPI visibility toggles | Internal/admin paths hidden by default and visible only when opted-in | **OK** | `test-openapi-system.sh` + `test-openapi-native.sh` opt-in checks |
| Console test templates interactivity | Test templates (`empty`,`hello`,`path-query`,`post-json`,`context-debug`) generate runnable payloads and invoke successfully | **OK** | `npm run test:e2e:ui -- --grep "test templates generate runnable payloads with dynamic values"` |
| AI chat panel UX | AI output pane remains scrollable and auto-scrolls to newest message | **OK** | `npm run test:e2e:ui -- --grep "AI chat panel is scrollable and auto-scrolls to latest message"` |
| Assistant live provider (OpenAI) | Real provider generate+invoke smoke in local runtime | **FAIL** | `ASSISTANT_LIVE_MODE=native ASSISTANT_LIVE_PORT=18133 WAIT_SECS=180 bash tests/integration/test-assistant-live-provider.sh openai` (`connect_error:api.openai.com could not be resolved`) |
| Assistant live provider (Claude) | Real provider generate+invoke smoke in local runtime | **FAIL** | `ASSISTANT_LIVE_MODE=native ASSISTANT_LIVE_PORT=18132 WAIT_SECS=180 bash tests/integration/test-assistant-live-provider.sh claude` (`connect_error:api.anthropic.com could not be resolved`) |

### Linked Tests and Report References

- OpenAPI Docker parity:
  - script: `tests/integration/test-openapi-system.sh`
  - related script reference: `tests/integration/test-openapi-native.sh`
  - report reference: [docs/internal/STATUS_UPDATE.md](./STATUS_UPDATE.md)
- OpenAPI Native parity:
  - script: `tests/integration/test-openapi-native.sh`
  - related script reference: `tests/integration/test-openapi-system.sh`
  - report reference: [docs/internal/STATUS_UPDATE.md](./STATUS_UPDATE.md)
- UX demo reference:
  - showcase: [http://localhost:18080/showcase](http://localhost:18080/showcase)
  - linked page: [http://localhost:18080/html?name=Designer](http://localhost:18080/html?name=Designer)
- SDK parity checks:
  - script: `tests/unit/test-sdks.sh`
  - report reference: [docs/internal/STATUS_UPDATE.md](./STATUS_UPDATE.md)
- Assistant live-provider smoke:
  - script: `tests/integration/test-assistant-live-provider.sh`
  - report reference: [docs/internal/STATUS_UPDATE.md](./STATUS_UPDATE.md)
- CLI/process coverage checks:
  - package tests: `cd cli && go test ./cmd/... ./internal/process/...`
  - report reference: [docs/internal/STATUS_UPDATE.md](./STATUS_UPDATE.md)
- [x] Added native integration coverage for OpenAPI contract:
  - `tests/integration/test-openapi-native.sh`
  - validates default behavior (functions-only in spec, internal admin API still operational)
  - validates opt-in behavior (`FN_OPENAPI_INCLUDE_INTERNAL=1` exposes internal/admin paths)
  - validates host allowlist routing (`invoke.allow_hosts`) and `421 host not allowed`
- [x] Wired native parity test into core CLI test suite:
  - `cli/test-all.sh` now runs `tests/integration/test-openapi-native.sh`
- [x] Updated docs (EN/ES) to include Docker + Native OpenAPI contract checks:
  - `docs/en/how-to/run-and-test.md`
  - `docs/es/como-hacer/ejecutar-y-probar.md`
  - `docs/en/reference/http-api.md`
  - `docs/es/referencia/api-http.md`

## Goal: Make FastFN "Sellable" and Focus on Simplicity

The core objective has shifted to emphasize "Look how easy it is to make an API". We need to move away from heavy infrastructure comparisons and towards Developer Experience (DX) wins.

### Action Plan

1.  **Refactor Documentation & README.md**
    *   Shift focus from "Polyglot FaaS Platform" to "Instant API Backend".
    *   Show, don't tell. Code snippets first.
    *   Remove complex comparison tables from the very top.
    *   Highlight the "Zero Config" nature visually.

2.  **Improve Robustness (Python Daemon)**
    *   The "Magic" of `subprocess` patching and daemon management is powerful but risky.
    *   We need better error reporting. If a user's code crashes, they need a clear JSON error response, not a 500 or a silent failure.
    *   "It just works" depends heavily on handling edge cases gracefully.

3.  **Add Basic Observability**
    *   A simple `/system/metrics` or `/_fn/status` endpoint to show function health.
    *   This builds trust. "Is my function running?" -> "Yes, see here."

### Completed Steps

- [x] Rewrite `README.md` to be more "marketing" friendly and developer-centric. (Done)
- [x] Improve exception handling in `python_daemon.py` to return friendly errors in Development Mode. (Done - Tracebacks added)
- [x] Added `/system/metrics` for basic observability. (Done)

## Feature Analysis: CLI Assistant (Claude/Codex) to Help Build an App

### Current Baseline (already in repo)

- There is already an assistant backend with:
  - `POST /_fn/assistant/generate`
  - `GET /_fn/assistant/status`
- Current providers in runtime assistant: `openai`, `claude` (and `anthropic` alias).
- The Console wizard already uses this assistant flow to generate code and then create functions.
- Function creation/update endpoints already exist (`/_fn/function`, `/_fn/function-config`, `/_fn/function-code`).

### Complexity Estimate by Scope

1. **MVP CLI assistant (single function generation)**
   - Example: `fastfn ai generate --runtime python --name users --prompt "..."`
   - Flow: call local assistant endpoint, output code, optional `--apply` to create function.
   - **Complexity: Medium**
   - **Estimated effort: 2-4 days**
   - Why: backend exists; missing piece is CLI UX + command wiring + tests.

2. **CLI assistant to "create an app" (multi-function scaffold + routes)**
   - Example: generate `auth`, `users`, `health`, and route/method config from one prompt.
   - Needs structured planning format (JSON contract), validation, conflict handling, idempotency.
   - **Complexity: Medium-High**
   - **Estimated effort: 1-2 weeks**
   - Why: moves from single-file generation to orchestration across multiple functions/configs.

3. **Full coding assistant loop in CLI (chat, edit, test, iterate)**
   - Example: conversational flow that edits existing code and runs smoke checks between turns.
   - Needs session memory, patch safety rules, retries, and deterministic output handling.
   - **Complexity: High**
   - **Estimated effort: 2-4+ weeks**
   - Why: agent-style workflow + reliability/guardrails is the hard part, not raw model calls.

### Claude vs Codex Feasibility

- **Claude:** practically ready (already wired through `FN_ASSISTANT_PROVIDER=claude` + `ANTHROPIC_*` env vars).
- **Codex (OpenAI models):**
  - Fast path: treat as OpenAI provider and set `OPENAI_MODEL` to a Codex-capable model.
  - If we want explicit `--provider codex`, add a small alias layer in CLI/runtime.
  - **Extra complexity for explicit codex label: Low (about 0.5-1 day).**

### Recommended Delivery Plan

1. **Phase 1 (MVP, quick win):** `fastfn ai generate` + `fastfn ai create` reusing existing assistant/function endpoints.
2. **Phase 2:** `fastfn ai app "<prompt>"` with a strict JSON plan (functions, routes, methods, env keys) and dry-run mode.
3. **Phase 3:** iterative assistant mode (`chat/edit/test`) with safety checks and targeted integration tests.

### Overall Conclusion

Adding an assistant to the CLI is feasible with **medium complexity** for a useful first version, because most backend primitives already exist.  
What becomes complex is the jump from "generate one function" to "safely create a whole app with repeatable results."

---

## Full Project Audit (2026-02-15)

### 1. Repo Hygiene — Artifacts That Should Not Be Tracked

| Severity | Item | Detail |
|----------|------|--------|
| **Critical** | `bin/fastfn` | 10 MB Mach-O arm64 binary committed. Build output, useless on CI Linux. Must `.gitignore` + `git rm --cached`. |
| **Medium** | `my-test-function/` | Boilerplate from `fastfn init` committed by accident. Not referenced by any test or script. |
| **Medium** | Root `index.html` + `style.css` | Stale console prototype. Real version lives in `openresty/console/`. Dead files. |
| **Medium** | `sdk/rust/app.js`, `wizard.js`, `index.html`, `style.css`, `target/` | Console UI files + Cargo build output misplaced inside the Rust SDK directory. |
| **Low** | `.gitignore` gaps | Missing: `bin/`, `coverage/`, `site/` (MkDocs output). |

### 2. Documentation vs Code — CLI Reference

The CLI reference doc (`docs/en/reference/cli.md`) is significantly behind the code:

| Undocumented in CLI Ref | Code location |
|------------------------|---------------|
| Command `version` | `cli/cmd/version.go` |
| Command `run` (production mode) | `cli/cmd/run.go` (75 lines, zero tests) |
| Command `docs` (opens Swagger) | `cli/cmd/docs.go` |
| Flag `dev --native` | `cli/cmd/dev.go` — major mode, routes to `dev_native.go` |
| Flag global `--config` | `cli/cmd/root.go` |
| `logs` — full command with 5 flags (`--native`, `--docker`, `--lines`, `--no-follow`, `--file`) | `cli/cmd/logs.go` — docs dismiss it as "use docker compose" |
| `doctor domains --enforce-https` | `cli/cmd/doctor.go` |

**False in docs:** heading says `up` / `down` are commands — they are not implemented; only `logs` is real.

### 3. Documentation vs Code — Function Spec

The function spec (`docs/en/reference/function-spec.md`) is incomplete:

| Undocumented | Runtime reality |
|-------------|-----------------|
| Filenames: `main.py`, `index.js`, `index.ts`, `app.ts`, `handler.ts`, `index.php` | `routes.lua` `has_app_file()` accepts them all |
| `fn.config.json` field `entrypoint` | Implemented in `routes.lua` |
| `keep_warm` config (`enabled`, `min_warm`, `ping_every_seconds`, `idle_ttl_seconds`) | ~40 lines of logic in `routes.lua` |
| `worker_pool` config (`enabled`, `min_warm`, `max_workers`, `max_queue`, `idle_ttl_seconds`, `queue_timeout_ms`, `overflow_status`) | ~80 lines of logic in `routes.lua` |
| `response.include_debug_headers` nested alias | Working alias in normalizer |

### 4. SDK Inconsistencies

#### 4.1 Methods: SDK types vs Runtime

JS and Python SDKs declare `OPTIONS` and `HEAD` as valid methods, but the runtime (`invoke_rules.lua` `ALLOWED_METHODS`) only allows `GET/POST/PUT/PATCH/DELETE`. Functions using `OPTIONS`/`HEAD` get **405**.

#### 4.2 API surface mismatch across languages

| Feature | JS | PHP | Python | Rust |
|---------|-----|-----|--------|------|
| `Response.json()` | ✅ | ✅ | ❌ (types only) | ✅ |
| `Response.text()` | ✅ | ❌ | ❌ | ❌ |
| `Response.proxy()` | ✅ | ✅ | ❌ | ✅ |

Python SDK is types-only (no runtime helpers), while the other three provide constructors.

### 5. Test Coverage Gaps

#### 5.1 Go — Critical gaps

| Area | Lines | Status |
|------|-------|--------|
| `doctor.go` (local diagnostics) | ~640 of 980 | **Largest CLI file, zero tests** (only `domains` subcommand covered) |
| `run.go` (production mode) | 75 | Zero tests |
| `root.go` (config loading, JSON/TOML precedence) | 94 | Zero tests |
| `process/runner.go`, `check.go`, `config.go` | Core native execution | Zero tests |
| `dev_native.go` | Thin wrapper | Zero tests |

#### 5.2 Lua — 11 of 19 modules untested

No unit tests for: `client`, `http_client`, `scheduler`, `jobs`, `watchdog`, `assistant`, `guard`, `auth`, `ui`, `data` (CRUD), `packs`, `functions_endpoint`, `invoke_endpoint`, `dashboard_endpoint`, `assistant_endpoint`, `secrets_endpoint`, `login/logout_endpoint`.

#### 5.3 Handler tests

- **Rust:** Zero handler unit tests (only integration/e2e coverage).
- **Handler tests hardcode `examples/functions/` paths:** any rename breaks ~1000 lines of tests.
- `test_usuarios_api.js` validates a legacy two-argument `handler(event, context)` pattern no longer standard.

#### 5.4 Missing integration tests

No integration tests for: `fastfn run --native`, `fastfn doctor`, `fastfn logs`.

#### 5.5 Stale fixtures

`tests/fixtures/test-cfg-config/` and `tests/fixtures/test-config-config/` — not referenced by any test.

### 6. Build / CI / Config Issues

| Severity | Issue |
|----------|-------|
| **Medium** | **Go version mismatch:** `go.mod` says `go 1.20`, `CONTRIBUTING.md` says "Go 1.21+". |
| **Medium** | **CONTRIBUTING.md test command is broken:** says `go test ./cli/...` but `go.mod` is inside `cli/`. Correct: `cd cli && go test ./...`. |
| **Low** | `docker-compose.integration.yml` missing env vars: `FN_SCHEDULER_ENABLED`, `FN_DEFAULT_TIMEOUT_MS`, `FN_DEFAULT_MAX_CONCURRENCY`, `FN_DEFAULT_MAX_BODY_BYTES`. |
| **Low** | CI pipeline never runs coverage (`cli/coverage.sh` exists but is not invoked). |
| **Low** | `test-playwright.sh` assumes pre-built `bin/fastfn` — uses stale binary if run standalone. |
| **Cosmetic** | `LICENSE` says `Copyright (c) 2026` with no name/entity. |

### 7. Orphan Documentation (17 files)

Files exist on disk but are **not in mkdocs.yml nav**:

- **EN (8):** `polyglot-step-by-step.md`, `authentication.md`, `zero-config-routing.md`, `polyglot-nextstyle-apis.md`, `php-template.md`, `rust-template.md`, `comparison.md`, `nextjs-style-routing-benefits.md`
- **ES (4):** `poliglota-paso-a-paso.md`, `apis-poliglotas-next-style.md`, `plantilla-php.md`, `plantilla-rust.md`
- **Internal (5):** `ASSETS_PLAN.md`, `FASTFN_IMPROVEMENT_PLAN.md`, `STATE_2026-02-12.md`, `STATUS_UPDATE.md`, `USER_AI_TEST_GUIDE.md`

Note: README links to `docs/en/explanation/comparison.md` which exists but is not in nav.

### 8. Dead/Phantom Code

| Item | Detail |
|------|--------|
| **Go runtime** implemented | daemon + Docker/native wiring + console/OpenAPI coverage now shipped (`go_daemon.py`, Dockerfiles/start scripts, `runner.go`, OpenAPI integration tests). |
| `invoke.content_type` in edge-proxy example | Field in `fn.config.json` not consumed by any runtime code. |

### 9. Prioritized Action Items

1. **Clean repo:** remove binary, `my-test-function/`, root `index.html`/`style.css`, update `.gitignore`.
2. **Update CLI docs:** document `run`, `version`, `docs`, `dev --native`, all `logs` flags, `--config` global.
3. **Update Function Spec docs:** document `keep_warm`, `worker_pool`, `entrypoint`, additional accepted filenames.
4. **Fix SDKs:** remove `OPTIONS`/`HEAD` from type definitions, rename PHP `startProxy()` to `proxy()`.
5. **Add tests:** `doctor.go` diagnostics, `run.go`, `root.go` config, Rust handlers.
6. **Fix CONTRIBUTING.md:** correct test command, reconcile Go version.
7. **Done:** implemented Go runtime and added Docker/native integration coverage.

### 10. Technical Architecture & Risks (Critical)

| Severity | Issue | Detail & Mitigation |
|----------|-------|---------------------|
| **URGENT** | **Native Mode Security (No Sandbox)** | In `fastfn run --native`, user code runs with **host privileges**. A malicious (or buggy) function can wipe the user's home dir (`rm -rf ~`). <br> **Mitigation:** Must explicitly warn users "Dev Only". For "Production Native", we need OS-level isolation (nobody user, cgroups) or strictly recommend Docker. |
| **High** | **Single Daemon Bottleneck** | A single `python_daemon.py` handles ALL Python traffic. One CPU-heavy loop blocks *every* other function. One crash kills *all* functions. <br> **Fix:** The `prefork-plan.md` is not optional; it is required for stability. |
| **High** | **Jobs System (Disk Based)** | The current Jobs queue uses file-system polling (`.fastfn/jobs`). This is slow (IO bound) and prone to locking issues. <br> **Fix:** Use **OpenResty Shared Memory (`ngx.shared.DICT`)** for the queue. It is RAM-based, atomic, requires no Redis (Zero Config), and is significantly faster than disk. |
