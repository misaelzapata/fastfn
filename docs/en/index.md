<div class="hero-section">
  <h1 class="hero-title">FastFN</h1>
  <p class="hero-subtitle">
    FastFN web framework.<br>
    High performance, easy to learn, fast to code, ready for production.
  </p>
  <div class="hero-actions">
    <a href="./tutorial/first-steps/" class="btn-primary">Get Started →</a>
    <a href="https://github.com/misaelzapata/fastfn" class="btn-secondary">Star on GitHub</a>
  </div>
  <div class="hero-badges" markdown>
  [![GitHub](https://img.shields.io/badge/GitHub-misaelzapata%2Ffastfn-181717?logo=github&logoColor=white)](https://github.com/misaelzapata/fastfn)
  [![CI](https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml/badge.svg)](https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml)
  [![Docs](https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml/badge.svg)](https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml)
  [![Coverage](https://codecov.io/gh/misaelzapata/fastfn/graph/badge.svg)](https://codecov.io/gh/misaelzapata/fastfn)
  </div>
</div>

<div class="feature-grid">
  <div class="feature-card">
    <h3>⚡️ Fast to Code</h3>
    <p>Increase the speed to develop features by about 200% to 300%. Drop a file, get an endpoint.</p>
  </div>
  <div class="feature-card">
    <h3>📂 Automatic Docs</h3>
    <p>Interactive API documentation (Swagger UI) generated automatically from your code.</p>
  </div>
  <div class="feature-card">
    <h3>🌐 Polyglot Power</h3>
    <p>Use the best tool for the job. AI in Python, IO in Node, glue logic in Lua, performance in Rust.</p>
  </div>
</div>

!!! tip "Philosophy"
    **FastFN** brings the "Vercel experience" to your own servers. 
    Drop a file, get an endpoint. Zero config. Null boilerplate.

## Documentation

This documentation follows the strict **[Diátaxis](https://diataxis.fr/)** framework.

<div class="grid cards" markdown>

-   :material-school: **Tutorials**
    
    Start here. Step-by-step lessons to build your first API.
    
    [Start Learning :arrow_right:](./tutorial/first-steps.md)

-   :material-compass-outline: **How-To Guides**
    
    Solve specific problems. "How do I add auth?", "How do I deploy?".
    
    [See Recipes :arrow_right:](./how-to/operational-recipes.md)

-   :material-book-open-page-variant: **Reference**
    
    Technical details. Config schemas, CLI commands, and contracts.
    
    [Browse API :arrow_right:](./reference/http-api.md)

-   :material-text-box-search-outline: **Explanation**
    
    Understand the architecture. Why processes? Why not containers?
    
    [Read Design :arrow_right:](./explanation/architecture.md)

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
