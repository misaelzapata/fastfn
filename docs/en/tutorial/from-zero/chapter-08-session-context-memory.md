# Chapter 8 - Context (Auth + Trace IDs)

**Goal**: Read user context from `event.context` without mixing it into your JSON body.

FastFN extracts a small safe subset of headers and maps them into context.

## 1) Create a `whoami` endpoint

Create `functions/whoami/get.js`:

```js
exports.handler = async (event) => {
  const ctx = event.context || {};
  const user = ctx.user || { id: "anonymous" };

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ok: true,
      request_id: event.id,
      user,
    }),
  };
};
```

## 2) Send user headers

```bash
curl -sS \
  -H 'x-user-id: 123' \
  -H 'x-role: admin' \
  http://127.0.0.1:8080/whoami
```

Expected shape:

```json
{"ok":true,"request_id":"...","user":{"id":"123","role":"admin"}}
```

## 3) Note about internal invocation

FastFN also exposes `POST /_fn/invoke` for internal tooling. It can inject a full JSON context object (including `context.user`) directly.

This is useful for:

- internal test harnesses
- controlled scheduler/job invocations

It is not recommended as a public endpoint.

