# Performance Benchmarks


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
This page publishes reproducible benchmark snapshots for FastFN.

Reporting goals:

- publish workload + limits, not only one RPS number
- publish status mix (`200`, `429`, `5xx`)
- publish reproducible commands
- publish raw result files

## Fast-path (Polyglot “Hello World”)

Snapshot: **Tuesday, February 17, 2026**.

Workload:

- Endpoints (polyglot tutorial):
  - `GET /step-1` (Node)
  - `GET /step-2` (Python)
  - `GET /step-3` (PHP)
  - `GET /step-4` (Rust)
- Runner:
  - `tests/stress/benchmark-fastpath.py`
- Measurement:
  - requests per point: `4000`
  - concurrency matrix: `1,2,4,8,16,20,24,32`

Results (best clean point: **`200` only**):

| Runtime | Endpoint | Best clean point |
|---|---|---:|
| Node | `/step-1` | `1772.69 RPS` (`c=16`) |
| Python | `/step-2` | `878.73 RPS` (`c=16`) |
| PHP | `/step-3` | `562.90 RPS` (`c=20`) |
| Rust | `/step-4` | `866.69 RPS` (`c=20`) |

Raw artifact:

- `tests/stress/results/2026-02-17-fastpath-default.json`

### Reproduce

Start the polyglot tutorial app:

```bash
bin/fastfn dev examples/functions/polyglot-tutorial
```

Run the benchmark:

```bash
python3 tests/stress/benchmark-fastpath.py \
  --base-url http://127.0.0.1:8080 \
  --profile default \
  --total 4000 \
  --concurrency-set 1,2,4,8,16,20,24,32
```

## QR workload (CPU-bound)

QR generation is intentionally more CPU-heavy than JSON fast-path routes.

Runner:

- `cli/benchmark-qr.sh`

Raw artifacts:

- `tests/stress/results/` (date-stamped JSON)

## Notes

- Numbers are environment-specific (host CPU, Docker runtime, local background load).
- Use this page as a baseline and trend reference, not a universal claim.

## Problem

What operational or developer pain this topic solves.

## Mental Model

How to reason about this feature in production-like environments.

## Design Decisions

- Why this behavior exists
- Tradeoffs accepted
- When to choose alternatives

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)

## Methodology and reproducibility

Always report:

- hardware and OS
- runtime mode (`docker` or `native`)
- request mix and payload sizes
- warmup duration and sample size
- p50/p95/p99 latency and error rate

Repro guidance:

- run from clean baseline
- keep config and datasets versioned
- include exact command lines in report
