# HTTP API Reference


> Verified status as of **March 13, 2026**.
> Runtime note: FastFN resolves dependencies and build steps per function: Python uses `requirements.txt`, Node uses `package.json`, PHP installs from `composer.json` when present, and Rust handlers are built with `cargo`. Host runtimes/tools are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
Formal reference for public and internal endpoints.

## Quick View

- Complexity: Reference
- Typical time: 15-30 minutes
- Use this when: you need exact endpoint contracts or status-code behavior
- Outcome: reproducible API calls for public routes and `/_fn/*` operations

## Conventions

- Local base URL: `http://127.0.0.1:8080`
- Common error payload:

```json
{"error":"message"}
```

## Public endpoints

FastFN serves functions at normal paths like `/hello` and `/users/123`.

These are the routes you see in:

- `GET /openapi.json`
- `GET /docs` (Swagger UI)

### `GET|POST|PUT|PATCH|DELETE /<route>`

Invokes the mapped function behind that route.

Mapped routes come from:

- file-based routes (Next.js-style),
- `fn.routes.json`,
- or explicit `fn.config.json -> invoke.routes`.

### GET example

```bash
curl -sS 'http://127.0.0.1:8080/hello?name=World'
```

### POST example

```bash
curl -sS -X POST 'http://127.0.0.1:8080/risk-score?email=user@example.com' \
  -H 'Content-Type: application/json' \
  -d '{"source":"web"}'
```

## Version pinning (optional)

FastFN supports side-by-side versions under the function directory (for example `v2/`).

### `GET|POST|PUT|PATCH|DELETE /<name>@<version>`

Invokes a specific version by name.

Key rule (applies to all of the above):

- allowed methods come from `fn.config.json -> invoke.methods`
- if not allowed: `405` + `Allow` header

### Custom routes via `invoke.routes`

By default, a function at `functions/my-func/app.py` is reachable at `/my-func`. With `invoke.routes` you can expose it at one or more custom public URLs instead — useful for REST APIs, vanity paths, or mounting a function at a specific prefix.

```json
{
  "invoke": {
    "methods": ["GET"],
    "routes": ["/api/node-echo"]
  }
}
```

- `routes` is an array of URL paths. Each path becomes a public endpoint that invokes this function.
- Wildcard routes are supported: `"/api/v1/*"` matches `/api/v1/anything/here`.
- `methods` restricts which HTTP methods are allowed (default: all methods).
- After discovery (startup or hot-reload), the gateway registers these routes automatically.
- If another function already maps the same route, the request is rejected unless `invoke.force-url` is `true`.

### Debug headers (opt-in)

When a function enables debug headers, responses can include:

- `X-Fn-Runtime`
- `X-Fn-Runtime-Routing`
- `X-Fn-Runtime-Socket-Index`
- `X-Fn-Worker-Pool-Max-Workers`
- `X-Fn-Worker-Pool-Max-Queue`

This is useful when you want to confirm which runtime handled a request and whether traffic is rotating across multiple sockets.

## Path operation configuration (FastFN equivalents)

FastFN does not use decorator-based path operation objects like FastAPI. Configuration is distributed between file routes and `fn.config.json`.

| FastAPI-style concept | FastFN equivalent | Notes |
|---|---|---|
| operation method/path | filename + folder path | source of truth is filesystem or `fn.routes.json` |
| allowed methods | `invoke.methods` | enforced at gateway, returns `405` + `Allow` |
| summary | `invoke.summary` or handler hint `@summary` | reflected in OpenAPI summary text |
| query/body examples | `invoke.query`, `invoke.body`, `invoke.content_type` | used for OpenAPI request examples |
| operationId | generated automatically | format: `<method>_<runtime>_<name>_<version>` |
| tags | generated (`functions` / `internal`) | no per-route custom tag mapping yet |

Non-1:1 note: if you need deep OpenAPI customization per operation, keep FastFN as runtime router and place extended schema transformations in your delivery pipeline.

## Internal platform endpoints (`/_fn/*`)

### Health and discovery

- `GET /_fn/health`
- `POST /_fn/reload`
- `GET /_fn/catalog`
- `GET /_fn/packs`
- `GET /_fn/schedules`
- `GET /_fn/jobs`
- `POST /_fn/jobs`
- `GET /_fn/jobs/<id>`
- `DELETE /_fn/jobs/<id>`
- `GET /_fn/jobs/<id>/result`

#### `GET /_fn/health`

Returns a runtime and route snapshot for the current process.

Example:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
```

Simplified shape:

```json
{
  "python": {
    "routing": "round_robin",
    "health": { "up": true, "reason": "ok" },
    "sockets": [
      { "index": 1, "uri": "unix:/tmp/fastfn/fn-python-1.sock", "up": true, "reason": "ok" },
      { "index": 2, "uri": "unix:/tmp/fastfn/fn-python-2.sock", "up": true, "reason": "ok" }
    ]
  }
}
```

Use it to confirm:

- enabled runtimes
- runtime routing mode (`single` or `round_robin`)
- per-socket health
- route conflict counts and function state summaries

### CRUD and configuration

- `GET|POST|DELETE /_fn/function`
- `GET|PUT /_fn/function-config`
- `GET|PUT /_fn/function-env`
- `PUT /_fn/function-code`

### Console operations

- `POST /_fn/invoke`
- `POST /_fn/login`
- `POST /_fn/logout`
- `GET|POST|PUT|PATCH|DELETE /_fn/ui-state`

`/_fn/ui-state` rules:

- `GET` requires Console API access.
- `POST|PUT|PATCH|DELETE` require Console API access **and** write permission (`FN_CONSOLE_WRITE_ENABLED=1` or admin token).

`/_fn/function-config` PUT accepts top-level or nested route/method fields:

```json
{
  "timeout_ms": 5000,
  "methods": ["GET", "POST"],
  "routes": ["/alice/demo", "/alice/demo/{id}"]
}
```

This is equivalent to the nested form:

```json
{
  "timeout_ms": 5000,
  "invoke": {
    "methods": ["GET", "POST"],
    "routes": ["/alice/demo", "/alice/demo/{id}"]
  }
}
```

When both top-level and `invoke.*` are provided, `invoke.*` takes precedence.

`/_fn/function-env` payload accepts:

- scalar values: `"KEY":"value"`
- secret objects: `"KEY":{"value":"secret","is_secret":true}`
- `null` to delete a key

`GET /_fn/function` can also return runtime dependency resolution metadata when the runtime emits it (today mainly Python/Node):

- `metadata.dependency_resolution.mode` (`manifest` or `inferred`)
- `metadata.dependency_resolution.manifest_generated`
- `metadata.dependency_resolution.inferred_imports`
- `metadata.dependency_resolution.resolved_packages`
- `metadata.dependency_resolution.unresolved_imports`
- `metadata.dependency_resolution.last_install_status` / `last_error`

## `/_fn/invoke` (full payload)

```bash
curl -sS 'http://127.0.0.1:8080/_fn/invoke' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{
    "runtime":"node",
    "name":"node-echo",
    "version":null,
    "method":"POST",
    "query":{"name":"Node"},
    "body":"{\"x\":1}",
    "context":{"trace_id":"abc-123"}
  }'
```

Fields:

- `runtime` optional when name is not ambiguous
  - supported values: `python`, `node`, `php`, `rust`
- `name` required
- `version` optional (`null` for default)
- `method` required
- `query` optional object
- `body` string or JSON-serializable value
- `context` optional object forwarded to `event.context.user`

## OpenAPI and Swagger

- `GET /openapi.json`
- `GET /docs`

OpenAPI is generated dynamically and reflects currently allowed methods per function/version.

## Serialization and encoding edge cases

FastFN normalizes runtime output into HTTP, but serialization behavior still depends on the `body` type and response headers.

| Runtime return body | Header strategy | Client result |
|---|---|---|
| object/array | no explicit `Content-Type` | JSON serialization with `application/json` |
| string | no explicit `Content-Type` | plain text output |
| string JSON | `application/json` | sent as text; clients parse JSON manually if needed |
| binary/base64 string | explicit content type + decoding at handler side | binary-safe delivery pattern |

Recommended deterministic pattern:

```json
{
  "status": 200,
  "headers": { "Content-Type": "application/json; charset=utf-8" },
  "body": { "ok": true }
}
```

## Error table

| Code | Meaning | Typical cause |
|---|---|---|
| `404` | function/version not found | unknown name/version |
| `405` | method not allowed | calling POST on GET-only function |
| `409` | route ambiguity | same function name across runtimes or same mapped route in multiple functions |
| `413` | payload too large | body exceeds `max_body_bytes` |
| `429` | concurrency limit reached | exceeds `max_concurrency` |
| `502` | invalid runtime response | runtime contract violation |
| `503` | runtime down | socket unavailable |
| `504` | timeout | function exceeded `timeout_ms` |
| `500` | internal error | gateway exception |

## HTTP Lifecycle Diagram

```mermaid
flowchart LR
  A["HTTP request"] --> B["Gateway"]
  B --> C["Internal admin/public router"]
  C --> D["Runtime invocation"]
  D --> E["HTTP response"]
```

## Contract

Defines expected request/response shape, configuration fields, and behavioral guarantees.

## End-to-End Example

Use the examples in this page as canonical templates for implementation and testing.

## Edge Cases

- Missing configuration fallbacks
- Route conflicts and precedence
- Runtime-specific nuances

## See also

- [Function Specification](function-spec.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
- [Architecture Overview](../explanation/architecture.md)

## Extending OpenAPI: points and limits

Extension points:

- route metadata inferred from file routing + method files
- explicit examples in docs aligned with runtime behavior
- tags/operation grouping through naming conventions

Limits:

- OpenAPI should reflect real runtime behavior; avoid documenting statuses not returned by handlers.
- Advanced schema generation differs by runtime implementation details.

Validation command:

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | jq '.paths | keys'
```

## Validation

Run this smoke sequence:

```bash
curl -i -sS 'http://127.0.0.1:8080/_fn/health'
curl -sS 'http://127.0.0.1:8080/_fn/catalog' | jq '{mapped_routes, mapped_route_conflicts}'
curl -sS 'http://127.0.0.1:8080/openapi.json' | jq '.paths | keys | length'
```

Expected:

- health returns `200`
- catalog returns mapped routes and deterministic conflict data
- OpenAPI paths count is non-zero for public projects

## Troubleshooting

- If `/_fn/*` returns `401/403`, check admin token and console-access flags.
- If OpenAPI is empty, verify that at least one public route exists and is discoverable.
- If a route responds `405`, verify `invoke.methods` in function config.
- If route calls return `503`, verify runtime socket health in `/_fn/health`.

## Next step
Continue with [Run and test](../how-to/run-and-test.md) to validate this contract end-to-end in local/CI flows.

## Related links
- [Run and test](../how-to/run-and-test.md)
- [Zero-config routing](../how-to/zero-config-routing.md)
- [Platform runtime plumbing](../how-to/platform-runtime-plumbing.md)
- [Function specification](./function-spec.md)
- [Runtime contract](./runtime-contract.md)
- [Built-in functions](./builtin-functions.md)
- [Architecture](../explanation/architecture.md)
- [Get help](../how-to/get-help.md)
