# Section D Editorial Context

pairs: 4

## Pair
EN: `docs/en/tutorial/security-for-functions.md`
ES: `docs/es/tutorial/seguridad-para-funciones.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
EN headings:
- Quick View
- What you need to protect
- Read the user once
- Validation
- Troubleshooting
- Next step
- Related links
EN internal links:
- ../how-to/authentication.md
- ../articles/practical-auth-for-functions.md
- ../how-to/security-confidence.md
- ../how-to/run-and-test.md
- ../how-to/deploy-to-production.md
- ../reference/http-api.md
- ../reference/function-spec.md
- ../reference/runtime-contract.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
ES headings:
- Vista rapida
- Qué debes proteger
- Leer el usuario una sola vez
- Validacion
- Troubleshooting
- Siguiente paso
- Enlaces relacionados
ES internal links:
- ../como-hacer/autenticacion.md
- ../articulos/auth-practica-para-funciones.md
- ../como-hacer/checklist-seguridad-produccion.md
- ../como-hacer/ejecutar-y-probar.md
- ../como-hacer/desplegar-a-produccion.md
- ../referencia/api-http.md
- ../referencia/especificacion-funciones.md
- ../referencia/contrato-runtime.md

## Pair
EN: `docs/en/how-to/authentication.md`
ES: `docs/es/como-hacer/autenticacion.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
EN headings:
- Quick View
- Two kinds of auth
- 1) Platform admin surface (`/_fn/*` and `/console`)
- 2) Function-level auth patterns
- Option A: API key
- Option B: session cookie
- Option C: bearer token + scope
- Validation
- Troubleshooting
- Next step
- Related links
EN internal links:
- ./reuse-auth-and-validation.md
- ../tutorial/security-for-functions.md
- ../articles/practical-auth-for-functions.md
- ./security-confidence.md
- ./run-and-test.md
- ../reference/http-api.md
- ../reference/function-spec.md
- ./console-admin-access.md
- ../explanation/security-model.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=9/8 next=True
ES headings:
- Vista rápida
- Dos tipos de auth
- 1) Superficie admin de plataforma (`/_fn/*` y `/console`)
- 2) Patrones de auth por función
- Opción A: API key
- Opción B: cookie de sesión
- Opción C: bearer token + scope
- Validación
- Troubleshooting
- Siguiente paso
- Enlaces relacionados
ES internal links:
- ./reutilizar-auth-y-validacion.md
- ../tutorial/seguridad-para-funciones.md
- ../articulos/auth-practica-para-funciones.md
- ./checklist-seguridad-produccion.md
- ./ejecutar-y-probar.md
- ../referencia/api-http.md
- ../referencia/especificacion-funciones.md
- ./consola-admin.md
- ../explicacion/modelo-seguridad.md

## Pair
EN: `docs/en/articles/practical-auth-for-functions.md`
ES: `docs/es/articulos/auth-practica-para-funciones.md`

EN metrics: quick=True validation=True troubleshooting=True related=True links=12/6 next=True
EN headings:
- Why this article matters
- Quick View
- Read this with
- Simple security plan
- Step 1: Lock the route first
- Step 2: Add an API key
- Step 3: Add signature checks for webhooks
- Step 4: Protect admin pages and APIs
- Quick checklist
- Validation
- Common mistakes
- Troubleshooting
EN internal links:
- ../reference/http-api.md
- ../reference/function-spec.md
- ../how-to/authentication.md
- ../how-to/security-confidence.md
- ../how-to/run-and-test.md
- ../how-to/deploy-to-production.md
- ../how-to/console-admin-access.md
- ../explanation/security-model.md
ES metrics: quick=True validation=True troubleshooting=True related=True links=12/6 next=True
ES headings:
- Por qué importa este artículo
- Vista rápida
- Léelo junto con
- Plan simple de seguridad
- Paso 1: Bloquear la ruta primero
- Paso 2: Agregar API key
- Paso 3: Agregar firma para webhooks
- Paso 4: Proteger consola y APIs admin
- Checklist rápido
- Validación
- Errores frecuentes
- Troubleshooting
ES internal links:
- ../referencia/api-http.md
- ../referencia/especificacion-funciones.md
- ../como-hacer/autenticacion.md
- ../como-hacer/checklist-seguridad-produccion.md
- ../como-hacer/ejecutar-y-probar.md
- ../como-hacer/desplegar-a-produccion.md
- ../como-hacer/consola-admin.md
- ../explicacion/modelo-seguridad.md

## Pair
EN: `docs/en/how-to/security-confidence.md`
ES: `docs/es/como-hacer/checklist-seguridad-produccion.md`

EN metrics: quick=True validation=False troubleshooting=True related=True links=12/8 next=True
EN headings:
- Quick View
- What is already protected
- What you still need to configure
- Quick trust verification (copy/paste)
- Important limit
- Read next
- Flow Diagram
- Troubleshooting
- HTTP Basic auth
- Next step
- Related links
EN internal links:
- ../explanation/security-model.md
- ./console-admin-access.md
- ./deploy-to-production.md
- ./run-and-test.md
- ./authentication.md
- ../reference/http-api.md
- ../reference/function-spec.md
- ../explanation/architecture.md
ES metrics: quick=True validation=False troubleshooting=True related=True links=12/8 next=True
ES headings:
- Vista rápida
- Qué ya viene protegido
- Qué todavía debes configurar
- Verificación rápida de confianza (copy/paste)
- Límite importante
- Sigue con
- Diagrama de Flujo
- Solución de Problemas
- HTTP Basic
- Siguiente paso
- Enlaces relacionados
ES internal links:
- ../explicacion/modelo-seguridad.md
- ./consola-admin.md
- ./desplegar-a-produccion.md
- ./ejecutar-y-probar.md
- ./autenticacion.md
- ../referencia/api-http.md
- ../referencia/especificacion-funciones.md
- ../explicacion/arquitectura.md
