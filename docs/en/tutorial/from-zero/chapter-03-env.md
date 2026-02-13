# Chapter 3 - Environment Variables (`fn.env.json`)

Goal: configure values without hardcoding in code.

## Why this matters

You do not want this in code:

- API keys
- tokens
- environment mode (`dev`, `prod`)

Use `fn.env.json` instead.

## Step 1: create `fn.env.json`

Path:

- `srv/fn/functions/node/hello_world/fn.env.json`

Content:

```json
{
  "APP_MODE": { "value": "dev", "is_secret": false },
  "WELCOME_PREFIX": { "value": "Hi", "is_secret": false },
  "MY_API_KEY": { "value": "change-me-locally", "is_secret": true }
}
```

## What `is_secret` means

- `true`: UI/API should mask this value
- `false`: safe to show in config views

The function still receives both values in `event.env`.

## Step 2: update `app.js`

```js
exports.handler = async (event) => {
  const env = event.env || {};
  const query = event.query || {};
  const name = query.name || "world";

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      message: `${env.WELCOME_PREFIX || "Hello"} ${name}`,
      app_mode: env.APP_MODE || "unknown",
      has_api_key: Boolean(env.MY_API_KEY),
    }),
  };
};
```

## Step 3: test

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello_world?name=Ana'
```

Expected fields:

- `message: "Hi Ana"`
- `app_mode: "dev"`
- `has_api_key: true`

## If values do not change

1. Confirm file path:
   - `srv/fn/functions/node/hello_world/fn.env.json`
2. Confirm valid JSON syntax.
3. Wait a few seconds for hot reload, or restart stack:

```bash
docker compose restart openresty
```

## Security note

Never commit real production keys in git.
