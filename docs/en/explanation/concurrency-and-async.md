# Concurrency and Async

> Verified status as of **March 13, 2026**.

## Quick View

- Complexity: Intermediate
- Typical time: 10-15 minutes
- Outcome: practical mental model for concurrency by runtime in FastFN

## Runtime Concurrency Model

| Runtime | Model | Practical note |
|---|---|---|
| Node.js | event loop + async IO | avoid blocking CPU work in request path |
| Python | process + worker model | choose async libraries for IO-heavy tasks |
| Rust | compiled handler with explicit async model choices | keep serialization and IO bounded |
| PHP | persistent daemon handling invocation cycles | minimize per-request bootstrap cost |
| Go | goroutines + concurrency primitives | keep shared state explicit and race-safe |
| Lua | lightweight runtime inside OpenResty flow | keep handler logic short and IO-aware |

## What to Optimize First

1. external IO latency (DB/APIs)
2. payload size and serialization cost
3. timeout budgets and retries

## Validation

- p95 latency is stable under expected concurrency.
- timeouts are explicit and tested.
- retries are bounded and idempotent.

## Troubleshooting

- If p95 degrades, profile IO before optimizing handler CPU.
- If timeouts spike, check downstream rate limits and pool sizing.

## Related links

- [Performance benchmarks](./performance-benchmarks.md)
- [Run and test](../how-to/run-and-test.md)
- [Platform runtime plumbing](../how-to/platform-runtime-plumbing.md)
