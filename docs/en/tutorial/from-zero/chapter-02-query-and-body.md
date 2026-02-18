# Chapter 2 - Query String and Body (Input)

Goal: read user input from URL and request body.

## Quick concepts

- **Query string**: data in URL after `?`
  - Example: `?name=Ana&lang=en`
- **Body**: data sent in POST/PUT/PATCH requests

## Step 1: add a POST handler

FastFN file routes are method-specific. To support `POST /hello-world`, create:

- `functions/hello-world/post.js`

Paste this code into `functions/hello-world/post.js`:

```js
module.exports.handler = async (event) => {
  const query = event.query || {};
  const name = query.name || "world";

  let bodyParsed = null;
  if (event.body && event.body.trim() !== "") {
    try {
      bodyParsed = JSON.parse(event.body);
    } catch (_) {
      bodyParsed = { raw: event.body };
    }
  }

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      hello: name,
      query,
      body: bodyParsed,
      method: event.method,
    }),
  };
};
```

## Step 2: test query input

```bash
curl -sS 'http://127.0.0.1:8080/hello-world?name=Misael&lang=en'
```

Look for:

- `hello: "Misael"`
- `query.lang: "en"`

## Step 3: test JSON body

```bash
curl -sS -X POST 'http://127.0.0.1:8080/hello-world?name=Misael' \
  -H 'content-type: application/json' \
  --data '{"city":"Cordoba","role":"admin"}'
```

Look for:

- `method: "POST"`
- `body.city: "Cordoba"`

## Step 4: test plain text body

```bash
curl -sS -X POST 'http://127.0.0.1:8080/hello-world?name=Misael' \
  -H 'content-type: text/plain' \
  --data 'hello from body'
```

Look for:

- `body.raw: "hello from body"`

## If it does not work

- Confirm you created `functions/hello-world/post.js`.
- Confirm you are calling `POST /hello-world`.
