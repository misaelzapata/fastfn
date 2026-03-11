---
hide:
  - toc
---

<style>
.md-content .md-typeset h1 { display: none; }
</style>

<p align="center">
  <img src="../logo.PNG" alt="FastFN Logo" width="180">
</p>
<p align="center">
    <em>FastFN framework, high performance, easy to learn, fast to code, ready for production</em>
</p>
<p align="center">
<a href="https://github.com/misaelzapata/fastfn" target="_blank">
    <img src="https://img.shields.io/badge/GitHub-misaelzapata%2Ffastfn-181717?logo=github&logoColor=white" alt="GitHub">
</a>
<a href="https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml" target="_blank">
    <img src="https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml" target="_blank">
    <img src="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml/badge.svg" alt="Docs">
</a>
<a href="https://codecov.io/gh/misaelzapata/fastfn" target="_blank">
    <img src="https://codecov.io/gh/misaelzapata/fastfn/graph/badge.svg" alt="Coverage">
</a>
</p>

<hr />
<p><strong>Documentation</strong>: <a href="./index.md" target="_blank">https://misaelzapata.github.io/fastfn/en/</a></p>
<p><strong>Source Code</strong>: <a href="https://github.com/misaelzapata/fastfn" target="_blank">https://github.com/misaelzapata/fastfn</a></p>
<hr />

> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

<p>FastFN is a modern, fast (high-performance), serverless framework for building APIs with multiple languages based on file-system routing.</p>

<p>The key features are:</p>
<ul>
<li><strong>Fast to code</strong>: Increase the speed to develop features by about 200% to 300%. Drop a file, get an endpoint.</li>
<li><strong>Automatic Docs</strong>: Interactive API documentation (Swagger UI) generated automatically from your code.</li>
<li><strong>Polyglot Power</strong>: Use the best tool for the job. AI in Python, IO in Node, glue logic in Lua, performance in Rust.</li>
</ul>

## Start in 60 seconds

### 1. Drop a file, get an endpoint

Create a file named `hello.js` (or `.py`, `.php`, `.rs`):

=== "Node.js"
    ```js
    // hello.js
    exports.handler = async () => "Hello World";
    ```

=== "Python"
    ```python
    # hello.py
    def handler(event):
        return {"hello": "world"}
    ```

=== "PHP"
    ```php
    <?php
    function handler($event) {
        return "Hello World";
    }
    ```

=== "Lua"
    ```lua
    function handler(event)
      return { hello = "world" }
    end
    ```

=== "Go"
    ```go
    package main

    func handler(event map[string]interface{}) map[string]interface{} {
        return map[string]interface{}{
            "status": 200,
            "body": "Hello World",
        }
    }
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn handler(_event: Value) -> Value {
        json!({
            "status": 200,
            "body": "Hello World"
        })
    }
    ```

### 2. Run the server

```bash
fastfn dev
```

### 3. Call your API

<p align="center">
  <img src="../assets/screenshots/browser-hello-world.png" alt="FastFN full browser view for /hello" width="100%">
</p>

<p align="center">
  <img src="../demo.gif" alt="FastFN Terminal Demo" width="100%">
</p>

No `serverless.yml`. No framework boilerplate. File routes are discovered automatically.

## Documentation

This documentation is structured to help you learn FastFN step-by-step, from your first route to production deployment.

<div class="grid cards" markdown>

-   **Getting Started**
    
    Install FastFN and build your first API endpoint in 5 minutes.
    
    [Quick Start](./tutorial/first-steps.md)

-   **Core Concepts**
    
    Understand how file-system routing and configuration work.
    
    [File-System Routing](./tutorial/routing.md)

-   **Learn (The Course)**
    
    A complete 4-part course to build a real-world API from scratch.
    
    [Start the Course](./tutorial/from-zero/index.md)

-   **How-To Guides**
    
    Practical recipes for deployment, authentication, and more.
    
    [See Guides](./how-to/deploy-to-production.md)

</div>

## Key Features

*   **Magic Routing**: `[id]`, `[...slug]` supported out of the box.
*   **Low overhead gateway**: OpenResty validates policy and dispatches over local unix sockets.
*   **Standards Based**: Fully compliant OpenAPI 3.1 generation for all your functions.
*   **Developer First**: The platform adapts to your files, not the other way around.
*   **Multi-Runtime**: Python, Node, PHP, Lua, and Rust with one contract.

## Quick Links

*   [HTTP API definition](./reference/http-api.md)
*   [Runtime Contract](./reference/runtime-contract.md)
*   [Built-in Functions](./reference/builtin-functions.md)
*   [Operational Recipes](./how-to/operational-recipes.md)
*   [Security Confidence Checklist](./how-to/security-confidence.md)

## Extended Tutorials

*   [Build a complete API (end-to-end)](./tutorial/build-complete-api.md)
*   [QR patterns in Python + Node + PHP + Lua (dependency isolation)](./tutorial/qr-in-python-node.md)
*   [Versioning and rollout](./tutorial/versioning-and-rollout.md)
*   [Auth and secrets](./tutorial/auth-and-secrets.md)

## Visual Guides

*   [Visual flows](./explanation/visual-flows.md)

## See also

- [Function Specification](reference/function-spec.md)
- [HTTP API Reference](reference/http-api.md)
- [Run and Test Checklist](how-to/run-and-test.md)
