# Serve a SPA and API Together

> Verified status as of **March 27, 2026**.
> This works well with framework build outputs like Vite/React, Vue, Svelte, Astro, or plain static bundles.

One of the nicest FastFN setups is this:

- your SPA build lives in `dist/` or `public/`
- your API handlers live in another folder like `api/`
- FastFN serves both under the same app with almost no config

That means you can ship a simple browser app and a small API together without adding a separate proxy layer first. It is one of the cleanest ways to show FastFN's SPA + API story.

## What we will build

- `/` serves the SPA shell from `dist/index.html`
- `/dashboard` deep-links back to the same SPA shell
- `/api/hello` returns JSON from a normal FastFN handler

## 1. Project layout

```text
my-app/
├── fn.config.json
├── dist/
│   ├── index.html
│   └── assets/
│       └── app.js
└── api/
    └── hello/
        └── handler.js
```

`dist/` can be the output of Vite, React, Vue, Svelte, Astro, or any other SPA build.

## 2. Root config

Create a root `fn.config.json`:

```json
{
  "assets": {
    "directory": "dist",
    "not_found_handling": "single-page-application",
    "run_worker_first": false
  }
}
```

This is the main idea:

- `directory: "dist"` mounts your SPA build at `/`
- `single-page-application` sends deep links like `/dashboard` back to `dist/index.html`
- `run_worker_first: false` keeps the setup simple when your API lives under `/api/*`

## 3. Add one API route

Create `api/hello/handler.js`:

```js
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    ok: true,
    message: "hello from FastFN",
  }),
});
```

That gives you a normal handler at `/api/hello`.

If this API handler needs external packages later, prefer adding an explicit `package.json` or `requirements.txt`.
FastFN can infer dependencies for Python and Node, including optional backends such as `pipreqs`, `detective`, and `require-analyzer`, but that path is slower and is best used as a convenience while bootstrapping.

## 4. Run the app

```bash
fastfn dev .
```

## 5. Try the three important URLs

SPA shell:

```bash
curl -I http://127.0.0.1:8080/
```

SPA deep link:

```bash
curl -I -H 'Accept: text/html' http://127.0.0.1:8080/dashboard
```

API route:

```bash
curl -sS http://127.0.0.1:8080/api/hello
```

Expected API response:

```json
{
  "ok": true,
  "message": "hello from FastFN"
}
```

## Why this setup is strong

- your frontend can stay a normal framework build output
- your API stays file-based and easy to grow
- local dev stays one command
- the SPA and the API share one base URL
- you do not need to introduce a custom reverse proxy just to get started

## Static-first vs worker-first

For the simplest SPA + API setup, keep your API under `/api/*` and leave `run_worker_first` as `false`.

If you want handler routes to win before static files, switch to:

```json
{
  "assets": {
    "directory": "dist",
    "not_found_handling": "single-page-application",
    "run_worker_first": true
  }
}
```

That is useful when a framework build produces a path that should lose to a runtime handler.

## Runnable examples

- `examples/functions/assets-spa-fallback`
- `examples/functions/assets-worker-first`
- `examples/functions/assets-static-first`

## See also

- [Zero-Config Routing](../how-to/zero-config-routing.md)
- [Function Specification](../reference/function-spec.md)
- [Cloudflare-Style Public Assets](../articles/cloudflare-style-public-assets.md)
