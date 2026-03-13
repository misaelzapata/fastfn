# Part 4: Advanced Responses

> Verified status as of **March 13, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

## Quick View

- Complexity: Intermediate
- Typical time: 30-40 minutes
- Outcome: stable response contracts with explicit multi-status behavior

## 1. Response shape guarantees

Use explicit envelope style in all branches:

```json
{
  "status": 200,
  "headers": {"Content-Type": "application/json; charset=utf-8"},
  "body": {"data": {}, "error": null, "meta": {}}
}
```

## 2. Alternate response models by state

Choose one runtime implementation for `functions/tasks/[id]/get.*`:

=== "Node.js"
    ```js
    exports.handler = async (_event, { id }) => {
      if (id === "404") return { status: 404, body: { error: { code: "TASK_NOT_FOUND", message: "task not found" } } };
      return { status: 200, body: { data: { id, title: "Write docs" }, error: null } };
    };
    ```

=== "Python"
    ```python
    def handler(_event, params):
        task_id = params.get("id")
        if task_id == "404":
            return {"status": 404, "body": {"error": {"code": "TASK_NOT_FOUND", "message": "task not found"}}}
        return {"status": 200, "body": {"data": {"id": task_id, "title": "Write docs"}, "error": None}}
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn handler(_event: Value, params: Value) -> Value {
        let id = params.get("id").and_then(|v| v.as_str()).unwrap_or("");
        if id == "404" {
            return json!({"status": 404, "body": {"error": {"code": "TASK_NOT_FOUND", "message": "task not found"}}});
        }
        json!({"status": 200, "body": {"data": {"id": id, "title": "Write docs"}, "error": null}})
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
        return ['status' => 200, 'body' => ['data' => ['id' => $id, 'title' => 'Write docs'], 'error' => null]];
    }
    ```

Runtime curls:

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

## 3. Status code strategy

| Status | When to use | Body contract |
|---|---|---|
| `200` | read/update success | `data` present, `error: null` |
| `201` | resource created | `data` with created id |
| `202` | accepted async work | `job_id` + polling URL |
| `400` | malformed request | error with client-fix message |
| `404` | missing route/resource | error code + message |
| `409` | conflict | deterministic conflict details |
| `422` | semantic validation fail | field-level validation message |

## 4. Additional status codes in one endpoint

Choose one runtime for `functions/tasks/post.*`:

=== "Node.js"
    ```js
    exports.handler = async (event) => {
      const body = JSON.parse(event.body || "{}");
      if (!body.title) return { status: 422, body: { error: "title required" } };
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
            return {"status": 422, "body": {"error": "title required"}}
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
            return json!({"status": 422, "body": {"error": "title required"}});
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
        if (empty($body['title'])) return ['status' => 422, 'body' => ['error' => 'title required']];
        if (($body['async'] ?? false) === true) {
            return ['status' => 202, 'body' => ['job_id' => 'job-123', 'status_url' => '/_fn/jobs/job-123']];
        }
        return ['status' => 201, 'body' => ['id' => 99, 'title' => $body['title']]];
    }
    ```

Curls by runtime:

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

## 5. Error envelope

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "title required",
    "hint": "send title as non-empty string"
  }
}
```

## 6. Body updates (PUT vs PATCH)

Use `PUT` to replace the resource and `PATCH` to merge partial fields.

=== "Node.js"
    ```js
    exports.handler = async (event, params) => {
      const id = params.id;
      const body = JSON.parse(event.body || "{}");
      if (event.method === "PUT") {
        return { status: 200, body: { id, title: body.title || "", done: !!body.done } };
      }
      if (event.method === "PATCH") {
        const current = { id, title: "Existing title", done: false };
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
            current = {"id": item_id, "title": "Existing title", "done": False}
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
            let mut current = json!({"id": id, "title": "Existing title", "done": false});
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
            $current = ['id' => $id, 'title' => 'Existing title', 'done' => false];
            $merged = array_merge($current, $body);
            $merged['id'] = $id;
            return ['status' => 200, 'body' => $merged];
        }
        return ['status' => 405, 'body' => ['error' => 'method not allowed']];
    }
    ```

```bash
curl -sS -X PUT 'http://127.0.0.1:8080/tasks/9' -H 'Content-Type: application/json' -d '{"title":"Replaced","done":true}'
curl -sS -X PATCH 'http://127.0.0.1:8080/tasks/9' -H 'Content-Type: application/json' -d '{"done":true}'
```

## 7. Return a response directly

Return an already-built response to control body and status without envelope helpers:

```json
{
  "status": 204,
  "headers": {},
  "body": ""
}
```

Useful for no-content deletes and idempotent operations.

## 8. Custom response payload and content type

Use `text/html`, `text/csv`, or binary-safe headers when needed:

```bash
curl -i 'http://127.0.0.1:8080/report/html'
curl -i 'http://127.0.0.1:8080/report/csv'
```

Expected headers:

- `Content-Type: text/html; charset=utf-8` for HTML
- `Content-Type: text/csv; charset=utf-8` for CSV
- `Cache-Control` when payload can be cached

## 9. Additional responses in OpenAPI

When a function can return different statuses (for example `200`, `404`, `409`), keep examples aligned with route behavior and verify in OpenAPI:

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | jq '.paths["/tasks/{id}"].get.responses'
```

## 10. Response cookies

Set and clear cookies explicitly:

```bash
curl -i 'http://127.0.0.1:8080/session/start'
curl -i 'http://127.0.0.1:8080/session/end'
```

Recommended cookie flags in production:

- `HttpOnly`
- `Secure`
- `SameSite=Lax` (or `Strict` for sensitive backoffices)

## 11. Response headers

Add operational headers for traceability and caching:

- `X-Request-Id`
- `X-Trace-Source`
- `Cache-Control`
- `ETag`

```bash
curl -i 'http://127.0.0.1:8080/tasks/1'
```

## 12. Dynamic status changes

Return status based on runtime state, not only route:

- `200` when upsert updated an existing record
- `201` when upsert created a new record
- `202` when operation queued async

```bash
curl -i -X POST 'http://127.0.0.1:8080/tasks/upsert' -H 'Content-Type: application/json' -d '{"id":"1","title":"a"}'
```

## Validation

- `GET /tasks/:id` returns `200` and `404` with stable envelope.
- `POST /tasks` returns `201`, `202`, or `422` based on payload.
- `PUT`/`PATCH` update behavior is explicit and predictable.
- `openapi.json` reflects documented alternate responses.

## Troubleshooting

- If status/body mismatch appears, confirm handler always returns either object body or JSON string consistently.
- If cookies are not visible in browser, check `Secure` + `SameSite` and HTTPS/localhost constraints.
- If OpenAPI does not show alternate responses, re-run discovery and verify route metadata generation.

## Related links

- [Request validation and schemas](../request-validation-and-schemas.md)
- [HTTP API reference](../../reference/http-api.md)
- [Deploy to production](../../how-to/deploy-to-production.md)
