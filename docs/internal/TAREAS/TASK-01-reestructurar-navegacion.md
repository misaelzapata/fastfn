# TASK-01: Reestructurar la Navegación (mkdocs.yml)

**Status:** ✅ Done
**Encargado:** Claude (Agente) — Completado 2026-02-20
**Revisión Cross:** Gemini (Agente) ✅ Done

## Criterios de Revisión (Cross-Review)
El revisor (Gemini) deberá verificar:
1. Que el archivo `mkdocs.yml` cargue correctamente sin errores de sintaxis YAML.
2. Que la navegación en el sitio local (`mkdocs serve`) refleje exactamente la estructura de "embudo" solicitada (Getting Started -> Core Concepts -> Learn -> Guides).
3. Que no se haya eliminado ninguna configuración de tema, plugins o CSS del archivo original.
4. Que los enlaces a los archivos `.md` no estén rotos (404).

## Contexto del Proyecto
FastFN es un framework serverless políglota. Actualmente, su documentación (`mkdocs.yml`) sigue el framework Diátaxis de forma muy estricta, lo que resulta en un menú lateral fragmentado y abrumador para usuarios nuevos. El objetivo es reorganizar el menú para que se parezca al de Next.js: un embudo de aprendizaje claro ("Getting Started" -> "Core Concepts" -> "Learn" -> "Guides").

## Archivos a Modificar
- `mkdocs.yml`

## Instrucciones Detalladas
1. Abre el archivo `mkdocs.yml` en la raíz del proyecto.
2. Localiza la sección `nav:` al final del archivo.
3. Reemplaza toda la sección `nav:` (tanto para "English Docs" como para "Documentación en Español") con la estructura proporcionada en el snippet de abajo.
4. **Nota:** No elimines ni modifiques ninguna otra sección del archivo (como `theme`, `plugins`, `extra_css`, etc.). Solo modifica el bloque `nav:`.

## Snippet de Código Exacto (Reemplazo para `nav:`)

```yaml
nav:
  - Home: index.md
  - Landing Preview: fastfn-landing.html
  - English Docs:
    - Getting Started:
      - Introduction: en/index.md
      - Installation: en/how-to/homebrew.md
      - Quick Start: en/tutorial/first-steps.md
    - Core Concepts:
      - File-System Routing: en/tutorial/routing.md
      - Zero-Config Routing: en/how-to/zero-config-routing.md
      - Function Config (fn.config.json): en/reference/function-spec.md
      - Global Config (fastfn.json): en/reference/fastfn-config.md
    - Learn (The Course):
      - Overview: en/tutorial/from-zero/index.md
      - 1. Hello World: en/tutorial/from-zero/chapter-01-hello-world.md
      - 2. Query and Body: en/tutorial/from-zero/chapter-02-query-and-body.md
      - 3. Env Vars: en/tutorial/from-zero/chapter-03-env.md
      - 4. Metadata: en/tutorial/from-zero/chapter-04-meta-and-methods.md
      - 5. Edge Proxy: en/tutorial/from-zero/chapter-05-edge-proxy.md
      - 6. External Libs: en/tutorial/from-zero/chapter-06-external-libraries.md
      - 7. Rich Responses: en/tutorial/from-zero/chapter-07-rich-responses.md
      - 8. Context & Memory: en/tutorial/from-zero/chapter-08-session-context-memory.md
      - 9. Shared Code: en/tutorial/from-zero/chapter-09-shared-deps-env.md
    - Tutorials & Examples:
      - Build a Complete API: en/tutorial/build-complete-api.md
      - QR Generator: en/tutorial/qr-in-python-node.md
      - WhatsApp Bot: en/tutorial/whatsapp-bot-demo.md
      - Artistic QRs: en/tutorial/artistic-qrs.md
    - How-To Guides:
      - Deploy to Production: en/how-to/deploy-to-production.md
      - FastAPI/Next.js Playbook: en/how-to/fastapi-nextjs-playbook.md
      - Authentication: en/how-to/authentication.md
      - Security Confidence: en/how-to/security-confidence.md
      - Console Access: en/how-to/console-admin-access.md
      - Manage Functions: en/how-to/manage-functions.md
      - Telegram Bot (Cron): en/how-to/telegram-digest.md
      - Telegram Bot (E2E): en/how-to/telegram-e2e.md
      - Contributing: en/how-to/contributing.md
      - Tools: en/how-to/tools.md
    - Advanced Articles:
      - Local Hot Reload: en/articles/local-serverless-hot-reload-openapi.md
      - Practical Auth: en/articles/practical-auth-for-functions.md
      - Polyglot APIs (Next-style): en/articles/polyglot-nextstyle-apis.md
      - Telegram AI Reply: en/articles/telegram-ai-reply-how-it-works.md
      - Telegram Loop: en/articles/telegram-loop.md
      - Telegram AI Memory: en/articles/telegram-ai-memory-cron.md
      - Doctor Domains: en/articles/doctor-domains-and-ci.md
      - IP Geolocation: en/articles/ip-geolocation-with-maxmind-and-ipapi.md
      - Workers Compatibility (Beta): en/articles/workers-compatibility-beta.md
    - Reference:
      - CLI Reference: en/reference/cli.md
      - HTTP API: en/reference/http-api.md
      - Runtime Contract: en/reference/runtime-contract.md
      - Builtin Functions: en/reference/builtin-functions.md
      - PHP Template: en/reference/php-template.md
      - Rust Template: en/reference/rust-template.md
    - Architecture & Explanation:
      - Architecture: en/explanation/architecture.md
      - Security Model: en/explanation/security-model.md
      - Technical Comparison: en/explanation/comparison.md
      - Scheduler vs Cron: en/explanation/scheduler-vs-cron.md
      - Next.js Style Routing: en/explanation/nextjs-style-routing-benefits.md
      - Invocation Lifecycle: en/explanation/invocation-flow.md
      - Performance: en/explanation/performance-benchmarks.md
      - Visual Flows: en/explanation/visual-flows.md
  - Documentación en Español:
    # (Aplica la misma estructura lógica traducida para la sección en español)
    - Empezando:
      - Introducción: es/index.md
      - Instalación: es/como-hacer/homebrew.md
      - Inicio Rápido: es/tutorial/primeros-pasos.md
    - Conceptos Core:
      - Enrutamiento por Archivos: es/tutorial/routing.md
      - Enrutamiento Zero-Config: es/como-hacer/zero-config-routing.md
      - Configuración de Función (fn.config.json): es/referencia/especificacion-funciones.md
      - Configuración Global (fastfn.json): es/referencia/config-fastfn.md
    - Aprende (El Curso):
      - Vista General: es/tutorial/desde-cero/index.md
      - 1. Hola Mundo: es/tutorial/desde-cero/capitulo-01-hola-mundo.md
      - 2. Query y Body: es/tutorial/desde-cero/capitulo-02-query-y-body.md
      - 3. Env y Secretos: es/tutorial/desde-cero/capitulo-03-env.md
      - 4. Metadatos HTTP: es/tutorial/desde-cero/capitulo-04-meta-y-metodos.md
      - 5. Edge Proxy: es/tutorial/desde-cero/capitulo-05-edge-proxy.md
      - 6. Librerias Externas: es/tutorial/desde-cero/capitulo-06-librerias-externas.md
      - 7. Respuestas Rich: es/tutorial/desde-cero/capitulo-07-respuestas-rich.md
      - 8. Contexto y Memoria: es/tutorial/desde-cero/capitulo-08-sesion-contexto-memoria.md
      - 9. Código Compartido: es/tutorial/desde-cero/capitulo-09-compartir-deps-env.md
    - Tutoriales y Ejemplos:
      - Construir API Completa: es/tutorial/construir-api-completa.md
      - QR (Python/Node): es/tutorial/qr-python-node.md
      - WhatsApp Bot: es/tutorial/demo-bot-whatsapp.md
      - QRs Artísticos: es/tutorial/qrs-artisticos.md
    - Guías Cómo-Hacer:
      - Desplegar a Producción: es/como-hacer/desplegar-a-produccion.md
      - Playbook FastAPI/Next.js: es/como-hacer/playbook-fastapi-nextjs.md
      - Consola y Administración: es/como-hacer/consola-admin.md
      - Gestionar Funciones: es/como-hacer/gestionar-funciones.md
      - Recetas Operativas: es/como-hacer/recetas-operativas.md
      - "Receta: Digest Telegram (Cron)": es/como-hacer/telegram-digest.md
      - "Receta: Bot E2E": es/como-hacer/telegram-e2e.md
      - Ejecutar y Probar: es/como-hacer/ejecutar-y-probar.md
      - "Checklist de seguridad": es/como-hacer/checklist-seguridad-produccion.md
      - Herramientas (Tools): es/como-hacer/herramientas.md
      - Contribuir: es/como-hacer/contribuir.md
    - Artículos Avanzados:
      - Hot Reload Local + OpenAPI: es/articulos/serverless-local-hot-reload-openapi.md
      - Autenticación Práctica: es/articulos/auth-practica-para-funciones.md
      - APIs Poliglotas (Next-style): es/articulos/apis-poliglotas-next-style.md
      - "Telegram AI Reply": es/articulos/telegram-ai-reply-como-funciona.md
      - Telegram Loop: es/articulos/telegram-loop.md
      - Telegram AI Memoria (Cron): es/articulos/telegram-ai-memoria-cron.md
      - Doctor Dominios + CI: es/articulos/doctor-dominios-y-ci.md
      - Geolocalizacion IP: es/articulos/geolocalizacion-ip-con-maxmind-e-ipapi.md
      - Workers Compatibility (Beta): es/articulos/workers-compat-beta.md
    - Referencia:
      - CLI Reference: es/referencia/cli-reference.md
      - API HTTP: es/referencia/api-http.md
      - Contrato Runtime: es/referencia/contrato-runtime.md
      - Funciones de Ejemplo: es/referencia/funciones-ejemplo.md
      - Plantilla PHP: es/referencia/plantilla-php.md
      - Plantilla Rust: es/referencia/plantilla-rust.md
    - Arquitectura y Explicación:
      - Arquitectura: es/explicacion/arquitectura.md
      - Ciclo de Invocación: es/explicacion/flujo-invocacion.md
      - Modelo de Seguridad: es/explicacion/modelo-seguridad.md
      - Scheduler vs Cron: es/explicacion/scheduler-vs-cron.md
```
