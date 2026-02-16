# Scheduler vs Cron

FastFN has a built-in scheduler that can auto-invoke functions inside the gateway process. “Cron” is the general concept of time-based scheduling (often implemented by an external service/process).

## TL;DR

- FastFN Scheduler: per-function config in `fn.config.json`, supports **interval** (`every_seconds`) and **cron** (`cron` + `timezone`), plus optional **retry/backoff**.
- Cron systems: typically support richer timezone rules (IANA names), job history/management, and running arbitrary commands (not just HTTP/function calls).

## Run “Every X Minutes”

Use `every_seconds`:

```json
{
  "schedule": {
    "enabled": true,
    "every_seconds": 300,
    "method": "GET",
    "query": { "action": "inc" }
  }
}
```

Rule of thumb:

- `X minutes` = `every_seconds = X * 60`

## Run “At 9am” (Cron + Timezone)

FastFN supports 5-field and 6-field cron expressions and a limited `timezone`:

- `UTC` (or `Z`)
- `local`
- fixed offsets like `-05:00`, `+02:00`

Example (daily at 09:00 UTC):

```json
{
  "schedule": {
    "enabled": true,
    "cron": "0 9 * * *",
    "timezone": "UTC",
    "method": "GET"
  }
}
```

Example (daily at 09:00 with a fixed offset):

```json
{
  "schedule": {
    "enabled": true,
    "cron": "0 9 * * *",
    "timezone": "-05:00",
    "method": "GET"
  }
}
```

## Retry/Backoff (Built-In)

Enable retries for transient failures (429/503/5xx):

```json
{
  "schedule": {
    "enabled": true,
    "cron": "*/1 * * * * *",
    "timezone": "UTC",
    "retry": true
  }
}
```

## Observability

- API snapshot: `GET /_fn/schedules`
- Console view: `/console/scheduler`

## Persistence Between Restarts

FastFN persists scheduler state (last/next/status/errors, plus pending retries) to a local file under your functions root:

- default: `<FN_FUNCTIONS_ROOT>/.fastfn/scheduler-state.json`

Controls:

- `FN_SCHEDULER_PERSIST_ENABLED=0` disables state persistence.
- `FN_SCHEDULER_PERSIST_INTERVAL` controls how often state is flushed (seconds).
- `FN_SCHEDULER_STATE_PATH` overrides the state file path.

## Checklist

- [x] “Call a function every X minutes”: `every_seconds`
- [x] Cron expressions + timezone: `cron` + `timezone`
- [x] Built-in retry/backoff: `schedule.retry`
- [x] Persist scheduler state between restarts: `.fastfn/scheduler-state.json`
- [x] Inspect last/next/last_status/last_error: `/_fn/schedules` + Console

## Known Limits (Current)

- No full IANA timezone names like `America/New_York` (only `UTC`, `local`, fixed offsets).
- Not a distributed job queue (no cross-node coordination, no exactly-once guarantees).
