# TASK-02: Reescribir "First Steps" y Cambiar el Tono

**Status:** ✅ Done
**Encargado:** Gemini (Agente)
**Revisión Cross:** Codex (Agente)

## Criterios de Revisión (Cross-Review)
El revisor (Codex) deberá verificar:
1. Que el tono del documento sea conversacional, empático y no asuma conocimientos previos de compilación (`make build-cli`).
2. Que el flujo de comandos sea lógico y funcional (instalar -> init -> dev -> ver en navegador).
3. Que exista un placeholder claro (`<!-- [REQUIERE CAPTURA DE PANTALLA...] -->`) para la imagen del Swagger UI.
4. Que el documento en español (`primeros-pasos.md`) refleje exactamente el mismo tono y estructura que la versión en inglés.

## Contexto del Proyecto
El tutorial actual de "First Steps" (`docs/en/tutorial/first-steps.md`) se lee como una guía para contribuidores del repositorio (pide hacer `make build-cli`). Necesitamos que se lea como un tutorial de producto para usuarios finales, similar a FastAPI. Debe ser rápido, empático y mostrar la "magia" (Swagger UI) inmediatamente.

## Archivos a Modificar
- `docs/en/tutorial/first-steps.md`
- `docs/es/tutorial/primeros-pasos.md` (Aplicar los mismos cambios en español)

## Instrucciones Detalladas
1. **Eliminar la fricción de compilación:** Borra la sección "Before you start" que menciona `make build-cli`.
2. **Asumir instalación estándar:** Inicia el tutorial asumiendo que el usuario ya instaló FastFN (ej. vía `brew install fastfn` o descargando el binario).
3. **Cambiar el tono:** Usa un lenguaje conversacional. En lugar de "Create a minimal function", usa "Let's build your first API endpoint. In FastFN, your folder structure is your API."
4. **Añadir la sección de "Magia" (Swagger UI):** Después de iniciar el servidor, añade una sección explícita pidiendo al usuario que abra el navegador para ver la documentación interactiva generada automáticamente.
5. **Insertar Placeholder para Captura de Pantalla:** Deja un comentario HTML claro para que el equipo inserte la captura de pantalla del Swagger UI.

## Snippet de Código Exacto (Estructura sugerida para `first-steps.md`)

```markdown
# Quick Start

Welcome to FastFN! This guide is the fastest way to experience the magic of file-based routing and automatic OpenAPI generation.

If you are coming from FastAPI or Next.js API routes, you'll feel right at home: drop a file, get an endpoint.

## 1. Initialize your project

Let's create your first function. Open your terminal and run:

```bash
fastfn init hello --template node
```

This creates a `hello` folder with a `handler.js` file. That's it! You just created an API endpoint.

## 2. Start the development server

Start FastFN in your current directory:

```bash
fastfn dev .
```

Behind the scenes, FastFN instantly spins up a lightning-fast OpenResty gateway, boots up your Node.js runtime, and maps your folders to live HTTP routes.

## 3. See the Magic: Automatic Interactive Docs

FastFN automatically generates OpenAPI 3.1 documentation for every function you create. 

Open your browser and navigate to:
👉 **[http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs)**

<!-- [REQUIERE CAPTURA DE PANTALLA: Insertar aquí una captura de pantalla limpia y atractiva del Swagger UI mostrando el endpoint /hello] -->

You can test your endpoint directly from this UI!

## 4. Call your API

You can also call your new endpoint using `curl` or your browser:

```bash
curl -i 'http://127.0.0.1:8080/hello?name=World'
```

**Expected Output:**
```json
{
  "status": 200,
  "body": "Hello World"
}
```

## Next Steps

Notice how you didn't have to write any routing logic or configure a server? 
- Learn how to use dynamic parameters in [Routing & Parameters](../../en/tutorial/routing.md).
- Dive deep with our [From Zero Course](../../en/tutorial/from-zero/index.md).
```
