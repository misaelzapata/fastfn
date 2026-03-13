# History, Design, and Future

> Verified status as of **March 13, 2026**.

## Quick View

- Complexity: Conceptual
- Typical time: 8-12 minutes
- Outcome: context for why FastFN uses file-based routing and polyglot runtimes

## Design Rationale

Core design choices:

- file-system routing for low cognitive load
- runtime polyglot support behind a unified HTTP contract
- OpenAPI-first visibility for local and production workflows

## Tradeoffs

- strong simplicity in route ownership vs fewer framework-level abstractions
- explicit composition patterns instead of heavy DI/decorator systems

## Future Direction

Near-term priorities:

- stronger production deployment workflows
- tighter docs parity and examples coverage
- improved runtime observability and guardrails

## Related links

- [Architecture](./architecture.md)
- [Technical comparison](./comparison.md)
- [Contributing](../how-to/contributing.md)
