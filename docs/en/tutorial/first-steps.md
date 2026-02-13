# First Steps <small>🚀</small>

Welcome to **fastfn**. This guide will take you from zero to a fully functional local serverless platform in under **2 minutes**.

---

## 🎯 What we are building

We are not just running a script; we are booting up a **Production-Ready FaaS Platform** locally that includes:

1.  **Gateway (OpenResty)**: Handles routing, security, and load balancing.
2.  **Workers (Python, Node.js, PHP, Rust)**: Persistently running processes ready to execute code instantly.
3.  **Console & Docs**: Built-in UI to manage and test your functions.

---

## 1. Setup & Create Function ⚡️

First, build the CLI tool and initialize your first serverless function.

```bash
# Build the CLI tool
make build-cli

# Create a new function (choose your language: node, python, php, rust)
./bin/fastfn init my-first-func --template node
```

This creates a `my-first-func/` directory with a configuration file and handler code.

---

## 2. Start the Runtime 🚀

Start the platform in development mode. This will mount your current directory (including your new function) into the runtime environment.

```bash
# Start the development server
make dev
```

<div class="result" markdown>
:white_check_mark: **Done.** The platform is now listening on port `8080`.
</div>

!!! tip "Under the Hood"
    `make dev` runs `docker compose up` but dynamically mounts local function directories into the container, enabling hot-reload.

---

## 2. Verify System Health 🏥

Before we run code, let's make sure the brain of the system is active.

=== "Browser"
    Open **[http://127.0.0.1:8080/_fn/health](http://127.0.0.1:8080/_fn/health)**

=== "Terminal"
    ```bash
    curl -sS 'http://127.0.0.1:8080/_fn/health' | jq
    ```

**Expected Output:**
```json
{
  "runtimes": {
    "python": { "health": { "up": true } },
    "node":   { "health": { "up": true } },
    "php":    { "health": { "up": true } },
    "rust":   { "health": { "up": true } }
  }
}
```

If you see `"up": true`, the workers are connected to the gateway via Unix Sockets and are waiting for commands.

---

## 3. First Demo: QR Generator 📞

The platform includes built-in examples. Start with QR:

**Request:**
```bash
curl 'http://127.0.0.1:8080/fn/qr?text=HelloQR' -o /tmp/qr.svg
```

Then check a JSON function:

```bash
curl 'http://127.0.0.1:8080/fn/hello?name=World'
```

!!! question "How did that happen?"
    1.  Request hit **Nginx** at port 8080.
    2.  Nginx saw `/fn/hello` and routed it to the **Lua Controller**.
    3.  Lua checked the discovered function files under `FN_FUNCTIONS_ROOT`.
    4.  It forwarded the request to the resolved runtime socket.
    5.  Worker executed `handler()` and returned the JSON.
    **All in typically < 5ms.**

---

## 4. Explore the Dashboard 🎛️

You don't have to use `curl` for everything. We include a visual console.

Open **[http://127.0.0.1:8080/console/wizard](http://127.0.0.1:8080/console/wizard)** (beginner-friendly step-by-step)

From here you can:
*   See all deployed functions.
*   Edit code in the browser (if enabled).
*   **Test functions** with custom JSON payloads.
*   View execution logs.

!!! note "Console disabled by default"
    The Console UI is off unless you enable it:

    ```bash
    export FN_UI_ENABLED=1
    docker compose up -d --build
    ```

[Next: Write Your First Function :arrow_right:](./your-first-function.md){ .md-button .md-button--primary }

[WhatsApp Bot Demo (QR login + send/receive + AI) :arrow_right:](./whatsapp-bot-demo.md){ .md-button }
