# FastAPI / Next.js Style Playbook

## Quick View

- Complexity: Advanced
- Typical time: 45-90 minutes
- Use this when: you are migrating a FastAPI or Next.js API surface
- Outcome: route and policy parity are validated with rollout checkpoints


This is the operational playbook for teams migrating from:

- FastAPI-style backend APIs
- Next.js API routes and file-based routing

It is optimized for practical delivery: route parity, policy parity, and release tracking.

## Migration objective

Deliver the same external API behavior while moving execution to FastFN:

- same public paths
- same allowed methods
- same auth/host policy
- same response contracts

## Stage 1: map current API surface

Before touching code, generate a baseline map:

1. list public routes and methods
2. list auth and host restrictions
3. list request/response contract assumptions

Use this table format:

| Route | Methods | Current service | Auth rule | Notes |
|---|---|---|---|---|
| `/users` | `GET` | FastAPI | Bearer | list users |
| `/users/{id}` | `GET` | FastAPI | Bearer | fetch one |
| `/health` | `GET` | Next API route | public | basic health |

## Stage 2: create route structure in FastFN

Use file-based routing first, then add policy only where required.

Example layout:

```text
functions/
  python/
    users/
      get.py
      [id]/
        get.py
  node/
    health/
      get.js
```

Routing rules:

- [Zero-config routing](./zero-config-routing.md)
- [Function spec](../reference/function-spec.md)

## Stage 3: apply policy and explicit routes

Use `fn.config.json` when you need:

- explicit `invoke.routes`
- `invoke.allow_hosts`
- timeout/concurrency/body limits
- controlled override behavior with `invoke.force-url`

Do not force route override globally unless you are in a migration cutover window.

References:

- [Function spec (`invoke.routes`, `invoke.force-url`)](../reference/function-spec.md)
- [Global `FN_FORCE_URL` config](../reference/fastfn-config.md)

## Stage 4: verify parity with concrete checks

Run these checks on every migration branch:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health' | jq
curl -sS 'http://127.0.0.1:8080/_fn/openapi.json' | jq '.paths | keys'
curl -sS 'http://127.0.0.1:8080/_fn/catalog' | jq '{mapped_routes, mapped_route_conflicts}'
```

Then run integration suites:

```bash
bash tests/integration/test-openapi-system.sh
bash tests/integration/test-api.sh
```

If native mode is part of your release target:

```bash
bash tests/integration/test-openapi-native.sh
```

## Stage 5: documentation and tracking gates

For each migrated route group:

- update function docs/examples
- update OpenAPI expectations in tests
- add rollout notes for changed behavior

Recommended tracking checklist:

- [ ] all baseline routes are mapped in FastFN
- [ ] no unexpected `mapped_route_conflicts`
- [ ] OpenAPI methods match route policy methods
- [ ] auth policy parity validated on representative endpoints
- [ ] CI integration suite green

## Stage 6: rollout strategy

Safe rollout pattern:

1. mirror traffic in staging
2. compare response status/body/header signatures
3. switch traffic gradually per route group
4. keep `invoke.force-url` only during cutover, then remove

Related guides:

- [Run and test](./run-and-test.md)
- [Deploy to production](./deploy-to-production.md)
- [Security confidence](./security-confidence.md)
