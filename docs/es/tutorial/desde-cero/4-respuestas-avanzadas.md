# Parte 4: Respuestas Avanzadas

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.

## Vista rápida

- Complejidad: Intermedio
- Tiempo típico: 30-40 minutos
- Resultado: contratos estables de respuesta con comportamiento multi-status explícito

## 1. Garantía de forma de respuesta

Usa envelope explícito:

```json
{
  "status": 200,
  "headers": {"Content-Type": "application/json; charset=utf-8"},
  "body": {"data": {}, "error": null, "meta": {}}
}
```

## 2. Modelos alternativos según estado

Elige un runtime para `functions/tasks/[id]/get.*`:

=== "Node.js"
    ```js
    exports.handler = async (_event, { id }) => {
      if (id === "404") return { status: 404, body: { error: { code: "TASK_NOT_FOUND", message: "task not found" } } };
      return { status: 200, body: { data: { id, title: "Escribir docs" }, error: null } };
    };
    ```

=== "Python"
    ```python
    def handler(_event, params):
        task_id = params.get("id")
        if task_id == "404":
            return {"status": 404, "body": {"error": {"code": "TASK_NOT_FOUND", "message": "task not found"}}}
        return {"status": 200, "body": {"data": {"id": task_id, "title": "Escribir docs"}, "error": None}}
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn handler(_event: Value, params: Value) -> Value {
        let id = params.get("id").and_then(|v| v.as_str()).unwrap_or("");
        if id == "404" {
            return json!({"status": 404, "body": {"error": {"code": "TASK_NOT_FOUND", "message": "task not found"}}});
        }
        json!({"status": 200, "body": {"data": {"id": id, "title": "Escribir docs"}, "error": null}})
    }
    ```

=== "PHP"
    ```php
    <?php
    function handler(array $event, array $params): array {
        $id = $params['id'] ?? '';
        if ($id === '404') {
            return ['status' => 404, 'body' => ['error' => ['code' => 'TASK_NOT_FOUND', 'message' => 'task not found']]];
        }
        return ['status' => 200, 'body' => ['data' => ['id' => $id, 'title' => 'Escribir docs'], 'error' => null]];
    }
    ```

Curls por runtime:

=== "Node.js"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/1'
    curl -sS 'http://127.0.0.1:8080/tasks/404'
    ```

=== "Python"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/1'
    curl -sS 'http://127.0.0.1:8080/tasks/404'
    ```

=== "Rust"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/1'
    curl -sS 'http://127.0.0.1:8080/tasks/404'
    ```

=== "PHP"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/1'
    curl -sS 'http://127.0.0.1:8080/tasks/404'
    ```

## 3. Estrategia de códigos de estado

| Estado | Cuándo usar | Contrato |
|---|---|---|
| `200` | lectura/actualización ok | `data` presente, `error: null` |
| `201` | recurso creado | `data` con id |
| `202` | trabajo async aceptado | `job_id` + URL de consulta |
| `400` | request malformado | error accionable |
| `404` | recurso/ruta inexistente | error + mensaje |
| `409` | conflicto | detalle de conflicto |
| `422` | validación semántica | mensaje por campo |

## 4. Códigos adicionales en un endpoint

Elige runtime para `functions/tasks/post.*`:

=== "Node.js"
    ```js
    exports.handler = async (event) => {
      const body = JSON.parse(event.body || "{}");
      if (!body.title) return { status: 422, body: { error: "title requerido" } };
      if (body.async === true) return { status: 202, body: { job_id: "job-123", status_url: "/_fn/jobs/job-123" } };
      return { status: 201, body: { id: 99, title: body.title } };
    };
    ```

=== "Python"
    ```python
    import json

    def handler(event):
        body = json.loads(event.get("body") or "{}")
        if not body.get("title"):
            return {"status": 422, "body": {"error": "title requerido"}}
        if body.get("async") is True:
            return {"status": 202, "body": {"job_id": "job-123", "status_url": "/_fn/jobs/job-123"}}
        return {"status": 201, "body": {"id": 99, "title": body["title"]}}
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let parsed: Value = serde_json::from_str(event.get("body").and_then(|x| x.as_str()).unwrap_or("{}")).unwrap_or(json!({}));
        if parsed.get("title").and_then(|x| x.as_str()).unwrap_or("").is_empty() {
            return json!({"status": 422, "body": {"error": "title requerido"}});
        }
        if parsed.get("async").and_then(|x| x.as_bool()).unwrap_or(false) {
            return json!({"status": 202, "body": {"job_id": "job-123", "status_url": "/_fn/jobs/job-123"}});
        }
        json!({"status": 201, "body": {"id": 99, "title": parsed["title"]}})
    }
    ```

=== "PHP"
    ```php
    <?php
    function handler(array $event): array {
        $body = json_decode($event['body'] ?? '{}', true) ?: [];
        if (empty($body['title'])) return ['status' => 422, 'body' => ['error' => 'title requerido']];
        if (($body['async'] ?? false) === true) {
            return ['status' => 202, 'body' => ['job_id' => 'job-123', 'status_url' => '/_fn/jobs/job-123']];
        }
        return ['status' => 201, 'body' => ['id' => 99, 'title' => $body['title']]];
    }
    ```

Curls por runtime:

=== "Node.js"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Docs","async":true}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Docs"}'
    ```

=== "Python"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Docs","async":true}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Docs"}'
    ```

=== "Rust"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Docs","async":true}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Docs"}'
    ```

=== "PHP"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Docs","async":true}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Docs"}'
    ```

## 5. Envelope de errores

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "title requerido",
    "hint": "enviar title como string no vacío"
  }
}
```

## Enlaces relacionados

- [Validación y schemas](../validacion-y-schemas.md)
- [Referencia API HTTP](../../referencia/api-http.md)
- [Desplegar a producción](../../como-hacer/desplegar-a-produccion.md)
