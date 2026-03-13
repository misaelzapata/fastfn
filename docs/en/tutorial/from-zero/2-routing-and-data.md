# Part 2: Routing and Data

> Verified status as of **March 13, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

## Quick View

- Complexity: Intermediate
- Typical time: 25-35 minutes
- Outcome: dynamic path/query/body handling with explicit validation errors

## 1. Path parameters: single and catch-all

Create files:

```text
node/
  tasks/
    [id].js
  reports/
    [...slug].js
```

`node/tasks/[id].js`:

```js
exports.handler = async (_event, { id }) => ({
  status: 200,
  body: { task_id: id }
});
```

`node/reports/[...slug].js`:

```js
exports.handler = async (_event, { slug }) => ({
  status: 200,
  body: { path: slug }
});
```

Validate:

```bash
curl -sS 'http://127.0.0.1:8080/tasks/42'
curl -sS 'http://127.0.0.1:8080/reports/2026/03/daily'
```

Expected:

```json
{"task_id":"42"}
{"path":"2026/03/daily"}
```

## 2. Query params: required vs optional and defaults

`node/tasks/search.js`:

```js
exports.handler = async (event) => {
  const q = event.query?.q;
  const page = Number(event.query?.page || "1");

  if (!q) {
    return { status: 400, body: { error: "q is required" } };
  }

  return { status: 200, body: { q, page } };
};
```

Validate:

```bash
curl -sS 'http://127.0.0.1:8080/tasks/search?page=2'
curl -sS 'http://127.0.0.1:8080/tasks/search?q=fastfn'
```

Expected:

```json
{"error":"q is required"}
{"q":"fastfn","page":1}
```

## 3. JSON body parsing and error cases

`node/tasks/post.js`:

```js
exports.handler = async (event) => {
  let payload;
  try {
    payload = JSON.parse(event.body || "{}");
  } catch (_err) {
    return { status: 400, body: { error: "invalid JSON body" } };
  }

  if (!payload.title || typeof payload.title !== "string") {
    return { status: 422, body: { error: "title must be a non-empty string" } };
  }

  return { status: 201, body: { id: 3, title: payload.title } };
};
```

Validate:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{bad'
curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Write docs"}'
```

Expected statuses/bodies:

- `400` with `{"error":"invalid JSON body"}`
- `422` with `{"error":"title must be a non-empty string"}`
- `201` with created task payload

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
- params missing: check if route uses `[id]` or `[...slug]` pattern correctly
- body parse errors: confirm `Content-Type: application/json` and valid JSON syntax

## Next step

[Go to Part 3: Configuration and Secrets](./3-config-and-secrets.md)

## Related links

- [Request validation and schemas](../request-validation-and-schemas.md)
- [Request metadata and files](../request-metadata-and-files.md)
- [HTTP API reference](../../reference/http-api.md)
