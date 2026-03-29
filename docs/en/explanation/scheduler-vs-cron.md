# Scheduler vs Cron


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
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

FastFN supports 5-field and 6-field cron expressions, common macros, and a limited `timezone`:

- `UTC` (or `Z`)
- `local`
- fixed offsets like `-05:00`, `+02:00`, `-0500`, `+0200`
- macros such as `@hourly`, `@daily`, `@midnight`, `@weekly`, `@monthly`, `@yearly`, `@annually`

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
- Pending retries appear as `retry_due` and `retry_attempt` in the scheduler snapshot.

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
- Cron matching uses standard day/month aliases and Vixie-style `OR` semantics for day-of-month vs day-of-week, which is worth remembering when porting schedules from other systems.

## Problem

This answers a common operational question: should a function be triggered by FastFN itself, by a cron-like external service, or by a job runner outside the app?

Use the built-in scheduler when you want:

- the trigger definition to live next to the function in `fn.config.json`
- retries and last-run state to stay visible in `/_fn/schedules`
- the invocation to pass through the same gateway/runtime policy as normal traffic

Use an external scheduler when you need richer timezone support, fleet-wide coordination, or non-HTTP command execution.

## Mental Model

Treat a FastFN schedule as a synthetic HTTP invocation owned by the gateway:

- `every_seconds` is best for simple polling or heartbeat-style jobs
- `cron` is best for wall-clock schedules like "every day at 09:00 UTC"
- `method`, `query`, `headers`, `body`, and `context` become the scheduled request payload
- `last`, `next`, `last_status`, and `last_error` are scheduler state, not function config

## Design Decisions

- The scheduler runs inside the gateway so scheduled traffic follows the same auth, policy, timeout, and runtime path as normal requests.
- Timezone support is intentionally limited to `UTC`, `local`, `Z`, and fixed offsets to keep evaluation deterministic across local dev, Docker, and CI.
- Retries are built in for transient runtime failures, but this is still not a distributed job system.
- If you need IANA timezones, multi-node coordination, job history, or arbitrary shell execution, use an external scheduler.

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
