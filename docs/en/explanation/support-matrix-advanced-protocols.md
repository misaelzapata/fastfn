# Support Matrix: Advanced Protocols

> Verified status as of **March 13, 2026**.

## Quick View

- Complexity: Intermediate
- Typical time: 10 minutes
- Outcome: clear support posture (`supported`, `adjacent-stack`, `out-of-scope`) for advanced protocol needs

## Support Posture

| Capability | Posture | Why | Recommended path |
|---|---|---|---|
| Sub-app proxying | adjacent-stack | depends on upstream gateway topology | front with dedicated API gateway/reverse proxy |
| Static files | adjacent-stack | better served by CDN/object storage | serve static from CDN, call FastFN for API |
| Templates server-side | adjacent-stack | runtime-specific and stateful concerns | pre-render or dedicated web tier |
| GraphQL server | adjacent-stack | needs dedicated schema/runtime lifecycle | run GraphQL service and call FastFN where needed |
| WebSockets | out-of-scope (core) | long-lived connection model differs from request/response FaaS | use realtime service + HTTP callbacks |

## Decision Guide

- choose FastFN for short-lived HTTP function workloads
- combine with specialized components for persistent connections and heavy template rendering
- keep API contracts stable between components

## Validation

- Chosen architecture documents which part runs in FastFN vs adjacent stack.
- Limits are explicit in implementation docs.

## Troubleshooting

- If websocket-like behavior is needed, switch to polling/SSE or dedicated realtime infra.
- If static/template latency is high, move rendering closer to CDN or edge cache.

## Related links

- [Architecture](./architecture.md)
- [Technical comparison](./comparison.md)
- [Deploy to production](../how-to/deploy-to-production.md)
