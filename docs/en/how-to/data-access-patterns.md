# Data Access Patterns

> Verified status as of **March 13, 2026**.

## Quick View

- Complexity: Intermediate
- Typical time: 20-30 minutes
- Outcome: consistent SQL/async SQL/NoSQL integration patterns in FastFN functions

## SQL Starter Pattern

Principles:

- keep connection config in env
- initialize client lazily
- keep query timeout bounded

Neutral path example: `functions/orders/get.*`

```bash
curl -sS 'http://127.0.0.1:8080/orders?id=1'
```

## Async SQL Pattern

Use async drivers/runtime-friendly IO when available, but keep the same HTTP envelope.

Minimum contract:

- `200` with `data`
- `404` when record missing
- `500` with non-sensitive error code

## NoSQL Adapter Pattern

Keep repository interface stable:

- `get_by_id(id)`
- `list(filters)`
- `upsert(record)`

Then swap SQL/NoSQL backend without changing handler contract.

## Validation

- Queries run with bounded timeout.
- Missing record returns deterministic `404` shape.
- Backend swap does not break route response envelope.

## Troubleshooting

- If connections fail in native mode, verify local service reachability.
- If latency spikes, log query duration and payload size.
- If schema drifts, enforce migration/version tags in stored records.

## Related links

- [Configuration and secrets](../tutorial/from-zero/3-config-and-secrets.md)
- [Run and test](./run-and-test.md)
- [Bigger app structure](./bigger-app-structure.md)
