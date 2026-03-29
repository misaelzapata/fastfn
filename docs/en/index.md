---
hide:
  - toc
---

<style>
.md-content .md-typeset h1 { display: none; }
</style>

<p align="center">
  <img src="../logo.png" alt="FastFN Logo" width="180">
</p>
<p align="center">
    <em>Self-hosted FaaS platform, high performance, easy to learn, fast to code</em>
</p>
<p align="center">
<a href="https://github.com/misaelzapata/fastfn" target="_blank">
    <img src="https://img.shields.io/badge/GitHub-misaelzapata%2Ffastfn-181717?logo=github&logoColor=white" alt="GitHub">
</a>
<a href="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml" target="_blank">
    <img src="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml/badge.svg" alt="Docs">
</a>
<a href="https://codecov.io/gh/misaelzapata/fastfn" target="_blank">
    <img src="https://codecov.io/gh/misaelzapata/fastfn/graph/badge.svg" alt="Coverage">
</a>
</p>

<hr />
<p><strong>Documentation</strong>: <a href="https://fastfn.dev/en/" target="_blank">https://fastfn.dev/en/</a></p>
<p><strong>Source Code</strong>: <a href="https://github.com/misaelzapata/fastfn" target="_blank">https://github.com/misaelzapata/fastfn</a></p>
<hr />

<p>FastFN is a CLI-friendly, self-hosted FaaS server for building file-routed APIs, shipping SPA + API stacks, and keeping the whole project easy to run locally or on a VM.</p>

<p>The key features are:</p>
<ul>
<li><strong>Fast to code</strong>: Drop a file, get an endpoint, and keep the route tree close to the code that serves it.</li>
<li><strong>Automatic Docs</strong>: Interactive API documentation (Swagger UI) generated automatically from your code.</li>
<li><strong>Polyglot Power</strong>: Use the best tool for the job. Python, Node, PHP, Lua, Rust, or Go in one project.</li>
<li><strong>SPA + API</strong>: Mount a configurable <code>public/</code> or <code>dist/</code> folder at <code>/</code> and keep simple API handlers beside it.</li>
</ul>

<p align="center">
  <img src="../demo.gif" alt="FastFN terminal demo" width="100%">
</p>

<p align="center">
  <a href="./tutorial/first-steps.md"><strong>Quick Start</strong></a>
  &bull;
  <a href="./tutorial/spa-and-api-together.md"><strong>SPA + API</strong></a>
  &bull;
  <a href="./how-to/run-as-a-linux-service.md"><strong>Linux Service</strong></a>
  &bull;
  <a href="./articles/cloudflare-style-public-assets.md"><strong>Public Assets</strong></a>
</p>

## What you get in the first 5 minutes

- Create one function file and serve it locally.
- Call the route immediately with `curl`.
- Open automatic docs at `http://127.0.0.1:8080/docs`.
- Keep scaling the same API with Python, Node, PHP, Lua, and Rust under one URL tree.
- Serve a simple SPA and a tiny API together when that is the better fit.

## 5-minute path (recommended order)

1. Tutorial: [Quick Start](./tutorial/first-steps.md)
2. Tutorial: [Serve a SPA and API Together](./tutorial/spa-and-api-together.md)
3. How-to: [Zero-Config Routing](./how-to/zero-config-routing.md)
4. Reference: [HTTP API definition](./reference/http-api.md)
5. Article: [Cloudflare-Style Public Assets](./articles/cloudflare-style-public-assets.md)
6. How-to: [Run as a Linux Service](./how-to/run-as-a-linux-service.md)

If you are reading this page on GitHub and a styled card below does not resolve correctly, use these direct links:

- [Quick Start](https://fastfn.dev/en/tutorial/first-steps/)
- [Serve a SPA and API Together](https://fastfn.dev/en/tutorial/spa-and-api-together/)
- [Zero-Config Routing](https://fastfn.dev/en/how-to/zero-config-routing/)
- [HTTP API definition](https://fastfn.dev/en/reference/http-api/)
- [Cloudflare-Style Public Assets](https://fastfn.dev/en/articles/cloudflare-style-public-assets/)
- [Run as a Linux Service](https://fastfn.dev/en/how-to/run-as-a-linux-service/)

## Start in 60 seconds

### 1. Drop a file, get an endpoint

Create a file named `hello.js` (or `.py`, `.php`, `.rs`):

=== "Node.js"
    ```js
    // hello.js
    exports.handler = async (event) => ({
      message: 'Hello from FastFN!',
      query: event.query || {},
      runtime: 'node',
    });
    ```

=== "Python"
    ```python
    # hello.py
    def handler(event):
        name = event.get("query", {}).get("name", "World")
        return {
            "status": 200,
            "body": {"hello": name, "runtime": "python"}
        }
    ```

### 2. Run the server

```bash
fastfn dev
```

### 3. Call your API

```bash
curl "http://127.0.0.1:8080/hello?name=Misael"
```

Expected response:

```json
{
    "message": "Hello from FastFN!",
    "query": {
        "name": "Misael"
    },
    "runtime": "node"
}
```

No `serverless.yml`. No framework boilerplate. File routes are discovered automatically.

### 4. Open the generated docs

- Swagger UI: `http://127.0.0.1:8080/docs`
- OpenAPI JSON: `http://127.0.0.1:8080/openapi.json`

If you want the shortest path from zero to production-like usage, go in this order:

1. [Quick Start](./tutorial/first-steps.md)
2. [From Zero](./tutorial/from-zero/index.md)
3. [HTTP API definition](./reference/http-api.md)
4. [Deploy to Production](./how-to/deploy-to-production.md)

## Documentation

This documentation is structured to help you learn FastFN step-by-step, from your first route to production deployment.

<div class="grid cards" markdown>

-   **Getting Started**
    
    Install FastFN and build your first API endpoint in 5 minutes.
    
    [Quick Start](./tutorial/first-steps.md)

-   **Core Concepts**
    
    Understand how file-system routing and configuration work.
    
    [File-System Routing](./tutorial/routing.md)

-   **Support Matrix**
    
    See what FastFN gives you out of the box and where it fits best.
    
    [Explore Support Matrix](./explanation/support-matrix-advanced-protocols.md)

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
*   [Serve a SPA and API Together](./tutorial/spa-and-api-together.md)
*   [Cloudflare-Style Public Assets](./articles/cloudflare-style-public-assets.md)
*   [Run as a Linux Service](./how-to/run-as-a-linux-service.md)
*   [Runtime Contract](./reference/runtime-contract.md)
*   [Typed Inputs and Responses](./tutorial/typed-inputs-and-responses.md)
*   [Built-in Functions](./reference/builtin-functions.md)
*   [Support Matrix (Advanced Protocols)](./explanation/support-matrix-advanced-protocols.md)
*   [Operational Recipes](./how-to/operational-recipes.md)
*   [Security Confidence Checklist](./how-to/security-confidence.md)

## Extended Tutorials

*   [Build a complete API (end-to-end)](./tutorial/build-complete-api.md)
*   [QR patterns in Python + Node + PHP + Lua (dependency isolation)](./tutorial/qr-in-python-node.md)
*   [Versioning and rollout](./tutorial/versioning-and-rollout.md)
*   [Auth and secrets](./tutorial/auth-and-secrets.md)

## Visual Guides

*   [Visual flows](./explanation/visual-flows.md)
