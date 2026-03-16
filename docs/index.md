---
hide:
  - toc
---

<style>
.md-content .md-typeset h1 { display: none; }
</style>

<p align="center">
  <img src="logo.PNG" alt="FastFN Logo" width="180">
</p>
<p align="center">
    <em>FastFN framework, high performance, easy to learn, fast to code</em>
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
<p><strong>Documentation</strong>: <a href="./en/index.md" target="_blank">https://misaelzapata.github.io/fastfn/en/</a></p>
<p><strong>Source Code</strong>: <a href="https://github.com/misaelzapata/fastfn" target="_blank">https://github.com/misaelzapata/fastfn</a></p>
<hr />

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
  <img src="assets/screenshots/browser-hello-world.png" alt="FastFN full browser view for /hello" width="100%">
</p>

<p align="center">
  <img src="demo.gif" alt="FastFN Terminal Demo" width="100%">
</p>

No `serverless.yml`. No framework boilerplate. File routes are discovered automatically.

## Where to go next

<div class="grid cards" markdown>

-   **Documentation**
    
    Start learning FastFN step-by-step.
    
    [Read the Docs](./en/index.md)

</div>
