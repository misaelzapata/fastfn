# Typed Inputs and Responses

> Verified status as of **March 13, 2026**.
> Runtime note: `fastfn dev --native` requires host runtimes; `fastfn dev` uses Docker.

## Complexity
Intermediate

## Time
20-30 minutes

## Outcome
You can design stable request/response contracts in FastFN and implement explicit type normalization in Python and Node routes.

## Validation
1. Start local runtime: `fastfn dev examples/functions`.
2. Call a route with typed coercion:
   ```bash
   curl -sS -X POST http://127.0.0.1:8080/tasks \
     -H "Content-Type: application/json" \
     -d '{"title":"Write docs","priority":"2","done":false}'
   ```
3. Confirm output types (`priority` as number, `done` as boolean).
4. Confirm OpenAPI still reflects the route at `/openapi.json` when enabled.

## Troubleshooting
- If you get `JSONDecodeError` or `Unexpected token`, verify `Content-Type: application/json` and raw payload format.
- If params are missing, verify filesystem route naming (`[id]`, `[slug]`, etc.).
- If runtime behavior differs, compare against the runtime contract and normalize in handler code.

## Mental model
FastFN gives you one stable request envelope and one stable response envelope.

Request side:
- Route params come from filesystem routing.
- Query, headers, cookies, and body come through `event`.
- Body is raw text by default and should be parsed explicitly when needed.

Response side:
- Return `status`, `headers`, `body`.
- Keep body as your typed domain payload.

## Input typing patterns

### Route params
Route shape is your first typing hint.

Python example:
```python

def handler(event, id):
    item_id = int(id)
    return {"status": 200, "body": {"id": item_id}}
```

Node example:
```javascript
exports.handler = async (_event, { id }) => {
  return { status: 200, body: { id: Number(id) } };
};
```

### Query + body
Normalize explicitly near the top of the handler.

Python:
```python
import json


def handler(event):
    query = event.get("query") or {}
    payload = json.loads(event.get("body") or "{}")

    limit = int(query.get("limit", 10))
    title = str(payload.get("title", "untitled"))
    done = bool(payload.get("done", False))

    return {
        "status": 200,
        "body": {"limit": limit, "title": title, "done": done},
    }
```

Node:
```javascript
exports.handler = async (event) => {
  const query = event.query || {};
  const payload = JSON.parse(event.body || "{}");

  const limit = Number(query.limit || 10);
  const title = String(payload.title || "untitled");
  const done = Boolean(payload.done || false);

  return {
    status: 200,
    body: { limit, title, done },
  };
};
```

### Request metadata
Use headers/cookies for auth, tracing, locale, and policy.

```text
event.headers["authorization"]
event.headers["x-request-id"]
event.session.cookies
event.query
event.body
```

## Response typing patterns
Canonical envelope:

```json
{
  "status": 200,
  "headers": {
    "Content-Type": "application/json"
  },
  "body": {
    "ok": true
  }
}
```

Practical rules:
- Set `status` explicitly for intent.
- Use `headers` for content type and response policy.
- Keep `body` minimal, typed, and client-focused.

## End-to-end typed route example

```bash
curl -sS -X POST http://127.0.0.1:8080/tasks \
  -H "Content-Type: application/json" \
  -d '{"title":"Write docs","priority":"2","done":false}'
```

Expected body:
```json
{
  "title": "Write docs",
  "priority": 2,
  "done": false
}
```

## Validation strategy
1. Coerce primitives early.
2. Validate required fields before business logic.
3. Return explicit `400` errors for conversion failures.
4. Extract shared validation only when genuinely reused across routes.

## Related links
- [Direct Params Injection](./direct-params.md)
- [Routing](./routing.md)
- [Request Metadata and Files](./request-metadata-and-files.md)
- [From Zero: Routing and Data](./from-zero/2-routing-and-data.md)
- [From Zero: Advanced Responses](./from-zero/4-advanced-responses.md)
- [HTTP API Reference](../reference/http-api.md)
