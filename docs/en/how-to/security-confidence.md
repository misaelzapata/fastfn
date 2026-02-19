# Security Confidence Checklist

This page is a practical security section for teams that want confidence before using FastFN in real environments.

## What is safe by default

FastFN already applies these controls by default:

- strict function filesystem sandbox (`FN_STRICT_FS=1`)
- internal/admin routes separated from public routes
- edge proxy guardrails for control-plane paths (`/_fn/*`, `/console/*`)
- per-function method and body limits
- per-function timeout/concurrency controls
- secret masking when configured as secret values

## What you still must configure in production

Use this baseline every time:

1. Put FastFN behind your reverse proxy (Nginx/Caddy/ALB).
2. Restrict `/_fn/*` and `/console/*` to trusted IPs or private network.
3. Use strong admin token and disable write surface if not needed.
4. Keep function secrets in environment/secret manager, not in source.
5. Enforce host allowlists (`invoke.allow_hosts`, edge allowlists).
6. Use explicit `FN_HOST_PORT` and avoid port conflicts with other services.
7. Monitor health and logs (`/_fn/health`, structured runtime logs).

## Quick trust verification (copy/paste)

```bash
# Health endpoint
curl -sS http://127.0.0.1:8080/_fn/health | jq .

# Internal admin should be blocked from public network path/policy
curl -i -sS http://127.0.0.1:8080/_fn/catalog | sed -n '1,20p'

# Confirm strict fs mode is active in your runtime env
env | rg '^FN_STRICT_FS='
```

## Security boundaries (important)

FastFN reduces risk by default, but it is not a full multi-tenant isolation platform out of the box.  
For strong tenant isolation, add host-level controls (containers, seccomp/cgroups, network segmentation, separate worker hosts).

## Recommended next read

- [Security Model](../explanation/security-model.md)
- [Console and Admin Access](./console-admin-access.md)
- [Deploying to Production](./deploy-to-production.md)
