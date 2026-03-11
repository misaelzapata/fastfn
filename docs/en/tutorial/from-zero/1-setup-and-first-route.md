# Part 1: Setup and Your First Route


> Verified status as of **March 10, 2026**.
> Runtime note: FastFN auto-installs function-local dependencies from `requirements.txt` / `package.json`; host runtimes are required in `fastfn dev --native`, while `fastfn dev` depends on a running Docker daemon.
Welcome to the FastFN course! In this first part, we'll set up our "Task Manager API" project and create an endpoint that returns a list of tasks.

## 1. Create the Project

Let's start by creating a folder for our API and initializing our first function. Open your terminal and run:

```bash
mkdir task-manager-api
cd task-manager-api
fastfn init tasks --template node
```

This creates a `tasks` folder with a `handler.js` file. In FastFN, your folder structure is your API. The `tasks` folder automatically becomes the `/tasks` endpoint.

## 2. Write the Code

Open `tasks/handler.js` (or `.py`, `.php`, `.rs` depending on your preferred language) and replace its contents with the following code:

=== "Python"
    ```python
    def handler(event):
        tasks = [
            {"id": 1, "title": "Learn FastFN", "completed": False},
            {"id": 2, "title": "Build an API", "completed": False}
        ]

        return {
            "status": 200,
            "body": tasks
        }
    ```

=== "Node.js"
    ```javascript
    exports.handler = async (event) => {
        const tasks = [
            { id: 1, title: "Learn FastFN", completed: false },
            { id: 2, title: "Build an API", completed: false }
        ];

        return {
            status: 200,
            body: tasks
        };
    };
    ```

=== "PHP"
    ```php
    <?php
    return function($event) {
        $tasks = [
            ["id" => 1, "title" => "Learn FastFN", "completed" => false],
            ["id" => 2, "title" => "Build an API", "completed" => false]
        ];

        return [
            "status" => 200,
            "body" => $tasks
        ];
    };
    ```

### What this code means
- **`handler`**: The entry function FastFN executes.
- **`status: 200`**: The successful HTTP response code.
- **`body`**: The payload. FastFN automatically serializes arrays and objects into JSON for you!

## 3. Run the Server

Start the FastFN development server from the root of your `task-manager-api` folder:

```bash
fastfn dev .
```

Open your browser and navigate to `http://127.0.0.1:8080/tasks`. You should see your list of tasks returned as JSON!

![Browser showing JSON response at /tasks](../../../assets/screenshots/browser-json-tasks.png)

## Next Steps

You now have a working API endpoint. In the next part, we'll learn how to fetch a specific task using dynamic routing (`/tasks/1`) and how to add new tasks by reading the request body.

[Go to Part 2: Routing and Data :arrow_right:](./2-routing-and-data.md)

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
