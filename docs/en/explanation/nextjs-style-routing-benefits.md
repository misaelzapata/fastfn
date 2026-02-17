# Next.js-Style Routing: Practical Benefits in FastFN

This document summarizes why FastFN moved to Next.js-style routing (technical: file-based routing with dynamic-segment conventions) as the default DX and what was validated in real runs.

## 1. Faster Development Loop

- No mandatory `fn.config.json` per endpoint.
- Runtime is inferred from extension (`.js`, `.py`, `.php`, `.rs`, `.go`).
- New files and folders are picked up in dev without restarting (`fastfn dev` mounts full root).

Result:

- Fewer manual config steps.
- Less drift between code and routing config.

## 2. Clear, Predictable URL Mapping

File naming maps directly to routes:

- `users/index.js` -> `GET /users`
- `users/[id].js` -> `GET /users/:id`
- `blog/[...slug].py` -> `GET /blog/:slug*`
- `post.users.[id].py` -> `POST /users/:id`

This removes hidden routing rules and makes paths discoverable by reading the tree.

## 3. Safe Overrides Instead of “All-or-Nothing”

Precedence is deterministic:

1. `fn.config.json`
2. `fn.routes.json`
3. file-based routes

Important behavior:

- Empty/invalid `fn.config.json` does not break discovery.
- `fn.routes.json` overrides only overlapping route+method pairs.
- Non-overlapping file routes remain active.

This keeps explicit control where needed while preserving zero-config convenience.

## 4. Multi-App Monorepo Support

`fastfn dev <root>` supports multiple apps/directories in one run.

Validated examples:

- `GET /nextstyle-clean/users` -> 200
- `GET /nextstyle-clean/blog/a/b` -> 200
- `POST /nextstyle-clean/admin/users/123` -> 200
- `GET /items` -> 200 (from `polyglot-demo/fn.routes.json`)
- `POST /items` -> 200
- `GET /items/123` -> 200
- `DELETE /items/123` -> 200

This enables one local stack for mixed demos/services.

## 5. Better Polyglot Story

In a single root, Node/Python/PHP/Rust routes can coexist naturally.

Validated with:

- Playwright E2E: `6 passed`
- Integration script (`tests/integration/test-multilang-e2e.js`): all checks passed
- CLI tests: passed
- Discovery unit coverage: `89.6%`

## 6. Operational Visibility (Warm/Cold)

Gateway now signals runtime state:

- `X-FastFN-Function-State: cold|warm`
- `X-FastFN-Warmed: true` on cold-start success
- `X-FastFN-Warming: true` + `Retry-After: 1` while warming

For compiled Rust handlers, first-hit build timing is bounded and configurable:

- `FN_RUST_BUILD_TIMEOUT_S` (default `20`)

This reduces ambiguity during cold starts and helps debugging.

## 7. Internal Surface Can Be Disabled Cleanly

Validated behavior with:

- `FN_DOCS_ENABLED=0`
- `FN_ADMIN_API_ENABLED=0`

Results:

- `GET /_fn/docs` -> 404
- `GET /_fn/openapi.json` -> 404
- `GET /_fn/catalog` -> 404
- User routes (for example `GET /docs/a/b`) still work (`200`)

So internal tooling can be off in hardened environments without sacrificing app routes.

## 8. Why This Is Better Than `/fn/*`-Only DX

- Lower setup friction.
- Better source-of-truth: route is near handler code.
- Easier onboarding for teams already using file-based routing conventions.
- More scalable for monorepos and mixed languages.
- Cleaner migration path: explicit config and manifest still work where needed.
