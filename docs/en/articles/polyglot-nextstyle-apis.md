# Polyglot APIs with File-Based Routing in FastFN


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
FastFN now supports a practical polyglot workflow: one gateway, one routing model, multiple runtimes in the same app tree.

This article summarizes what that means in real projects and why it reduces operational friction.

## 1) One URL model across languages

With file-based routing, paths come from filenames, not per-runtime adapters.

Example from `examples/functions/next-style`:

- `users/index.js` -> `GET /users` (Node)
- `users/[id].js` -> `GET /users/:id` (Node)
- `blog/[...slug].py` -> `GET /blog/:slug*` (Python)
- `php/get.profile.[id].php` -> `GET /php/profile/:id` (PHP)
- `rust/get.health.rs` -> `GET /rust/health` (Rust)
- `admin/post.users.[id].py` -> `POST /admin/users/:id` (Python)

The important part is parity: the routing rules stay the same even when runtime changes.

## 2) Runtime choice becomes a file-level decision

In a polyglot service, teams often migrate endpoint-by-endpoint:

- Keep stable paths.
- Rewrite one handler in another language.
- Keep OpenAPI and gateway policy behavior consistent.

Because runtime is inferred from extension (`.js`, `.py`, `.php`, `.rs`), this migration path is incremental and low-risk.

## 3) Explicit overrides still work

You are not locked into pure file routing:

1. `fn.config.json` (highest priority)
2. `fn.routes.json`
3. file-based routes

This allows mixed strategies:

- Most routes zero-config.
- Selected routes explicitly mapped in `fn.routes.json`.
- Special policy/runtime tuning in `fn.config.json`.

In `tests/fixtures/polyglot-demo`, this pattern is used to mix Node/Python/PHP/Rust handlers with explicit route mapping.

## 4) Unified OpenAPI for mixed runtimes

A common polyglot problem is fragmented docs per language stack.

FastFN generates one gateway-level OpenAPI from discovered routes, so consumers see one API surface even when handlers are split across runtimes.

Operationally, this helps:

- SDK generation from one spec.
- Cleaner contract reviews.
- Fewer mismatches between teams.

## 5) Better local dev for monorepos

`fastfn dev <root>` mounts the full root in development, so adding new files/folders is reflected without manual remount workflows.

For polyglot repos, this avoids the classic issue where one runtime hot-reloads but another requires rebuild scripts.

## 6) Warm/cold visibility across runtimes

Responses expose runtime state headers:

- `X-FastFN-Function-State: cold|warm`
- `X-FastFN-Warmed: true`
- `X-FastFN-Warming: true` with `Retry-After: 1`

This matters more in polyglot setups, where startup behavior differs by runtime (for example Rust first-build vs interpreted runtimes).

## 7) Practical adoption path

Recommended sequence:

1. Start with file-based routes in one folder.
2. Add cross-runtime endpoints in the same tree.
3. Introduce `fn.routes.json` only where explicit control is needed.
4. Keep `fn.config.json` for policy/concurrency/timeouts, not for every route.
5. Validate with integration suite before rollout.

Result: one platform contract, language flexibility, and lower operational overhead than maintaining separate gateways per runtime.

## Key takeaway

The biggest win is not just "many languages." It is one URL tree, one deployment surface, and one OpenAPI document even when different teams choose different runtimes.

## What to keep in mind

- File extension decides the runtime, but the URL comes from the same folder rules everywhere.
- Keep shared policy in `fn.config.json`; use `fn.routes.json` only when you really need an override.
- Validate warm and cold behavior in each runtime before moving latency-sensitive endpoints.

## When this approach is worth it

- Use it when teams share one API surface but not one language.
- Keep a single runtime if the whole service has the same tooling and performance needs.
- Use explicit route overrides for legacy paths or special cases, not as the default way to build new endpoints.

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
