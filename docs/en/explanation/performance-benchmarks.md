# Performance Benchmarks

> Verified status as of **March 14, 2026**.
> Runtime note: FastFN resolves dependencies and build steps per function: Python uses `requirements.txt`, Node uses `package.json`, PHP installs from `composer.json` when present, and Rust handlers are built with `cargo`. Host runtimes and tools are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

This page publishes reproducible benchmark snapshots for FastFN. The goal is to show real measurements, not broad claims.

## Quick View

- Complexity: Intermediate
- Typical time: 10-25 minutes
- Use this when: you need a baseline before changing daemon counts, queue sizes, or deployment defaults
- Outcome: reproducible numbers and raw artifacts you can compare over time

## Reporting rules

Each benchmark report should include:

- workload shape
- runtime mode (`docker` or `native`)
- concurrency and repeats
- status mix
- raw artifact path

## Fast-path snapshot

Snapshot: **February 17, 2026**.

Workload:

- Endpoints:
  - `GET /step-1` (Node)
  - `GET /step-2` (Python)
  - `GET /step-3` (PHP)
  - `GET /step-4` (Rust)
- Runner: `tests/stress/benchmark-fastpath.py`
- Requests per point: `4000`
- Concurrency matrix: `1,2,4,8,16,20,24,32`

Best clean point (`200` only):

| Runtime | Endpoint | Best clean point |
| --- | --- | ---: |
| Node | `/step-1` | `1772.69 RPS` (`c=16`) |
| Python | `/step-2` | `878.73 RPS` (`c=16`) |
| PHP | `/step-3` | `562.90 RPS` (`c=20`) |
| Rust | `/step-4` | `866.69 RPS` (`c=20`) |

Raw artifact:

- `tests/stress/results/2026-02-17-fastpath-default.json`

## Runtime daemon routing snapshot

Snapshot: **March 14, 2026**.

Workload:

- Fixture: `tests/fixtures/worker-pool`
- Request pattern: `6` concurrent requests, `3` measured repeats, `2` warmup requests per case
- Handler cost: `sleep(200ms)`
- Compared modes:
  - `native`
  - `docker`
- Compared settings:
  - `runtime-daemons = 1`
  - `runtime-daemons = 3`

Results:

| Runtime | Path | Native `1` | Native `3` | Docker `1` | Docker `3` | What this means |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Node | `/slow-node` | `276.7ms` | `243.1ms` | `284.1ms` | `258.9ms` | modest gain in both modes |
| Python | `/slow-python` | `1283.3ms` | `451.6ms` | `1928.0ms` | `450.1ms` | strong gain in both modes |
| PHP | `/slow-php` | `872.9ms` | `953.0ms` | `368.0ms` | `268.6ms` | worse in native, better in Docker |
| Rust | `/slow-rust` | `529.2ms` | `423.3ms` | `329.5ms` | `314.7ms` | better in both modes, but modest in Docker |

Raw artifact:

- `tests/stress/results/2026-03-14-runtime-daemon-scaling-native.json`
- `tests/stress/results/2026-03-14-runtime-daemon-scaling-docker.json`

## How to read these numbers

This benchmark is useful because it shows real tradeoffs instead of one blanket story:

- adding daemons helped Python strongly in both modes
- adding daemons helped Node a little in both modes
- PHP reacted differently between native and Docker
- Rust improved in both modes, but the Docker gain was small enough to treat as workload-dependent

The practical conclusion is simple:

- do not turn on `runtime-daemons > 1` for every runtime by default
- measure the workload you actually care about
- treat `worker_pool` and `runtime-daemons` as separate controls

One more operational point matters here:

- FastFN now exposes socket-level health in `/_fn/health`
- a runtime can remain `up=true` while one socket is `up=false`
- the remaining sockets continue serving traffic while the failed daemon restarts

That behavior is covered by:

- `tests/integration/test-runtime-daemon-failover.sh`

`worker_pool.max_workers` is a per-function admission and queueing control. `runtime-daemons` is a per-runtime routing control. They can work together, but they answer different questions.

## Reproduce the runtime-daemon benchmark

1. Start from a clean stack.
2. Run the benchmark in `native`, `docker`, or both.
3. Keep the same request count, warmup, and concurrency.
4. Save the raw result under `tests/stress/results/`.

Minimal example:

```bash
python3 tests/stress/benchmark-runtime-daemons.py --mode both
```

Validation check:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
```

## Notes

- Results depend on host CPU, background load, and runtime install/build state.
- Native and Docker mode can behave differently, so publish both if you care about both.
- A better average time is useful only if error rate stays acceptable.
- Docker Python with one daemon showed the highest variance in this snapshot, so always inspect the raw samples, not only the average.

## Troubleshooting

- If one runtime looks much slower than expected, inspect `/_fn/health` first and confirm all sockets are up.
- If results vary too much between runs, increase warmup and repeats.
- If PHP or Rust get slower with more daemons, verify that the extra process overhead is not larger than the handler cost.
- If Node or Python do not improve, confirm that the extra daemon count is really active in `/_fn/health`.

## Next step

Continue with [Scale runtime daemons](../how-to/scale-runtime-daemons.md) if you want to tune counts, or [Run and test](../how-to/run-and-test.md) if you want to turn these checks into a repeatable validation flow.

## Related links

- [Architecture](./architecture.md)
- [Function specification](../reference/function-spec.md)
- [Global config](../reference/fastfn-config.md)
- [Scale runtime daemons](../how-to/scale-runtime-daemons.md)
- [Run and test](../how-to/run-and-test.md)
- [HTTP API reference](../reference/http-api.md)
- [Platform runtime plumbing](../how-to/platform-runtime-plumbing.md)
