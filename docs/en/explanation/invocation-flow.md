# Invocation Flow and ngx.location.capture

## `/fn/...` public path

1. Nginx routes request to `fn_gateway.lua`.
2. Gateway parses `<name>` and optional `@<version>`.
3. Discovery resolves runtime (`python`, `node`, `php`, or `rust`) and effective policy.
4. Gateway validates method/body/concurrency.
5. Gateway sends framed JSON to runtime socket.
6. Runtime executes handler and returns `{status, headers, body}`.
7. Gateway returns HTTP response.

## `/_fn/invoke` internal helper

`/_fn/invoke` does not call runtimes directly.

It builds an internal request and runs:

- `ngx.location.capture('/fn/...')`

So it reuses exactly the same gateway path, method policy, limits, and response behavior as external clients.

## Context forwarding

`/_fn/invoke` can include `context` in payload. It is forwarded via an internal query marker and decoded by gateway into `event.context.user`.
