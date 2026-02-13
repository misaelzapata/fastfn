# Gestionar funciones (API de consola)

Flujo CRUD practico usando endpoints `/_fn/*`.

## Importante: rutas de funciones configurables

Los archivos de funciones viven bajo `FN_FUNCTIONS_ROOT` (no hardcodeado).

Defaults:

- Docker: `/app/srv/fn/functions`
- local repo: `$PWD/srv/fn/functions`

Si quieres fijarlo explicitamente:

```bash
export FN_FUNCTIONS_ROOT="$PWD/srv/fn/functions"
```

## Requisitos

- plataforma en `http://127.0.0.1:8080`
- API habilitada (`FN_CONSOLE_API_ENABLED=1`)
- escritura habilitada (`FN_CONSOLE_WRITE_ENABLED=1`) o token admin

## 1) Revisar catalogo

```bash
curl -sS 'http://127.0.0.1:8080/_fn/catalog'
```

Usalo para confirmar runtimes y ver el `functions_root` activo.

## 2) Crear funcion

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=python&name=demo_new' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{"methods":["GET"],"summary":"Funcion demo"}'
```

## 3) Ver detalle

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=python&name=demo_new&include_code=1'
```

## 4) Actualizar politica (metodos/limites)

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=demo_new' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"timeout_ms":1200,"max_concurrency":5,"max_body_bytes":262144,"invoke":{"methods":["GET","POST"]}}'
```

## 4a) Reutilizar packs de dependencias compartidas (opcional)

Si varias funciones necesitan las mismas dependencias, puedes crear un pack compartido en:

```text
<FN_FUNCTIONS_ROOT>/.fastfn/packs/<runtime>/<pack>/
```

Luego lo asocias a una funcion con `shared_deps`:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=demo_new' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"shared_deps":["common_http"]}'
```

## 4b) Agregar schedule (cron por intervalo)

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=demo_new' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"schedule":{"enabled":true,"every_seconds":60,"method":"GET","query":{"action":"inc"},"headers":{},"body":"","context":{}}}'
```

Ver estado del scheduler:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/schedules'
```

## 5) Actualizar env

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-env?runtime=python&name=demo_new' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"GREETING_PREFIX":"hola"}'
```

## 6) Actualizar codigo

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-code?runtime=python&name=demo_new' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"code":"import json\n\ndef handler(event):\n    q = event.get(\"query\") or {}\n    return {\"status\":200,\"headers\":{\"Content-Type\":\"application/json\"},\"body\":json.dumps({\"ok\":True,\"query\":q})}\n"}'
```

## 7) Invocar por helper interno

```bash
curl -sS 'http://127.0.0.1:8080/_fn/invoke' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{"runtime":"python","name":"demo_new","method":"GET","query":{"name":"Ops"}}'
```

Esto usa `ngx.location.capture('/fn/...')`, por eso aplica la misma politica que trafico publico.

## 7b) Encolar job asincrono (ejecuta luego)

```bash
curl -sS 'http://127.0.0.1:8080/_fn/jobs' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{"name":"demo_new","method":"GET","query":{"name":"Async"}}'
```

Luego consultar:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/jobs/<id>'
curl -sS 'http://127.0.0.1:8080/_fn/jobs/<id>/result'
```

## 8) Eliminar funcion

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=python&name=demo_new' -X DELETE
```

## Errores comunes

- `404`: funcion/version inexistente
- `405`: metodo no permitido por politica
- `409`: ambiguedad por nombre en varios runtimes (o conflicto de rutas mapeadas)
- `403`: escritura bloqueada/local-only
