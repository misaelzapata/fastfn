---
title: Building a REST API with File-Based Method Routing
description: How to use FastFN's file-based routing to build clean REST APIs with one file per HTTP method.
---

# Building a REST API with File-Based Method Routing


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
Most serverless platforms give you one handler per endpoint. If that endpoint needs to
respond to GET, POST, PUT, and DELETE, you end up with a growing `if/else` chain or a
`switch` statement that becomes harder to read, test, and maintain over time.

FastFN takes a different approach: **one file per HTTP method**. The filename declares
the method, the directory declares the path, and brackets declare dynamic parameters.
No routing table. No config file. Just files.

This article walks through building a full CRUD API for a `products` resource using
file-based method routing, then extends the pattern to a versioned multi-level API.

---

## The Problem

Consider a typical serverless handler that supports multiple HTTP methods:

```python
def handler(event):
    method = event.get("method", "GET")

    if method == "GET":
        return list_products()
    elif method == "POST":
        return create_product(event)
    elif method == "PUT":
        return update_product(event)
    elif method == "DELETE":
        return delete_product(event)
    else:
        return {"status": 405, "body": {"error": "Method not allowed"}}
```

This works, but it has real costs:

- **Readability degrades** as the handler grows. A five-method endpoint with validation
  quickly reaches 200+ lines in a single file.
- **Testing gets noisy.** You need to mock the method field and test every branch
  within the same test module.
- **Code review is harder.** A diff that touches the DELETE branch also shows the
  unchanged GET branch, adding visual noise.
- **Permissions blur.** If POST requires auth but GET does not, that logic lives in
  the same handler, mixed with business logic.

In many stacks this is solved with route decorators or separate handler modules. In
function-as-a-service, you usually get one entry point per deployed function. FastFN
bridges that gap without making you keep a routing table by hand.

---

## The Solution: One File Per Method

FastFN's zero-config routing uses three conventions to map files to HTTP endpoints:

1. **Filename = method.** A file named `get.py` handles GET requests. `post.py`
   handles POST. Supported prefixes: `get`, `post`, `put`, `patch`, `delete`.
2. **Directory = route path.** The folder structure mirrors the URL path.
   `products/` becomes `/products`.
3. **Brackets = dynamic segments.** A folder named `[id]` captures a path parameter.
   `products/[id]/get.py` handles `GET /products/:id`.

No routing table file. No decorator. No config. The filesystem **is** the router.

---

## Step 1: Plan Your API

Before writing code, define the endpoints. A standard products CRUD looks like this:

| Method   | Path             | Action              | File                          |
|----------|------------------|----------------------|-------------------------------|
| `GET`    | `/products`      | List all products    | `products/get.py`             |
| `POST`   | `/products`      | Create a product     | `products/post.py`            |
| `GET`    | `/products/:id`  | Get one product      | `products/[id]/get.py`        |
| `PUT`    | `/products/:id`  | Update a product     | `products/[id]/put.py`        |
| `DELETE` | `/products/:id`  | Delete a product     | `products/[id]/delete.py`     |

Five endpoints, five files. Each file does exactly one thing.

---

## Step 2: Create the Directory Structure

```text
rest-api-methods/
  products/
    get.py
    post.py
    [id]/
      get.py
      put.py
      delete.py
```

That is the entire project. No `fn.config.json`, no `fn.routes.json`, no framework
boilerplate.

---

## Step 3: Write the Handlers

### `products/get.py` -- List all products

```python
def handler(event):
    """GET /products -- list all products"""
    return {
        "status": 200,
        "body": {
            "products": [
                {"id": 1, "name": "Widget", "price": 9.99},
                {"id": 2, "name": "Gadget", "price": 24.99},
            ],
            "total": 2,
        },
    }
```

The handler receives an `event` dict and returns a response dict with `status` and
`body`. That is the entire contract.

### `products/post.py` -- Create a product

```python
import json

def handler(event):
    """POST /products -- create a product"""
    body = event.get("body", "")
    try:
        data = json.loads(body) if isinstance(body, str) else (body or {})
    except Exception:
        return {"status": 400, "body": {"error": "Invalid JSON"}}

    name = data.get("name", "").strip()
    price = data.get("price", 0)

    if not name:
        return {"status": 400, "body": {"error": "name is required"}}

    return {
        "status": 201,
        "body": {"id": 42, "name": name, "price": price, "created": True},
    }
```

Validation is local to this file. The GET handler does not need to know about it.

### `products/[id]/get.py` -- Get one product

```python
def handler(event, id):
    """GET /products/:id -- get one product"""
    return {
        "status": 200,
        "body": {"id": int(id), "name": "Widget", "price": 9.99},
    }
```

The `[id]` folder name becomes the `id` parameter, injected directly into your handler
signature. No manual parsing of the URL path.

### `products/[id]/put.py` -- Update a product

```python
import json

def handler(event, id):
    """PUT /products/:id -- update a product"""
    body = event.get("body", "")
    try:
        data = json.loads(body) if isinstance(body, str) else (body or {})
    except Exception:
        return {"status": 400, "body": {"error": "Invalid JSON"}}

    return {
        "status": 200,
        "body": {"id": int(id), **data, "updated": True},
    }
```

### `products/[id]/delete.py` -- Delete a product

```python
def handler(event, id):
    """DELETE /products/:id -- delete a product"""
    return {
        "status": 200,
        "body": {"id": int(id), "deleted": True},
    }
```

Each file is 5-15 lines. Each is independently testable.

---

## Same API, Every Runtime

The examples above use Python, but the exact same file structure works with **every
FastFN runtime**. Just swap the file extension. Here is `products/[id]/get` in all six
supported languages:

### Node.js — `products/[id]/get.js`

```javascript
exports.handler = async (event, { id }) => {
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id: Number(id), name: "Widget", price: 9.99 }),
  };
};
```

### PHP — `products/[id]/get.php`

```php
<?php
function handler($event, $params) {
    $id = $params["id"] ?? "";
    return [
        "status" => 200,
        "headers" => ["Content-Type" => "application/json"],
        "body" => json_encode(["id" => (int)$id, "name" => "Widget", "price" => 9.99]),
    ];
}
```

### Go — `products/[id]/get.go`

```go
package main

import (
    "encoding/json"
    "strconv"
)

func handler(event map[string]interface{}) interface{} {
    // Go receives params merged into event
    params, _ := event["params"].(map[string]interface{})
    idStr, _ := params["id"].(string)
    id, _ := strconv.Atoi(idStr)

    body, _ := json.Marshal(map[string]interface{}{
        "id": id, "name": "Widget", "price": 9.99,
    })
    return map[string]interface{}{
        "status":  200,
        "headers": map[string]string{"Content-Type": "application/json"},
        "body":    string(body),
    }
}
```

### Rust — `products/[id]/get.rs`

```rust
use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    // Rust receives params merged into event
    let id: i64 = event["params"]["id"].as_str()
        .unwrap_or("0").parse().unwrap_or(0);

    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": serde_json::to_string(&json!({
            "id": id, "name": "Widget", "price": 9.99
        })).unwrap()
    })
}
```

### Lua — `products/[id]/get.lua`

```lua
local cjson = require("cjson")

local function handler(event, params)
    local id = params.id or ""
    return {
        status = 200,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode({
            id = tonumber(id),
            name = "Widget",
            price = 9.99,
        }),
    }
end

return handler
```

### POST with validation — every runtime

Creating a product requires parsing the body and validating fields. Here is the
POST handler in each language:

=== "Node.js"
    ```javascript
    exports.handler = async (event) => {
      let data;
      try {
        data = typeof event.body === "string" ? JSON.parse(event.body) : event.body || {};
      } catch {
        return { status: 400, body: JSON.stringify({ error: "Invalid JSON" }) };
      }

      const name = (data.name || "").trim();
      if (!name) {
        return { status: 400, body: JSON.stringify({ error: "name is required" }) };
      }

      return {
        status: 201,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: 42, name, price: data.price || 0, created: true }),
      };
    };
    ```

=== "PHP"
    ```php
    <?php
    function handler($event) {
        $body = $event["body"] ?? "";
        $data = is_string($body) ? json_decode($body, true) : ($body ?: []);

        $name = trim($data["name"] ?? "");
        if ($name === "") {
            return ["status" => 400, "body" => json_encode(["error" => "name is required"])];
        }

        return [
            "status" => 201,
            "headers" => ["Content-Type" => "application/json"],
            "body" => json_encode(["id" => 42, "name" => $name, "price" => $data["price"] ?? 0, "created" => true]),
        ];
    }
    ```

=== "Go"
    ```go
    package main

    import "encoding/json"

    func handler(event map[string]interface{}) interface{} {
        bodyRaw, _ := event["body"].(string)
        var data map[string]interface{}
        if err := json.Unmarshal([]byte(bodyRaw), &data); err != nil {
            errBody, _ := json.Marshal(map[string]string{"error": "Invalid JSON"})
            return map[string]interface{}{"status": 400, "body": string(errBody)}
        }

        name, _ := data["name"].(string)
        if name == "" {
            errBody, _ := json.Marshal(map[string]string{"error": "name is required"})
            return map[string]interface{}{"status": 400, "body": string(errBody)}
        }

        price, _ := data["price"].(float64)
        body, _ := json.Marshal(map[string]interface{}{
            "id": 42, "name": name, "price": price, "created": true,
        })
        return map[string]interface{}{
            "status": 201, "headers": map[string]string{"Content-Type": "application/json"},
            "body": string(body),
        }
    }
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let body_str = event["body"].as_str().unwrap_or("{}");
        let data: Value = match serde_json::from_str(body_str) {
            Ok(v) => v,
            Err(_) => return json!({"status": 400, "body": r#"{"error":"Invalid JSON"}"#}),
        };

        let name = data["name"].as_str().unwrap_or("").trim().to_string();
        if name.is_empty() {
            return json!({"status": 400, "body": r#"{"error":"name is required"}"#});
        }

        let price = data["price"].as_f64().unwrap_or(0.0);
        json!({
            "status": 201,
            "headers": { "Content-Type": "application/json" },
            "body": serde_json::to_string(&json!({
                "id": 42, "name": name, "price": price, "created": true
            })).unwrap()
        })
    }
    ```

=== "Lua"
    ```lua
    local cjson = require("cjson")

    local function handler(event)
        local ok, data = pcall(cjson.decode, event.body or "")
        if not ok then
            return { status = 400, body = cjson.encode({ error = "Invalid JSON" }) }
        end

        local name = (data.name or ""):match("^%s*(.-)%s*$")
        if name == "" then
            return { status = 400, body = cjson.encode({ error = "name is required" }) }
        end

        return {
            status = 201,
            headers = { ["Content-Type"] = "application/json" },
            body = cjson.encode({ id = 42, name = name, price = data.price or 0, created = true }),
        }
    end

    return handler
    ```

### Quick reference: handler signature per runtime

| Runtime    | File ext | Entry point                                         | Param access (direct injection)        |
|------------|----------|------------------------------------------------------|----------------------------------------|
| **Python** | `.py`    | `def handler(event, id):`                            | `id` (injected as kwarg)               |
| **Node.js**| `.js`    | `exports.handler = async (event, { id }) => {}`      | `id` (destructured from 2nd arg)       |
| **PHP**    | `.php`   | `function handler($event, $params) {}`               | `$params["id"]`                        |
| **Go**     | `.go`    | `func handler(event map[string]interface{}) interface{}` | `event["params"].(map[string]interface{})["id"]` |
| **Rust**   | `.rs`    | `pub fn handler(event: Value) -> Value {}`           | `event["params"]["id"].as_str()`       |
| **Lua**    | `.lua`   | `local function handler(event, params) ... return handler` | `params.id`                      |

---

## Step 4: Run and Test

Start the dev server:

```bash
fastfn dev examples/functions/rest-api-methods
```

FastFN discovers the files, infers the routes, and starts serving. You will see log
output similar to:

```text
[routes] GET    /products         -> products/get.py (python)
[routes] POST   /products         -> products/post.py (python)
[routes] GET    /products/:id     -> products/[id]/get.py (python)
[routes] PUT    /products/:id     -> products/[id]/put.py (python)
[routes] DELETE /products/:id     -> products/[id]/delete.py (python)
```

Now test with curl:

```bash
# List products
curl http://127.0.0.1:8080/products
# {"products":[{"id":1,"name":"Widget","price":9.99},{"id":2,"name":"Gadget","price":24.99}],"total":2}

# Create a product
curl -X POST http://127.0.0.1:8080/products \
  -H "Content-Type: application/json" \
  -d '{"name":"Widget","price":9.99}'
# {"id":42,"name":"Widget","price":9.99,"created":true}

# Get one product
curl http://127.0.0.1:8080/products/42
# {"id":42,"name":"Widget","price":9.99}

# Update a product
curl -X PUT http://127.0.0.1:8080/products/42 \
  -H "Content-Type: application/json" \
  -d '{"name":"Updated Widget","price":12.99}'
# {"id":42,"name":"Updated Widget","price":12.99,"updated":true}

# Delete a product
curl -X DELETE http://127.0.0.1:8080/products/42
# {"id":42,"deleted":true}
```

Each curl hits a different file. Each file returns its own response. No method
dispatching needed.

---

## Step 5: Check the Auto-Generated OpenAPI

FastFN generates an OpenAPI 3.0 spec from the discovered routes. Fetch it at:

```bash
curl http://127.0.0.1:8080/_fn/openapi.json | python3 -m json.tool
```

The output includes the correct HTTP method for each path:

```json
{
  "openapi": "3.0.0",
  "info": { "title": "FastFN API", "version": "1.0.0" },
  "paths": {
    "/products": {
      "get": {
        "operationId": "get_products",
        "summary": "products/get.py",
        "responses": { "200": { "description": "OK" } }
      },
      "post": {
        "operationId": "post_products",
        "summary": "products/post.py",
        "responses": { "200": { "description": "OK" } }
      }
    },
    "/products/{id}": {
      "get": {
        "operationId": "get_products_id",
        "summary": "products/[id]/get.py",
        "parameters": [
          { "name": "id", "in": "path", "required": true, "schema": { "type": "string" } }
        ],
        "responses": { "200": { "description": "OK" } }
      },
      "put": {
        "operationId": "put_products_id",
        "summary": "products/[id]/put.py",
        "responses": { "200": { "description": "OK" } }
      },
      "delete": {
        "operationId": "delete_products_id",
        "summary": "products/[id]/delete.py",
        "responses": { "200": { "description": "OK" } }
      }
    }
  }
}
```

This spec is generated entirely from the filesystem. You can point Swagger UI, Redoc,
or any OpenAPI-compatible tool at `/_fn/openapi.json` and get a live, accurate
reference for your API.

---

## Deep Nesting: API Versioning

File-based routing supports up to **6 levels** of directory nesting. This is useful
for versioned APIs where the version prefix is part of the URL path.

Consider this structure:

```text
versioned-api/
  api/
    v1/
      users/
        index.js        GET /api/v1/users
        [id].js         GET /api/v1/users/:id
      health/
        index.py        GET /api/v1/health
    v2/
      users/
        index.js        GET /api/v2/users
        [id].js         GET /api/v2/users/:id
```

Here `api/v1/users/index.js` maps to `GET /api/v1/users` and
`api/v2/users/[id].js` maps to `GET /api/v2/users/:id`. Each version is an
independent directory subtree.

### v1 handler (minimal response)

```javascript
exports.handler = function(event) {
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      version: "v1",
      users: [
        { id: 1, name: "Alice" },
        { id: 2, name: "Bob" },
      ],
    }),
  };
};
```

### v2 handler (extended response with pagination)

```javascript
exports.handler = function(event) {
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      version: "v2",
      data: {
        users: [
          { id: 1, name: "Alice", email: "alice@example.com" },
          { id: 2, name: "Bob", email: "bob@example.com" },
        ],
        total: 2,
        page: 1,
      },
    }),
  };
};
```

Both versions coexist in the same project. You can also mix runtimes: the health
check is in Python while the user endpoints are in Node. FastFN infers the runtime
from the file extension.

### Why this works well

- **Incremental migration.** Ship v2 endpoints one at a time while v1 stays live.
- **Independent deployment.** Changing `api/v2/users/index.js` does not touch any v1
  file.
- **Clear boundaries.** Each version directory is self-contained. No shared routing
  tables to update.

---

## How It Looks in the FastFN Cloud Dashboard

If you use the FastFN Cloud dashboard, navigate to your project and open the
**Config** tab. The **Detected Routes** section shows every discovered route with:

- The HTTP method displayed as a color-coded badge (green for GET, blue for POST,
  orange for PUT, red for DELETE).
- The URL path.
- The source file that handles the route.
- The inferred runtime (Python, Node, etc.).

This gives you an instant visual overview of your entire API surface. When you add a
new method file and refresh, the dashboard picks it up automatically during the next
scan cycle.

---

## Single Handler vs Method Files: When to Use Which

Both patterns are valid in FastFN. The choice depends on the complexity of the
endpoint.

| Aspect             | Single Handler (`index.py`)           | Method Files (`get.py`, `post.py`, ...) |
|--------------------|----------------------------------------|------------------------------------------|
| **Best for**       | Simple functions, webhooks, one-method endpoints | REST APIs, CRUD resources, multi-method endpoints |
| **Code organization** | All methods in one file             | One file per method                      |
| **Readability**    | Clean for 1-2 methods; gets messy at 4+ | Each file is focused and short           |
| **Testing**        | Must test all method branches together | Test each file independently             |
| **Code review**    | Changes to one method show all methods in diff | Only the changed method file appears     |
| **Permissions**    | Auth logic mixed with all methods     | Can apply different middleware per method |
| **OpenAPI output** | One operation per path                | Separate operations per method per path  |

**Rule of thumb:** if your endpoint handles more than two HTTP methods, split into
method files. If it only handles GET (or a single webhook POST), a single handler
file is simpler.

### Mixed approach

You can mix both styles in the same project. Some routes use `index.py` (single
handler), while others use `get.py` / `post.py` (method files). FastFN resolves
both conventions with the same routing engine.

---

## Common Patterns

### Shared utilities

If multiple method handlers need the same logic (database connection, auth check),
create a shared module:

```text
products/
  _helpers.py        (ignored by router -- starts with _)
  get.py
  post.py
  [id]/
    get.py
    put.py
    delete.py
```

Files starting with `_` are ignored by the route scanner. Import them normally:

```python
# products/post.py
from products._helpers import validate_product, get_db

def handler(event):
    ...
```

### Static and dynamic on the same level

You can combine static and dynamic segments:

```text
users/
  index.js           GET /users
  me.js              GET /users/me
  [id].js            GET /users/:id
```

FastFN gives static routes higher precedence than dynamic ones, so `/users/me` will
always match `me.js` rather than `[id].js`.

---

## Summary

- **One file per method** eliminates method-dispatch boilerplate and keeps each
  handler focused, testable, and easy to review.
- **Directories define paths**, brackets define parameters. No config needed.
- **OpenAPI is auto-generated** from the filesystem, with correct methods per path.
- **Deep nesting** (up to 6 levels) supports versioned APIs and complex URL
  hierarchies.
- **Mix and match**: use single handlers for simple endpoints, method files for CRUD,
  and shared `_helpers` modules for common logic.

The complete working examples are available at:

- `examples/functions/rest-api-methods/` -- CRUD products API
- `examples/functions/versioned-api/` -- versioned API with deep nesting

Clone the repo, run `fastfn dev`, and start building.

## Key takeaway

Use one file per HTTP method when a resource has multiple operations. The folder tree becomes the API map, and each handler stays short enough to understand in one read.

## What to keep in mind

- Static routes win over dynamic segments, so `me.js` beats `[id].js`.
- `_helpers` files are ignored by the router and are the right place for shared code.
- A single `index.*` handler is still a good fit for simple one-method endpoints or webhooks.

## When to choose another layout

- Use method files for CRUD-style resources with three or more operations.
- Use one handler file when the route only has one method and very little branching.
- Use explicit route config only when you need to preserve a legacy URL shape that the folder layout does not express cleanly.

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
