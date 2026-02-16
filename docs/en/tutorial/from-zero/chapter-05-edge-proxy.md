# Chapter 5 - Edge Proxy (Workers-style)

In traditional architectures, if your API needs to fetch data from another service (e.g., GitHub API, Stripe, or an internal microservice), your function would:
1. Receive the request.
2. `await fetch(...)` the upstream service.
3. Wait for the response.
4. Send the data back to the client.

This consumes memory and execution time in your function while just "waiting".

**FastFN** has a superpower called **Edge Proxy**. Your function can simply "instruct" the gateway to fetch the data for you right after your function returns.

## Goal
We will configure a function that delegates the fetching of data to the core engine.

## Step 1: Enable Edge Mode

By default, functions are sandboxed. To allow them to tell the router "Go fetch this URL", we need to enable it in the configuration.

Edit (or create) `fn.config.json` in your function folder:

```json title="fn.config.json"
{
  "edge": {
    "base_url": "http://127.0.0.1:8080",
    "allow_hosts": ["127.0.0.1:8080", "api.github.com"],
    "allow_private": true
  }
}
```

!!! info "Configuration Explained"
    *   `base_url`: A shortcut; if you proxy to `/foo`, it maps to `base_url/foo`.
    *   `allow_hosts`: A security whitelist. Only these domains are allowed.
    *   `allow_private`: Set to `true` if you need to access localhost/internal network.

## Step 2: Return a Proxy Directive

Instead of using `axios` or `fetch`, you just return a special JSON object.

=== "Node.js"

    ```js title="index.js"
    exports.handler = async (req) => {
      // Logic: You can inspect headers or validation here first!
      if (!req.headers['x-secret']) {
        return { status: 401, body: "Unauthorized" };
      }

      // Pass-through via the gateway
      return {
        proxy: {
          // Control-plane paths (/_fn/* and /console/*) are blocked. Proxy to a public endpoint instead.
          // In this tutorial we'll proxy to the "hello" endpoint from Chapter 1.
          path: "/hello?name=edge",
          method: "GET",
          headers: {
            "x-proxy-client": "fastfn-fn"
          }
        }
      };
    };
    ```

=== "Python"

    ```python title="main.py"
    def handler(req):
        return {
            "proxy": {
                "path": "/hello?name=edge",
                "method": "GET"
            }
        }
    ```

## Step 3: Verify it works

Run the function. You should see the response from the *target* endpoint (in this case `/hello`), delivered through your function.

```bash
curl -v http://127.0.0.1:8080/my-proxy-fn
```

### Why use this?
*   **Performance:** The gateway (OpenResty/Lua) handles networking efficiently.
*   **Cost model:** Function execution ends when you return the directive; the proxy happens after.
