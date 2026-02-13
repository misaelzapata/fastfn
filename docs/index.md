---
hide:
  - navigation
  - toc
---

<div class="hero-section">
  <div class="hero-content">
    <h1 class="hero-title">fastfn</h1>
    <p class="hero-subtitle">The zero-friction serverless platform. <br>Drop code. Run anywhere.</p>
    
    <div class="hero-buttons">
      <a href="./en/" class="btn btn-primary">
         Get Started 
      </a>
      <a href="https://github.com/misaelzapata/fastfn" class="btn btn-secondary">
        View on GitHub
      </a>
    </div>

    <div class="hero-badges">
      <a href="https://github.com/misaelzapata/fastfn/actions">
        <img src="https://img.shields.io/github/actions/workflow/status/misaelzapata/fastfn/ci.yml?branch=main&label=CI&logo=github" alt="CI Status" />
      </a>
      <a href="https://codecov.io/gh/misaelzapata/fastfn">
        <img src="https://codecov.io/gh/misaelzapata/fastfn/graph/badge.svg" alt="Coverage" />
      </a>
      <a href="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml">
        <img src="https://img.shields.io/github/actions/workflow/status/misaelzapata/fastfn/docs.yml?branch=main&label=Docs&logo=github" alt="Docs Status" />
      </a>
      <img src="https://img.shields.io/badge/OpenResty-1.27.1.2-orange?logo=nginx" alt="OpenResty" />
      <img src="https://img.shields.io/badge/Python-3.x-3776AB?logo=python&logoColor=white" alt="Python" />
      <img src="https://img.shields.io/badge/Node.js-18%2B-339933?logo=nodedotjs&logoColor=white" alt="Node.js" />
      <img src="https://img.shields.io/badge/license-MIT-green" alt="License" />
    </div>
  </div>
</div>

## 🚀 Why fastfn is different?

Other FaaS platforms (OpenFaaS, Knative) require Kubernetes, Docker builds, and complex YAML. **fastfn is just files.**

1.  **Create** `srv/fn/functions/python/my-api/app.py`
2.  **Call** `GET /fn/my-api`
3.  **Done.**

No build step. No registry push. No per-request runtime spawn by default.

---

## ⚡️ Multi-Language Support

Write in your favorite language. The contract is simple: receive a JSON `event`, return `{status, headers, body}`.

=== "Python"

    ```python
    # srv/fn/functions/python/hello/app.py
    def handler(event):
        name = event.get("query", {}).get("name", "World")
        return {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": '{"hello":"%s"}' % name
        }
    ```

=== "Node.js"

    ```javascript
    // srv/fn/functions/node/hello/app.js
    exports.handler = async (event) => {
      const query = event.query || {};
      const name = query.name || "World";
      return {
        status: 200,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ hello: name }),
      };
    };
    ```

=== "Rust (Experimental)"

    ```rust
    // srv/fn/functions/rust/hello/app.rs
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let name = event
            .get("query")
            .and_then(|q| q.get("name"))
            .and_then(|v| v.as_str())
            .unwrap_or("world");

        json!({
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json!({ "hello": name }).to_string()
        })
    }
    ```

=== "PHP (Experimental)"

    ```php
    // srv/fn/functions/php/hello/app.php
    function handler($event) {
        $name = ($event["query"]["name"] ?? "world");
        return [
          "status" => 200,
          "headers" => ["Content-Type" => "application/json"],
          "body" => json_encode(["hello" => $name]),
        ];
    }
    ```

---

## 🛠 Real-World Use Cases

What can you build with **fastfn**?

<div class="grid cards" markdown>

-   **Dynamic QR Generator**
    
    Generate QR codes from Python and Node with per-function dependency installs.
    
    [View Tutorial :arrow_right:](./en/tutorial/qr-in-python-node.md)

-   **PDF Invoicing** (Coming Soon)
    
    Render dynamic PDFs using HTML templates or PDF libraries.

-   **Data Processing**
    
    Accept webhooks (Stripe, Slack), transform payload, and save to database.

</div>

---

<div class="grid cards" markdown>

-   <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" class="card-icon" fill="currentColor"><path d="M7,2V13H10V22L17,10H14V2H7Z" /></svg>
    **Instant Hot-Reload**

    Edit `app.py`, `app.js`, `app.php`, or `app.rs` and see changes immediately. <br>
    **No build steps, no container rebuilds.** Just code and save.

-   <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" class="card-icon" fill="currentColor"><path d="M12,1L3,5V11C3,16.55 6.84,21.74 12,23C17.16,21.74 21,16.55 21,11V5L12,1M12,11.99H7V10.99H12V5.5L17,10.99L12,16.49V11.99Z" /></svg>
    **Enterprise Security**

    Built-in protection against path traversal, symlinks, and resource exhaustion.
    **Defense-in-depth architecture** ready for production.

-   <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" class="card-icon" fill="currentColor"><path d="M12,2A10,10 0 0,0 2,12C2,16.42 4.87,20.17 8.84,21.5C9.34,21.58 9.5,21.27 9.5,21C9.5,20.77 9.5,20.14 9.5,19.31C6.73,19.91 6.14,17.97 6.14,17.97C5.68,16.81 5.03,16.5 5.03,16.5C4.12,15.88 5.1,15.9 5.1,15.9C6.1,15.97 6.63,16.93 6.63,16.93C7.5,18.45 8.97,18 9.54,17.76C9.63,17.11 9.89,16.67 10.17,16.42C7.95,16.17 5.62,15.31 5.62,11.5C5.62,10.39 6,9.5 6.65,8.79C6.55,8.54 6.2,7.5 6.75,6.15C6.75,6.15 7.59,5.88 9.5,7.17C10.29,6.95 11.15,6.84 12,6.84C12.85,6.84 13.71,6.95 14.5,7.17C16.41,5.88 17.25,6.15 17.25,6.15C17.8,7.5 17.45,8.54 17.35,8.79C18,9.5 18.38,10.39 18.38,11.5C18.38,15.32 16.04,16.16 13.81,16.41C14.17,16.72 14.5,17.33 14.5,18.26C14.5,19.6 14.5,20.68 14.5,21C14.5,21.27 14.66,21.59 15.17,21.5C19.14,20.16 22,16.42 22,12A10,10 0 0,0 12,2Z" /></svg>
    **Open Source**
    
    Fork it, tweak it, own it. MIT Licensed.
    **Powered by OpenResty**, the engine behind Cloudflare & Kong.

-   <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" class="card-icon" fill="currentColor"><path d="M12,10L8,14H11V20H13V14H16L12,10M21,16.5C21,16.88 20.79,17.21 20.47,17.38L12.57,21.82C12.41,21.94 12.21,22 12,22C11.79,22 11.59,21.94 11.43,21.82L3.53,17.38C3.21,17.21 3,16.88 3,16.5V7.5C3,7.12 3.21,6.79 3.53,6.62L11.43,2.18C11.59,2.06 11.79,2 12,2C12.21,2 12.41,2.06 12.57,2.18L20.47,6.62C20.79,6.79 21,7.12 21,7.5V16.5Z" /></svg>
    **Polyglot Runtime**

    Run **Python**, **Node.js**, **PHP**, and **Rust** functions side-by-side. 
    Consistent API, seamless integration.

</div>

## More Demos

<div class="grid cards" markdown>

-   **Artistic QR Variants**

    Style QRs (PNG) with optional PIL-based rendering.

    [View Gallery :arrow_right:](./en/tutorial/artistic-qrs.md)

-   **WhatsApp Bot Demo**

    End-to-end WhatsApp demo (QR login + send/receive + optional AI reply) using Node.js.

    [View Tutorial :arrow_right:](./en/tutorial/whatsapp-bot-demo.md)

</div>

## 🌎 Documentation / Documentación

Select your language to view the full documentation.

<div class="grid cards" markdown>

-   **English Documentation**
    
    Start here for tutorials, architecture deep-dives, and API reference.
    
    [Read in English :arrow_right:](./en/index.md)

-   **Documentación en Español**
    
    Comienza aquí para tutoriales, arquitectura y referencia de API.
    
    [Leer en Español :arrow_right:](./es/index.md)

</div>
