# Internal Changelog

## 2026-02-19

- Revision: `ops-reliability-2026-02-19-r1`
- Target version: `next patch after current main`
- Scope:
  - native process manager reliability
  - runtime socket safety preflight
  - docker/native parity for runtime restart behavior
  - docs requirements hardening

### Added

- native service manager auto-restart support (default enabled for managed services) with exponential backoff.
- native runtime socket preflight (`in-use` fail, `stale` cleanup, non-socket path fail).
- docker runtime supervisors with restart loop + socket preflight before daemon launch.
- runtime daemon socket safety checks before bind (`node`, `python`, `php`, `rust`, `go`) with embed parity copy update.
- targeted unit coverage for restart/socket preflight behavior in `cli/internal/process`.

### Operational impact

- runtime daemon crashes no longer require manual `fastfn` restart in common cases.
- startup now fails earlier and clearer when socket paths are already occupied by active processes.
- stale socket paths are auto-cleaned before daemon bind, reducing false startup failures.
