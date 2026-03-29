# Debugging and Troubleshooting

> Verified status as of **March 27, 2026**.
> Runtime note: FastFN resolves dependencies and build steps per function. Python uses `requirements.txt`, Node uses `package.json`, PHP installs from `composer.json` when present, and Rust handlers are built with `cargo`.

## Quick View

- Complexity: Beginner
- Typical time: 10-15 minutes
- Use this when: a route, runtime, asset, or console action does not behave as expected
- Outcome: you can narrow the issue to discovery, runtime, assets, or documentation

## First check

Before chasing a bug, answer these four questions:

1. Is the request reaching FastFN?
2. Does `/_fn/health` report the runtime as up?
3. Does the route appear in `/_fn/catalog` and `/_fn/openapi.json`?
4. Is the path a function route, an asset, or an internal endpoint?

If you can answer those quickly, most issues become obvious.

## 404, 405, 502, 503

Use these symptoms as a guide:

- `404`: the route was not discovered, was shadowed, or belongs to a private path
- `405`: the route exists, but the method is not allowed by policy or filename
- `502`: the gateway reached a runtime, but the runtime returned a malformed or failed response
- `503`: the runtime is unavailable, unhealthy, or missing

Good commands:

```bash
curl -i 'http://127.0.0.1:8080/hello'
curl -sS 'http://127.0.0.1:8080/_fn/health' | jq
curl -sS 'http://127.0.0.1:8080/_fn/catalog' | jq '{mapped_routes, mapped_route_conflicts}'
curl -sS 'http://127.0.0.1:8080/_fn/openapi.json' | jq '.paths | keys'
```

## What to inspect first

### If a route returns 404

- Confirm the file name and folder layout match the routing convention.
- Check whether a conflicting route is already mapped.
- Confirm the route is not private, ignored, or under a reserved prefix.
- Re-run discovery by restarting the stack or using the reload flow if your setup supports it.

### If a route returns 405

- Confirm the handler filename method prefix, for example `get.`, `post.`, `put.`
- Confirm `fn.config.json` does not restrict the method list
- Confirm the request method is the one you intended

### If you get 502 or 503

- Check `/_fn/health` first
- Check runtime logs next
- Confirm the required runtime binaries are installed in native mode
- Confirm the function entrypoint exists and stays inside the function root

### If the Console behaves oddly

- Confirm the relevant `FN_CONSOLE_*` flags are set
- Check whether the UI is local-only
- Confirm login/session cookies are present if login is enabled

## Logs

FastFN captures handler output and makes it available in the usual places:

- `fastfn dev`: terminal output
- native mode: `fastfn logs --native --file runtime`
- admin/console flows: `/_fn/invoke` and `/_fn/logs`

Example:

```bash
fastfn logs --native --file runtime --lines 50
```

## Assets and SPA

If a static page or asset is missing:

- confirm the configured assets directory exists
- confirm the file is under the configured assets root
- confirm the request is a navigation request if SPA fallback is enabled
- confirm the asset is not larger than the configured limit

If a JSON API unexpectedly returns HTML, the request may be matching SPA navigation heuristics instead of a function route.

## Native vs Docker

- In `fastfn dev`, container logs and the gateway stack matter most
- In `fastfn dev --native`, host binaries and runtime executables matter most
- If a problem happens only in native mode, inspect `FN_*_BIN`, `FN_RUNTIME_SOCKETS`, and `/_fn/health`

## Dependency inference

If Python or Node dependency inference behaves unexpectedly:

- check `metadata.dependency_resolution.infer_backend` first
- if the backend is `pipreqs`, `detective`, or `require-analyzer`, confirm that tool is installed in the environment running the daemon
- remember that external inference is slower than an explicit manifest and is better used as a convenience, not as your only production workflow
- if you already know the packages, add `requirements.txt`, `package.json`, or inline `#@requirements` and re-run

## Related links

- [Run and test](./run-and-test.md)
- [Get help](./get-help.md)
- [Environment variables](../reference/environment-variables.md)
- [Complete config reference](../reference/fn-config-complete.md)
- [Architecture](../explanation/architecture.md)
