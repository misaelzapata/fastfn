# Part 2: Routing and Data

> Verified status as of **March 13, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

## Quick View

- Complexity: Intermediate
- Typical time: 25-35 minutes
- Outcome: dynamic path/query/body handling with explicit validation errors

## 1. Path params and catch-all

Create dynamic route files under `functions/`.

=== "Node.js"
    File: `functions/tasks/[id].js`

    ```js
    exports.handler = async (_event, { id }) => ({ status: 200, body: { task_id: id } });
    ```

    File: `functions/reports/[...slug].js`

    ```js
    exports.handler = async (_event, { slug }) => ({ status: 200, body: { path: slug } });
    ```

=== "Python"
    File: `functions/tasks/[id].py`

    ```python
    def handler(_event, params):
        return {"status": 200, "body": {"task_id": params.get("id")}}
    ```

    File: `functions/reports/[...slug].py`

    ```python
    def handler(_event, params):
        return {"status": 200, "body": {"path": params.get("slug")}}
    ```

=== "Rust"
    File: `functions/tasks/[id].rs`

    ```rust
    use serde_json::{json, Value};

    pub fn handler(_event: Value, params: Value) -> Value {
        json!({"status": 200, "body": {"task_id": params.get("id").and_then(|v| v.as_str()).unwrap_or("")}})
    }
    ```

=== "PHP"
    File: `functions/tasks/[id].php`

    ```php
    <?php
    function handler(array $event, array $params): array {
        return ['status' => 200, 'body' => ['task_id' => $params['id'] ?? '']];
    }
    ```

Validation curls (same for all runtimes):

```bash
curl -sS 'http://127.0.0.1:8080/tasks/42'
curl -sS 'http://127.0.0.1:8080/reports/2026/03/daily'
```

## 2. Query params with defaults

=== "Node.js"
    File: `functions/tasks/search.js`

    ```js
    exports.handler = async (event) => {
      const q = event.query?.q;
      const page = Number(event.query?.page || "1");
      if (!q) return { status: 400, body: { error: "q is required" } };
      return { status: 200, body: { q, page } };
    };
    ```

=== "Python"
    File: `functions/tasks/search.py`

    ```python
    def handler(event):
        query = event.get("query") or {}
        q = query.get("q")
        page = int(query.get("page", "1"))
        if not q:
            return {"status": 400, "body": {"error": "q is required"}}
        return {"status": 200, "body": {"q": q, "page": page}}
    ```

=== "Rust"
    File: `functions/tasks/search.rs`

    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let q = event.get("query").and_then(|x| x.get("q")).and_then(|x| x.as_str());
        if q.is_none() {
            return json!({"status": 400, "body": {"error": "q is required"}});
        }
        json!({"status": 200, "body": {"q": q.unwrap(), "page": 1}})
    }
    ```

=== "PHP"
    File: `functions/tasks/search.php`

    ```php
    <?php
    function handler(array $event): array {
        $query = $event['query'] ?? [];
        $q = $query['q'] ?? null;
        $page = intval($query['page'] ?? '1');
        if (!$q) return ['status' => 400, 'body' => ['error' => 'q is required']];
        return ['status' => 200, 'body' => ['q' => $q, 'page' => $page]];
    }
    ```

Runtime curls:

=== "Node.js"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/search?page=2'
    curl -sS 'http://127.0.0.1:8080/tasks/search?q=fastfn'
    ```

=== "Python"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/search?page=2'
    curl -sS 'http://127.0.0.1:8080/tasks/search?q=fastfn'
    ```

=== "Rust"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/search?page=2'
    curl -sS 'http://127.0.0.1:8080/tasks/search?q=fastfn'
    ```

=== "PHP"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/search?page=2'
    curl -sS 'http://127.0.0.1:8080/tasks/search?q=fastfn'
    ```

## 3. JSON body parsing and validation

=== "Node.js"
    File: `functions/tasks/post.js`

    ```js
    exports.handler = async (event) => {
      let payload;
      try { payload = JSON.parse(event.body || "{}"); }
      catch { return { status: 400, body: { error: "invalid JSON body" } }; }
      if (!payload.title || typeof payload.title !== "string") {
        return { status: 422, body: { error: "title must be a non-empty string" } };
      }
      return { status: 201, body: { id: 3, title: payload.title } };
    };
    ```

=== "Python"
    File: `functions/tasks/post.py`

    ```python
    import json

    def handler(event):
        try:
            payload = json.loads(event.get("body") or "{}")
        except Exception:
            return {"status": 400, "body": {"error": "invalid JSON body"}}
        if not payload.get("title"):
            return {"status": 422, "body": {"error": "title must be a non-empty string"}}
        return {"status": 201, "body": {"id": 3, "title": payload["title"]}}
    ```

=== "Rust"
    File: `functions/tasks/post.rs`

    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let payload = event.get("body").and_then(|b| b.as_str()).unwrap_or("{}");
        let parsed: Value = serde_json::from_str(payload).unwrap_or(json!({"_error": "invalid"}));
        if parsed.get("_error").is_some() {
            return json!({"status": 400, "body": {"error": "invalid JSON body"}});
        }
        if parsed.get("title").and_then(|x| x.as_str()).unwrap_or("").is_empty() {
            return json!({"status": 422, "body": {"error": "title must be a non-empty string"}});
        }
        json!({"status": 201, "body": {"id": 3, "title": parsed["title"]}})
    }
    ```

=== "PHP"
    File: `functions/tasks/post.php`

    ```php
    <?php
    function handler(array $event): array {
        $raw = $event['body'] ?? '{}';
        $payload = json_decode($raw, true);
        if (!is_array($payload)) return ['status' => 400, 'body' => ['error' => 'invalid JSON body']];
        if (empty($payload['title']) || !is_string($payload['title'])) {
            return ['status' => 422, 'body' => ['error' => 'title must be a non-empty string']];
        }
        return ['status' => 201, 'body' => ['id' => 3, 'title' => $payload['title']]];
    }
    ```

Runtime curls:

=== "Node.js"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{bad'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Write docs"}'
    ```

=== "Python"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{bad'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Write docs"}'
    ```

=== "Rust"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{bad'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Write docs"}'
    ```

=== "PHP"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{bad'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Write docs"}'
    ```

## Flow diagram

```mermaid
flowchart LR
  A["Route path"] --> B["Path params"]
  B --> C["Query parsing"]
  C --> D["Body parsing"]
  D --> E["Validation result"]
  E --> F["HTTP response"]
```

## Troubleshooting

- wrong handler not invoked: verify filename prefixes and folder names
- params missing: verify `[id]` or `[...slug]` pattern
- body parse errors: confirm `Content-Type: application/json` and valid JSON syntax

## Next step

[Go to Part 3: Configuration and Secrets](./3-config-and-secrets.md)

## Related links

- [Request validation and schemas](../request-validation-and-schemas.md)
- [Request metadata and files](../request-metadata-and-files.md)
- [HTTP API reference](../../reference/http-api.md)
