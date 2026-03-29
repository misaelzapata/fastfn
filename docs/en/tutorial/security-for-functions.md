# Security for Functions

> Verified status as of **March 13, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

## Quick View

- Complexity: Intermediate
- Typical time: 20-30 minutes
- Outcome: a clear security baseline with identity resolution and least-privilege defaults

## Threat Model in FastFN

Default trust boundaries:

1. Public request boundary (`/<route>`)
2. Platform admin boundary (`/_fn/*`, `/console`)
3. Runtime process boundary (per language daemon/worker)

Recommended defaults:

- Keep `FN_CONSOLE_LOCAL_ONLY=1`
- Keep `FN_CONSOLE_WRITE_ENABLED=0` in shared environments
- Require `FN_ADMIN_TOKEN` for remote admin actions
- Store business secrets in function env (`event.env`)

## Identity Resolution Pattern

Resolve identity once and pass a normalized user object to business logic.

=== "Node.js"
    ```js
    exports.handler = async (event) => {
      const auth = event.headers?.authorization || "";
      const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
      if (!token) return { status: 401, body: { error: "missing bearer token" } };
      const user = { id: "u-123", roles: ["reader"] };
      return { status: 200, body: { user } };
    };
    ```

=== "Python"
    ```python
    def handler(event):
        auth = (event.get("headers") or {}).get("authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        if not token:
            return {"status": 401, "body": {"error": "missing bearer token"}}
        user = {"id": "u-123", "roles": ["reader"]}
        return {"status": 200, "body": {"user": user}}
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let auth = event["headers"]["authorization"].as_str().unwrap_or("");
        let token = auth.strip_prefix("Bearer ").unwrap_or("");
        if token.is_empty() {
            return json!({"status": 401, "body": {"error": "missing bearer token"}});
        }
        json!({"status": 200, "body": {"user": {"id": "u-123", "roles": ["reader"]}}})
    }
    ```

=== "PHP"
    ```php
    <?php
    function handler(array $event): array {
        $headers = $event['headers'] ?? [];
        $auth = $headers['authorization'] ?? '';
        $token = str_starts_with($auth, 'Bearer ') ? substr($auth, 7) : '';
        if ($token === '') return ['status' => 401, 'body' => ['error' => 'missing bearer token']];
        return ['status' => 200, 'body' => ['user' => ['id' => 'u-123', 'roles' => ['reader']]]];
    }
    ```

=== "Go"
    ```go
    package main

    import "strings"

    func Handler(event map[string]any) map[string]any {
      headers, _ := event["headers"].(map[string]any)
      auth, _ := headers["authorization"].(string)
      token := strings.TrimPrefix(auth, "Bearer ")
      if token == "" {
        return map[string]any{"status": 401, "body": map[string]any{"error": "missing bearer token"}}
      }
      return map[string]any{"status": 200, "body": map[string]any{"user": map[string]any{"id": "u-123", "roles": []string{"reader"}}}}
    }
    ```

=== "Lua"
    ```lua
    local cjson = require("cjson.safe")

    function handler(event)
      local headers = event.headers or {}
      local auth = headers.authorization or headers.Authorization or ""
      local token = auth:match("^Bearer%s+(.+)") or ""
      if token == "" then
        return { status = 401, body = cjson.encode({ error = "missing bearer token" }) }
      end
      return { status = 200, body = cjson.encode({ user = { id = "u-123", roles = { "reader" } } }) }
    end
    ```

## Validation

```bash
curl -i 'http://127.0.0.1:8080/profile/me'
curl -i 'http://127.0.0.1:8080/profile/me' -H 'authorization: Bearer demo-token'
```

Note: snippets are auth-flow patterns only (token extraction + gate). Signature/expiration verification must be implemented with your token library/provider.

Expected:

- no token: `401`
- token present: `200`

## Troubleshooting

- If all requests return `401`, confirm the header key seen by your runtime (`authorization` vs `Authorization`).
- If admin endpoints are exposed remotely, verify `FN_CONSOLE_LOCAL_ONLY` and firewall rules.
- If secrets are missing, check function env registration and runtime reload.

## Related links

- [Authentication and access control](../how-to/authentication.md)
- [Security confidence](../how-to/security-confidence.md)
- [Runtime contract](../reference/runtime-contract.md)
