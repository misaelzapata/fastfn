# Shared Logic Patterns (Dependency Equivalents)

> Verified status as of **March 13, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

## Quick View

- Complexity: Intermediate
- Typical time: 15-20 minutes
- Outcome: reusable request logic without framework-level dependency injection

FastFN does not use decorator-based dependency injection. The equivalent is explicit composition with helpers/modules shared across function folders.

## 1. First pattern: pure helper + route handler

Recommended neutral structure:

```text
functions/
  _shared/
    auth.*
    validate.*
  profile/
    get.*
```

In each runtime, import shared logic and run it before business code.

=== "Node.js"
    ```js
    // functions/_shared/auth.js
    exports.requireApiKey = (event) => {
      const key = event.headers?.["x-api-key"];
      if (key !== event.env?.API_KEY) return { ok: false, status: 401, error: "unauthorized" };
      return { ok: true };
    };
    ```

=== "Python"
    ```python
    # functions/_shared/auth.py
    def require_api_key(event):
        key = (event.get("headers") or {}).get("x-api-key")
        if key != (event.get("env") or {}).get("API_KEY"):
            return {"ok": False, "status": 401, "error": "unauthorized"}
        return {"ok": True}
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn require_api_key(event: &Value) -> Value {
        let key = event["headers"]["x-api-key"].as_str().unwrap_or("");
        let expected = event["env"]["API_KEY"].as_str().unwrap_or("");
        if key != expected {
            return json!({"ok": false, "status": 401, "error": "unauthorized"});
        }
        json!({"ok": true})
    }
    ```

=== "PHP"
    ```php
    <?php
    function require_api_key(array $event): array {
        $headers = $event['headers'] ?? [];
        $env = $event['env'] ?? [];
        if (($headers['x-api-key'] ?? null) !== ($env['API_KEY'] ?? null)) {
            return ['ok' => false, 'status' => 401, 'error' => 'unauthorized'];
        }
        return ['ok' => true];
    }
    ```

## 2. Class/module style reuse

If your team prefers class-based encapsulation, keep it local and explicit:

- Construct a service with config from `event.env`.
- Call service methods from the handler.
- Keep side effects at the edge.

This maps FastAPI "classes as dependencies" to plain language-native modules.

## 3. Composable helper chains (sub-dependencies equivalent)

Compose helpers in sequence:

1. Parse identity
2. Authorize role/scope
3. Validate payload
4. Execute business logic

Short runtime-agnostic flow:

```text
request -> parse_user -> require_scope -> validate_input -> handler_logic -> response
```

## Validation

- Shared helpers are imported and used by at least two functions.
- Unauthorized request returns `401` from helper guard path.
- Validation helper returns deterministic `422` errors.

## Troubleshooting

- If helpers cannot be imported, confirm relative paths from function file.
- If behavior diverges between runtimes, keep helper output envelope (`ok`, `status`, `error`) consistent.
- If tests are flaky, isolate helper functions from network and clock dependencies.

## Related links

- [Reuse auth and validation](../how-to/reuse-auth-and-validation.md)
- [Authentication](../how-to/authentication.md)
- [Run and test](../how-to/run-and-test.md)
