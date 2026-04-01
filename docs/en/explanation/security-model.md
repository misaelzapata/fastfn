# Security Model

> Verified status as of **April 1, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.

Security in FastFN is layered. The gateway protects routing and policy boundaries, runtimes enforce execution constraints for functions, and Firecracker-backed image workloads add a separate public-access policy plus a private workload-to-workload network.

## Scope and assumptions

- Function code is project-owned code.
- User input is untrusted.
- Runtime strict mode is enabled by default.
- This is not kernel-level isolation.

## 1) Edge controls

Before FastFN reaches a runtime or a resident app broker, the gateway enforces:

- function and method routing validation
- per-function method allowlists (`invoke.methods`)
- per-function host allowlists (`invoke.allow_hosts`)
- max body size (`max_body_bytes`)
- timeout and concurrency policy
- normalized error mapping (`404/405/413/429/502/503/504`)
- denylist protection for control-plane paths such as `/_fn/*` and `/console/*`

For public image workloads, the same edge also enforces the simple firewall:

- `access.allow_hosts` on HTTP endpoints
- `access.allow_cidrs` on HTTP and TCP public endpoints
- cumulative matching when both host and CIDR lists exist on one HTTP endpoint
- trusted proxy handling through `FN_TRUSTED_PROXY_CIDRS`

## 2) Strict filesystem sandbox for functions

By default (`FN_STRICT_FS=1`), runtime strict mode is enabled.

Current enforcement:

- Python and Node use strict filesystem interception for reads, writes, and subprocess calls.
- PHP, Lua, Rust, and Go apply runtime-level path validation and bounded execution inside their runtime model.

Allowed by default:

- the function directory
- runtime dependency directories under the function (`.deps`, `node_modules`)
- selected system paths required by runtimes (`/tmp`, certificate paths, timezone data)

Blocked by default:

- arbitrary reads outside the function sandbox
- reading protected platform files from handler code:
  - `fn.config.json`
  - `fn.env.json`
- subprocess spawning from handlers while strict mode is on

Optional extension:

- `FN_STRICT_FS_ALLOW=/path1,/path2` to allow extra read/write roots explicitly

## 3) Secrets handling

Function env is loaded from `fn.env.json` and injected into `event.env` for invocation.

- UI and API views mask secrets stored as `{"value":"...","is_secret":true}` entries.
- Secret values are not shown in clear text in console views.
- Public workload state keeps credential-bearing URLs redacted; credentials stay in env vars instead of being embedded into exposed `*_URL` fields.

## 4) Console access controls

Management surface (`/console`, `/_fn/*`) is guarded by flags:

- `FN_UI_ENABLED`
- `FN_CONSOLE_API_ENABLED`
- `FN_CONSOLE_WRITE_ENABLED`
- `FN_CONSOLE_LOCAL_ONLY`
- `FN_ADMIN_TOKEN` (override token via `x-fn-admin-token`)

## 5) Network boundaries

Gateway-to-runtime communication uses Unix sockets, not public TCP listeners.

- Python: `unix:/tmp/fastfn/fn-python.sock`
- Node: `unix:/tmp/fastfn/fn-node.sock`
- PHP: `unix:/tmp/fastfn/fn-php.sock`
- Rust: `unix:/tmp/fastfn/fn-rust.sock`

Firecracker image workloads add two more boundaries:

- public traffic goes through stable host-side brokers
- private workload traffic goes through guest loopback aliases plus host-mediated `vsock` bridges

Important distinctions:

- public access policy applies only to public app/service endpoints
- private `*.internal` traffic is not filtered by `allow_hosts` or `allow_cidrs`
- folder-local `fn.config.json` scopes which apps/services are visible to descendant folders, but does not expose them publicly by itself

Practical firewall example:

```json
{
  "app": {
    "dockerfile": "./Dockerfile.fastfn",
    "context": ".",
    "port": 8000,
    "routes": ["/*"],
    "access": {
      "allow_hosts": ["app.example.com", "*.corp.example.com"],
      "allow_cidrs": ["203.0.113.0/24"]
    }
  }
}
```

Rules:

- `allow_hosts` is HTTP-only.
- `allow_cidrs` accepts both CIDRs and single IPs.
- TCP public ports only support `allow_cidrs`.
- Only proxies listed in `FN_TRUSTED_PROXY_CIDRS` can influence client IP through forwarding headers.

## 6) Current limits

- Runtime sandboxing is language/runtime-level patching, not kernel sandboxing.
- For multi-tenant hard isolation, add host-level controls such as containers, seccomp, cgroups, or sandboxed workers.
- Firecracker workloads in this branch require Linux/KVM.
- Host bind mounts are not part of the storage boundary for Firecracker workloads in this branch.
- The public workload firewall is intentionally simple. It is useful for coarse allowlists, not as a replacement for a dedicated WAF or identity-aware proxy.

## See also

- [Architecture](./architecture.md)
- [Function Specification](../reference/function-spec.md)
- [Global Config](../reference/fastfn-config.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
