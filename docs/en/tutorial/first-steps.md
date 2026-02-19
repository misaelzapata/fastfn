# First Steps

This guide is the fastest way to understand how FastFN works in practice.

You will:

1. build the CLI
2. start the runtime stack
3. send real API traffic
4. verify health, routing, and OpenAPI consistency

If you are coming from FastAPI or Next.js API routes, this should feel familiar: files define routes, then policy/config layers refine behavior.

## Before you start

From repo root:

```bash
make build-cli
```

This creates `./bin/fastfn`.

Runtime modes:

- `docker` (default, recommended for first run): `./bin/fastfn dev .`
- `native` (requires OpenResty in PATH): `./bin/fastfn dev --native .`

Related references:

- [CLI flags](../reference/cli.md)
- [Deploy mode expectations](../how-to/deploy-to-production.md)
- [Architecture](../explanation/architecture.md)

## 1) Create a first function

Create a minimal function:

```bash
./bin/fastfn init hello --template node
```

This creates a function folder with:

- `fn.config.json` (function policy/config)
- `handler.js` (runtime handler)

Function config reference:

- [Function spec](../reference/function-spec.md)
- [fastfn.json config](../reference/fastfn-config.md)

## 2) Start FastFN

Docker mode:

```bash
./bin/fastfn dev .
```

Native mode:

```bash
./bin/fastfn dev --native .
```

What starts internally:

1. gateway (OpenResty)
2. runtime daemons (Node/Python/PHP/Lua and optional experimental runtimes)
3. file discovery and route map generation

Lifecycle details:

- [Invocation flow](../explanation/invocation-flow.md)
- [Runtime contract](../reference/runtime-contract.md)

## 3) Verify system health

In a new terminal:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health' | jq
```

Expected:

- gateway reachable
- each enabled runtime reports `"up": true`

If runtime health is down:

- check missing dependencies in native mode (`openresty`, `node`, `python3`, etc.)
- check Docker daemon in docker mode

Troubleshooting paths:

- [Run and test checklist](../how-to/run-and-test.md)
- [Operational recipes](../how-to/operational-recipes.md)

## 4) Send your first request

```bash
curl -i 'http://127.0.0.1:8080/hello?name=World'
```

What this validates:

1. public route resolution
2. gateway to runtime socket dispatch
3. handler output normalization to HTTP response

Routing model:

- [Zero-config routing](../how-to/zero-config-routing.md)
- [Next.js style routing rationale](../explanation/nextjs-style-routing-benefits.md)

## 5) Validate docs and route map consistency

OpenAPI:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/openapi.json' | jq '.paths | keys'
```

Catalog:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/catalog' | jq '{mapped_routes, mapped_route_conflicts}'
```

Expected:

- your route exists in both catalog and OpenAPI
- `mapped_route_conflicts` is empty

HTTP/API references:

- [HTTP API](../reference/http-api.md)
- [Built-in endpoints](../reference/builtin-functions.md)

## 6) Stop cleanly

Docker mode:

```bash
docker compose down --remove-orphans
```

Native mode:

- stop with `Ctrl+C` in the `fastfn dev --native` terminal.

## Next links

- [Write your first function](./your-first-function.md)
- [Build a complete API](./build-complete-api.md)
- [Run and test (full validation)](../how-to/run-and-test.md)
