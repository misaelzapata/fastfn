# Task Queue

Architecture rule (locked):
- Runtime execution is OpenResty-hosted (in-process or OpenResty-managed local execution).
- No separate runtime containers as part of the target architecture.

## Now

1. Method policy as source of truth (gateway/openapi/invoke)
- Status: completed
- Goal: `invoke.methods` in `fn.config.json` must drive:
  - gateway allow/deny (`405` + `Allow`)
  - OpenAPI operations per route/method
  - `/_fn/invoke` pre-validation.

2. Remove legacy response-mode complexity
- Status: completed
- Goal: keep a single response path (no `response.mode` switch).
- Keep binary support (`is_base64` + `body_base64`) and backward compatibility only where strictly needed.

3. UI invoke method setup (dynamic, not static)
- Status: completed
- Goal: method selector must always follow function metadata/policy (`GET`/`POST`/etc).
- Add optional `context` editor in UI invoke.
- Show advanced details only when debug is enabled.

4. Example behavior simplification
- Status: completed
- Goal: `hello` examples should return clean JSON by default.
- Debug-only details should appear only when debug is enabled.

## Next

5. Tests for method enforcement + swagger
- Status: completed
- Goal:
  - unit (lua): OpenAPI method presence/absence, gateway method policy helpers.
  - integration: `POST /fn/hello` => `405`, `POST /fn/risk_score` => `200`.
  - integration: OpenAPI path methods match configured methods.

6. Docs from zero (onboarding)
- Status: in_progress
- Goal: refresh README + architecture with:
  - method definition in `fn.config.json`
  - method reflection in Swagger
  - `405` behavior
  - simple JSON + HTML/CSV/PNG behavior
  - OpenResty-first run/testing instructions (docker only optional for local convenience, not architecture).

## Later

7. Optional UX refinements
- Status: planned
- Goal:
  - better env editor UX for secrets
  - compact function cards and faster filter UX.

8. New runtimes: PHP and Rust
- Status: completed (2026-02-11)
- Goal:
  - add `php` function support under OpenResty runtime model
  - add `rust` function support under OpenResty runtime model
  - auto-discovery compatibility with current function layout
  - method policy/env loading wired in gateway/runtime path
  - integration tests + OpenAPI coverage for both runtimes.

9. URL/Endpoint Mapping UI (after CRUD)
- Status: planned
- Priority: high
- Goal: map custom public endpoints to discovered functions/versions without `routes.json`.

10. Mapping data model and storage
- Status: planned
- Goal:
  - define mapping source file at repo level (proposed: `srv/fn/url-mappings.json`).
  - schema per entry:
    - `path` (example: `/api/v2/score`)
    - `target` (`runtime`, `name`, `version`)
    - optional `methods` override (default = function policy methods)
    - optional `strip_prefix`/`rewrite` rules (phase 2).
  - enforce deterministic load order and strict JSON validation.
  - add atomic write strategy for updates from UI/API.

11. Gateway resolution pipeline for mapped URLs
- Status: planned
- Goal:
  - extend `fn_gateway` path resolution:
    - first check explicit mapping table by incoming path
    - fallback to legacy `/fn/<name>@<version>`.
  - preserve existing policy checks (405/413/429/503/504).
  - guarantee no path traversal and no ambiguous target resolution.
  - include `X-Fn-Mapped-Route` debug header when debug enabled.

12. Mapping-aware OpenAPI/Swagger generation
- Status: planned
- Goal:
  - include mapped paths in `/openapi.json`.
  - operations per mapped path must reflect effective methods.
  - include target metadata in operation summary/description:
    - `runtime/name@version`.
  - conflict policy:
    - if mapped path collides with existing internal/public path, reject mapping write.

13. Console API for mapping CRUD
- Status: planned
- Goal:
  - endpoints:
    - `GET /_fn/mappings`
    - `POST /_fn/mappings`
    - `PUT /_fn/mappings`
    - `DELETE /_fn/mappings`
  - validation:
    - target function/version must exist.
    - methods subset of supported HTTP methods.
    - unique `(path, method)` space.
  - permission model:
    - read = API enabled
    - write = `enforce_write()`.

14. Console UI for mapping CRUD
- Status: planned
- Goal:
  - new panel in console:
    - list mappings
    - create/edit/delete mapping
    - bind target (`runtime`, `function`, `version`) via selects.
    - select methods (`GET/POST/PUT/PATCH/DELETE`).
  - show preview:
    - resulting public URL
    - target function
    - effective methods.
  - add quick action: “open in Swagger”.

15. Mapping conflicts and lifecycle safeguards
- Status: planned
- Goal:
  - block collisions against:
    - `/fn/*` legacy function routes
    - internal routes (`/_fn/*`, `/openapi.json`, `/docs`, `/console`).
  - block duplicate mappings for same `path + method`.
  - prevent delete of function/version while mapping references exist (or require force flag).
  - include migration helper when function version is removed.

16. Tests: mapping behavior full matrix
- Status: planned
- Goal:
  - unit:
    - schema validation
    - conflict detection
    - gateway mapping resolver precedence.
  - integration:
    - mapped endpoint invokes correct target.
    - method deny/allow on mapped routes.
    - openapi includes mapped paths and excludes invalid ones.
    - delete/update mapping reflected immediately.
    - timeout / concurrency handling unchanged via mapped paths in OpenResty runtime mode.

17. Docs for mapping feature
- Status: planned
- Goal:
  - update `README.md`:
    - how to create mappings in UI and API
    - examples (`/api/v2/x` -> `hello@v2`).
  - update `docs/en/explanation/architecture.md`:
    - resolution order and conflict rules.
  - add troubleshooting:
    - 404 vs 405 vs 409 for mapping errors.

## Serverless Parity Gaps (vs Lambda/Workers/OpenFaaS/Knative)

18. Strong isolation + resource limits (phase 1: local hardening)
- Status: planned
- Priority: high
- Goal:
  - enforce per-function CPU/memory/time limits more strictly (beyond wall-clock timeout).
  - document current isolation model (shared host) and risks.
  - evaluate minimal hardening options compatible with OpenResty-hosted runtime model.

19. Async invocations + job model
- Status: planned
- Priority: high
- Goal:
  - `POST /_fn/jobs` (enqueue), `GET /_fn/jobs/<id>` (status), `GET /_fn/jobs/<id>/logs`.
  - retries + idempotency key + dead-letter queue strategy (local-first).

20. Triggers / schedules (cron)
- Status: planned
- Priority: medium
- Goal:
  - simple schedule definition per function (opt-in) and a safe runner.
  - avoid introducing a second HTTP server; keep OpenResty as entrypoint.

21. Deploy/version lifecycle (alias + traffic shifting)
- Status: planned
- Priority: medium
- Goal:
  - formalize “versions” beyond folder naming: aliases, promotion, rollback metadata.
  - optional traffic split (canary) at gateway layer.

22. Observability: per-invocation logs + metrics + tracing hooks
- Status: planned
- Priority: high
- Goal:
  - structured logs with request_id/function/version/runtime/latency/status.
  - basic metrics endpoint (Prometheus-style) for counts/latency/errors.
  - trace/context propagation conventions (no vendor lock-in).

23. Multi-tenant/RBAC for Console/API
- Status: planned
- Priority: medium
- Goal:
  - replace “admin token only” with role model (read/write/admin) and audit logging.

24. Secrets management beyond file masking
- Status: planned
- Priority: medium
- Goal:
  - support external secret providers (optional) without leaking secrets in UI.
  - rotation story and minimal encryption-at-rest story.

25. Build/deps per-function (reproducible)
- Status: planned
- Priority: high
- Goal:
  - node: per-function install root and deterministic lockfile support.
  - python: per-function venv (or equivalent) with pinned requirements.
  - document cache invalidation strategy.

26. Console UI modularization (frontend)
- Status: planned
- Priority: medium
- Goal:
  - split `/openresty/console/console.js` into ES modules (no bundler required).
  - extend asset server to allow multiple static files under `/console/assets/*`.
  - keep console disabled by default and local-only by default.
