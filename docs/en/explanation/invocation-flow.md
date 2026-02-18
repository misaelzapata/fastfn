# Invocation Flow

## Public path (`/<name>`)

1. Nginx routes request to `fn_gateway.lua`.
2. Gateway parses the route (for example `/hello`) and optional `@<version>` (for example `/hello@v2`).
3. Discovery resolves runtime (`python`, `node`, `php`, or `rust`) and effective policy.
4. Gateway validates method/body/concurrency.
5. Gateway sends framed JSON to runtime socket.
6. Runtime executes handler and returns `{status, headers, body}`.
7. Gateway returns HTTP response.

## `/_fn/invoke` internal helper

`/_fn/invoke` does not call runtimes directly.

It builds an internal request and routes it through the same gateway routing/policy layer as external clients.
That means method policy, limits, and error mapping are consistent.

## Context forwarding

`/_fn/invoke` can include `context` in payload. It is forwarded via an internal query marker and decoded by gateway into `event.context.user`.
