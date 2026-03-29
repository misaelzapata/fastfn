# FastFN Examples

This directory collects runnable examples that mirror real FastFN usage.

## Start here

- [functions/next-style](functions/next-style/README.md) for file-based routing with multiple runtimes
- [functions/assets-static-first](functions/assets-static-first/README.md) for the static-first assets demo
- [functions/assets-spa-fallback](functions/assets-spa-fallback/README.md) for SPA fallback behavior
- [functions/assets-worker-first](functions/assets-worker-first/README.md) for routes before assets
- [functions/rest-api-methods](functions/rest-api-methods/README.md) for method-based routing
- [functions/versioned-api](functions/versioned-api/README.md) for versioned route layouts
- [functions/platform-equivalents](functions/platform-equivalents/README.md) for cross-platform patterns
- [functions/polyglot-tutorial](functions/polyglot-tutorial/README.md) for a step-by-step learning path
- [functions/node/auto-infer-node-multi-deps](functions/node/auto-infer-node-multi-deps/README.md) and [functions/python/auto-infer-python-multi-deps](functions/python/auto-infer-python-multi-deps/README.md) for optional dependency inference with several packages

## How the examples are grouped

- Some folders are grouped by runtime, for example `node/`, `python/`, `php/`, `rust/`, `go/`, and `lua/`
- Some folders are grouped by product pattern, for example `assets-*`, `next-style`, `rest-api-methods`, and `versioned-api`
- Some folders are meant to be read as mini guides with a matching `README.md`

## Suggested path for new users

1. Read `functions/README.md`
2. Open one small runtime example, like [node/node-echo](functions/node/node-echo/handler.js) or [python/hello](functions/python/hello/handler.py)
3. Try one routing example, like [rest-api-methods](functions/rest-api-methods/README.md) or [next-style](functions/next-style/README.md)
4. Finish with one assets example, like [assets-spa-fallback](functions/assets-spa-fallback/README.md)

## Notes

- Many examples auto-install dependencies when you run them
- Explicit manifests are still the fast path; the inference demos are there to show the optional bootstrap workflow
- Some examples are intentionally advanced and are better used after the basics
- If an example has its own `README.md`, start there first
