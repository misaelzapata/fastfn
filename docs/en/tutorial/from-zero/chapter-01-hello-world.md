# Chapter 1 - Hello World (First Function)

Goal: create one file and call it from your browser or `curl`, using the simplified routing.

## What you are building

A function named `hello-world`.

That means your URL will be:

- `/hello-world`

## Step 1: create the project folder

```bash
mkdir my-functions
cd my-functions
```

## Step 2: create the function file

Create a folder named `hello-world` inside `functions`, and add a `get.js` file.

```bash
mkdir -p functions/hello-world
touch functions/hello-world/get.js
```

Paste this code into `functions/hello-world/get.js`:

```js
exports.handler = async (event) => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    ok: true,
    message: "Hello FastFN",
    method: event.method,
    path: event.path,
  }),
});
```

### What this code means

- `exports.handler`: entry function FastFN executes
- `status: 200`: successful HTTP response
- `headers`: response type (JSON)
- `body`: payload (must be a string)

## Step 3: Run the development server

Use the `fastfn` CLI to start the server:

```bash
fastfn dev functions
```

You should see output indicating the server is running on `http://localhost:8080`.

## Step 4: call your function

Open:

- `http://127.0.0.1:8080/hello-world`

Expected output:

```json
{"ok":true,"message":"Hello FastFN","method":"GET","path":"/hello-world"}
```

## Troubleshooting

1. Portable mode: check if Docker is running.
2. Ensure the file is named `get.js` inside `functions/hello-world/`.
3. Native mode: try `fastfn dev --native functions` and confirm OpenResty is installed.

