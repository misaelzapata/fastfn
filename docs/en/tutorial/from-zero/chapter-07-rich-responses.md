# Chapter 7 - HTML/CSV/PNG Responses

Goal: return non-JSON payloads correctly.

## HTML

```js
return {
  status: 200,
  headers: { "Content-Type": "text/html; charset=utf-8" },
  body: "<h1>Hello</h1><p>This is HTML</p>",
};
```

## CSV

```js
return {
  status: 200,
  headers: {
    "Content-Type": "text/csv; charset=utf-8",
    "Content-Disposition": "inline; filename=data.csv"
  },
  body: "name,value\\nfoo,1\\nbar,2\\n",
};
```

## PNG

Use existing demos for quick verification:

```bash
curl -sS 'http://127.0.0.1:8080/fn/png_demo' --output out.png
file out.png
```

```bash
curl -sS 'http://127.0.0.1:8080/fn/qr?text=hello' --output qr.png
file qr.png
```
