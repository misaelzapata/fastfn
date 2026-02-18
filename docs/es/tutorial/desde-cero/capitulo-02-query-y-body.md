# Capítulo 2 - Query String y Body (Input)

Objetivo: leer input desde URL y desde el body HTTP.

## Conceptos rápidos

- **Query string**: data en la URL después de `?`
  - Ejemplo: `?name=Ana&lang=es`
- **Body**: data enviada en requests `POST/PUT/PATCH`

## Paso 1: agrega un handler para POST

Con file-routes, cada metodo vive en su propio archivo.

Crea `functions/hello-world/post.js` y pega este codigo:

```js
module.exports.handler = async (event) => {
  const query = event.query || {};
  const name = query.name || "mundo";

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

## Paso 2: prueba query (GET)

```bash
curl -sS 'http://127.0.0.1:8080/hello-world?name=Misael&lang=es'
```

## Paso 3: prueba body JSON (POST)

```bash
curl -sS -X POST 'http://127.0.0.1:8080/hello-world?name=Misael' \
  -H 'content-type: application/json' \
  --data '{"city":"Cordoba","role":"admin"}'
```

## Paso 4: prueba body texto plano (POST)

```bash
curl -sS -X POST 'http://127.0.0.1:8080/hello-world?name=Misael' \
  -H 'content-type: text/plain' \
  --data 'hola desde body'
```

## Si no funciona

- Confirma que creaste `functions/hello-world/post.js`.
- Confirma que estás llamando `POST /hello-world`.
