# Scale Runtime Daemons

> Verified status as of **March 14, 2026**.

## Quick View

- Complexity: Intermediate
- Typical time: 15-25 minutes
- Use this when: one runtime is the bottleneck and you want more than one socket target for it
- Outcome: FastFN starts multiple daemon instances for a runtime and routes across healthy sockets with `round_robin`

## What this changes

`runtime-daemons` is a global runtime setting. It is different from `worker_pool.max_workers`.

- `runtime-daemons` adds more daemon processes and sockets for a runtime.
- `worker_pool` stays at the gateway and controls admission and queueing per function.

Use `runtime-daemons` when you want more routing targets for a runtime such as Node or Python.

## Step 1: Add daemon counts

`fastfn.json`

```json
{
  "functions-dir": "functions",
  "runtime-daemons": {
    "node": 3,
    "python": 3
  }
}
```

You can also use the string form:

```json
{
  "runtime-daemons": "node=3,python=3"
}
```

Notes:

- Counts default to `1`.
- `lua` ignores daemon counts because it runs in-process.
- This setting is only meaningful for external runtimes.

## Step 2: Optionally choose the host binaries

If native mode should use a specific interpreter or toolchain, set `runtime-binaries`:

```json
{
  "runtime-binaries": {
    "python": "python3.12",
    "node": "node20",
    "openresty": "/opt/homebrew/bin/openresty"
  }
}
```

One important rule:

- FastFN chooses one executable per key.
- Every daemon in that runtime group uses the same configured executable.

If you prefer environment variables:

```bash
export FN_PYTHON_BIN=python3.12
export FN_NODE_BIN=node20
export FN_OPENRESTY_BIN=/opt/homebrew/bin/openresty
```

## Step 3: Start the stack

Native mode:

```bash
FN_RUNTIMES=node,python fastfn dev --native functions
```

Docker mode:

```bash
FN_RUNTIME_DAEMONS=node=3,python=3 fastfn dev functions
```

## Step 4: Confirm routing and socket health

Check health:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
```

What to look for:

- `routing: "round_robin"` for runtimes with more than one socket
- a `sockets` array with one entry per daemon
- `up: true` at both the runtime and socket level

If you enabled debug headers in a function config, responses can also include:

- `X-Fn-Runtime-Routing`
- `X-Fn-Runtime-Socket-Index`

One important behavior to verify:

- a runtime can stay available even if one daemon socket is down
- `/_fn/health` shows that degraded socket in the `sockets` list
- traffic keeps flowing through the remaining healthy sockets

The repository now has an integration check for this exact case:

```bash
bash tests/integration/test-runtime-daemon-failover.sh
```

## Step 5: Measure before keeping it on

Do not assume more daemons are always better.

The benchmark snapshot verified on **March 14, 2026** showed runtime-dependent results: some runtimes improved a lot, some only a little, and one native PHP path regressed before a follow-up fix.

Read the canonical numbers and raw artifacts here:

- [Performance benchmarks](../explanation/performance-benchmarks.md)

## Advanced override: explicit sockets

If you need full control over socket locations, use `FN_RUNTIME_SOCKETS`:

```bash
export FN_RUNTIME_SOCKETS='{"node":["unix:/tmp/fastfn/node-1.sock","unix:/tmp/fastfn/node-2.sock"],"python":"unix:/tmp/fastfn/python.sock"}'
fastfn dev --native functions
```

This override wins over `runtime-daemons`.

## Validation

Use this quick sequence:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
curl -i http://127.0.0.1:8080/hello
```

Expected:

- health returns `200`
- the target runtime shows the expected socket count
- the public route still returns the same functional response

## Troubleshooting

- If the daemon count seems ignored, check whether you are scaling `lua`.
- If a runtime stays down, confirm the binary selection first (`FN_*_BIN` or `runtime-binaries`).
- If only one socket appears, confirm there is no explicit `FN_RUNTIME_SOCKETS` override.
- If one socket is down but the runtime is still up, traffic should continue through the remaining sockets while the supervisor restarts the failed daemon.
- If performance gets worse, keep the count at `1` for that runtime and measure again later with a heavier workload.

## Related links

- [Global config](../reference/fastfn-config.md)
- [Function specification](../reference/function-spec.md)
- [HTTP API reference](../reference/http-api.md)
- [Architecture](../explanation/architecture.md)
- [Performance benchmarks](../explanation/performance-benchmarks.md)
- [Platform runtime plumbing](./platform-runtime-plumbing.md)
- [Run and test](./run-and-test.md)
