# Performance Benchmarks (QR Workload)

This page publishes a reproducible QR benchmark snapshot for **Wednesday, February 11, 2026**.

The reporting style follows practical patterns used by tools like:

- [n8n docs](https://docs.n8n.io/)
- [Windmill docs](https://www.windmill.dev/docs)

Meaning:

- publish workload + limits, not only one RPS number
- publish status mix (`200`, `429`, `5xx`)
- publish reproducible commands
- publish raw result files

## Benchmark profiles

We ran two profiles:

1. **Default policy (guardrails ON)**  
   Function policies unchanged (`max_concurrency=4` for both QR functions).
2. **No-throttle lab profile**  
   Temporary benchmark-only config (`max_concurrency=512`) to observe behavior without gateway throttling.

## Workload

- Endpoints:
  - `/fn/qr` (Python SVG QR)
  - `/fn/qr@v2` (Node PNG QR)
- Domains used as `text` payload:
  - `https://github.com/misaelzapata/fastfn`
  - `https://openai.com`
  - `https://example.org/path?x=1&y=2`
  - `https://n8n.io/workflows`
- Measurement:
  - requests per run: `160` (default profile), `240` (no-throttle profile)
  - concurrency matrix:
    - default: `1,2,4,6,8`
    - no-throttle: `1,2,4,8,16,24,32`

## Results summary

### Default policy (guardrails ON)

| Endpoint | First point with `429` | Best clean point (`200` only) |
|---|---:|---|
| `/fn/qr` | `c=6` | `155.07 RPS` (`c=2`, domain `n8n.io`) |
| `/fn/qr@v2` | `c=6` | `119.14 RPS` (`c=4`, domain `github.com`) |

Interpretation: throttling starts exactly where expected from policy (`max_concurrency=4`).

### No-throttle lab profile

| Endpoint | Clean points (`200` only) | Peak clean RPS in this run |
|---|---:|---|
| `/fn/qr` | `28/28` | `171.89 RPS` (`c=8`, `n8n.io`) |
| `/fn/qr@v2` | `28/28` | `149.58 RPS` (`c=24`, `github.com`) |

Interpretation: with high per-function concurrency limit, both endpoints stayed clean (`200` only) for tested range up to `c=32`.

## Raw artifacts

- `tests/stress/results/2026-02-11-qr-default-policy.json`
- `tests/stress/results/2026-02-11-qr-no-throttle.json`

## Reproduce

```bash
./scripts/benchmark-qr.sh default
./scripts/benchmark-qr.sh no-throttle
```

Optional tuning:

```bash
TOTAL=320 CONCURRENCY_SET=1,2,4,8,16,24,32,48 ./scripts/benchmark-qr.sh no-throttle
```

## Notes

- Numbers are environment-specific (host CPU, Docker runtime, local background load).
- Use this page as an engineering baseline and trend reference, not a universal claim.
