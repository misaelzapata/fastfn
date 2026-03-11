# Visual flows


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
## Public invocation flow

```mermaid
flowchart LR
  A["Client Request"] --> B["OpenResty public route"]
  B --> C{"Method allowed?"}
  C -- "No" --> D["405 + Allow header"]
  C -- "Yes" --> E{"Body size / concurrency ok?"}
  E -- "No" --> F["413 or 429"]
  E -- "Yes" --> G["Build event + context"]
  G --> H["Runtime over Unix socket"]
  H --> I{"Valid runtime response?"}
  I -- "No" --> J["502"]
  I -- "Yes" --> K["HTTP response to client"]
```

## Internal invoke flow (`/_fn/invoke`)

```mermaid
flowchart LR
  A["Console/API invoke payload"] --> B["/_fn/invoke"]
  B --> C["Validate method/policy"]
  C --> D["Inject context.user"]
  D --> E["Route through gateway router"]
  E --> F["Same policy path as external traffic"]
  F --> G["Runtime execution"]
  G --> H["JSON wrapper response"]
```

## Error mapping flow

```mermaid
flowchart TD
  A["Gateway call"] --> B{"Runtime reachable?"}
  B -- "No" --> C["503 runtime down"]
  B -- "Yes" --> D{"Timeout?"}
  D -- "Yes" --> E["504 timeout"]
  D -- "No" --> F{"Contract valid?"}
  F -- "No" --> G["502 invalid runtime response"]
  F -- "Yes" --> H["Return function status/body"]
```

## Problem

What operational or developer pain this topic solves.

## Mental Model

How to reason about this feature in production-like environments.

## Design Decisions

- Why this behavior exists
- Tradeoffs accepted
- When to choose alternatives

## See also

- [Function Specification](../reference/function-spec.md)
- [HTTP API Reference](../reference/http-api.md)
- [Run and Test Checklist](../how-to/run-and-test.md)
