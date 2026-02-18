# Chapter 5 - Edge Proxy (Workers-style)

**Goal**: Return a `proxy` directive so the gateway performs an outbound fetch for you.

This is useful when you want:

- an auth check or rewrite in your function,
- then a fast upstream fetch executed by the gateway (OpenResty/Lua).

Important safety behavior:

- Proxying to control-plane paths is blocked: `/_fn/*` and `/console/*` are never allowed.

## Step 1: create a proxy function

Create:

- `functions/edge-proxy/get.js`
- `functions/edge-proxy/fn.config.json`

`functions/edge-proxy/fn.config.json`:

```json
{
  "edge": {
    "base_url": "http://127.0.0.1:8080",
    "allow_hosts": ["127.0.0.1:8080", "api.github.com"],
    "allow_private": true
  },
  "invoke": {
    "summary": "Tutorial edge proxy demo (auth + passthrough)"
  }
}
```

`functions/edge-proxy/get.js`:

```js
exports.handler = async (event) => {
  const headers = event.headers || {};
  const secret = headers["x-secret"] || headers["X-Secret"];

  if (!secret) {
    return {
      status: 401,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
      body: "Unauthorized (missing x-secret)",
    };
  }

  // Pass-through via the gateway (gateway does the fetch).
  return {
    proxy: {
      path: "/hello-world?name=edge",
      method: "GET",
      headers: {
        "x-edge-proxy": "1",
      },
    },
  };
};
```

## Step 2: verify it works

Unauthorized request:

```bash
curl -i -sS 'http://127.0.0.1:8080/edge-proxy' | sed -n '1,20p'
```

Authorized request:

```bash
curl -sS 'http://127.0.0.1:8080/edge-proxy' -H 'x-secret: demo'
```

You should see the response from `/hello-world`, delivered through your function.

## Why use this pattern?

- Performance: the gateway is optimized for outbound networking.
- Cost model: your function returns quickly; the gateway completes the fetch.
- Security: you can enforce allowlists for upstream hosts and block internal control-plane access.

