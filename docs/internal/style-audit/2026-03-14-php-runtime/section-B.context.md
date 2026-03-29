# Section B Editorial Context

pairs: 8

## Pair
EN: `docs/en/tutorial/first-steps.md`
ES: `docs/es/tutorial/primeros-pasos.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
EN headings:
- Quick View
- Prerequisites
- 1. Create your first function (neutral path)
- 2. Start the local server
- 3. Validate with curl (per runtime)
- 4. Verify generated API docs
- Validation checklist
- Troubleshooting
- Next step
- Related links
EN internal links:
- ../../assets/screenshots/swagger-ui.png
- ./from-zero/1-setup-and-first-route.md
- ./from-zero/index.md
- ./routing.md
- ../reference/http-api.md
- ../how-to/run-and-test.md
- ../how-to/deploy-to-production.md
- ../explanation/architecture.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
ES headings:
- Vista rápida
- Prerrequisitos
- 1. Crea tu primera función (path neutral)
- 2. Inicia el servidor local
- 3. Valida con curl (por runtime)
- 4. Valida documentación generada
- Checklist de validación
- Solución de problemas
- Siguiente paso
- Enlaces relacionados
ES internal links:
- ../../assets/screenshots/swagger-ui.png
- ./desde-cero/1-setup-y-primera-ruta.md
- ./desde-cero/index.md
- ./routing.md
- ../referencia/api-http.md
- ../como-hacer/ejecutar-y-probar.md
- ../como-hacer/desplegar-a-produccion.md
- ../explicacion/arquitectura.md

## Pair
EN: `docs/en/tutorial/from-zero/1-setup-and-first-route.md`
ES: `docs/es/tutorial/desde-cero/1-setup-y-primera-ruta.md`

EN metrics: quick=True validation=False troubleshooting=True related=True links=14/8 next=True
EN headings:
- Quick View
- 1. Clean-room setup
- 2. Implement the first route (choose one runtime)
- 3. Run locally
- 4. Validate first request (per runtime)
- 5. Validate OpenAPI visibility
- Troubleshooting
- Next step
- Related links
- Next step
- Related links
EN internal links:
- ../../../assets/screenshots/browser-json-tasks.png
- ./2-routing-and-data.md
- ../request-validation-and-schemas.md
- ../../reference/http-api.md
- ../../how-to/run-and-test.md
- ../first-steps.md
- ./index.md
- ../../how-to/deploy-to-production.md
- ../../how-to/zero-config-routing.md
- ../../reference/function-spec.md
- ../../explanation/architecture.md
ES metrics: quick=True validation=False troubleshooting=True related=True links=14/8 next=True
ES headings:
- Vista rápida
- 1. Setup limpio
- 2. Implementa la primera ruta (elige runtime)
- 3. Ejecuta local
- 4. Valida primera request (por runtime)
- 5. Valida visibilidad OpenAPI
- Solución de problemas
- Próximo paso
- Enlaces relacionados
- Siguiente paso
- Enlaces relacionados
ES internal links:
- ../../../assets/screenshots/browser-json-tasks.png
- ./2-enrutamiento-y-datos.md
- ../validacion-y-schemas.md
- ../../referencia/api-http.md
- ../../como-hacer/ejecutar-y-probar.md
- ../primeros-pasos.md
- ./index.md
- ../../como-hacer/desplegar-a-produccion.md
- ../../como-hacer/zero-config-routing.md
- ../../referencia/especificacion-funciones.md
- ../../explicacion/arquitectura.md

## Pair
EN: `docs/en/tutorial/from-zero/2-routing-and-data.md`
ES: `docs/es/tutorial/desde-cero/2-enrutamiento-y-datos.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
EN headings:
- Quick View
- 1. Path params and catch-all
- 2. Query params with defaults
- 3. JSON body parsing and validation
- Flow diagram
- Validation
- Troubleshooting
- Next step
- Related links
EN internal links:
- ./3-config-and-secrets.md
- ../request-validation-and-schemas.md
- ../request-metadata-and-files.md
- ../../reference/http-api.md
- ./1-setup-and-first-route.md
- ./4-advanced-responses.md
- ../typed-inputs-and-responses.md
- ../../how-to/run-and-test.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
ES headings:
- Vista rápida
- 1. Path params y catch-all
- 2. Query params con defaults
- 3. Parseo JSON y validación de body
- Diagrama de flujo
- Validación
- Solución de problemas
- Próximo paso
- Enlaces relacionados
ES internal links:
- ./3-configuracion-y-secretos.md
- ../validacion-y-schemas.md
- ../metadata-request-y-archivos.md
- ../../referencia/api-http.md
- ./1-setup-y-primera-ruta.md
- ./4-respuestas-avanzadas.md
- ../inputs-y-respuestas-tipadas.md
- ../../como-hacer/ejecutar-y-probar.md

## Pair
EN: `docs/en/tutorial/request-validation-and-schemas.md`
ES: `docs/es/tutorial/validacion-y-schemas.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
EN headings:
- Quick View
- Example handler (Node, Python, Rust, PHP)
- Validation curls (per runtime)
- Path + body rules
- Validation
- Troubleshooting
- Next step
- Related links
EN internal links:
- ./from-zero/4-advanced-responses.md
- ./from-zero/2-routing-and-data.md
- ./typed-inputs-and-responses.md
- ../reference/runtime-coercion-patterns.md
- ../how-to/run-and-test.md
- ../reference/http-api.md
- ../reference/function-spec.md
- ../explanation/architecture.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
ES headings:
- Vista rápida
- Handler de ejemplo (Node, Python, Rust, PHP)
- Curls de validación (por runtime)
- Reglas de path + body
- Validación
- Solución de problemas
- Siguiente paso
- Enlaces relacionados
ES internal links:
- ./desde-cero/4-respuestas-avanzadas.md
- ./desde-cero/2-enrutamiento-y-datos.md
- ./inputs-y-respuestas-tipadas.md
- ../referencia/patrones-coercion-runtime.md
- ../como-hacer/ejecutar-y-probar.md
- ../referencia/api-http.md
- ../referencia/especificacion-funciones.md
- ../explicacion/arquitectura.md

## Pair
EN: `docs/en/tutorial/request-metadata-and-files.md`
ES: `docs/es/tutorial/metadata-request-y-archivos.md`

EN metrics: quick=False validation=True troubleshooting=True related=True links=12/8 next=True
EN headings:
- Complexity
- Time
- Outcome
- Validation
- Troubleshooting
- Support matrix
- Headers
- Cookies
- JSON and plain-text bodies
- Forms and multipart
- Limits that matter
- Next step
EN internal links:
- ./first-steps.md
- ./from-zero/index.md
- ../how-to/run-and-test.md
- ../how-to/deploy-to-production.md
- ../how-to/zero-config-routing.md
- ../reference/http-api.md
- ../reference/function-spec.md
- ../reference/runtime-contract.md
- ./typed-inputs-and-responses.md
- ./from-zero/4-advanced-responses.md
- ../explanation/architecture.md
ES metrics: quick=False validation=True troubleshooting=True related=True links=12/8 next=True
ES headings:
- Complejidad
- Tiempo
- Resultado
- Validación
- Solución de problemas
- Matriz de soporte
- Headers
- Cookies
- Body JSON y texto plano
- Forms y multipart
- Límites importantes
- Siguiente paso
ES internal links:
- ./primeros-pasos.md
- ./desde-cero/index.md
- ../como-hacer/ejecutar-y-probar.md
- ../como-hacer/desplegar-a-produccion.md
- ../como-hacer/zero-config-routing.md
- ../referencia/api-http.md
- ../referencia/especificacion-funciones.md
- ../referencia/contrato-runtime.md
- ./inputs-y-respuestas-tipadas.md
- ./desde-cero/4-respuestas-avanzadas.md
- ../explicacion/arquitectura.md

## Pair
EN: `docs/en/tutorial/from-zero/4-advanced-responses.md`
ES: `docs/es/tutorial/desde-cero/4-respuestas-avanzadas.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=12/8 next=True
EN headings:
- Quick View
- 1. Response shape guarantees
- 2. Alternate response models by state
- 3. Status code strategy
- 4. Additional status codes in one endpoint
- 5. Error envelope
- 6. Body updates (PUT vs PATCH)
- 7. Return a response directly
- 8. Custom response payload and content type
- 9. Additional responses in OpenAPI
- 10. Response cookies
- 11. Response headers
EN internal links:
- ../request-validation-and-schemas.md
- ../../reference/http-api.md
- ../../how-to/deploy-to-production.md
- ../../how-to/run-and-test.md
- ../typed-inputs-and-responses.md
- ../../reference/function-spec.md
- ../../explanation/architecture.md
- ../../explanation/performance-benchmarks.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=12/8 next=True
ES headings:
- Vista rápida
- 1. Garantía de forma de respuesta
- 2. Modelos alternativos según estado
- 3. Estrategia de códigos de estado
- 4. Códigos adicionales en un endpoint
- 5. Envelope de errores
- 6. Actualizaciones de body (PUT vs PATCH)
- 7. Responder directamente
- 8. Respuesta custom y tipo de contenido
- 9. Respuestas adicionales en OpenAPI
- 10. Cookies de respuesta
- 11. Headers de respuesta
ES internal links:
- ../validacion-y-schemas.md
- ../../referencia/api-http.md
- ../../como-hacer/desplegar-a-produccion.md
- ../../como-hacer/ejecutar-y-probar.md
- ../inputs-y-respuestas-tipadas.md
- ../../referencia/especificacion-funciones.md
- ../../explicacion/arquitectura.md
- ../../explicacion/benchmarks-rendimiento.md

## Pair
EN: `docs/en/how-to/zero-config-routing.md`
ES: `docs/es/como-hacer/zero-config-routing.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=12/8 next=True
EN headings:
- Quick View
- 1. Runtime Auto-Discovery
- 2. File-Based Route Rules
- Folder-defined home alias (`fn.config.json`)
- Root home behavior (`/`)
- 3. Precedence (Important)
- 4. Discovery Logs
- 5. Multi-Directory / Multi-App Behavior
- 6. HTML + CSS Endpoints
- 7. Method-Specific File Routing
- 8. Warm/Cold Runtime Signals
- 9. Internal Docs & Admin API Toggles
EN internal links:
- ../reference/function-spec.md
- ../reference/http-api.md
- run-and-test.md
- ../tutorial/first-steps.md
- ../tutorial/from-zero/index.md
- ./run-and-test.md
- ./deploy-to-production.md
- ../explanation/architecture.md
- ./get-help.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=12/8 next=True
ES headings:
- Vista Rápida
- 1. Auto-descubrimiento de Runtime
- 2. Reglas de Rutas Basadas en Archivos
- Home por carpeta (`fn.config.json`)
- Comportamiento de home raíz (`/`)
- 3. Precedencia (Importante)
- 4. Logs de Descubrimiento
- 5. Comportamiento Multi-Directorio / Multi-App
- 6. Endpoints HTML + CSS
- 7. Enrutamiento por Archivo de Método
- 8. Señales Warm/Cold del Runtime
- 9. Toggles de Docs Internas y API Admin
ES internal links:
- ../referencia/especificacion-funciones.md
- ../referencia/api-http.md
- ejecutar-y-probar.md
- ../tutorial/primeros-pasos.md
- ../tutorial/desde-cero/index.md
- ./ejecutar-y-probar.md
- ./desplegar-a-produccion.md
- ../explicacion/arquitectura.md
- ./obtener-ayuda.md

## Pair
EN: `docs/en/tutorial/from-zero/3-config-and-secrets.md`
ES: `docs/es/tutorial/desde-cero/3-configuracion-y-secretos.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=10/8 next=True
EN headings:
- Quick View
- Objective
- Prerequisites
- 1. Secret injection with `fn.env.json`
- 2. Route policy with `fn.config.json`
- 3. Layering rules
- Validation checklist
- Troubleshooting
- Next step
- Related links
EN internal links:
- ./2-routing-and-data.md
- ./4-advanced-responses.md
- ../../how-to/run-and-test.md
- ../security-for-functions.md
- ../../reference/http-api.md
- ../../reference/function-spec.md
- ../../how-to/security-confidence.md
- ../../explanation/architecture.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=10/8 next=True
ES headings:
- Vista rápida
- Objetivo
- Prerrequisitos
- 1. Inyección de secretos con `fn.env.json`
- 2. Política de ruta con `fn.config.json`
- 3. Reglas de capas
- Checklist de validación
- Troubleshooting
- Siguiente paso
- Enlaces relacionados
ES internal links:
- ./2-enrutamiento-y-datos.md
- ./4-respuestas-avanzadas.md
- ../../como-hacer/ejecutar-y-probar.md
- ../seguridad-para-funciones.md
- ../../referencia/api-http.md
- ../../referencia/especificacion-funciones.md
- ../../como-hacer/checklist-seguridad-produccion.md
- ../../explicacion/arquitectura.md
