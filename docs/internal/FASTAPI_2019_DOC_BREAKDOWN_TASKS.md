# FastAPI 2019 Docs Parity Backlog (Atomic 75)

Source baseline:
- Wayback snapshot: https://web.archive.org/web/20190818075856/https://fastapi.tiangolo.com/
- Snapshot datetime: 2019-08-18 07:58:56 UTC

Execution contract:
- EN/ES lockstep is mandatory: one task is done only when both language targets are updated in the same PR.
- No public internals leakage: generation pipelines and operational runbooks remain under `docs/internal/**`.
- No silent skips: every task needs explicit validation evidence in PR notes.

Validation profiles:
- `V-HTTP`: runnable local example (`curl`), expected status/body, OpenAPI visibility check, and troubleshooting note.
- `V-CONCEPT`: clear conceptual explanation, at least 2 related internal links, and at least 1 decision table/diagram/list.
- `V-LIMIT`: explicit support posture (`supported`, `adjacent-stack`, or `out-of-scope`) plus recommended workaround.
- `V-OPS`: reproducible commands for setup/run/verify plus failure diagnostics.

Global done criteria for each task:
- EN and ES pages updated.
- Path neutrality policy satisfied (no runtime-prefixed function paths unless explicitly runtime-specific example sections).
- Navigation and internal links resolve.
- `mkdocs build --strict` passes.

Progress:
- Total tasks: 75
- Completed: 39
- Pending: 36
- Path neutrality revalidation status: D001-D039 verified on 2026-03-13.

## A) Entry and Orientation (D001-D003)
- [x] D001 | Baseline: `/` | EN: `docs/en/index.md` | ES: `docs/es/index.md` | Validation: `V-CONCEPT` (5-minute path + links to tutorial, how-to, reference).
- [x] D002 | Baseline: `/features/` | EN: `docs/en/explanation/feature-matrix.md` | ES: `docs/es/explicacion/matriz-de-features.md` | Validation: `V-CONCEPT` (fit/non-fit matrix + capability table).
- [x] D003 | Baseline: `/python-types/` | EN: `docs/en/tutorial/typed-inputs-and-responses.md` | ES: `docs/es/tutorial/inputs-y-respuestas-tipadas.md` | Validation: `V-HTTP` (typed request/response examples in at least 2 runtimes).

## B) Tutorial - HTTP Fundamentals (D004-D034)
- [x] D004 | Baseline: `/tutorial/intro/` | EN: `docs/en/tutorial/first-steps.md` | ES: `docs/es/tutorial/primeros-pasos.md` | Validation: `V-CONCEPT` (scope, prerequisites, expected outcome).
- [x] D005 | Baseline: `/tutorial/first-steps/` | EN: `docs/en/tutorial/from-zero/1-setup-and-first-route.md` | ES: `docs/es/tutorial/desde-cero/1-setup-y-primera-ruta.md` | Validation: `V-OPS` (clean-room setup + first request).
- [x] D006 | Baseline: `/tutorial/path-params/` | EN: `docs/en/tutorial/from-zero/2-routing-and-data.md` | ES: `docs/es/tutorial/desde-cero/2-enrutamiento-y-datos.md` | Validation: `V-HTTP` (path params, wildcard params, examples).
- [x] D007 | Baseline: `/tutorial/query-params/` | EN: `docs/en/tutorial/from-zero/2-routing-and-data.md` | ES: `docs/es/tutorial/desde-cero/2-enrutamiento-y-datos.md` | Validation: `V-HTTP` (query defaults, required vs optional).
- [x] D008 | Baseline: `/tutorial/body/` | EN: `docs/en/tutorial/from-zero/2-routing-and-data.md` | ES: `docs/es/tutorial/desde-cero/2-enrutamiento-y-datos.md` | Validation: `V-HTTP` (JSON body parsing + error cases).
- [x] D009 | Baseline: `/tutorial/query-params-str-validations/` | EN: `docs/en/tutorial/request-validation-and-schemas.md` | ES: `docs/es/tutorial/validacion-y-schemas.md` | Validation: `V-HTTP` (string constraints + invalid payload examples).
- [x] D010 | Baseline: `/tutorial/path-params-numeric-validations/` | EN: `docs/en/tutorial/request-validation-and-schemas.md` | ES: `docs/es/tutorial/validacion-y-schemas.md` | Validation: `V-HTTP` (numeric guards + boundary examples).
- [x] D011 | Baseline: `/tutorial/body-multiple-params/` | EN: `docs/en/tutorial/request-validation-and-schemas.md` | ES: `docs/es/tutorial/validacion-y-schemas.md` | Validation: `V-HTTP` (merged body + params contract table).
- [x] D012 | Baseline: `/tutorial/body-schema/` | EN: `docs/en/tutorial/request-validation-and-schemas.md` | ES: `docs/es/tutorial/validacion-y-schemas.md` | Validation: `V-HTTP` (schema-like shape and field requirements).
- [x] D013 | Baseline: `/tutorial/body-nested-models/` | EN: `docs/en/tutorial/request-validation-and-schemas.md` | ES: `docs/es/tutorial/validacion-y-schemas.md` | Validation: `V-HTTP` (nested objects and arrays).
- [x] D014 | Baseline: `/tutorial/extra-data-types/` | EN: `docs/en/tutorial/request-validation-and-schemas.md` | ES: `docs/es/tutorial/validacion-y-schemas.md` | Validation: `V-HTTP` (dates, booleans, numbers, nullability).
- [x] D015 | Baseline: `/tutorial/cookie-params/` | EN: `docs/en/tutorial/request-metadata-and-files.md` | ES: `docs/es/tutorial/metadata-request-y-archivos.md` | Validation: `V-HTTP` (cookie extraction and fallback behavior).
- [x] D016 | Baseline: `/tutorial/header-params/` | EN: `docs/en/tutorial/request-metadata-and-files.md` | ES: `docs/es/tutorial/metadata-request-y-archivos.md` | Validation: `V-HTTP` (case-insensitive headers + defaults).
- [x] D017 | Baseline: `/tutorial/response-model/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (response shape guarantees).
- [x] D018 | Baseline: `/tutorial/extra-models/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (alternate response shapes by route/state).
- [x] D019 | Baseline: `/tutorial/response-status-code/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (status strategy table).
- [x] D020 | Baseline: `/tutorial/request-forms/` | EN: `docs/en/tutorial/request-metadata-and-files.md` | ES: `docs/es/tutorial/metadata-request-y-archivos.md` | Validation: `V-HTTP` (form-urlencoded examples).
- [x] D021 | Baseline: `/tutorial/request-files/` | EN: `docs/en/tutorial/request-metadata-and-files.md` | ES: `docs/es/tutorial/metadata-request-y-archivos.md` | Validation: `V-HTTP` (single/multi file upload).
- [x] D022 | Baseline: `/tutorial/request-forms-and-files/` | EN: `docs/en/tutorial/request-metadata-and-files.md` | ES: `docs/es/tutorial/metadata-request-y-archivos.md` | Validation: `V-HTTP` (multipart mixed payload contract).
- [x] D023 | Baseline: `/tutorial/handling-errors/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (error envelope + operational hints).
- [x] D024 | Baseline: `/tutorial/path-operation-configuration/` | EN: `docs/en/reference/http-api.md` | ES: `docs/es/referencia/api-http.md` | Validation: `V-CONCEPT` (FastFN metadata equivalents, non-1:1 note).
- [x] D025 | Baseline: `/tutorial/path-operation-advanced-configuration/` | EN: `docs/en/how-to/zero-config-routing.md` | ES: `docs/es/como-hacer/zero-config-routing.md` | Validation: `V-CONCEPT` (route naming/tags/operation ids in file-based model).
- [x] D026 | Baseline: `/tutorial/additional-status-codes/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (multi-status examples).
- [x] D027 | Baseline: `/tutorial/encoder/` | EN: `docs/en/reference/http-api.md` | ES: `docs/es/referencia/api-http.md` | Validation: `V-HTTP` (serialization edge cases).
- [x] D028 | Baseline: `/tutorial/body-updates/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (PATCH/PUT merge behavior).
- [x] D029 | Baseline: `/tutorial/response-directly/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (raw response control examples).
- [x] D030 | Baseline: `/tutorial/custom-response/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (custom headers/content-type).
- [x] D031 | Baseline: `/tutorial/additional-responses/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (explicit alternate responses in docs/OpenAPI).
- [x] D032 | Baseline: `/tutorial/response-cookies/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (set/clear cookie patterns).
- [x] D033 | Baseline: `/tutorial/response-headers/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (cache, trace, custom headers).
- [x] D034 | Baseline: `/tutorial/response-change-status-code/` | EN: `docs/en/tutorial/from-zero/4-advanced-responses.md` | ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md` | Validation: `V-HTTP` (dynamic status transitions documented).

## C) Dependencies Equivalents (D035-D039)
- [x] D035 | Baseline: `/tutorial/dependencies/first-steps/` | EN: `docs/en/explanation/shared-logic-patterns.md` | ES: `docs/es/explicacion/patrones-de-logica-compartida.md` | Validation: `V-CONCEPT` (FastFN-native dependency equivalent intro).
- [x] D036 | Baseline: `/tutorial/dependencies/classes-as-dependencies/` | EN: `docs/en/explanation/shared-logic-patterns.md` | ES: `docs/es/explicacion/patrones-de-logica-compartida.md` | Validation: `V-CONCEPT` (class/module reuse pattern by runtime).
- [x] D037 | Baseline: `/tutorial/dependencies/sub-dependencies/` | EN: `docs/en/explanation/shared-logic-patterns.md` | ES: `docs/es/explicacion/patrones-de-logica-compartida.md` | Validation: `V-CONCEPT` (composable helper chain examples).
- [x] D038 | Baseline: `/tutorial/dependencies/dependencies-in-path-operation-decorators/` | EN: `docs/en/how-to/reuse-auth-and-validation.md` | ES: `docs/es/como-hacer/reutilizar-auth-y-validacion.md` | Validation: `V-CONCEPT` (non-1:1 decorator note + equivalent patterns).
- [x] D039 | Baseline: `/tutorial/dependencies/advanced-dependencies/` | EN: `docs/en/how-to/reuse-auth-and-validation.md` | ES: `docs/es/como-hacer/reutilizar-auth-y-validacion.md` | Validation: `V-OPS` (advanced shared middleware/helper flow).

## D) Security Sequence (D040-D046)
- [ ] D040 | Baseline: `/tutorial/security/intro/` | EN: `docs/en/tutorial/security-for-functions.md` | ES: `docs/es/tutorial/seguridad-para-funciones.md` | Validation: `V-CONCEPT` (threat model + recommended defaults).
- [ ] D041 | Baseline: `/tutorial/security/first-steps/` | EN: `docs/en/how-to/authentication.md` | ES: `docs/es/como-hacer/autenticacion.md` | Validation: `V-HTTP` (simple token gate).
- [ ] D042 | Baseline: `/tutorial/security/get-current-user/` | EN: `docs/en/tutorial/security-for-functions.md` | ES: `docs/es/tutorial/seguridad-para-funciones.md` | Validation: `V-HTTP` (identity resolution pattern).
- [ ] D043 | Baseline: `/tutorial/security/simple-oauth2/` | EN: `docs/en/how-to/authentication.md` | ES: `docs/es/como-hacer/autenticacion.md` | Validation: `V-CONCEPT` (OAuth2-like flow boundaries in FastFN).
- [ ] D044 | Baseline: `/tutorial/security/oauth2-jwt/` | EN: `docs/en/articles/practical-auth-for-functions.md` | ES: `docs/es/articulos/auth-practica-para-funciones.md` | Validation: `V-HTTP` (JWT issuance/verification example).
- [ ] D045 | Baseline: `/tutorial/security/oauth2-scopes/` | EN: `docs/en/how-to/authentication.md` | ES: `docs/es/como-hacer/autenticacion.md` | Validation: `V-CONCEPT` (scope/permission mapping strategy).
- [ ] D046 | Baseline: `/tutorial/security/http-basic-auth/` | EN: `docs/en/how-to/security-confidence.md` | ES: `docs/es/como-hacer/checklist-seguridad-produccion.md` | Validation: `V-LIMIT` (if unsupported, explicit alternatives and rationale).

## E) Platform, Architecture, and Runtime Concerns (D047-D065)
- [ ] D047 | Baseline: `/tutorial/middleware/` | EN: `docs/en/how-to/platform-runtime-plumbing.md` | ES: `docs/es/como-hacer/plomeria-runtime-plataforma.md` | Validation: `V-CONCEPT` (request pipeline hooks and boundaries).
- [ ] D048 | Baseline: `/tutorial/cors/` | EN: `docs/en/how-to/platform-runtime-plumbing.md` | ES: `docs/es/como-hacer/plomeria-runtime-plataforma.md` | Validation: `V-HTTP` (CORS matrix + sample config).
- [ ] D049 | Baseline: `/tutorial/using-request-directly/` | EN: `docs/en/how-to/platform-runtime-plumbing.md` | ES: `docs/es/como-hacer/plomeria-runtime-plataforma.md` | Validation: `V-HTTP` (raw request access examples).
- [ ] D050 | Baseline: `/tutorial/sql-databases/` | EN: `docs/en/how-to/data-access-patterns.md` | ES: `docs/es/como-hacer/patrones-de-acceso-a-datos.md` | Validation: `V-OPS` (SQL integration starter).
- [ ] D051 | Baseline: `/tutorial/async-sql-databases/` | EN: `docs/en/how-to/data-access-patterns.md` | ES: `docs/es/como-hacer/patrones-de-acceso-a-datos.md` | Validation: `V-OPS` (async SQL pattern and caveats).
- [ ] D052 | Baseline: `/tutorial/nosql-databases/` | EN: `docs/en/how-to/data-access-patterns.md` | ES: `docs/es/como-hacer/patrones-de-acceso-a-datos.md` | Validation: `V-OPS` (NoSQL adapter pattern).
- [ ] D053 | Baseline: `/tutorial/bigger-applications/` | EN: `docs/en/how-to/bigger-app-structure.md` | ES: `docs/es/como-hacer/estructura-app-grande.md` | Validation: `V-CONCEPT` (repo layout and ownership boundaries).
- [ ] D054 | Baseline: `/tutorial/background-tasks/` | EN: `docs/en/how-to/bigger-app-structure.md` | ES: `docs/es/como-hacer/estructura-app-grande.md` | Validation: `V-OPS` (background/scheduled execution pattern).
- [ ] D055 | Baseline: `/tutorial/sub-applications-proxy/` | EN: `docs/en/explanation/support-matrix-advanced-protocols.md` | ES: `docs/es/explicacion/matriz-soporte-protocolos-avanzados.md` | Validation: `V-LIMIT` (proxy/sub-app support decision).
- [ ] D056 | Baseline: `/tutorial/application-configuration/` | EN: `docs/en/tutorial/from-zero/3-config-and-secrets.md` | ES: `docs/es/tutorial/desde-cero/3-configuracion-y-secretos.md` | Validation: `V-OPS` (config layering and override examples).
- [ ] D057 | Baseline: `/tutorial/static-files/` | EN: `docs/en/explanation/support-matrix-advanced-protocols.md` | ES: `docs/es/explicacion/matriz-soporte-protocolos-avanzados.md` | Validation: `V-LIMIT` (support posture + recommended setup).
- [ ] D058 | Baseline: `/tutorial/templates/` | EN: `docs/en/explanation/support-matrix-advanced-protocols.md` | ES: `docs/es/explicacion/matriz-soporte-protocolos-avanzados.md` | Validation: `V-LIMIT` (support posture + alternative pattern).
- [ ] D059 | Baseline: `/tutorial/graphql/` | EN: `docs/en/explanation/support-matrix-advanced-protocols.md` | ES: `docs/es/explicacion/matriz-soporte-protocolos-avanzados.md` | Validation: `V-LIMIT` (support posture + integration path).
- [ ] D060 | Baseline: `/tutorial/websockets/` | EN: `docs/en/explanation/support-matrix-advanced-protocols.md` | ES: `docs/es/explicacion/matriz-soporte-protocolos-avanzados.md` | Validation: `V-LIMIT` (support posture + alternative architecture).
- [ ] D061 | Baseline: `/tutorial/events/` | EN: `docs/en/how-to/platform-runtime-plumbing.md` | ES: `docs/es/como-hacer/plomeria-runtime-plataforma.md` | Validation: `V-CONCEPT` (lifecycle events and timing).
- [ ] D062 | Baseline: `/tutorial/testing/` | EN: `docs/en/how-to/run-and-test.md` | ES: `docs/es/como-hacer/ejecutar-y-probar.md` | Validation: `V-OPS` (unit + integration quick recipes).
- [ ] D063 | Baseline: `/tutorial/testing-dependencies/` | EN: `docs/en/how-to/run-and-test.md` | ES: `docs/es/como-hacer/ejecutar-y-probar.md` | Validation: `V-OPS` (FastFN-native seams/mocking guidance).
- [ ] D064 | Baseline: `/tutorial/debugging/` | EN: `docs/en/how-to/run-and-test.md` | ES: `docs/es/como-hacer/ejecutar-y-probar.md` | Validation: `V-OPS` (debug checklist and common failures).
- [ ] D065 | Baseline: `/tutorial/extending-openapi/` | EN: `docs/en/reference/http-api.md` | ES: `docs/es/referencia/api-http.md` | Validation: `V-CONCEPT` (OpenAPI extension points and limits).

## F) Advanced, Project, and Ecosystem Docs (D066-D075)
- [ ] D066 | Baseline: `/async/` | EN: `docs/en/explanation/concurrency-and-async.md` | ES: `docs/es/explicacion/concurrencia-y-async.md` | Validation: `V-CONCEPT` (runtime concurrency model by language).
- [ ] D067 | Baseline: `/deployment/` | EN: `docs/en/how-to/deploy-to-production.md` | ES: `docs/es/como-hacer/desplegar-a-produccion.md` | Validation: `V-OPS` (deployment matrix + preflight).
- [ ] D068 | Baseline: `/project-generation/` | EN: `docs/en/how-to/project-generation.md` | ES: `docs/es/como-hacer/generacion-proyecto.md` | Validation: `V-OPS` (starter generation and next steps).
- [ ] D069 | Baseline: `/alternatives/` | EN: `docs/en/explanation/comparison.md` | ES: `docs/es/explicacion/comparacion.md` | Validation: `V-CONCEPT` (decision guide and migration notes).
- [ ] D070 | Baseline: `/history-design-future/` | EN: `docs/en/explanation/history-design-future.md` | ES: `docs/es/explicacion/historia-diseno-futuro.md` | Validation: `V-CONCEPT` (design rationale and roadmap framing).
- [ ] D071 | Baseline: `/external-links/` | EN: `docs/en/reference/external-links.md` | ES: `docs/es/referencia/enlaces-externos.md` | Validation: `V-CONCEPT` (curated ecosystem index).
- [ ] D072 | Baseline: `/benchmarks/` | EN: `docs/en/explanation/performance-benchmarks.md` | ES: `docs/es/explicacion/benchmarks-rendimiento.md` | Validation: `V-OPS` (methodology + reproducibility steps).
- [ ] D073 | Baseline: `/help-fastapi/` | EN: `docs/en/how-to/get-help.md` | ES: `docs/es/como-hacer/obtener-ayuda.md` | Validation: `V-CONCEPT` (support channels and triage path).
- [ ] D074 | Baseline: `/contributing/` | EN: `docs/en/how-to/contributing.md` | ES: `docs/es/como-hacer/contribuir.md` | Validation: `V-OPS` (contribution workflow, tests, review checklist).
- [ ] D075 | Baseline: `/release-notes/` | EN: `CHANGELOG.md` + `docs/en/how-to/contributing.md` | ES: `docs/es/como-hacer/contribuir.md` | Validation: `V-OPS` (release-note policy and versioning discipline).

## Sequencing (blocked order)
1. Phase A: D001-D003
2. Phase B: D004-D034
3. Phase C: D035-D046
4. Phase D: D047-D065
5. Phase E: D066-D075

## PR acceptance checklist (for every docs PR)
- `[ ]` All touched tasks updated from `[ ]` to `[x]`.
- `[ ]` EN/ES parity confirmed.
- `[ ]` Path neutrality policy verified (runtime-prefixed function paths only in explicit runtime-specific examples).
- `[ ]` Internal links checked.
- `[ ]` `mkdocs build --strict` output attached.
- `[ ]` If a support limit was documented, `V-LIMIT` posture included.
