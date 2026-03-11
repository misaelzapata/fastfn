# Why FastFN? A Technical Comparison


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
Comparing FastFN to other tools helps clarify where it fits in your stack. FastFN is designed to fill the "gap" between rigid FaaS platforms and traditional web frameworks.

## Summary

| Feature | FastFN | FastAPI / Express | Nginx Unit | Next.js API Routes |
| :--- | :--- | :--- | :--- | :--- |
| **Routing** | File-System (Intuitive) | Code (`@app.get`) | JSON API (Imperative) | File-System |
| **Setup** | Zero Config | Boilerplate | Config API calls | Zero Config |
| **Experience** | "Drop code & run" | "Build app & run" | "Configure listener & apps" | "Drop code & run" |
| **Languages** | Polyglot (Mix & Match) | Single Language | Polyglot | JS/TS Only |
| **Hot Reload** | Instant (Watcher) | Restart App | Reload App | Instant |

## vs FastAPI / Express

Frameworks like FastAPI (Python) or Express (Node) are excellent for building monolithic services.

**The Problem:**
- **Boilerplate**: You need to set up the server, CORS, middleware, and routing manually.
- **Monolith**: As the app grows, `app.py` becomes 5000 lines or you need complex router splitting.
- **Single Language**: You can't easily execute a helper function in Rust for performance or Python for AI within the same Express app.

**The FastFN Solution:**
- **Zero Boilerplate**: There is no app setup. Just write the handler.
- **Micro-functions**: Each file is isolated. Deleting a file deletes the endpoint.
- **Polyglot**: Need to parse a heavy CSV? Write that one endpoint in Rust (`process.rs`) inside your Node.js API structure.

## vs Nginx Unit

Nginx Unit is an excellent polyglot application server.

**The Problem:**
- **Configuration Complexity**: Unit is configured entirely via a REST API with large JSON payloads. It does not auto-discover code.
- **Not a Framework**: It runs apps (like a Django app or Express app), it doesn't solve the "routing inside the app" problem. You still need a router inside your code.
- **Developer Experience**: Setting up a local dev environment with hot-reload and accurate routing usually requires external scripts or manual API calls (PUT /config).

**The FastFN Solution:**
- **Convention over Configuration**: We use the file system. You don't `PUT` a JSON to create a route; you `touch` a file.
- **Dev Server**: `fastfn dev` is built for humans, not sysadmins. It watches files and reloads instantly.

## vs OpenFaaS / Knative

These are "true" FaaS platforms running on Kubernetes.

**The Problem:**
- **Complexity**: Requires Kubernetes, Helm, Docker registries, and image building.
- **Slow feedback loop**: Change code -> Build Container -> Push -> Deploy -> Wait -> Test.
- **Resource Heavy**: Each function is often a full container (or pod).

**The FastFN Solution:**
- **Local First**: Designed to run on a cheap VPS or your laptop with `docker-compose` or just a binary.
- **Execution Model**: Uses pre-warmed worker pools. No container build per function.
- **Instant Feedback**: The "Dev" mode is real-time.

## vs Next.js API Routes

Next.js pioneered the file-system routing Developer Experience (DX).

**The Problem:**
- **JS/TS Only**: You are locked into the Node.js ecosystem.
- **Backend Limitations**: Hard to run system-level code or heavy compute tasks efficiently without blocking the event loop (though Worker threads help).

**The FastFN Solution:**
- **Same DX, Any Language**: We stole the routing model because it's perfect. But we applied it to Python, PHP, Rust, and Go.
- **Isolation**: Each function runs in its own process/worker, effectively sandboxed.

## When to use FastFN?

- **Rapid Prototyping**: Launch an API in minutes.
- **Polyglot Monorepos**: One team writing Python, another Node, all under one URL structure.
- **Self-Hosted FaaS**: When you want AWS Lambda/Vercel DX but on your own EC2 instance or Raspberry Pi.

## Problem

What operational or developer pain this topic solves.

## Mental Model

How to reason about this feature in production-like environments.

## Design Decisions

- Why this behavior exists
- Tradeoffs accepted
- When to choose alternatives

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
