# Security Model

Security in fastfn is layered. The gateway protects routing and policy boundaries, while runtimes enforce execution constraints.

## Scope and assumptions

- Function code is project-owned code.
- User input is untrusted.
- Runtime strict mode is enabled by default.
- This is not kernel-level isolation.

## 1) Edge controls (OpenResty)

Before runtime execution, the gateway enforces:

- function/method routing validation
- per-function method allowlists (`invoke.methods`)
- max body size (`max_body_bytes`)
- timeout and concurrency policy
- normalized error mapping (`404/405/413/429/502/503/504`)
- edge proxy denylist for control-plane paths (`/_fn/*`, `/console/*`)

## 2) Strict filesystem sandbox (runtime, default)

By default (`FN_STRICT_FS=1`), runtime strict mode is enabled.

Current enforcement:

- Python/Node: strict filesystem interception (read/write/subprocess guards); PHP/Lua/Rust apply runtime-level path validation and bounded execution in their runtime models.

Allowed by default:

- function directory
- runtime dependency directories under the function (`.deps`, `node_modules`)
- selected system paths required by runtimes (`/tmp`, cert/timezone paths)

Blocked by default:

- arbitrary reads outside function sandbox
- reading protected platform files from handler code:
  - `fn.config.json`
  - `fn.env.json`
- subprocess spawning from handlers (strict mode)

Optional extension:

- `FN_STRICT_FS_ALLOW=/path1,/path2` to allow extra read/write roots explicitly.

## 3) Secrets handling

Function env is loaded from `fn.env.json` and injected into `event.env` for invocation.

- UI/API masks secrets using `fn.env.json` entries (`{"value":"...","is_secret":true}`).
- Secret values are not shown in clear text in console views.

## 4) Console access controls

Management surface (`/console`, `/_fn/*`) is guarded by flags:

- `FN_UI_ENABLED`
- `FN_CONSOLE_API_ENABLED`
- `FN_CONSOLE_WRITE_ENABLED`
- `FN_CONSOLE_LOCAL_ONLY`
- `FN_ADMIN_TOKEN` (override token via `x-fn-admin-token`)

## 5) Network boundary

Gateway-to-runtime communication uses Unix sockets, not public TCP listeners.

- Python: `unix:/tmp/fastfn/fn-python.sock`
- Node: `unix:/tmp/fastfn/fn-node.sock`
- PHP: `unix:/tmp/fastfn/fn-php.sock`
- Rust: `unix:/tmp/fastfn/fn-rust.sock`

## 6) Current limits

- Runtime sandboxing is language/runtime-level patching, not kernel sandboxing.
- For multi-tenant hard isolation, add host-level controls (containers, seccomp, cgroups, sandboxed workers).
