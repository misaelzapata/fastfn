# Cloudflare-Style Public Assets in FastFN

FastFN can now serve a root-level static folder directly from the gateway, with the same mental model people expect from Cloudflare Workers static assets:

- one configurable public folder
- mounted at `/`
- optional SPA fallback
- optional worker-first precedence

This is not Cloudflare parity 1:1. It is the smallest subset that stays easy to explain, easy to test, and easy to ship across all FastFN runtimes.

## The config

Put this in the root `fn.config.json` of the app:

```json
{
  "assets": {
    "directory": "public",
    "not_found_handling": "single-page-application",
    "run_worker_first": false
  }
}
```

Meaning:

- `directory`: public folder relative to the app root. `public/` and `dist/` are common, but the name is configurable.
- `not_found_handling`: `404` or `single-page-application`.
- `run_worker_first`: when `true`, mapped function routes win first and assets become the fallback.

## The three modes

### 1. Static-first

Use this when the app is mostly static and handlers only fill a few API endpoints.

- existing files under `public/` win first
- function routes are checked only when no asset matches
- good for landing pages with a small `/api-*` surface

Runnable demo:

- `examples/functions/assets-static-first`

### 2. SPA fallback

Use this when the browser router owns deep links like `/dashboard/team`.

- `/dashboard/team` falls back to `public/index.html`
- missing file-like requests such as `/missing.js` still return `404`
- empty folders do not mint fake routes by themselves

Runnable demo:

- `examples/functions/assets-spa-fallback`

### 3. Worker-first

Use this when handlers own the URL space and static files are only a backup shell.

- FastFN checks mapped routes first
- assets only answer when no function route matches
- good when `/hello` should stay a runtime handler even if a static file exists nearby

Runnable demo:

- `examples/functions/assets-worker-first`

## Important edge cases

- The assets directory is excluded from zero-config discovery, so files under `public/` do not accidentally become functions.
- Only the configured assets directory is mounted. Neighboring function folders, dotfiles, and traversal attempts are not exposed as public files.
- `/_fn/*` and `/console/*` stay reserved.
- `GET` and `HEAD` are served directly by the gateway.
- `/` and directory URLs resolve to `index.html`.
- If the app has only an empty assets folder and no real asset, no home override, and no function routes, `/` returns `404` instead of inventing a new public route.

## Dev workflow

`fastfn dev` mounts the whole project root for non-leaf apps, so new folders and routes can appear without restarting the stack.

That matters for public-assets projects because:

- new asset files become visible immediately
- new explicit function folders keep their real function identity
- `handler.*` does not degrade an explicit function into a fake file-route alias

## Where to read the contract

- How-to: [`Zero-Config Routing`](../how-to/zero-config-routing.md)
- Reference: [`Function Specification`](../reference/function-spec.md)
- Explanation: [`Architecture`](../explanation/architecture.md)
