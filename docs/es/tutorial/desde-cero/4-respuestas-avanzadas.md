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

## 6. Actualizaciones de body (PUT vs PATCH)

Usa `PUT` para reemplazo completo y `PATCH` para merge parcial.

=== "Node.js"
    ```js
    exports.handler = async (event, params) => {
      const id = params.id;
      const body = JSON.parse(event.body || "{}");
      if (event.method === "PUT") {
        return { status: 200, body: { id, title: body.title || "", done: !!body.done } };
      }
      if (event.method === "PATCH") {
        const current = { id, title: "Titulo actual", done: false };
        return { status: 200, body: { ...current, ...body, id } };
      }
      return { status: 405, body: { error: "method not allowed" } };
    };
    ```

=== "Python"
    ```python
    import json

    def handler(event, params):
        item_id = params.get("id")
        body = json.loads(event.get("body") or "{}")
        method = (event.get("method") or "").upper()
        if method == "PUT":
            return {"status": 200, "body": {"id": item_id, "title": body.get("title", ""), "done": bool(body.get("done"))}}
        if method == "PATCH":
            current = {"id": item_id, "title": "Titulo actual", "done": False}
            current.update(body)
            current["id"] = item_id
            return {"status": 200, "body": current}
        return {"status": 405, "body": {"error": "method not allowed"}}
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value, params: Value) -> Value {
        let id = params.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let method = event.get("method").and_then(|v| v.as_str()).unwrap_or("");
        let body: Value = serde_json::from_str(event.get("body").and_then(|v| v.as_str()).unwrap_or("{}")).unwrap_or(json!({}));
        if method.eq_ignore_ascii_case("PUT") {
            return json!({"status": 200, "body": {"id": id, "title": body.get("title").and_then(|v| v.as_str()).unwrap_or(""), "done": body.get("done").and_then(|v| v.as_bool()).unwrap_or(false)}});
        }
        if method.eq_ignore_ascii_case("PATCH") {
            let mut current = json!({"id": id, "title": "Titulo actual", "done": false});
            if let Some(obj) = body.as_object() {
                for (k, v) in obj {
                    current[k] = v.clone();
                }
            }
            current["id"] = json!(id);
            return json!({"status": 200, "body": current});
        }
        json!({"status": 405, "body": {"error": "method not allowed"}})
    }
    ```

=== "PHP"
    ```php
    <?php
    function handler(array $event, array $params): array {
        $id = $params['id'] ?? '';
        $body = json_decode($event['body'] ?? '{}', true) ?: [];
        $method = strtoupper($event['method'] ?? '');
        if ($method === 'PUT') {
            return ['status' => 200, 'body' => ['id' => $id, 'title' => $body['title'] ?? '', 'done' => (bool)($body['done'] ?? false)]];
        }
        if ($method === 'PATCH') {
            $current = ['id' => $id, 'title' => 'Titulo actual', 'done' => false];
            $merged = array_merge($current, $body);
            $merged['id'] = $id;
            return ['status' => 200, 'body' => $merged];
        }
        return ['status' => 405, 'body' => ['error' => 'method not allowed']];
    }
    ```

```bash
curl -sS -X PUT 'http://127.0.0.1:8080/tasks/9' -H 'Content-Type: application/json' -d '{"title":"Reemplazo","done":true}'
curl -sS -X PATCH 'http://127.0.0.1:8080/tasks/9' -H 'Content-Type: application/json' -d '{"done":true}'
```

## 7. Responder directamente

Puedes devolver una respuesta armada sin helpers:

```json
{
  "status": 204,
  "headers": {},
  "body": ""
}
```

Útil para deletes idempotentes sin contenido.

## 8. Respuesta custom y tipo de contenido

Usa `text/html`, `text/csv` u otros tipos cuando no sea JSON:

```bash
curl -i 'http://127.0.0.1:8080/report/html'
curl -i 'http://127.0.0.1:8080/report/csv'
```

Headers esperados:

- `Content-Type: text/html; charset=utf-8`
- `Content-Type: text/csv; charset=utf-8`
- `Cache-Control` cuando aplique cache

## 9. Respuestas adicionales en OpenAPI

Si una función retorna varios estados (`200`, `404`, `409`), documenta y valida en OpenAPI:

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | jq '.paths["/tasks/{id}"].get.responses'
```

## 10. Cookies de respuesta

Set/Clear explícito:

```bash
curl -i 'http://127.0.0.1:8080/session/start'
curl -i 'http://127.0.0.1:8080/session/end'
```

Flags recomendadas en producción:

- `HttpOnly`
- `Secure`
- `SameSite=Lax` (o `Strict` en backoffice sensible)

## 11. Headers de respuesta

Headers operativos útiles:

- `X-Request-Id`
- `X-Trace-Source`
- `Cache-Control`
- `ETag`

```bash
curl -i 'http://127.0.0.1:8080/tasks/1'
```

## 12. Cambio dinámico de status

El estado puede variar según resultado real:

- `200` si `PUT /tasks/:id` actualizó un registro existente
- `201` si `PUT /tasks/:id` creó un registro nuevo
- `202` si encoló async

```bash
curl -i -X PUT 'http://127.0.0.1:8080/tasks/1' -H 'Content-Type: application/json' -d '{"title":"a"}'
```

## Validación

- `GET /tasks/:id` devuelve `200` y `404` con envelope consistente.
- `POST /tasks` devuelve `201`, `202` o `422` según payload.
- `PUT`/`PATCH` tienen semántica clara y estable.
- `openapi.json` refleja las respuestas alternativas.

## Troubleshooting

- Si hay mismatch de status/body, valida que el handler siempre devuelva body-objeto o JSON string de forma consistente.
- Si cookies no aparecen en navegador, revisa `Secure` + `SameSite` y si estás en HTTPS/localhost.
- Si OpenAPI no refleja respuestas alternativas, re-ejecuta discovery y verifica metadata de rutas.

## Enlaces relacionados

- [Validación y schemas](../validacion-y-schemas.md)
- [Referencia API HTTP](../../referencia/api-http.md)
- [Desplegar a producción](../../como-hacer/desplegar-a-produccion.md)
