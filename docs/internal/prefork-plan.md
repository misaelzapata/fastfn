# Future Design: Prefork Runtime Mode

## Why

Single daemon per runtime is simple but can bottleneck CPU-bound handlers. Prefork mode improves parallelism and isolation.

## Proposed model

- Multiple runtime processes per language.
- One socket per process:
  - `/sockets/fn-python-1.sock`
  - `/sockets/fn-python-2.sock`
- Route config includes runtime pools.
- Gateway does round-robin or least-busy selection.

## Gateway changes

- Extend runtime config from `socket` to `sockets[]`.
- Add socket index in shared dict for round-robin.
- Health-check each socket independently.
- Fallback to healthy sockets when one fails.

## Operational goals

- Zero-downtime rolling restart of runtime workers.
- Per-socket health and error metrics.
- Backpressure before worker saturation.
