# Capitulo 2 - Query String y Body

Objetivo: leer parametros URL y body HTTP.

## Ejemplo

```js
exports.handler = async (event) => {
  const query = event.query || {};
  const name = query.name || "mundo";
  const bodyText = event.body || "";

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      hello: name,
      body_len: bodyText.length,
      query,
    }),
  };
};
```

## Pruebas

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello_world?name=Misael' | jq .
curl -sS -X POST 'http://127.0.0.1:8080/fn/hello_world?name=Misael' \
  -H 'content-type: text/plain' \
  --data 'hola desde body' | jq .
```
