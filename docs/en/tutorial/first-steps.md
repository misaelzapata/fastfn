# Quick Start

> Verified status as of **March 13, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

## Quick View

- Complexity: Beginner
- Typical time: 10-15 minutes
- Scope: create one function, run locally, call it, and confirm OpenAPI visibility
- Expected outcome: a working `GET /hello` endpoint and docs at `/docs`

## Prerequisites

- FastFN CLI installed and available in `PATH`
- One execution mode ready:
  - Portable mode: Docker daemon running
  - Native mode: `openresty` and runtime binaries available

## 1. Create your first function (neutral path)

```bash
mkdir -p functions/hello
```

Choose one runtime implementation inside `functions/hello/`:

=== "Node.js"
    File: `functions/hello/handler.js`

    ```js
    exports.handler = async (event) => ({
      status: 200,
      body: { hello: event.query?.name || "World", runtime: "node" }
    });
    ```

=== "Python"
    File: `functions/hello/handler.py`

    ```python
    def handler(event):
        name = (event.get("query") or {}).get("name", "World")
        return {"status": 200, "body": {"hello": name, "runtime": "python"}}
    ```

=== "Rust"
    File: `functions/hello/handler.rs`

    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let name = event
            .get("query")
            .and_then(|q| q.get("name"))
            .and_then(|n| n.as_str())
            .unwrap_or("World");

        json!({
            "status": 200,
            "body": {
                "hello": name,
                "runtime": "rust"
            }
        })
    }
    ```

=== "PHP"
    File: `functions/hello/handler.php`

    ```php
    <?php

    function handler(array $event): array {
        $query = $event['query'] ?? [];
        $name = $query['name'] ?? 'World';

        return [
            'status' => 200,
            'body' => [
                'hello' => $name,
                'runtime' => 'php',
            ],
        ];
    }
    ```

## 2. Start the local server

```bash
fastfn dev functions
```

## 3. Validate with curl (per runtime)

=== "Node.js"
    ```bash
    curl -sS 'http://127.0.0.1:8080/hello?name=World'
    ```

=== "Python"
    ```bash
    curl -sS 'http://127.0.0.1:8080/hello?name=World'
    ```

=== "Rust"
    ```bash
    curl -sS 'http://127.0.0.1:8080/hello?name=World'
    ```

=== "PHP"
    ```bash
    curl -sS 'http://127.0.0.1:8080/hello?name=World'
    ```

Expected response shape:

```json
{
  "hello": "World",
  "runtime": "<selected-runtime>"
}
```

## 4. Verify generated API docs

- Swagger UI: [http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs)
- OpenAPI JSON: [http://127.0.0.1:8080/openapi.json](http://127.0.0.1:8080/openapi.json)

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | jq '.paths | has("/hello")'
```

Expected output:

```text
true
```

![Swagger UI showing FastFN routes](../../assets/screenshots/swagger-ui.png)

## Validation checklist

- `GET /hello` returns HTTP `200`
- `/openapi.json` contains `/hello`
- `/docs` loads and shows the route

## Troubleshooting

- Runtime down or `503`: check `/_fn/health` and missing host dependencies
- Route missing: confirm folder layout and rerun discovery (`/_fn/reload`)
- `/docs` empty: verify docs/OpenAPI toggles were not disabled

## Next links

- [Part 1: Setup and first route](./from-zero/1-setup-and-first-route.md)
- [Routing and parameters](./routing.md)
- [HTTP API reference](../reference/http-api.md)
