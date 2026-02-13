# Chat Dump: OpenResty + Multi-Runtime FaaS

## High-level conversation timeline

1. Initial idea: execute route handlers with OpenResty/Lua in Lambda-like style.
2. Constraint added: avoid "yet another server".
3. Python execution requested: discussed subprocess model and JSON contract.
4. Daemon model introduced: OpenResty host + runtime daemon over Unix socket.
5. Clarification: OpenResty can spawn daemons but is not a robust process supervisor.
6. Runtime expansion: same pattern applied to Node and PHP tradeoffs discussed.
7. Unified architecture selected: OpenResty host + multiple runtimes behind a common contract.
8. Versioning, health gates, timeout policies, and concurrency limits requested.
9. Prefork desired for future complexity; implementation deferred and documented.
10. Deliverable requested as Codex-ready project with docs and examples.

## Decisions captured

- Keep OpenResty as single HTTP entrypoint.
- Use framed JSON over Unix sockets.
- Use strict allowlists both in gateway and runtimes.
- Keep runtime transport non-HTTP.
- Map runtime failure modes to deterministic HTTP status codes.
- Document prefork mode as next phase.
