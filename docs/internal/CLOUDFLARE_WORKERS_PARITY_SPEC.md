# Cloudflare Workers Parity Spec (Internal)

Status: Draft  
Audience: Maintainers / Runtime / Docs owners  
Last updated: 2026-02-19

## 1) Objective

Define a precise internal spec for parity gaps between:

- Cloudflare Workers platform/documentation model.
- FastFN current runtime model and published docs.

This document is not public-facing. It is an execution blueprint for:

- docs backlog,
- runtime/API backlog,
- test/verification backlog.

## 2) Source Baseline

Cloudflare documentation snapshot reviewed on 2026-02-19:

- Workers overview
- Wrangler configuration
- Compatibility dates and flags
- Runtime handlers (`fetch`, `scheduled`, `queue`, `tail`, `email`)
- Context (`ctx.waitUntil`, `ctx.passThroughOnException`)
- Bindings (`env`) + Service Bindings/RPC
- Routing (`workers.dev`, routes, custom domains)
- Versions/deployments, gradual deployments, rollbacks
- Observability (logs, traces, tail workers)
- Limits and pricing

FastFN current baseline (examples):

- `docs/en/reference/function-spec.md`
- `docs/en/reference/runtime-contract.md`
- `docs/en/reference/http-api.md`
- `docs/en/reference/cli.md`
- `docs/en/reference/fastfn-config.md`
- `docs/en/tutorial/from-zero/chapter-05-edge-proxy.md`
- `docs/en/how-to/deploy-to-production.md`
- Spanish parity equivalents in `docs/es/...`

## 3) Current State Summary (FastFN)

FastFN already documents:

- Workers-like edge proxy pattern (`proxy` directive).
- File-based routing and function policy model.
- Runtime request/response contract.
- Internal scheduler/cron model.
- Core security model and self-hosted deployment.

FastFN does not currently document or model several major Workers platform concepts (detailed below).

## 4) Gap Taxonomy

Each gap is tracked with:

- `ID`: stable backlog ID.
- `Priority`: `P0` (critical), `P1` (important), `P2` (nice-to-have).
- `Type`: `Docs-only` or `Feature+Docs`.
- `Owner`: suggested team owner.

### P0 (Critical)

#### CF-P0-001 Compatibility Contract (`compatibility_date` / flags)

- Type: Feature+Docs
- Owner: Runtime + CLI + Docs
- Problem:
  - Cloudflare has explicit compatibility governance.
  - FastFN has no equivalent compatibility contract or migration policy.
- Proposed spec:
  - Add optional global config block in `fastfn.json`:
    - `compatibility.date` (ISO date, required when block exists)
    - `compatibility.flags` (string array)
  - Add optional per-function override in `fn.config.json`:
    - `runtime_compat.date`
    - `runtime_compat.flags`
  - Resolution precedence:
    1. function override
    2. global config
    3. runtime default (documented per runtime version)
  - Runtime behavior:
    - Unknown flag -> `400` at config load.
    - Deprecated flag -> warning in logs + `/ _fn/catalog` metadata.
  - API surface:
    - include effective compatibility fields in `GET /_fn/catalog`.
    - include effective compatibility in `event.context.runtime_compat`.
- Docs deliverables:
  - EN: `docs/en/reference/compatibility-model.md` (new)
  - ES: `docs/es/referencia/modelo-compatibilidad.md` (new)
  - Update references in:
    - `docs/en/reference/function-spec.md`
    - `docs/en/reference/fastfn-config.md`
    - `docs/en/reference/runtime-contract.md`
    - ES mirrors
- Acceptance criteria:
  - Can pin compatibility behavior and test it deterministically.
  - Breaking runtime changes must be hidden behind flag/date policy.

#### CF-P0-002 Handler Model Parity (non-HTTP triggers)

- Type: Feature+Docs
- Owner: Runtime + Scheduler/Jobs + Docs
- Problem:
  - Cloudflare documents first-class handlers (`fetch`, `scheduled`, `queue`, `tail`, `email`).
  - FastFN docs are strongly HTTP-centric, scheduler-only for timed execution.
- Proposed spec:
  - Define internal trigger taxonomy:
    - `http` (existing)
    - `scheduled` (existing scheduler path)
    - `queue` (new async queue consumer contract)
    - `tail` (new telemetry consumer contract)
    - `email` (new inbound message contract, optional phase)
  - Contract extension:
    - `event.type` required with enum above.
    - trigger-specific payload objects:
      - `event.scheduled`
      - `event.queue`
      - `event.tail`
      - `event.email`
  - Handler export naming:
    - default `handler(event)` remains valid.
    - optional explicit map in `fn.config.json`:
      - `invoke.handlers.http`
      - `invoke.handlers.scheduled`
      - `invoke.handlers.queue`
      - `invoke.handlers.tail`
      - `invoke.handlers.email`
  - Failure semantics:
    - queue trigger supports ack/retry/dlq policy.
    - scheduled retains retry/backoff policy.
- Docs deliverables:
  - EN: `docs/en/reference/trigger-handlers.md` (new)
  - ES: `docs/es/referencia/handlers-triggers.md` (new)
  - Update:
    - runtime contract pages EN/ES
    - function spec pages EN/ES
- Acceptance criteria:
  - Trigger payload contracts are fully specified and tested.
  - OpenAPI/internal docs clearly separate HTTP vs non-HTTP triggers.

#### CF-P0-003 `ctx` Semantics (`waitUntil` / fail-open behavior)

- Type: Feature+Docs
- Owner: Runtime + Gateway + Docs
- Problem:
  - Workers docs treat `ctx.waitUntil` and `passThroughOnException` as core behavior.
  - FastFN has no explicit cross-runtime context semantics chapter.
- Proposed spec:
  - Extend `event.context` contract:
    - `async_tasks.max`
    - `async_tasks.deadline_ms`
  - Runtime helper result contract:
    - allow handlers to return:
      - `defer`: array of internal task descriptors (for post-response execution)
      - `on_unhandled_error`: `"propagate" | "fallback_proxy" | "fallback_static"`
  - Define exact cancellation rules:
    - client disconnect behavior
    - max grace window for deferred tasks
- Docs deliverables:
  - EN: `docs/en/reference/execution-context.md` (new)
  - ES: `docs/es/referencia/contexto-ejecucion.md` (new)
  - Update runtime contract EN/ES.
- Acceptance criteria:
  - Deterministic behavior table for:
    - unhandled exception before/after body generation
    - client disconnect
    - deferred task failure.

#### CF-P0-004 Bilingual Reference Parity (EN/ES)

- Type: Docs-only
- Owner: Docs
- Problem:
  - ES CLI reference is currently a pointer/stub, not full parity.
- Proposed spec:
  - Every EN reference page must have ES twin with same section topology.
  - Allow controlled lag only behind `status: partial` banner.
  - Add "parity matrix" file in internal docs.
- Docs deliverables:
  - Expand:
    - `docs/es/referencia/cli-reference.md` to full content.
  - New internal tracker:
    - `docs/internal/DOCS_PARITY_MATRIX.md`.
- Acceptance criteria:
  - No stub-only reference pages in ES for core runtime/CLI/API docs.

### P1 (Important)

#### CF-P1-001 Binding Capability Model

- Type: Feature+Docs
- Owner: Runtime + Docs
- Problem:
  - Workers has explicit binding classes (`KV`, `R2`, `D1`, `Queues`, `Durable Objects`, etc.).
  - FastFN only documents `event.env` key/value usage.
- Proposed spec:
  - Introduce explicit binding registry abstraction in config:
    - `bindings` array with typed entries:
      - `type`, `name`, `config`.
  - Start with local/self-hosted targets:
    - `http_service`
    - `sqlite`
    - `filesystem_bucket`
    - `queue_local`
  - Inject resolved bindings under `event.bindings` (keep `event.env` for scalar vars).
- Docs deliverables:
  - EN: `docs/en/reference/bindings.md` (new)
  - ES: `docs/es/referencia/bindings.md` (new)
  - Update function spec and runtime contract EN/ES.
- Acceptance criteria:
  - Typed binding config validation.
  - Runtime emits explicit error when binding misconfigured.

#### CF-P1-002 Service-to-Service Invocation Model (Service Bindings/RPC analog)

- Type: Feature+Docs
- Owner: Gateway + Runtime + Docs
- Problem:
  - Workers supports intra-worker calls without public internet + RPC style.
  - FastFN lacks a first-class documented inter-function RPC model.
- Proposed spec:
  - Add internal service map:
    - `services` in `fastfn.json`:
      - `name`, `target`, `expose` (`http|rpc|both`), auth policy.
  - Runtime helper:
    - stable in-function call API for typed internal calls.
  - Policy:
    - deny access unless explicitly declared.
    - enforce loop depth and timeout budgets.
- Docs deliverables:
  - EN: `docs/en/how-to/service-to-service-calls.md` (new)
  - ES: `docs/es/como-hacer/llamadas-servicio-a-servicio.md` (new)
  - EN/ES reference section for service bindings config.
- Acceptance criteria:
  - Internal call does not require external URL.
  - Observability shows parent-child invocation IDs.

#### CF-P1-003 Environments and Config Inheritance

- Type: Feature+Docs
- Owner: CLI + Config + Docs
- Problem:
  - Workers has explicit environment model with inheritance/non-inheritance rules.
  - FastFN docs do not define robust `dev/staging/prod` environment schema.
- Proposed spec:
  - Extend `fastfn.json`:
    - `env.<name>` blocks.
    - define inherited keys allowlist.
    - define non-inheritable sensitive keys.
  - CLI:
    - `fastfn dev --env <name>`
    - `fastfn run --env <name>`
  - Precedence:
    1. CLI flag
    2. process env
    3. selected `env.<name>`
    4. root config
- Docs deliverables:
  - EN: `docs/en/reference/environments.md` (new)
  - ES: `docs/es/referencia/entornos.md` (new)
  - Update CLI + config references EN/ES.
- Acceptance criteria:
  - Environment override behavior is deterministic and test-covered.

#### CF-P1-004 Routing Domains Matrix (`workers.dev`/routes/custom-domain analog)

- Type: Docs-only (phase 1), Feature+Docs (phase 2)
- Owner: Networking + Docs
- Problem:
  - FastFN deploy docs are Nginx/self-host focused.
  - No clear routing mode matrix equivalent.
- Proposed spec:
  - Docs phase 1:
    - define three patterns:
      - direct host route
      - reverse-proxy route
      - dedicated domain as app origin
    - include constraints and same-zone invocation behavior.
  - Feature phase 2:
    - optional managed domain mapping abstraction in config.
- Docs deliverables:
  - EN: `docs/en/explanation/routing-and-domains.md` (new)
  - ES: `docs/es/explicacion/rutas-y-dominios.md` (new)
  - Update deploy guides EN/ES.
- Acceptance criteria:
  - Operators can choose topology from one canonical matrix.

#### CF-P1-005 Deployment Lifecycle (Versions, gradual rollout, rollback)

- Type: Feature+Docs
- Owner: Runtime + CLI + Docs
- Problem:
  - FastFN supports version folders but lacks explicit deployment lifecycle docs/tools.
- Proposed spec:
  - Introduce deployment manifest:
    - active version aliases
    - weighted traffic split rules
    - rollback pointer + history
  - CLI:
    - `fastfn deploy plan`
    - `fastfn deploy apply`
    - `fastfn deploy rollback`
  - API:
    - `GET /_fn/deployments`
    - `POST /_fn/deployments`
    - `POST /_fn/deployments/rollback`
- Docs deliverables:
  - EN: `docs/en/how-to/versioned-deployments.md` (new)
  - ES: `docs/es/como-hacer/despliegues-versionados.md` (new)
  - Update versioning tutorial EN/ES.
- Acceptance criteria:
  - Weighted rollout can shift 0->100% with audit trail.

#### CF-P1-006 Observability Model (logs, traces, tail stream)

- Type: Feature+Docs
- Owner: Runtime + Observability + Docs
- Problem:
  - FastFN has health/log endpoints but no unified observability contract docs.
- Proposed spec:
  - Define canonical event schema for logs/traces:
    - invocation identifiers
    - runtime/function/version
    - outcome + latency + resource indicators.
  - Add sampling controls in config.
  - Add optional tail-consumer function type.
- Docs deliverables:
  - EN: `docs/en/reference/observability.md` (new)
  - ES: `docs/es/referencia/observabilidad.md` (new)
  - Update HTTP API reference with observability endpoints.
- Acceptance criteria:
  - Traces/logs share correlation IDs.
  - Sampling behavior documented and testable.

### P2 (Nice-to-have / Strategic)

#### CF-P2-001 Formal limits and quotas chapter

- Type: Docs-only (phase 1), Feature+Docs (phase 2)
- Owner: Runtime + Docs
- Problem:
  - Limits are spread across pages; no canonical "platform limits" table.
- Proposed spec:
  - Publish one limits matrix:
    - body sizes
    - concurrency
    - timeout/cpu semantics
    - queue retries
    - scheduler constraints.
  - Mark each limit as:
    - hard-enforced
    - soft/default
    - planned.
- Deliverables:
  - EN: `docs/en/reference/platform-limits.md` (new)
  - ES: `docs/es/referencia/limites-plataforma.md` (new)

#### CF-P2-002 Pricing/operational cost model guide

- Type: Docs-only
- Owner: Product + Docs
- Problem:
  - No transparent cost model guidance for self-hosted operators.
- Proposed spec:
  - Publish resource-to-cost estimation worksheet.
  - Include minimal sizing examples by traffic profile.
- Deliverables:
  - EN: `docs/en/explanation/cost-model.md` (new)
  - ES: `docs/es/explicacion/modelo-costos.md` (new)

#### CF-P2-003 Build pipeline + CI/CD + IaC guide

- Type: Docs-only (phase 1), Feature+Docs (phase 2)
- Owner: CLI + DevEx + Docs
- Problem:
  - No consolidated release/deploy automation playbook.
- Proposed spec:
  - Define supported deployment pathways:
    - CLI manual
    - CI pipeline
    - API-driven/IaC style.
  - Define non-interactive requirements and secret handling.
- Deliverables:
  - EN: `docs/en/how-to/ci-cd-and-iac.md` (new)
  - ES: `docs/es/como-hacer/ci-cd-e-iac.md` (new)

## 5) Documentation Information Architecture (Proposed)

### New EN files

- `docs/en/reference/compatibility-model.md`
- `docs/en/reference/trigger-handlers.md`
- `docs/en/reference/execution-context.md`
- `docs/en/reference/bindings.md`
- `docs/en/reference/environments.md`
- `docs/en/reference/observability.md`
- `docs/en/reference/platform-limits.md`
- `docs/en/explanation/routing-and-domains.md`
- `docs/en/explanation/cost-model.md`
- `docs/en/how-to/service-to-service-calls.md`
- `docs/en/how-to/versioned-deployments.md`
- `docs/en/how-to/ci-cd-and-iac.md`

### New ES files

- `docs/es/referencia/modelo-compatibilidad.md`
- `docs/es/referencia/handlers-triggers.md`
- `docs/es/referencia/contexto-ejecucion.md`
- `docs/es/referencia/bindings.md`
- `docs/es/referencia/entornos.md`
- `docs/es/referencia/observabilidad.md`
- `docs/es/referencia/limites-plataforma.md`
- `docs/es/explicacion/rutas-y-dominios.md`
- `docs/es/explicacion/modelo-costos.md`
- `docs/es/como-hacer/llamadas-servicio-a-servicio.md`
- `docs/es/como-hacer/despliegues-versionados.md`
- `docs/es/como-hacer/ci-cd-e-iac.md`

## 6) Test and Verification Requirements

For each `Feature+Docs` item, done means all of:

1. Unit tests for parser/validation/contract semantics.
2. Integration tests for runtime behavior and error paths.
3. Docs examples are executable copy/paste and validated in CI.
4. EN + ES pages shipped together or explicitly marked partial in the same PR.

Mandatory verification categories:

- Config validation behavior (`400` vs startup fail-fast).
- Contract serialization (`event.*` + runtime response schema).
- OpenAPI/internal metadata consistency.
- Security behavior under malformed inputs.

## 7) Suggested Execution Order

Phase A (P0 baseline):

1. CF-P0-004 (ES CLI parity, docs-only quick win)
2. CF-P0-001 (compatibility contract skeleton)
3. CF-P0-003 (execution context contract)
4. CF-P0-002 (trigger handler taxonomy, starting with `scheduled` + `queue`)

Phase B (P1 platform shape):

1. CF-P1-003 (environments)
2. CF-P1-001 (bindings typed model)
3. CF-P1-006 (observability schema)
4. CF-P1-005 (deployment lifecycle)
5. CF-P1-002 + CF-P1-004

Phase C (P2 hardening):

1. CF-P2-001
2. CF-P2-003
3. CF-P2-002

## 8) Risks and Guardrails

- Risk: documenting Workers-equivalent features before runtime support exists.
  - Guardrail: mark chapters as `Implemented` / `Experimental` / `Planned`.
- Risk: EN/ES drift.
  - Guardrail: parity matrix gate in docs CI.
- Risk: expanding internal APIs without security model update.
  - Guardrail: every new trigger/binding must update security model docs in same PR.

## 9) Definition of Done (Program Level)

This parity program is considered complete when:

1. All P0 items are released with tests and EN/ES docs.
2. P1 items have either:
   - implementation shipped, or
   - explicit "out of scope" decision recorded in this file.
3. Public docs can explain, without ambiguity:
   - runtime compatibility policy,
   - trigger model,
   - bindings model,
   - deployment lifecycle,
   - observability and limits.

