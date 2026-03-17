# FastFN Doctor for Domains and CI


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
`fastfn doctor` gives a single entry point to validate local prerequisites and domain readiness.

## Why this matters

Domain issues are usually discovered too late:
- DNS points to the wrong target
- TLS is expired or close to expiring
- HTTP does not redirect to HTTPS
- ACME challenge path is blocked

`fastfn doctor domains` catches these before deployment.

## Quick start

```bash
fastfn doctor
fastfn doctor --json
```

Domain check:

```bash
fastfn doctor domains --domain api.example.com
fastfn doctor domains --domain api.example.com --expected-target lb.example.net
```

CI-friendly output:

```bash
fastfn doctor domains --domain api.example.com --json
```

## Configure domains in `fastfn.json`

```json
{
  "domains": [
    "api.example.com",
    {
      "domain": "www.example.com",
      "expected-target": "lb.example.net",
      "enforce-https": true
    }
  ]
}
```

Then run:

```bash
fastfn doctor domains
```

## Check contract (OK/WARN/FAIL)

- `domain.format`: hostname syntax validation.
- `dns.resolve`: A/AAAA/CNAME resolution.
- `dns.target`: expected DNS target match (when configured).
- `tls.handshake`: certificate validity for host.
- `tls.expiry`: expiry window (warns when near expiration).
- `https.reachability`: basic HTTPS response.
- `http.redirect`: HTTP -> HTTPS policy.
- `acme.challenge`: reachability of `/.well-known/acme-challenge/...`.

## Safe auto-fix

`fastfn doctor --fix` applies only local safe changes.

Current safe fix:
- create a minimal `fastfn.json` when missing.

## Key takeaway

Use `fastfn doctor domains` as a preflight for your public edge, not as a generic app health check. It tells you whether the hostname, DNS target, TLS, redirect policy, and ACME path look correct from the outside before you switch traffic.

## What to keep in mind

- Run it after DNS changes, before certificate renewals, and in CI before a release.
- Use `--json` when you want machine-readable output for pipelines or deployment gates.
- Set `expected-target` only when you know the final DNS target you want to enforce.

## When to pick another tool

- Use application health endpoints for upstream bugs, database failures, or slow dependencies.
- Use ongoing monitoring for continuous reachability and certificate-expiry alerts.
- Use `fastfn doctor --fix` only for local setup help; it intentionally avoids rewriting remote DNS or TLS state.

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
