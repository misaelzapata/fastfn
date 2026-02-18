# Capitulo 4 - Metadatos y Metodos (`fn.config.json`)

Objetivo: controlar metodos HTTP, timeout, concurrencia y metadata que aparece en Swagger/OpenAPI.

## Paso 1: crea `fn.config.json`

Crea `functions/hello-world/fn.config.json`:

```json
{
  "timeout_ms": 1500,
  "max_concurrency": 10,
  "max_body_bytes": 262144,
  "invoke": {
    "summary": "Funcion hello-world del tutorial",
    "methods": ["GET"],
    "query": { "name": "World" },
    "body": ""
  }
}
```

Notas:

- En layout de file-routes, un `fn.config.json` sin `runtime`/`name`/`entrypoint` es un **overlay de policy** para todos los handlers debajo de esa carpeta.
- Aca bloqueamos `POST` a proposito (aunque el Capitulo 2 creo `post.js`) para mostrar el comportamiento de `405`.

## Paso 2: valida el policy

Permitido (GET):

```bash
curl -i -sS 'http://127.0.0.1:8080/hello-world' | sed -n '1,12p'
```

Bloqueado (POST):

```bash
curl -i -sS -X POST 'http://127.0.0.1:8080/hello-world' --data '{}' | sed -n '1,20p'
```

Esperado: `405 Method Not Allowed`.

## Paso 3: confirma en Swagger

Abre `http://127.0.0.1:8080/docs` y verifica que solo aparezca `GET /hello-world`.

