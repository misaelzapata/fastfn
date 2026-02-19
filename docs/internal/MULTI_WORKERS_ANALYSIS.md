# Multiple Workers Analysis

- Date: 2026-02-19
- Revision: `arch-workers-2026-02-19-r1`
- Applies to: current `main` runtime architecture (OpenResty host + runtime daemons)

## Executive Summary

Implementing "multiple workers" is feasible, but difficulty depends on layer:

- per-function worker pools inside runtime daemons: already partially implemented (`node`, `python`) and medium-complexity to extend.
- multiple daemon instances per runtime behind one socket endpoint: high complexity (socket routing, load balancing, health/retry semantics).
- full prefork model with deterministic routing + graceful drain: high complexity and requires explicit orchestration contracts.

## Current Baseline

- OpenResty gateway dispatches runtime calls over one socket path per runtime.
- Runtime daemons already isolate function execution in worker subprocesses/threads for key runtimes.
- Health model is runtime-socket based (`up/down`), not worker-instance topology aware.

## Complexity Assessment

1. Daemon-internal worker scaling
- Effort: Medium
- Main work:
  - unify worker-pool config schema across runtimes.
  - normalize queue/backpressure semantics (`429` vs `503` policy).
  - align warm/cold visibility in health and debug headers.

2. Multi-daemon per runtime (same host)
- Effort: High
- Main work:
  - socket fan-out (N sockets per runtime) and selection strategy.
  - outlier ejection/retry strategy without duplicate side effects.
  - per-instance health and rolling restart behavior.

3. Prefork + graceful lifecycle
- Effort: High
- Main work:
  - lifecycle coordinator (spawn, drain, rotate, kill).
  - stable in-flight request handling during worker replacement.
  - stronger observability for pool pressure and crash loops.

## Recommended Sequence

1. Stabilize restart + socket preflight first (done in this revision).
2. Standardize daemon-internal worker pool contracts across runtimes.
3. Add runtime-instance metrics and health granularity.
4. Evaluate multi-daemon fan-out only after (2) and (3) are stable.

## Risks

- inconsistent behavior across runtimes if worker-pool policies diverge.
- hidden overload if queue limits are not observable in health/metrics.
- duplicate execution risk on retries when idempotency is not enforced.
