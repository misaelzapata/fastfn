---
hide:
  - navigation
  - toc
---

<div align="center">
  <img src="./logo.PNG" alt="FastFN logo" width="170" />
  <h1>FastFN</h1>
  <p><strong>Drop code. Get endpoints.</strong><br/>Polyglot runtimes, OpenAPI by default, production gateway.</p>
  <p>
    <a href="https://github.com/misaelzapata/fastfn">GitHub</a>
    ·
    <a href="./fastfn-landing.html">Marketing Landing</a>
    ·
    <a href="./en/index.md">English Docs</a>
    ·
    <a href="./es/index.md">Documentación en Español</a>
  </p>
</div>

<p align="center">
  <a href="https://github.com/misaelzapata/fastfn"><img src="https://img.shields.io/badge/GitHub-misaelzapata%2Ffastfn-181717?logo=github&logoColor=white" alt="GitHub" /></a>
  <a href="https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/misaelzapata/fastfn/ci.yml?branch=main&label=CI&logo=github" alt="CI" /></a>
  <a href="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml"><img alt="Docs" src="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml/badge.svg" /></a>
  <a href="https://codecov.io/gh/misaelzapata/fastfn"><img alt="Coverage" src="https://codecov.io/gh/misaelzapata/fastfn/graph/badge.svg" /></a>
  <img src="https://img.shields.io/badge/OpenAPI-3.1-6BA539?logo=openapiinitiative&logoColor=white" alt="OpenAPI" />
  <img src="https://img.shields.io/badge/runtimes-python%20%7C%20node%20%7C%20php%20%7C%20lua%20(%2B%20rust%2C%20go%20experimental)-0A7EA4" alt="Runtimes" />
</p>

## Start in 60 seconds

### Option A: Run the demo app from this repo

```bash
bin/fastfn dev examples/functions/next-style
```

Then open:

- `http://127.0.0.1:8080/showcase`
- `http://127.0.0.1:8080/docs`

### Option B: Drop a file, get an endpoint

1. Create `hello.js`
2. Run `fastfn dev .`
3. Call `GET /hello`

```js
// hello.js
exports.handler = async (event) => ({
  message: 'Hello from FastFN!',
  query: event.query || {},
  runtime: 'node',
});
```

```bash
curl -sS 'http://127.0.0.1:8080/hello?name=World'
```

No `serverless.yml`. No framework boilerplate. File routes are discovered automatically.

Next:

- Example catalog: [Example Function Catalog](./en/reference/builtin-functions.md)
- Routing rules: [Zero-Config Routing](./en/how-to/zero-config-routing.md)

## Install

```bash
brew tap misaelzapata/homebrew-fastfn
brew install fastfn
```

More: [Install and Release (Homebrew)](./en/how-to/homebrew.md)

## Multi-language from the first page

### Python

```python
# hello.py
import json

def handler(event):
    query = event.get("query") or {}
    name = query.get("name", "World")
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"hello": name, "runtime": "python"}),
    }
```

### Node.js

```js
// hello.js
exports.handler = async (event) => ({
  hello: (event.query || {}).name || 'World',
  runtime: 'node',
});
```

### PHP

```php
<?php
function handler(array $event): array {
  $query = $event["query"] ?? [];
  $name = $query["name"] ?? "World";
  return [
    "status" => 200,
    "headers" => ["Content-Type" => "application/json"],
    "body" => json_encode(["hello" => $name, "runtime" => "php"], JSON_UNESCAPED_SLASHES),
  ];
}
```

### Lua

```lua
local cjson = require("cjson.safe")

function handler(event)
  local query = event.query or {}
  local name = query.name or "World"
  return {
    status = 200,
    headers = { ["Content-Type"] = "application/json" },
    body = cjson.encode({ hello = name, runtime = "lua" }),
  }
end
```

### Rust (Experimental)

```rust
use serde_json::{json, Value};

pub fn handler(event: Value) -> Value {
    let name = event
        .get("query")
        .and_then(|q| q.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("World");

    json!({
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json!({ "hello": name, "runtime": "rust" }).to_string()
    })
}
```

## Where to go next

- New users: [English docs](./en/index.md)
- Usuarios en español: [Documentación en español](./es/index.md)
- File routing rules: [Zero-Config Routing](./en/how-to/zero-config-routing.md)
- Full marketing landing: [FastFN landing](./fastfn-landing.html)

---

Note: Rust and Go are experimental and require explicit opt-in via `FN_RUNTIMES`.
