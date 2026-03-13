# Bigger App Structure

> Verified status as of **March 13, 2026**.

## Quick View

- Complexity: Intermediate
- Typical time: 25 minutes
- Outcome: scalable repository layout with clear ownership and background task patterns

## Recommended Structure

```text
functions/
  _shared/
  api/
    users/
    orders/
  jobs/
    render-report/
  webhooks/
```

Guidelines:

- isolate shared logic in `_shared`
- keep API routes and background jobs separate
- use explicit names for cross-team ownership

## Background/Scheduled Execution Pattern

Use scheduler/job functions for non-request work:

- cron trigger receives minimal payload
- function fetches work unit
- idempotency key prevents duplicate side effects

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health'
```

## Validation

- API routes and jobs are discoverable without ambiguity.
- Job functions are idempotent.
- Ownership boundaries map to folders.

## Troubleshooting

- If route collisions happen, check folder depth and method files.
- If jobs duplicate execution, add lock/idempotency key.
- If modules are reused too widely, split by domain to reduce coupling.

## Related links

- [Zero-config routing](./zero-config-routing.md)
- [Manage functions](./manage-functions.md)
- [Data access patterns](./data-access-patterns.md)
