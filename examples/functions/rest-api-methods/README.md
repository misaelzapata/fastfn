# REST API with Method-Specific File Routing

Demonstrates FastFN's zero-config file routing where each HTTP method gets its own handler file.
Every handler is implemented in **all 6 supported runtimes**: Python, Node.js, PHP, Go, Rust, and Lua.

## Structure

```
products/
  _shared.go                           private helper for Go product routes
  _shared.lua                          private helper for Lua product routes
  get.{py,js,php,go,rs,lua}          GET    /products        — list all
  post.{py,js,php,go,rs,lua}         POST   /products        — create
  [id]/
    get.{py,js,php,go,rs,lua}        GET    /products/:id    — read one
    put.{py,js,php,go,rs,lua}        PUT    /products/:id    — update
    delete.{py,js,php,go,rs,lua}     DELETE /products/:id    — delete

posts/
  [slug]/
    get.{py,js,php,go,rs,lua}        GET    /posts/:slug     — single param
  [category]/[slug]/
    get.{py,js,php,go,rs,lua}        GET    /posts/:cat/:slug — multi-param

files/
  [...path]/
    get.{py,js,php,go,rs,lua}        GET    /files/*         — catch-all wildcard
```

FastFN picks the handler by file extension matching the runtime. One file per method — no `if method == "POST"` branches.

This example also demonstrates private helper imports in a pure file tree:

- `products/_shared.go` is compiled together with `products/get.go` and `products/post.go`
- `products/_shared.lua` is loaded via `require("_shared")` from the Lua handlers

Because these helpers are prefixed with `_`, they stay private and do not become `/products/_shared`.

## Direct Params Injection

Route params from bracket filenames (`[id]`, `[slug]`, `[...path]`) arrive as **direct function arguments** — no need to dig into `event.params`.

### How each runtime receives params

| Runtime   | Mechanism                           | Example                                  |
|-----------|-------------------------------------|------------------------------------------|
| Python    | `inspect.signature` → kwargs        | `def handler(event, id):`                |
| Node.js   | Second arg (when `handler.length>1`)| `async (event, { id }) =>`              |
| PHP       | `ReflectionFunction` → second arg   | `function handler($event, $params)`      |
| Lua       | Always passed as second arg         | `function handler(event, params)`        |
| Go        | Params merged into event map        | `event["id"].(string)`                   |
| Rust      | Params merged into event value      | `event["id"].as_str()`                   |

## Param Types

### `[id]` — Single Dynamic Param

**Python** (`products/[id]/get.py`)
```python
def handler(event, id):
    return {"status": 200, "body": {"id": int(id), "name": "Widget"}}
```

**Node.js** (`products/[id]/get.js`)
```javascript
exports.handler = async (event, { id }) => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ id: Number(id), name: "Widget" }),
});
```

**PHP** (`products/[id]/get.php`)
```php
function handler($event, $params) {
    $id = $params["id"] ?? "";
    return ["status" => 200, "body" => json_encode(["id" => (int)$id])];
}
```

**Lua** (`products/[id]/get.lua`)
```lua
local function handler(event, params)
    local id = params.id or ""
    return { status = 200, body = cjson.encode({ id = tonumber(id) }) }
end
return handler
```

**Go** (`products/[id]/get.go`) — params merged into event
```go
func handler(event map[string]interface{}) interface{} {
    idStr, _ := event["id"].(string)  // merged from params
    id, _ := strconv.Atoi(idStr)
    // ...
}
```

**Rust** (`products/[id]/get.rs`) — params merged into event
```rust
pub fn handler(event: Value) -> Value {
    let id: i64 = event["id"].as_str().unwrap_or("0").parse().unwrap_or(0);
    // ...
}
```

### `[slug]` — Named Param

**Python** (`posts/[slug]/get.py`)
```python
def handler(event, slug):
    return {"status": 200, "body": {"slug": slug, "title": f"Post: {slug}"}}
```

**Node.js** (`posts/[slug]/get.js`)
```javascript
exports.handler = async (event, { slug }) => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ slug, title: `Post: ${slug}` }),
});
```

### `[category]/[slug]` — Multiple Params

**Python** (`posts/[category]/[slug]/get.py`)
```python
def handler(event, category, slug):
    return {"status": 200, "body": {"category": category, "slug": slug}}
```

**Node.js** (`posts/[category]/[slug]/get.js`)
```javascript
exports.handler = async (event, { category, slug }) => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ category, slug }),
});
```

### `[...path]` — Catch-All Wildcard

**Python** (`files/[...path]/get.py`)
```python
def handler(event, path):
    segments = path.split("/") if isinstance(path, str) else []
    return {"status": 200, "body": {"path": path, "segments": segments}}
```

**Node.js** (`files/[...path]/get.js`)
```javascript
exports.handler = async (event, { path }) => {
  const segments = typeof path === "string" ? path.split("/") : [];
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ path, segments, depth: segments.length }),
  };
};
```

## Run

Every handler is implemented in all 6 runtimes. Since multiple files map to the
same route, you must select a single runtime to avoid 409 ambiguity:

```bash
FN_RUNTIMES=python fastfn dev examples/functions/rest-api-methods
FN_RUNTIMES=node   fastfn dev examples/functions/rest-api-methods
FN_RUNTIMES=php    fastfn dev examples/functions/rest-api-methods
FN_RUNTIMES=lua    fastfn dev examples/functions/rest-api-methods
FN_RUNTIMES=go     fastfn dev examples/functions/rest-api-methods
FN_RUNTIMES=rust   fastfn dev examples/functions/rest-api-methods
```

## Test

```bash
# List products
curl http://127.0.0.1:8080/products

# Create a product
curl -X POST http://127.0.0.1:8080/products \
  -H "Content-Type: application/json" \
  -d '{"name":"Widget","price":9.99}'

# Get one product (param injection: id=42)
curl http://127.0.0.1:8080/products/42

# Update a product
curl -X PUT http://127.0.0.1:8080/products/42 \
  -H "Content-Type: application/json" \
  -d '{"name":"Updated Widget","price":12.99}'

# Delete a product
curl -X DELETE http://127.0.0.1:8080/products/42

# Slug param
curl http://127.0.0.1:8080/posts/hello-world

# Multi-param
curl http://127.0.0.1:8080/posts/tech/hello-world

# Wildcard catch-all
curl http://127.0.0.1:8080/files/docs/2024/report.pdf
```

## Event Object

All runtimes receive the same event structure:

| Field     | Type   | Description                                |
|-----------|--------|--------------------------------------------|
| `params`  | object | Dynamic route params, e.g. `{id: "42"}`    |
| `query`   | object | URL query parameters                       |
| `body`    | string | Raw request body                           |
| `method`  | string | HTTP method (`GET`, `POST`, etc.)          |
| `headers` | object | Request headers                            |
| `session` | object | Session data (auto-managed)                |
| `env`     | object | Environment variables from `fn.env.json`   |
| `context` | object | Runtime context (user, trace_id, etc.)     |

All runtimes return the same response shape:

| Field     | Type   | Description                |
|-----------|--------|----------------------------|
| `status`  | number | HTTP status code           |
| `headers` | object | Response headers           |
| `body`    | string | Response body (serialized) |
