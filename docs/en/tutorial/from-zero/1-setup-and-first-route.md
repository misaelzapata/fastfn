# Part 1: Setup and Your First Route

> Verified status as of **March 13, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

## Quick View

- Complexity: Beginner
- Typical time: 15-20 minutes
- Outcome: clean project with one `GET /tasks` endpoint and OpenAPI entry

## 1. Clean-room setup

```bash
mkdir -p task-manager-api/functions/tasks
cd task-manager-api
```

## 2. Implement the first route (choose one runtime)

=== "Node.js"
    File: `functions/tasks/handler.js`

    ```js
    exports.handler = async () => ({
      status: 200,
      body: [
        { id: 1, title: "Learn FastFN", completed: false },
        { id: 2, title: "Ship first endpoint", completed: false }
      ]
    });
    ```

=== "Python"
    File: `functions/tasks/main.py`

    ```python
    def handler(_event):
        return {
            "status": 200,
            "body": [
                {"id": 1, "title": "Learn FastFN", "completed": False},
                {"id": 2, "title": "Ship first endpoint", "completed": False},
            ],
        }
    ```

=== "Rust"
    File: `functions/tasks/handler.rs`

    ```rust
    use serde_json::json;

    pub fn handler(_event: serde_json::Value) -> serde_json::Value {
        json!({
            "status": 200,
            "body": [
                { "id": 1, "title": "Learn FastFN", "completed": false },
                { "id": 2, "title": "Ship first endpoint", "completed": false }
            ]
        })
    }
    ```

=== "PHP"
    File: `functions/tasks/handler.php`

    ```php
    <?php

    function handler(array $event): array {
        return [
            'status' => 200,
            'body' => [
                ['id' => 1, 'title' => 'Learn FastFN', 'completed' => false],
                ['id' => 2, 'title' => 'Ship first endpoint', 'completed' => false],
            ],
        ];
    }
    ```

## 3. Run locally

```bash
fastfn dev functions
```

## 4. Validate first request (per runtime)

=== "Node.js"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks'
    ```

=== "Python"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks'
    ```

=== "Rust"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks'
    ```

=== "PHP"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks'
    ```

Expected body shape:

```json
[
  { "id": 1, "title": "...", "completed": false },
  { "id": 2, "title": "...", "completed": false }
]
```

## 5. Validate OpenAPI visibility

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | jq '.paths | has("/tasks")'
```

Expected output:

```text
true
```

![Browser showing JSON response at /tasks](../../../assets/screenshots/browser-json-tasks.png)

## Troubleshooting

- `503`: check `/_fn/health` and runtime dependencies
- route not found: confirm handler path under `functions/tasks/`
- OpenAPI missing path: run `curl -X POST http://127.0.0.1:8080/_fn/reload`

## Next step

[Go to Part 2: Routing and Data](./2-routing-and-data.md)

## Related links

- [Request validation and schemas](../request-validation-and-schemas.md)
- [HTTP API reference](../../reference/http-api.md)
- [Run and test](../../how-to/run-and-test.md)
