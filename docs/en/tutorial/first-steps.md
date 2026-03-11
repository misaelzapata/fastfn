# Quick Start


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
Welcome to FastFN! This guide is the fastest way to experience the magic of file-based routing and automatic OpenAPI generation.

If you are coming from FastAPI or Next.js API routes, you'll feel right at home: drop a file, get an endpoint. Zero boilerplate.

## 1. Initialize your project

Let's build your first API endpoint. In FastFN, your folder structure is your API. Open your terminal and run:

```bash
fastfn init hello --template node
```

This creates `node/hello/` with a `handler.js` file. That's it! You just created an API endpoint.

## 2. Start the development server

Start FastFN in your current directory:

```bash
fastfn dev .
```

Behind the scenes, FastFN spins up an OpenResty gateway, starts the runtimes needed by discovered handlers, and maps folders to live HTTP routes.

!!! note "What installs automatically (and what does not)"
    - FastFN auto-installs function dependencies from `requirements.txt` / `package.json` next to the handler.
    - FastFN does not install host runtimes (`python`, `node`, etc.).
    - In `fastfn dev` (portable mode), Docker must be running.
    - In `fastfn dev --native`, OpenResty + host runtimes are required.

!!! info "How a request flows through FastFN"
    ```mermaid
    flowchart LR
      A["Client Request"] --> B["OpenResty public route"]
      B --> C{"Method allowed?"}
      C -- "No" --> D["405 + Allow header"]
      C -- "Yes" --> E["Build event + context"]
      E --> F["Runtime over Unix socket"]
      F --> G["HTTP response to client"]
    ```

## 3. See the Magic: Automatic Interactive Docs

FastFN automatically generates OpenAPI 3.1 documentation for every function you create. 

Open your browser and navigate to:
👉 **[http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs)**

![Swagger UI showing FastFN routes](../../assets/screenshots/swagger-ui.png)

You can test your endpoint directly from this UI! Click on the `GET /hello` route, click "Try it out", and hit "Execute".

## 4. Call your API

You can also call your new endpoint using your browser or `curl`:

```bash
curl -i 'http://127.0.0.1:8080/hello?name=World'
```

**Expected Output:**
```json
{
  "status": 200,
  "body": "Hello World"
}
```

### Simple response shortcut

In `node`, `php`, and `lua` you can return a direct value (without full envelope), and FastFN normalizes it.

Example (Node):

```js
exports.handler = async () => "Hello World";
```

Result for `GET /hello`:

- HTTP `200`
- `Content-Type: text/plain; charset=utf-8`
- body: `Hello World`

For cross-runtime portability (including `go` and `rust`), prefer explicit `{ status, headers, body }`.

## 5. Stop the server

When you are done, simply press `Ctrl+C` in the terminal where `fastfn dev` is running to stop the server cleanly.

## Next Steps

Notice how you didn't have to write any routing logic or configure a server? 
- Learn how to use dynamic parameters in [Routing & Parameters](./routing.md).
- Dive deep with our [From Zero Course](./from-zero/index.md).

## Objective

Clear scope, expected outcome, and who should use this page.

## Prerequisites

- FastFN CLI available
- Runtime dependencies by mode verified (Docker for `fastfn dev`, OpenResty+runtimes for `fastfn dev --native`)

## Validation Checklist

- Command examples execute with expected status codes
- Routes appear in OpenAPI where applicable
- References at the end are reachable

## Troubleshooting

- If runtime is down, verify host dependencies and health endpoint
- If routes are missing, re-run discovery and check folder layout

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
