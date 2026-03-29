# TASK-05: Consolidar el Tutorial "From Zero"

**Status:** ✅ Done
**Encargado:** Gemini (Agente)
**Revisión Cross:** Claude (Agente) ✅ — Revisión completada 2026-02-20. Los 5 criterios pasan. Defecto corregido: PHP tab faltante en redirect de Part 4 (compartido con TASK-03).

## Criterios de Revisión (Cross-Review)
El revisor (Claude) deberá verificar:
1. Que los 9 capítulos originales hayan sido fusionados en un curso cohesivo de 4 partes (ej. "Task Manager API").
2. Que la narrativa fluya lógicamente de un capítulo a otro, construyendo sobre el proyecto anterior.
3. Que se introduzcan `fn.config.json` y `fn.env.json` en el momento adecuado (ej. al conectar a una base de datos simulada).
4. Que el menú lateral (`mkdocs.yml`) refleje la nueva estructura de 4 partes.
5. Que los ejemplos de código en los nuevos capítulos utilicen pestañas políglotas (`=== "Lenguaje"`).

## Contexto del Proyecto
El tutorial actual "From Zero" (`docs/en/tutorial/from-zero/`) está fragmentado en 9 capítulos muy pequeños. Esto rompe el flujo de aprendizaje y hace que el menú lateral sea abrumador. Para alcanzar el nivel de Next.js o FastAPI, necesitamos transformar estos 9 capítulos en un curso cohesivo de 4 partes donde el usuario construya una sola aplicación real (ej. una API de Tareas o un CRM simple) de principio a fin.

## Archivos a Modificar
- `docs/en/tutorial/from-zero/*.md` (Todos los capítulos actuales)
- `docs/es/tutorial/desde-cero/*.md` (Sus equivalentes en español)
- `mkdocs.yml` (Para actualizar la navegación)

## Instrucciones Detalladas
1. **Definir el proyecto:** Elige una aplicación sencilla pero realista que requiera rutas dinámicas, lectura de body/query, y variables de entorno. (Ej. "Task Manager API").
2. **Fusionar Capítulos 1 y 2 (Instalación y Primera Ruta):** Enfócate en el momento "Aha!" de crear un archivo y verlo en el navegador.
3. **Fusionar Capítulos 4 y 5 (Enrutamiento y Datos):** Explica rutas dinámicas `[id]` y cómo leer el body/query en el contexto del proyecto.
4. **Fusionar Capítulos 3 y 9 (Configuración y Secretos):** Introduce `fn.config.json` y `fn.env.json` cuando el proyecto necesite conectarse a una "base de datos" simulada o API externa.
5. **Fusionar Capítulos 7 y 8 (Respuestas Avanzadas):** Muestra cómo devolver HTML o imágenes si el proyecto lo requiere.
6. **Actualizar `mkdocs.yml`:** Refleja la nueva estructura de 4 partes en el menú lateral.

## Snippet de Código Exacto (Estructura sugerida para el nuevo curso)

**Nueva Estructura de Archivos:**
- `docs/en/tutorial/from-zero/index.md` (Overview del proyecto "Task Manager API")
- `docs/en/tutorial/from-zero/1-setup-and-first-route.md` (Combina Capítulos 1 y 2)
- `docs/en/tutorial/from-zero/2-routing-and-data.md` (Combina Capítulos 4 y 5)
- `docs/en/tutorial/from-zero/3-config-and-secrets.md` (Combina Capítulos 3 y 9)
- `docs/en/tutorial/from-zero/4-advanced-responses.md` (Combina Capítulos 7 y 8)

**Ejemplo de Narrativa (Para `1-setup-and-first-route.md`):**
```markdown
# Part 1: Setup and Your First Route

Welcome to the FastFN course! Over the next 4 parts, we'll build a complete "Task Manager API" from scratch. You'll learn how to handle routing, read data, manage secrets, and return rich responses.

## The Goal

By the end of this part, you'll have a working API endpoint that returns a list of tasks.

## 1. Create the Project

Let's start by creating a folder for our API and initializing our first function.

```bash
mkdir task-manager-api
cd task-manager-api
fastfn init tasks --template node
```

This creates a `tasks` folder with a `handler.js` file.

## 2. Write the Code

Open `tasks/handler.js` and replace its contents with the following code:

=== "Node.js"
    ```javascript
    exports.handler = async (event) => {
        const tasks = [
            { id: 1, title: "Learn FastFN", completed: false },
            { id: 2, title: "Build an API", completed: false }
        ];

        return {
            status: 200,
            body: tasks
        };
    };
    ```

=== "Python"
    ```python
    def handler(event):
        tasks = [
            {"id": 1, "title": "Learn FastFN", "completed": False},
            {"id": 2, "title": "Build an API", "completed": False}
        ]

        return {
            "status": 200,
            "body": tasks
        }
    ```

## 3. Run the Server

Start the FastFN development server:

```bash
fastfn dev .
```

Open your browser and navigate to `http://127.0.0.1:8080/tasks`. You should see your list of tasks returned as JSON!

## Next Steps

In the next part, we'll learn how to fetch a specific task using dynamic routing (`/tasks/1`) and how to add new tasks by reading the request body.
```
