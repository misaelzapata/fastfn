# Performance Benchmarks

> Verified status as of **April 1, 2026**.
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

## Firecracker image workload matrix

Snapshot: **April 1, 2026**.

Harness:

- Tool: `cd cli && go run ./tools/image-matrix-bench`
- Cases: `20`
- Hot loop: `50` sequential requests after prewarm
- Native host: Linux/KVM with resident Firecracker workloads
- Outputs: Markdown, JSON, CSV, plus per-case logs under the configured `--smoke-dir` and benchmark workspace

Metric meanings:

- `build_or_pull_ms`: time spent building a Dockerfile or pulling/loading an image source
- `bundle_ms`: time to convert the OCI input into the cached Firecracker bundle
- `prewarm_ready_ms`: time until the workload becomes warm and attachable
- `first_ok_ms`: time until the first successful verification response
- `hot_p50_ms`, `hot_p95_ms`, `hot_p99_ms`: steady-state latency after prewarm
- `same_firecracker_pid`: whether the hot loop reused the same Firecracker process before and after the measurement window

Representative results:

| Case | Source | Build/Pull | First OK | Hot p50 | Hot p95 | Hot p99 | Same PID |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Flask (`flask-compose`) | Dockerfile repo | `1168ms` | `5017ms` | `1.94ms` | `3.05ms` | `4.10ms` | `true` |
| Registry app (`traefik/whoami:v1.10.2`) | Registry image | `98ms` | `2508ms` | `1.26ms` | `2.09ms` | `2.28ms` | `true` |
| FastAPI + Postgres (`fastapi-realworld`) | Dockerfile repo + private service | `1202ms` | `17036ms` | `5.29ms` | `7.02ms` | `7.94ms` | `true` |
| Two equal `postgres:16` services | Same OCI, same native `5432` | `1246ms` | `22090ms` | `10.92ms` | `28.85ms` | `32.58ms` | `true` |
| Rust + Postgres (`rust-postgres`) | Dockerfile repo + private service | `35139ms` | `47602ms` | `2.66ms` | `3.86ms` | `10.27ms` | `true` |

What this matrix shows:

- cold build/pull plus prewarm is still measured in seconds
- after prewarm, the resident hot path drops into low single-digit milliseconds for lighter apps and stays in the same order of magnitude for DB-backed apps
- `same_firecracker_pid = true` across the matrix confirms the hot loop reused the same resident microVM instead of restarting Firecracker
- identical OCI services can coexist with the same native port as long as their workload names are different

The full 20-case matrix is produced by the harness itself and written to the configured smoke directory as Markdown/JSON/CSV. The repo docs keep the summary here while the detailed operator bundle is generated outside the repo.

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

Follow-up check after removing per-request PHP process spawning:

- PHP native quick check: `1 daemon = 802.2ms`, `3 daemons = 625.9ms`
- improvement: `22.0%`
- artifact: `tests/stress/results/2026-03-14-php-persistent-check.json`
- practical meaning: the earlier native PHP regression no longer represents the current runtime path

## How to read these numbers

This benchmark is useful because it shows real tradeoffs instead of one blanket story:

- adding daemons helped Python strongly in both modes
- adding daemons helped Node a little in both modes
- PHP originally reacted differently between native and Docker, but the follow-up run improved after removing per-request spawning inside the PHP daemon
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
- If Rust gets slower with more daemons, verify that the extra process overhead is not larger than the handler cost.
- If PHP gets slower again, check first that the runtime is still using persistent PHP workers and not falling back to a one-shot execution path.
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
