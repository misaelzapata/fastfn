# From Zero Tutorial (Absolute Beginner)

If this is your first time building a function, start here.

This tutorial assumes **zero prior knowledge** of fastfn.

## What is fastfn in one sentence?

`fastfn` lets you put code in a folder and call it like an HTTP endpoint.

Example endpoint:

- `http://127.0.0.1:8080/fn/hello-world`

## What you need before Chapter 1

1. Docker Desktop running.
2. This repo cloned on your machine.
3. Terminal open in repo root.

## Start the stack

```bash
docker compose up -d
```

## Confirm it is alive

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health'
```

You should see JSON output. If you get `connection refused`, wait a few seconds and try again.

## Folder you will use

All chapters use this folder:

- `srv/fn/functions/node/hello-world`

## Learning path

1. [Chapter 1 - Hello World](./chapter-01-hello-world.md)
2. [Chapter 2 - Query String and Body](./chapter-02-query-and-body.md)
3. [Chapter 3 - Environment Variables (`fn.env.json`)](./chapter-03-env.md)
4. [Chapter 4 - Function Metadata and Methods (`fn.config.json`)](./chapter-04-meta-and-methods.md)
5. [Chapter 5 - Edge Proxy (Workers-style)](./chapter-05-edge-proxy.md)
6. [Chapter 6 - External Libraries](./chapter-06-external-libraries.md)
7. [Chapter 7 - HTML/CSV/PNG Responses](./chapter-07-rich-responses.md)
8. [Chapter 8 - Session, Context, and Basic Memory](./chapter-08-session-context-memory.md)
9. [Chapter 9 - Shared Dependencies and Shared Config Patterns](./chapter-09-shared-deps-env.md)
