# Chapter 7 - HTML/CSV/PNG Responses

**Goal**: Return content types other than JSON.

FastFN forwards your response headers directly, so `Content-Type` is entirely under your control.

## 1) Returning HTML

Create `functions/render-html/get.js`:

```js
exports.handler = async (event) => {
  const query = event.query || {};
  const name = query.name || "World";
  return {
    status: 200,
    headers: { "Content-Type": "text/html; charset=utf-8" },
    body: `<h1>Hello, ${name}</h1><p>Rendered from FastFN</p>`,
  };
};
```

Test in browser:

- `http://127.0.0.1:8080/render-html?name=Developer`

## 2) Returning CSV (download)

Create `functions/data-export/get.js`:

```js
exports.handler = async () => {
  const csv = "id,name,role\n1,Misael,Admin\n2,Ana,User\n";
  return {
    status: 200,
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": 'attachment; filename="users-export.csv"',
    },
    body: csv,
  };
};
```

Test:

```bash
curl -i -sS 'http://127.0.0.1:8080/data-export' | sed -n '1,20p'
```

## 3) Returning binary (PNG) with base64

Create `functions/png-demo/get.py`:

```python
import base64

PNG_1X1_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII="
)

def main(req):
    return {
        "status": 200,
        "headers": {"Content-Type": "image/png"},
        "is_base64": True,
        "body_base64": PNG_1X1_BASE64,
    }
```

Test (download to a file):

```bash
curl -sS 'http://127.0.0.1:8080/png-demo' --output out.png
file out.png
```

