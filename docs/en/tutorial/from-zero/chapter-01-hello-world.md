# Chapter 1 - Hello World (First Function)

Goal: create one file and call it from your browser or `curl`.

## What you are building

A function named `hello-world`.

That means your URL will be:

- `/fn/hello-world`

## Step 1: create the folder

Run exactly:

```bash
mkdir -p srv/fn/functions/node/hello-world
```

## Step 2: create the function file

Create this file:

- `srv/fn/functions/node/hello-world/app.js`

Paste this exact code:

```js
exports.handler = async (event) => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    ok: true,
    message: "Hello fastfn",
    method: event.method,
    path: event.path,
  }),
});
```

### What this code means

- `exports.handler`: entry function fastfn executes
- `status: 200`: successful HTTP response
- `headers`: response type (JSON)
- `body`: payload (must be a string)

## Step 3: call your function

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello-world'
```

Expected output:

```json
{"ok":true,"message":"Hello fastfn","method":"GET","path":"/fn/hello-world"}
```

## Step 4: try in browser

Open:

- `http://127.0.0.1:8080/fn/hello-world`

## If it does not work

1. Check stack is running:

```bash
docker compose ps
```

2. Check logs:

```bash
docker compose logs --tail=100 openresty
```

3. Make sure file path and filename are exact:

- `srv/fn/functions/node/hello-world/app.js`
