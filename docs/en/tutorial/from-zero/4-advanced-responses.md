# Part 4: Advanced Responses


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
So far, our Task Manager API has only returned JSON. But FastFN is a full web framework. You can return HTML, CSVs, images, and set custom HTTP headers.

## 1. Returning HTML

Let's create a simple web page to view our tasks. Create a new folder called `view` and add a `handler.js` (or `.py`, `.php`) inside it.

```text
task-manager-api/
├── tasks/
│   └── ...
└── view/
    └── handler.js     # -> GET /view
```

To return HTML, you just need to set the `Content-Type` header and pass a string as the body:

=== "Python"
    ```python hl_lines="4 5"
    def handler(event):
        html = "<h1>My Tasks</h1><ul><li>Learn FastFN</li></ul>"
        return {
            "status": 200,
            "headers": {"Content-Type": "text/html; charset=utf-8"},
            "body": html
        }
    ```

=== "Node.js"
    ```javascript hl_lines="4 5"
    exports.handler = async (event) => {
        const html = `<h1>My Tasks</h1><ul><li>Learn FastFN</li></ul>`;
        return {
            status: 200,
            headers: { "Content-Type": "text/html; charset=utf-8" },
            body: html
        };
    };
    ```

=== "PHP"
    ```php hl_lines="4 5"
    <?php
    return function($event) {
        $html = "<h1>My Tasks</h1><ul><li>Learn FastFN</li></ul>";
        return [
            "status" => 200,
            "headers" => ["Content-Type" => "text/html; charset=utf-8"],
            "body" => $html
        ];
    };
    ```

Open `http://127.0.0.1:8080/view` in your browser, and you'll see a rendered HTML page!

![Browser rendering HTML response at /view](../../../assets/screenshots/browser-html-view.png)

## 2. Custom Headers and Redirects

You can use the `headers` object to control browser behavior, like setting cookies or performing redirects.

Let's say we want to redirect users from `/old-tasks` to our new `/tasks` endpoint. Create `old-tasks/handler.js`:

=== "Python"
    ```python
    def handler(event):
        return {
            "status": 301,
            "headers": {"Location": "/tasks"}
        }
    ```

=== "Node.js"
    ```javascript
    exports.handler = async (event) => {
        return {
            status: 301, // Permanent Redirect
            headers: { "Location": "/tasks" }
        };
    };
    ```

=== "PHP"
    ```php
    <?php
    return function($event) {
        return [
            "status" => 301,
            "headers" => ["Location" => "/tasks"]
        ];
    };
    ```

## Congratulations! 🎉

You've completed the "From Zero" course! You've built a Task Manager API that handles dynamic routing, reads request bodies, manages secrets, enforces HTTP methods, and returns rich HTML responses.

You now have all the core skills needed to build production-ready applications with FastFN.

### Where to go next?
- Check out the [FastAPI/Next.js Playbook](../../how-to/fastapi-nextjs-playbook.md) to migrate existing apps.
- Learn how to [Deploy to Production](../../how-to/deploy-to-production.md).
- Explore the [HTTP API Reference](../../reference/http-api.md) for advanced details.

## Objective

Clear scope, expected outcome, and who should use this page.

## Prerequisites

- FastFN CLI available
- Runtime dependencies by mode verified (Docker for `fastfn dev`, OpenResty+runtimes for `fastfn dev --native`)

## Validation Checklist

- Command examples execute with expected status codes
- Routes appear in OpenAPI where applicable
- References at the end are reachable

## Troubleshooting

- If runtime is down, verify host dependencies and health endpoint
- If routes are missing, re-run discovery and check folder layout

## See also

- [Function Specification](../../reference/function-spec.md)
- [HTTP API Reference](../../reference/http-api.md)
- [Run and Test Checklist](../../how-to/run-and-test.md)
