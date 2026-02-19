# Workers Compatibility (Beta): port Cloudflare Workers and Lambda into FastFN

This beta feature reduces migration overhead so teams can reuse existing handlers with minimal changes.

## Goal

Port existing code with small deltas:

- Cloudflare Workers (`fetch(request, env, ctx)`)
- AWS Lambda Node/Python (`handler(event, context)`), including Node callback handlers (`handler(event, context, callback)`).

## Current beta scope

Implemented for:

- Node
- Python

Per-function activation in `fn.config.json`:

```json
{
  "invoke": {
    "adapter": "cloudflare-worker"
  }
}
```

Supported values:

- `native` (default): FastFN contract (`handler(event)`)
- `aws-lambda`
- `cloudflare-worker`

## Real 1:1 mapping examples

### 1) Cloudflare Worker (real repo example)

Reference used:

- [advissor/nodejs-cloudflare-workers/src/index.js](https://github.com/advissor/nodejs-cloudflare-workers/blob/main/src/index.js)

That example uses:

- `export default { async fetch(request, env) { ... } }`
- CORS preflight
- path versioning (`/api/v1/...`)
- `Response` JSON output

In FastFN beta, business logic maps 1:1. Current practical Node delta is export syntax (CommonJS):

```js
module.exports = {
  async fetch(request, env, ctx) {
    return new Response('ok');
  },
};
```

`fn.config.json`:

```json
{
  "invoke": {
    "adapter": "cloudflare-worker"
  }
}
```

### 2) AWS Lambda Node (official docs)

Official reference:

- [AWS Lambda Node.js handler](https://docs.aws.amazon.com/lambda/latest/dg/nodejs-handler.html)

`aws-lambda` adapter supports:

- async handler: `handler(event, context)`
- callback handler: `handler(event, context, callback)`

AWS official note:

- AWS recommends async/await and documents callback-based handlers as supported only up to Node.js 22.

`fn.config.json`:

```json
{
  "invoke": {
    "adapter": "aws-lambda"
  }
}
```

## Node callback example

```js
exports.handler = (event, context, callback) => {
  callback(null, {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ok: true, requestId: context.awsRequestId }),
  });
};
```

## Beta notes

- `cloudflare-worker` reproduces handler shape and core request/response behavior, not Cloudflare isolate/distributed infrastructure.
- For Workers-style in Node today, `module.exports.fetch = ...` is the most stable form.
- In Lambda callback mode, FastFN resolves on the first valid completion (callback or Promise), with double-resolution guards.

## Full plan

### Phase 0 (done)

1. `invoke.adapter` per function.
2. Node/Python `aws-lambda` compatibility.
3. Node/Python `cloudflare-worker` compatibility.
4. Node Lambda callback support.
5. Dedicated adapter unit tests.

### Phase 1 (next)

1. Native Node ESM support for `export default { fetch }`.
2. 1:1 provider fixtures under `tests/fixtures/compat/`.
3. Adapter contract tests (headers/query/status/binary/errors).

### Phase 2 (hardening)

1. `ctx.waitUntil` observability and cancellation policy.
2. Clear parity boundary doc (what is emulated vs not emulated).
3. CI regression matrix for adapters.

### Phase 3 (beta to stable)

1. Exit criteria (coverage, stability, migration feedback).
2. Provider migration guides.
3. Compatibility versioning strategy if needed.

## References

- [Cloudflare: How Workers works](https://developers.cloudflare.com/workers/reference/how-workers-works/)
- [Cloudflare Worker example repo](https://github.com/advissor/nodejs-cloudflare-workers/blob/main/src/index.js)
- [AWS Lambda Node.js handlers](https://docs.aws.amazon.com/lambda/latest/dg/nodejs-handler.html)
