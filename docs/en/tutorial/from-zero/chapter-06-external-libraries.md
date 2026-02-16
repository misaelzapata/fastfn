# Chapter 6 - External Libraries

Goal: install dependencies per function.

## Node example

1. Create `package.json` in your function folder:

`srv/fn/functions/node/hello-world/package.json`

```json
{
  "name": "hello-world",
  "private": true,
  "dependencies": {
    "dayjs": "^1.11.13"
  }
}
```

2. Use the dependency in `app.js`:

```js
const dayjs = require("dayjs");

exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ now: dayjs().toISOString() }),
});
```

3. Invoke:

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello-world' | jq .
```

## Python equivalent

- Add `requirements.txt`
- Import package in `app.py`
- Return normal `{status, headers, body}`
