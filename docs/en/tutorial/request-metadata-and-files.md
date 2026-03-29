# Request Metadata and Files

> Verified status as of **March 13, 2026**.
> Runtime note: this page documents current FastFN behavior, including raw-body handling for form and multipart requests.

## Complexity
Intermediate

## Time
20-30 minutes

## Outcome
You understand how headers, cookies, query values, JSON body, forms, and file-upload inputs arrive in FastFN today, and where parsing is explicit.

## Validation
1. Start local runtime: `fastfn dev examples/functions`.
2. Run request metadata check:
   ```bash
   curl -sS http://127.0.0.1:8080/request-inspector \
     -H "x-request-id: req-123" \
     -H "Cookie: session_id=abc123; theme=dark"
   ```
3. Run JSON body check:
   ```bash
   curl -sS -X POST http://127.0.0.1:8080/tasks \
     -H "Content-Type: application/json" \
     -d '{"title":"Write docs","priority":"2"}'
   ```
4. Run form-urlencoded raw-body check:
   ```bash
   curl -sS -X POST http://127.0.0.1:8080/contact \
     -H "Content-Type: application/x-www-form-urlencoded" \
     --data 'name=Misael&role=admin'
   ```

## Troubleshooting
- If headers are missing, inspect casing and reverse-proxy forwarding rules.
- If cookies are empty, confirm the `Cookie` header reaches FastFN.
- If JSON parse fails, verify `Content-Type` and payload validity.
- For multipart parsing needs, treat current support as raw-body only.

## Support matrix

| Input type | Current posture | How it arrives |
| :--- | :--- | :--- |
| Headers | Supported | `event.headers` |
| Cookies | Supported | `event.session.cookies` |
| Query string | Supported | `event.query` |
| JSON body | Supported with explicit parsing | `event.body` raw string |
| Plain text body | Supported | `event.body` raw string |
| `application/x-www-form-urlencoded` | Raw-only | `event.body` raw string |
| `multipart/form-data` | Raw-only (no first-class parser) | `event.body` raw string |
| Binary request payloads | Limited | avoid assuming automatic structured parsing |

## Headers

```text
event.headers
```

Python:
```python

def handler(event):
    headers = event.get("headers") or {}
    return {
        "status": 200,
        "body": {
            "request_id": headers.get("x-request-id"),
            "authorized": bool(headers.get("x-api-key")),
        },
    }
```

Node:
```javascript
exports.handler = async (event) => {
  const headers = event.headers || {};
  return {
    status: 200,
    body: {
      request_id: headers["x-request-id"] || null,
      authorized: Boolean(headers["x-api-key"] || null),
    },
  };
};
```

## Cookies
FastFN exposes parsed cookies under `event.session.cookies`.

```json
{
  "session": {
    "id": "abc123",
    "cookies": {
      "session_id": "abc123",
      "theme": "dark"
    }
  }
}
```

Python:
```python

def handler(event):
    session = event.get("session") or {}
    cookies = session.get("cookies") or {}
    return {"status": 200, "body": {"theme": cookies.get("theme", "light")}}
```

## JSON and plain-text bodies
Body is raw text. Parse explicitly.

Python:
```python
import json


def handler(event):
    payload = json.loads(event.get("body") or "{}")
    return {
        "status": 200,
        "body": {
            "title": payload.get("title"),
            "priority": int(payload.get("priority", 1)),
        },
    }
```

Node:
```javascript
exports.handler = async (event) => {
  const payload = JSON.parse(event.body || "{}");
  return {
    status: 200,
    body: {
      title: payload.title || null,
      priority: Number(payload.priority || 1),
    },
  };
};
```

## Forms and multipart
- `application/x-www-form-urlencoded`: available as raw string in `event.body`.
- `multipart/form-data`: currently raw-only in gateway contract; no built-in field/file abstraction.

Practical recommendation:
1. Prefer JSON for API contracts.
2. Keep multipart parsing explicit in runtime code only when you fully control format.
3. For heavy upload workflows, use specialized upstream components.

## Limits that matter
- Request size is constrained by `max_body_bytes`.
- Per-function policy still applies before handler execution.
- Response metadata (cookies/headers) remains controlled by response envelope fields.

## Related links
- [Runtime Contract](../reference/runtime-contract.md)
- [Function Specification](../reference/function-spec.md)
- [Typed Inputs and Responses](./typed-inputs-and-responses.md)
- [From Zero: Advanced Responses](./from-zero/4-advanced-responses.md)
