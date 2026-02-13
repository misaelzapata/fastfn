# Welcome to fastfn

!!! info "Philosophy"
    **fastfn** is designed to be the fastest path from code to an HTTP endpoint: drop a handler file, hit `/fn/<name>`.

This documentation follows the strict **[Diátaxis](https://diataxis.fr/)** framework to ensure you find exactly what you need, when you need it.

<div class="grid cards" markdown>

-   :material-school: **Tutorials**
    
    Start here if you are new. Step-by-step lessons to get you running.
    
    [Start Here :arrow_right:](./tutorial/first-steps.md)

-   :material-compass-outline: **How-To Guides**
    
    Practical, task-focused recipes for real operational needs.
    
    [See Guides :arrow_right:](./how-to/run-and-test.md)

-   :material-book-open-page-variant: **Reference**
    
    Technical descriptions of APIs, contracts, and configurations.
    
    [Browse Reference :arrow_right:](./reference/http-api.md)

-   :material-text-box-search-outline: **Explanation**
    
    Deep dives into the architecture, design choices, and "Why".
    
    [Read Explanations :arrow_right:](./explanation/architecture.md)

</div>

## Key Features

*   **Low overhead gateway**: OpenResty validates policy and dispatches over local unix sockets.
*   **Standards Based**: Fully compliant OpenAPI 3.1 generation for all your functions.
*   **Developer First**: The platform adapts to your files, not the other way around.
*   **Multi-Runtime**: Python, Node, PHP, and Rust with one contract.

## Quick Links

*   [HTTP API definition](./reference/http-api.md)
*   [Runtime Contract](./reference/runtime-contract.md)
*   [Built-in Functions](./reference/builtin-functions.md)
*   [Operational Recipes](./how-to/operational-recipes.md)

## Extended Tutorials

*   [Build a complete API (end-to-end)](./tutorial/build-complete-api.md)
*   [QR in Python + Node (dependency isolation)](./tutorial/qr-in-python-node.md)
*   [Versioning and rollout](./tutorial/versioning-and-rollout.md)
*   [Auth and secrets](./tutorial/auth-and-secrets.md)

## Visual Guides

*   [Visual flows](./explanation/visual-flows.md)
