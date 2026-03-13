# Reuse Auth and Validation Across Functions

> Verified status as of **March 13, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

## Quick View

- Complexity: Intermediate
- Typical time: 20-25 minutes
- Outcome: one reusable auth/validation chain used by multiple routes

## Objective

Implement a reusable guard flow equivalent to "advanced dependencies":

1. Authenticate request
2. Authorize permissions/scopes
3. Validate input shape
4. Run route logic

## Prerequisites

- A FastFN project with `functions/` root
- `API_KEY` or token secret configured in function env
- `curl` available

## 1. Create shared helpers

Use a neutral shared folder:

```text
functions/
  _shared/
    auth.*
    validate.*
  reports/
    [id]/
      get.*
```

## 2. Runtime examples (tabs)

=== "Node.js"
    ```js
    // functions/reports/[id]/get.js
    const { requireApiKey, requireScope } = require("../../_shared/auth");
    const { requireId } = require("../../_shared/validate");

    exports.handler = async (event, params) => {
      const auth = requireApiKey(event);
      if (!auth.ok) return { status: auth.status, body: { error: auth.error } };
      const scope = requireScope(event, "reports:read");
      if (!scope.ok) return { status: scope.status, body: { error: scope.error } };
      const valid = requireId(params.id);
      if (!valid.ok) return { status: 422, body: { error: valid.error } };
      return { status: 200, body: { id: params.id, source: "reports" } };
    };
    ```

=== "Python"
    ```python
    # functions/reports/[id]/get.py
    from _shared.auth import require_api_key, require_scope
    from _shared.validate import require_id

    def handler(event, params):
        auth = require_api_key(event)
        if not auth["ok"]:
            return {"status": auth["status"], "body": {"error": auth["error"]}}
        scope = require_scope(event, "reports:read")
        if not scope["ok"]:
            return {"status": scope["status"], "body": {"error": scope["error"]}}
        valid = require_id(params.get("id"))
        if not valid["ok"]:
            return {"status": 422, "body": {"error": valid["error"]}}
        return {"status": 200, "body": {"id": params.get("id"), "source": "reports"}}
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};
    use crate::shared::{require_api_key, require_scope, require_id};

    pub fn handler(event: Value, params: Value) -> Value {
        let auth = require_api_key(&event);
        if !auth["ok"].as_bool().unwrap_or(false) {
            return json!({"status": auth["status"], "body": {"error": auth["error"]}});
        }
        let scope = require_scope(&event, "reports:read");
        if !scope["ok"].as_bool().unwrap_or(false) {
            return json!({"status": scope["status"], "body": {"error": scope["error"]}});
        }
        let id = params.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let valid = require_id(id);
        if !valid["ok"].as_bool().unwrap_or(false) {
            return json!({"status": 422, "body": {"error": valid["error"]}});
        }
        json!({"status": 200, "body": {"id": id, "source": "reports"}})
    }
    ```

=== "PHP"
    ```php
    <?php
    require_once __DIR__ . '/../../_shared/auth.php';
    require_once __DIR__ . '/../../_shared/validate.php';

    function handler(array $event, array $params): array {
        $auth = require_api_key($event);
        if (!$auth['ok']) return ['status' => $auth['status'], 'body' => ['error' => $auth['error']]];
        $scope = require_scope($event, 'reports:read');
        if (!$scope['ok']) return ['status' => $scope['status'], 'body' => ['error' => $scope['error']]];
        $valid = require_id($params['id'] ?? '');
        if (!$valid['ok']) return ['status' => 422, 'body' => ['error' => $valid['error']]];
        return ['status' => 200, 'body' => ['id' => ($params['id'] ?? ''), 'source' => 'reports']];
    }
    ```

Runtime-specific import notes:

- Python: add `functions/_shared/__init__.py` and keep `functions/` on runtime import path.
- Rust: expose shared helpers in your crate entry (`mod shared;` in `lib.rs`/`main.rs`) before using `crate::shared::*`.
- PHP: for deep nested routes, prefer a bootstrap with a stable base path constant instead of many `../`.

## 3. Verify with curl

```bash
curl -i 'http://127.0.0.1:8080/reports/1'
curl -i 'http://127.0.0.1:8080/reports/1' -H 'x-api-key: demo'
curl -i 'http://127.0.0.1:8080/reports/1' -H 'x-api-key: demo' -H 'x-scope: reports:read'
```

Expected result:

- Missing key: `401`
- Missing scope: `403`
- Invalid id: `422`
- Valid request: `200`

## Validation

- Guard chain executes in fixed order (auth -> scope -> validation -> logic).
- At least two routes reuse the same helper modules.
- Response errors are consistent across runtimes.

## Troubleshooting

- If scope header parsing fails, normalize separators (`space`, `comma`) in helper.
- If imports fail in native mode, check runtime working directory and relative paths.
- If behavior differs between runtimes, validate helper return contracts first.

## Related links

- [Shared logic patterns](../explanation/shared-logic-patterns.md)
- [Authentication](./authentication.md)
- [Security confidence](./security-confidence.md)
