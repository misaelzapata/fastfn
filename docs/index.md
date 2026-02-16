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
    <a href="./fastfn-landing.html">Marketing Landing</a>
    ·
    <a href="./en/index.md">English Docs</a>
    ·
    <a href="./es/index.md">Documentación en Español</a>
  </p>
</div>

<p align="center">
  <a href="https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/misaelzapata/fastfn/ci.yml?branch=main&label=CI&logo=github" alt="CI" /></a>
  <img src="https://img.shields.io/badge/OpenAPI-3.1-6BA539?logo=openapiinitiative&logoColor=white" alt="OpenAPI" />
  <img src="https://img.shields.io/badge/runtimes-python%20%7C%20node%20%7C%20php%20%7C%20rust%20%7C%20go-0A7EA4" alt="Runtimes" />
</p>

## Start in 60 seconds

1. Create `functions/my-api/get.py`
2. Run `fastfn dev functions`
3. Call `GET /my-api`

```python
# functions/my-api/get.py
def main(req):
    return {"message": "Hello from FastFN"}
```

```bash
curl -sS http://127.0.0.1:8080/my-api
```

No container build. No registry push. No route YAML.

## Multi-language from the first page

=== "Python"

    ```python
    # functions/hello/get.py
    def main(req):
        name = (req.get("query") or {}).get("name", "World")
        return {"hello": name}
    ```

=== "Node.js"

    ```javascript
    // functions/hello/get.js
    exports.main = async (req) => {
      const name = (req.query || {}).name || "World";
      return { hello: name };
    };
    ```

=== "PHP"

    ```php
    <?php
    function main($req) {
      $query = isset($req["query"]) ? $req["query"] : [];
      $name = isset($query["name"]) ? $query["name"] : "World";
      return ["hello" => $name];
    }
    ```

=== "Rust (Experimental)"

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
            "headers": { "Content-Type": "application/json" },
            "body": json!({ "hello": name }).to_string()
        })
    }
    ```

## Where to go next

- New users: [English docs](./en/index.md)
- Usuarios en español: [Documentación en español](./es/index.md)
- Full marketing landing: [FastFN landing](./fastfn-landing.html)
