# Section E Editorial Context

pairs: 6

## Pair
EN: `docs/en/reference/http-api.md`
ES: `docs/es/referencia/api-http.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=12/6 next=True
EN headings:
- Quick View
- Conventions
- Public endpoints
- `GET|POST|PUT|PATCH|DELETE /<route>`
- GET example
- POST example
- Version pinning (optional)
- `GET|POST|PUT|PATCH|DELETE /<name>@<version>`
- Custom routes via `invoke.routes`
- Debug headers (opt-in)
- Path operation configuration (FastFN equivalents)
- Internal platform endpoints (`/_fn/*`)
EN internal links:
- function-spec.md
- ../how-to/run-and-test.md
- ../explanation/architecture.md
- ../how-to/zero-config-routing.md
- ../how-to/platform-runtime-plumbing.md
- ./function-spec.md
- ./runtime-contract.md
- ./builtin-functions.md
- ../how-to/get-help.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=12/6 next=True
ES headings:
- Vista rápida
- Convenciones
- Endpoints publicos
- `GET|POST|PUT|PATCH|DELETE /<ruta>`
- Ejemplo GET
- Ejemplo POST
- Versionado (opcional)
- `GET|POST|PUT|PATCH|DELETE /<name>@<version>`
- Rutas custom via `invoke.routes`
- Debug headers (opt-in)
- Configuración de operaciones (equivalencias en FastFN)
- Endpoints internos de plataforma (`/_fn/*`)
ES internal links:
- especificacion-funciones.md
- ../como-hacer/ejecutar-y-probar.md
- ../explicacion/arquitectura.md
- ../como-hacer/zero-config-routing.md
- ../como-hacer/plomeria-runtime-plataforma.md
- ./especificacion-funciones.md
- ./contrato-runtime.md
- ./funciones-ejemplo.md
- ../como-hacer/obtener-ayuda.md

## Pair
EN: `docs/en/how-to/platform-runtime-plumbing.md`
ES: `docs/es/como-hacer/plomeria-runtime-plataforma.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
EN headings:
- Quick View
- Request Pipeline Boundaries
- CORS Matrix
- Using Raw Request Directly
- Lifecycle Events and Timing
- Validation
- Troubleshooting
- Related links
- Next step
EN internal links:
- ../tutorial/first-steps.md
- ../tutorial/from-zero/index.md
- ./run-and-test.md
- ./deploy-to-production.md
- ./zero-config-routing.md
- ../reference/http-api.md
- ../reference/function-spec.md
- ../explanation/architecture.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
ES headings:
- Vista rapida
- Limites del pipeline
- Matriz CORS
- Uso de request raw
- Eventos y timing
- Validacion
- Troubleshooting
- Enlaces relacionados
- Siguiente paso
ES internal links:
- ../tutorial/primeros-pasos.md
- ../tutorial/desde-cero/index.md
- ./ejecutar-y-probar.md
- ./desplegar-a-produccion.md
- ./zero-config-routing.md
- ../referencia/api-http.md
- ../referencia/especificacion-funciones.md
- ../explicacion/arquitectura.md

## Pair
EN: `docs/en/how-to/data-access-patterns.md`
ES: `docs/es/como-hacer/patrones-de-acceso-a-datos.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=10/8 next=True
EN headings:
- Quick View
- SQL Starter Pattern
- Async SQL Pattern
- NoSQL Adapter Pattern
- Validation
- Troubleshooting
- Related links
- Next step
EN internal links:
- ../tutorial/first-steps.md
- ../tutorial/from-zero/index.md
- ../tutorial/from-zero/3-config-and-secrets.md
- ./run-and-test.md
- ./bigger-app-structure.md
- ./deploy-to-production.md
- ../reference/http-api.md
- ../reference/function-spec.md
- ../explanation/architecture.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=10/8 next=True
ES headings:
- Vista rapida
- Patron SQL base
- Patron SQL async
- Patron adaptador NoSQL
- Validacion
- Troubleshooting
- Enlaces relacionados
- Siguiente paso
ES internal links:
- ../tutorial/primeros-pasos.md
- ../tutorial/desde-cero/index.md
- ../tutorial/desde-cero/3-configuracion-y-secretos.md
- ./ejecutar-y-probar.md
- ./estructura-app-grande.md
- ./desplegar-a-produccion.md
- ../referencia/api-http.md
- ../referencia/especificacion-funciones.md
- ../explicacion/arquitectura.md

## Pair
EN: `docs/en/how-to/bigger-app-structure.md`
ES: `docs/es/como-hacer/estructura-app-grande.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=10/8 next=True
EN headings:
- Quick View
- Recommended Structure
- Background/Scheduled Execution Pattern
- Validation
- Troubleshooting
- Related links
- Next step
EN internal links:
- ../tutorial/first-steps.md
- ../tutorial/from-zero/index.md
- ./zero-config-routing.md
- ./manage-functions.md
- ./data-access-patterns.md
- ./run-and-test.md
- ./deploy-to-production.md
- ../reference/http-api.md
- ../explanation/architecture.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=10/8 next=True
ES headings:
- Vista rapida
- Estructura recomendada
- Patron background/scheduler
- Validacion
- Troubleshooting
- Enlaces relacionados
- Siguiente paso
ES internal links:
- ../tutorial/primeros-pasos.md
- ../tutorial/desde-cero/index.md
- ./zero-config-routing.md
- ./gestionar-funciones.md
- ./patrones-de-acceso-a-datos.md
- ./ejecutar-y-probar.md
- ./desplegar-a-produccion.md
- ../referencia/api-http.md
- ../explicacion/arquitectura.md

## Pair
EN: `docs/en/explanation/support-matrix-advanced-protocols.md`
ES: `docs/es/explicacion/matriz-soporte-protocolos-avanzados.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=12/6 next=True
EN headings:
- Quick View
- Support Posture
- Decision Guide
- Validation
- Troubleshooting
- Related links
- Next step
- Related links
EN internal links:
- ./architecture.md
- ./comparison.md
- ../how-to/deploy-to-production.md
- ../tutorial/first-steps.md
- ../tutorial/from-zero/index.md
- ../how-to/run-and-test.md
- ../how-to/zero-config-routing.md
- ../reference/http-api.md
- ../reference/function-spec.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=12/6 next=True
ES headings:
- Vista rapida
- Postura de soporte
- Guia de decision
- Validacion
- Troubleshooting
- Enlaces relacionados
- Siguiente paso
- Enlaces relacionados
ES internal links:
- ./arquitectura.md
- ./comparacion.md
- ../como-hacer/desplegar-a-produccion.md
- ../tutorial/primeros-pasos.md
- ../tutorial/desde-cero/index.md
- ../como-hacer/ejecutar-y-probar.md
- ../como-hacer/zero-config-routing.md
- ../referencia/api-http.md
- ../referencia/especificacion-funciones.md

## Pair
EN: `docs/en/how-to/run-and-test.md`
ES: `docs/es/como-hacer/ejecutar-y-probar.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=22/8 next=True
EN headings:
- Quick View
- Validation scope
- Prerequisites
- Stage 1: build and start
- Stage 2: health and core endpoint checks
- Stage 3: OpenAPI and routing parity checks
- Stage 4: explicit conflict behavior check
- Stage 5: run full regression suites
- Stage 6: publish-quality tracking checklist
- Flow Diagram
- Objective
- Validation Checklist
EN internal links:
- ../explanation/architecture.md
- ../explanation/invocation-flow.md
- ../reference/function-spec.md
- ./fastapi-nextjs-playbook.md
- ./zero-config-routing.md
- ../reference/http-api.md
- ../reference/fastfn-config.md
- ./deploy-to-production.md
- ./security-confidence.md
- ./platform-runtime-plumbing.md
- ./get-help.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=26/8 next=True
ES headings:
- Vista rápida
- Alcance de validacion
- Requisitos
- Etapa 1: build y arranque
- Etapa 2: salud y endpoints base
- Etapa 3: paridad OpenAPI y mapa de rutas
- Etapa 4: validar politica de conflictos
- Etapa 5: suites de regresion
- Etapa 6: checklist de seguimiento antes de merge/release
- Diagrama de Flujo
- Objetivo
- Prerrequisitos
ES internal links:
- ../explicacion/arquitectura.md
- ../explicacion/flujo-invocacion.md
- ../referencia/especificacion-funciones.md
- ./playbook-fastapi-nextjs.md
- ../referencia/api-http.md
- ../referencia/config-fastfn.md
- ./zero-config-routing.md
- ./plomeria-runtime-plataforma.md
- ./desplegar-a-produccion.md
- ./checklist-seguridad-produccion.md
- ./patrones-de-acceso-a-datos.md
- ./estructura-app-grande.md
