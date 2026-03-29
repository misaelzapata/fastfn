# Platform Runtime Plumbing

> Verified status as of **March 13, 2026**.

## Quick View

- Complexity: Advanced
- Typical time: 25-35 minutes
- Outcome: predictable request pipeline behavior (middleware-style hooks, CORS, raw request access, events)

## Request Pipeline Boundaries

FastFN request path:

1. Route resolution
2. Method/guard checks
3. Runtime dispatch
4. Response normalization

Equivalent to middleware responsibilities in other stacks: keep policy checks before business code.

## CORS Matrix

| Scenario | Origin | Methods | Headers | Credentials | Result |
|---|---|---|---|---|---|
| Public read API | specific domains | `GET` | minimal | no | safest default |
| Dashboard backend | trusted domain | `GET,POST,PUT,DELETE` | auth headers | yes | strict allowlist |
| Internal tools | private network | all needed | explicit list | optional | keep network-restricted |

Example check:

```bash
curl -i 'http://127.0.0.1:8080/items' \
  -H 'Origin: https://app.example.com' \
  -H 'Access-Control-Request-Method: POST'
```

## Using Raw Request Directly

Use `event` fields directly for edge cases:

- `event.method`
- `event.headers`
- `event.query`
- `event.path`
- `event.body`

This is useful for custom signature verification or low-level protocol adaptation.

## Lifecycle Events and Timing

Operational events to observe:

- startup (OpenResty + runtime daemons)
- health checks (`/_fn/health`)
- graceful shutdown / restart
- runtime process crash + restart path

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health'
```

## Validation

- CORS preflight and simple requests behave consistently.
- Policy checks reject unauthorized traffic before runtime handler logic.
- Health endpoint reflects runtime up/down state.

## Troubleshooting

- If CORS fails, confirm exact `Origin` and response headers.
- If preflight passes but request fails, inspect method guards and auth checks separately.
- If requests hang, verify runtime daemon socket health.

## Related links

- [Run and test](./run-and-test.md)
- [Deploy to production](./deploy-to-production.md)
- [Architecture](../explanation/architecture.md)
